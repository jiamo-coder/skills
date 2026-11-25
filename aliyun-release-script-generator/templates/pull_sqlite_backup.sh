#!/usr/bin/env bash
set -euo pipefail
umask 077

MODE="${1:-pull}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PO_DEPLOY_ENV_FILE="${PO_DEPLOY_ENV_FILE:-$DEPLOY_DIR/.deploy.local.sh}"
source "$PO_DEPLOY_ENV_FILE"
PROJECT="${PO_PROJECT_NAME:-$(basename "${PO_REMOTE_ROOT:?PO_REMOTE_ROOT is required}")}"
REMOTE_DIR="${PO_REMOTE_BACKUP_DIR:-$PO_REMOTE_DATA_DIR/backups}"
LOCAL_DIR="${PO_LOCAL_BACKUP_DIR:-$HOME/Backups/aliyun/$PROJECT}"
CHECK_TIMEOUT="${PO_DB_CHECK_TIMEOUT_SEC:-3600}"
TRANSFER_TIMEOUT="${PO_DB_TRANSFER_TIMEOUT_SEC:-3600}"
MAX_AGE_HOURS="${PO_BACKUP_MAX_AGE_HOURS:-48}"
KEEP_DAYS="${PO_BACKUP_LOCAL_KEEP_DAYS:-30}"
source "$SCRIPT_DIR/ssh_transport.sh"
PO_APPROVED_DEPLOY_ENV="${PO_DEPLOY_ENV:?PO_DEPLOY_ENV is required}"
po_transport_init
po_check_login
for n in "$CHECK_TIMEOUT" "$TRANSFER_TIMEOUT" "$MAX_AGE_HOURS" "$KEEP_DAYS"; do
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid backup timeout or retention' >&2; exit 1; }
done
[[ "$REMOTE_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo 'Unsafe remote backup path' >&2; exit 1; }
mkdir -p "$LOCAL_DIR"
limited() { perl -e 'alarm shift @ARGV; exec @ARGV or die $!' "$1" "${@:2}"; }
remote() { limited "$TRANSFER_TIMEOUT" "${PO_SSH_PREFIX[@]}" ssh -T -p "$PO_DEPLOY_PORT" "${PO_SSH_OPTIONS[@]}" "$PO_SSH_TARGET" "$1"; }
fetch() { limited "$TRANSFER_TIMEOUT" "${PO_SSH_PREFIX[@]}" scp -P "$PO_DEPLOY_PORT" "${PO_SSH_OPTIONS[@]}" "$PO_SSH_TARGET:$1" "$2" >/dev/null; }
file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

mkdir -p "$LOCAL_DIR"
manifest_list="$(remote "find '$REMOTE_DIR' -maxdepth 1 -type f -name 'db-*.sqlite.manifest' -print | sort -r")"
[[ -n "$manifest_list" ]] || { echo 'No remote SQLite backups found' >&2; exit 1; }

validate_manifest() {
  local manifest="$1" stamp="$2" size="$3" sha="$4" file="$5"
  [[ "$stamp" =~ ^[0-9]+$ && "$size" =~ ^[0-9]+$ && "$sha" =~ ^[a-f0-9]{64}$ && "$file" =~ ^db-[0-9]{8}T[0-9]{6}Z\.sqlite$ ]] || { echo "Invalid backup manifest: $manifest" >&2; return 1; }
  [[ "$manifest" == "$REMOTE_DIR/$file.manifest" ]] || return 1
}

check_one() {
  local manifest="$1" stamp size sha file extra local_file proof proof_stamp proof_size proof_sha proof_file proof_mtime
  local manifest_tmp="$(mktemp "$LOCAL_DIR/.manifest.XXXXXX")"
  fetch "$manifest" "$manifest_tmp"
  IFS=$'\t' read -r stamp size sha file extra < "$manifest_tmp"
  validate_manifest "$manifest" "$stamp" "$size" "$sha" "$file" || { rm -f "$manifest_tmp"; return 1; }
  local_file="$LOCAL_DIR/$file"
  proof="$local_file.proof"
  if [[ "$MODE" == verify-recent ]]; then
    [[ -f "$proof" && -f "$local_file" ]] || { echo 'No locally verified backup' >&2; rm -f "$manifest_tmp"; return 1; }
    IFS=$'\t' read -r proof_stamp proof_size proof_sha proof_file proof_mtime < "$proof"
    [[ "$stamp" == "$proof_stamp" && "$size" == "$proof_size" && "$sha" == "$proof_sha" && "$file" == "$proof_file" ]] || { rm -f "$manifest_tmp"; return 1; }
    [[ "$(file_size "$local_file")" == "$size" && "$(file_mtime "$local_file")" == "$proof_mtime" ]] || { rm -f "$manifest_tmp"; return 1; }
    (( $(date -u +%s) - stamp <= MAX_AGE_HOURS * 3600 )) || { echo 'Verified backup is older than allowed' >&2; rm -f "$manifest_tmp"; return 1; }
    rm -f "$manifest_tmp"
    echo "Recent locally verified backup: $local_file"
    return 0
  fi
  if [[ -f "$proof" && -f "$local_file" ]]; then
    IFS=$'\t' read -r proof_stamp proof_size proof_sha proof_file proof_mtime < "$proof"
    if [[ "$stamp" == "$proof_stamp" && "$size" == "$proof_size" && "$sha" == "$proof_sha" && "$(file_size "$local_file")" == "$size" && "$(file_mtime "$local_file")" == "$proof_mtime" ]]; then
      remote "touch '$REMOTE_DIR/$file.verified'"
      rm -f "$manifest_tmp"
      return 0
    fi
  fi
  local partial="$(mktemp "$LOCAL_DIR/.db-partial.XXXXXX")"
  trap 'rm -f "$partial" "$manifest_tmp"' RETURN
  fetch "$REMOTE_DIR/$file" "$partial"
  [[ "$(file_size "$partial")" == "$size" ]] || { echo 'Backup size mismatch' >&2; return 1; }
  [[ "$(shasum -a 256 "$partial" | cut -d' ' -f1)" == "$sha" ]] || { echo 'Backup SHA-256 mismatch' >&2; return 1; }
  local result
  result="$(limited "$CHECK_TIMEOUT" sqlite3 -readonly "$partial" 'PRAGMA quick_check;')" || { echo 'Local quick_check timed out or failed' >&2; return 1; }
  [[ "$result" == ok ]] || { echo "Local quick_check failed: $result" >&2; return 1; }
  mv "$partial" "$local_file"
  printf '%s\t%s\t%s\t%s\t%s\n' "$stamp" "$size" "$sha" "$file" "$(file_mtime "$local_file")" > "$proof.tmp"
  mv "$proof.tmp" "$proof"
  cp "$manifest_tmp" "$local_file.manifest"
  remote "touch '$REMOTE_DIR/$file.verified'"
  rm -f "$manifest_tmp"
  trap - RETURN
  echo "SQLite backup verified locally: $local_file"
}

case "$MODE" in
  verify-recent)
    found=0
    while IFS= read -r manifest; do
      if check_one "$manifest"; then found=1; break; fi
    done <<< "$manifest_list"
    [[ "$found" == 1 ]] || { echo 'No verified backup within the freshness window' >&2; exit 1; }
    ;;
  pull-latest)
    check_one "${manifest_list%%$'\n'*}"
    ;;
  pull)
    while IFS= read -r manifest; do check_one "$manifest"; done <<< "$manifest_list"
    count=0
    while IFS= read -r file; do
      count=$((count + 1))
      (( count > 2 )) || continue
      [[ -n "$(find "$file" -mtime +"$KEEP_DAYS" -print)" ]] || continue
      rm -f -- "$file" "$file.proof" "$file.manifest"
    done < <(find "$LOCAL_DIR" -maxdepth 1 -type f -name 'db-*.sqlite' -print | sort -r)
    ;;
  *) echo 'Usage: pull_sqlite_backup.sh pull|pull-latest|verify-recent' >&2; exit 1 ;;
esac
