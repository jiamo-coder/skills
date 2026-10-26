#!/usr/bin/env bash
set -euo pipefail
umask 077

MODE="${1:-create}"
DB_FILE="${PO_REMOTE_DATABASE_FILE:?PO_REMOTE_DATABASE_FILE is required}"
BACKUP_DIR="${PO_REMOTE_BACKUP_DIR:?PO_REMOTE_BACKUP_DIR is required}"
LOCK_FILE="${PO_REMOTE_ROOT:?PO_REMOTE_ROOT is required}/.release-backup.lock"
BACKUP_TIMEOUT="${PO_DB_BACKUP_TIMEOUT_SEC:-1800}"
KEEP_DAYS="${PO_BACKUP_REMOTE_KEEP_DAYS:-7}"

[[ "$DB_FILE" == /* && "$BACKUP_DIR" == /* ]] || { echo 'SQLite paths must be absolute' >&2; exit 1; }
[[ "$BACKUP_TIMEOUT" =~ ^[1-9][0-9]*$ && "$KEEP_DAYS" =~ ^[1-9][0-9]*$ ]] || exit 1
command -v sqlite3 >/dev/null || { echo 'sqlite3 is required' >&2; exit 1; }
command -v flock >/dev/null || { echo 'flock is required' >&2; exit 1; }
command -v timeout >/dev/null || { echo 'timeout is required' >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
if [[ "${PO_RELEASE_LOCK_HELD:-0}" != 1 ]]; then
  exec 9>"$LOCK_FILE"
  flock -w 30 9 || { echo 'Backup/release lock is busy' >&2; exit 1; }
fi

prune() {
  local count=0 file
  while IFS= read -r file; do
    count=$((count + 1))
    (( count > 2 )) || continue
    [[ -f "$file.verified" ]] || continue
    [[ -n "$(find "$file" -mtime +"$KEEP_DAYS" -print)" ]] || continue
    rm -f -- "$file" "$file.manifest" "$file.verified"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'db-*.sqlite' -print | sort -r)
}

if [[ "$MODE" == prune ]]; then prune; exit 0; fi
[[ "$MODE" == create ]] || { echo 'Usage: sqlite_backup.sh create|prune' >&2; exit 1; }
[[ -f "$DB_FILE" ]] || { echo "SQLite database is missing: $DB_FILE" >&2; exit 1; }
[[ "$DB_FILE" != *"'"* && "$BACKUP_DIR" != *"'"* ]] || { echo 'SQLite path contains unsupported quote' >&2; exit 1; }
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$BACKUP_DIR/db-$stamp.sqlite"
[[ ! -e "$backup" ]] || { echo "Backup already exists: $backup" >&2; exit 1; }
partial="$(mktemp "$BACKUP_DIR/.db-partial.XXXXXX")"
trap 'rm -f -- "$partial" "$backup.manifest.tmp"' EXIT
timeout --signal=TERM --kill-after=10s "$BACKUP_TIMEOUT" sqlite3 -readonly -bail "$DB_FILE" ".backup '$partial'"
[[ -s "$partial" ]] || { echo 'SQLite backup is empty' >&2; exit 1; }
size="$(stat -c %s "$partial")"
sha="$(sha256sum "$partial" | cut -d' ' -f1)"
mv -- "$partial" "$backup"
chmod 600 "$backup"
printf '%s\t%s\t%s\t%s\n' "$(date -u +%s)" "$size" "$sha" "$(basename "$backup")" > "$backup.manifest.tmp"
mv -- "$backup.manifest.tmp" "$backup.manifest"
chmod 600 "$backup.manifest"
echo "SQLite consistent backup created: $backup"
prune
