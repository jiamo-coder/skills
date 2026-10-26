#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "${PO_DEPLOY_ENV_FILE:-$DEPLOY_DIR/.deploy.local.sh}" ]]; then
  source "${PO_DEPLOY_ENV_FILE:-$DEPLOY_DIR/.deploy.local.sh}"
fi
PROJECT="${PO_PROJECT_NAME:-$(basename "${PO_REMOTE_ROOT:?PO_REMOTE_ROOT is required}")}"
[[ "$PROJECT" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || exit 1

if [[ "$MODE" == remote ]]; then
  DB_FILE="${PO_REMOTE_DATABASE_FILE:?SQLite path is required}"
  BACKUP_DIR="${PO_REMOTE_BACKUP_DIR:-$PO_REMOTE_DATA_DIR/backups}"
  RUN_USER="${PO_REMOTE_RUN_USER:?Remote run user is required}"
  stable_dir="$PO_REMOTE_ROOT/shared/scripts"
  sudo install -d -m 755 "$stable_dir"
  sudo install -d -o "$RUN_USER" -g "$RUN_USER" -m 700 "$BACKUP_DIR"
  sudo install -m 755 "$SCRIPT_DIR/sqlite_backup.sh" "$stable_dir/sqlite_backup.sh"
  config="$(mktemp)"
  unit="$(mktemp)"
  timer="$(mktemp)"
  trap 'rm -f "$config" "$unit" "$timer"' EXIT
  for value in "$PO_REMOTE_ROOT" "$DB_FILE" "$BACKUP_DIR"; do
    [[ "$value" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo 'Unsafe SQLite schedule path' >&2; exit 1; }
  done
  {
    printf 'PO_REMOTE_ROOT=%s\n' "$PO_REMOTE_ROOT"
    printf 'PO_REMOTE_DATABASE_FILE=%s\n' "$DB_FILE"
    printf 'PO_REMOTE_BACKUP_DIR=%s\n' "$BACKUP_DIR"
    printf 'PO_DB_BACKUP_TIMEOUT_SEC=%s\n' "${PO_DB_BACKUP_TIMEOUT_SEC:-1800}"
    printf 'PO_BACKUP_REMOTE_KEEP_DAYS=%s\n' "${PO_BACKUP_REMOTE_KEEP_DAYS:-7}"
  } > "$config"
  cat > "$unit" <<UNIT
[Unit]
Description=Daily SQLite consistent backup for $PROJECT
[Service]
Type=oneshot
User=$RUN_USER
EnvironmentFile=/etc/$PROJECT/sqlite-backup.conf
ExecStart=/bin/bash $stable_dir/sqlite_backup.sh create
TimeoutStartSec=${PO_DB_BACKUP_TOTAL_TIMEOUT_SEC:-3600}
UNIT
  cat > "$timer" <<TIMER
[Unit]
Description=Daily SQLite backup for $PROJECT
[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=1800
Unit=$PROJECT-sqlite-backup.service
[Install]
WantedBy=timers.target
TIMER
  sudo install -d -m 755 "/etc/$PROJECT"
  sudo install -m 600 "$config" "/etc/$PROJECT/sqlite-backup.conf"
  sudo install -m 644 "$unit" "/etc/systemd/system/$PROJECT-sqlite-backup.service"
  sudo install -m 644 "$timer" "/etc/systemd/system/$PROJECT-sqlite-backup.timer"
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$PROJECT-sqlite-backup.timer"
  exit 0
fi

if [[ "$MODE" == local ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'Local scheduler requires macOS' >&2; exit 1; }
  plist="$HOME/Library/LaunchAgents/com.aliyun.sqlite-backup.$PROJECT.plist"
  mkdir -p "$(dirname "$plist")"
  mkdir -p "$HOME/Library/Logs"
  config_file="${PO_DEPLOY_ENV_FILE:-$DEPLOY_DIR/.deploy.local.sh}"
  node - "$plist" "$SCRIPT_DIR/pull_sqlite_backup.sh" "$PROJECT" "$config_file" "$HOME/Library/Logs/aliyun-backup-$PROJECT.log" <<'NODE'
const fs = require('fs');
const [file, script, project, config, log] = process.argv.slice(2);
const esc = (s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
fs.writeFileSync(file, `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>com.aliyun.sqlite-backup.${esc(project)}</string><key>ProgramArguments</key><array><string>/bin/bash</string><string>${esc(script)}</string><string>pull</string></array><key>EnvironmentVariables</key><dict><key>PO_DEPLOY_ENV_FILE</key><string>${esc(config)}</string></dict><key>StandardOutPath</key><string>${esc(log)}</string><key>StandardErrorPath</key><string>${esc(log)}</string><key>RunAtLoad</key><true/><key>StartCalendarInterval</key><dict><key>Hour</key><integer>04</integer><key>Minute</key><integer>00</integer></dict></dict></plist>\n`, { mode: 0o600 });
NODE
  launchctl bootout "gui/$UID" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$UID" "$plist"
  echo "Local backup pull scheduled: $plist"
  exit 0
fi

echo 'Usage: install_sqlite_backup_schedule.sh remote|local' >&2
exit 1
