#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote/data" "$TMP/remote/releases" "$TMP/local" "$TMP/project/deploy/aliyun/scripts"
export REAL_SQLITE="$(command -v sqlite3)"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/bin/flock" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/bin/timeout" <<'SH'
#!/usr/bin/env bash
[[ "${FAIL_BACKUP_TIMEOUT:-0}" != 1 ]] || exit 124
shift 3
exec "$@"
SH
cat > "$TMP/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -c ]]; then /usr/bin/stat -f %z "$3"; else /usr/bin/stat "$@"; fi
SH
cat > "$TMP/bin/sha256sum" <<'SH'
#!/usr/bin/env bash
shasum -a 256 "$1"
SH
cat > "$TMP/bin/sqlite3" <<'SH'
#!/usr/bin/env bash
if [[ "${FAIL_CHECK:-0}" == 1 && "$*" == *quick_check* ]]; then exit 124; fi
exec "$REAL_SQLITE" "$@"
SH
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
cmd="${*: -1}"
bash -c "$cmd"
SH
cat > "$TMP/bin/scp" <<'SH'
#!/usr/bin/env bash
[[ "${FAIL_SCP:-0}" != 1 ]] || exit 124
src="${*: -2:1}"
dest="${*: -1}"
cp "${src#*:}" "$dest"
SH
cat > "$TMP/bin/sudo" <<'SH'
#!/usr/bin/env bash
case "$1" in
  chown|systemctl) exit 0 ;;
  install)
    shift
    args=("$@")
    if [[ "${args[0]}" == -d ]]; then
      target="${args[${#args[@]}-1]}"
      if [[ "$target" == /etc/* ]]; then target="$TEST_ETC${target#/etc}"; fi
      mkdir -p "$target"
      exit 0
    fi
    source="${args[${#args[@]}-2]}"
    target="${args[${#args[@]}-1]}"
    if [[ "$target" == /etc/* ]]; then target="$TEST_ETC${target#/etc}"; fi
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
    ;;
  *) exec "$@" ;;
esac
SH
cat > "$TMP/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$TMP/bin/mv" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == -Tf ]]; then
  rm -f "$3"
  /bin/mv "$2" "$3"
else
  /bin/mv "$@"
fi
SH
cat > "$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "${FAIL_WEB_HEALTH:-0}" == 1 && "$*" == *https://* ]]; then exit 22; fi
if [[ "${FAIL_NEW_HEALTH:-0}" == 1 && "$(readlink "$TEST_CURRENT" 2>/dev/null || true)" == "$TEST_NEW" ]]; then exit 22; fi
exit 0
SH
chmod +x "$TMP/bin/"*

DB="$TMP/remote/data/app.sqlite"
"$REAL_SQLITE" "$DB" 'CREATE TABLE items (id INTEGER PRIMARY KEY); INSERT INTO items VALUES (1);'
export PO_REMOTE_ROOT="$TMP/remote" PO_REMOTE_DATABASE_FILE="$DB"
export PO_REMOTE_BACKUP_DIR="$TMP/remote/data/backups" PO_DB_BACKUP_TIMEOUT_SEC=10
bash "$SKILL_DIR/templates/sqlite_backup.sh" create >/dev/null
backup="$(find "$PO_REMOTE_BACKUP_DIR" -name 'db-*.sqlite' -type f | head -n 1)"
[[ -s "$backup" && -s "$backup.manifest" ]]
[[ "$(sqlite3 "$backup" 'SELECT count(*) FROM items;')" == 1 ]]
sleep 1
if FAIL_BACKUP_TIMEOUT=1 bash "$SKILL_DIR/templates/sqlite_backup.sh" create >/dev/null 2>&1; then exit 1; fi
[[ "$(find "$PO_REMOTE_BACKUP_DIR" -name 'db-*.manifest' | wc -l | tr -d ' ')" == 1 ]]
for date in 20000101 20000201 20000301; do
  old_backup="$PO_REMOTE_BACKUP_DIR/db-${date}T000000Z.sqlite"
  cp "$backup" "$old_backup"
  touch -t 202001010000 "$old_backup"
done
touch "$PO_REMOTE_BACKUP_DIR/db-20000101T000000Z.sqlite.verified"
bash "$SKILL_DIR/templates/sqlite_backup.sh" prune
[[ ! -f "$PO_REMOTE_BACKUP_DIR/db-20000101T000000Z.sqlite" ]]
[[ -f "$PO_REMOTE_BACKUP_DIR/db-20000201T000000Z.sqlite" ]]

cat > "$TMP/project/deploy/aliyun/.deploy.local.sh" <<EOF
export PO_REMOTE_ROOT='$PO_REMOTE_ROOT'
export PO_REMOTE_DATA_DIR='$TMP/remote/data'
export PO_REMOTE_BACKUP_DIR='$PO_REMOTE_BACKUP_DIR'
export PO_LOCAL_BACKUP_DIR='$TMP/local'
export PO_DEPLOY_HOST='example.invalid'
export PO_DEPLOY_USER='tester'
export PO_SSH_AUTH_METHOD='agent'
export PO_BACKUP_MAX_AGE_HOURS='48'
export PO_DB_CHECK_TIMEOUT_SEC='10'
EOF
cp "$SKILL_DIR/templates/pull_sqlite_backup.sh" "$TMP/project/deploy/aliyun/scripts/"
pull="$TMP/project/deploy/aliyun/scripts/pull_sqlite_backup.sh"
bash "$pull" pull-latest >/dev/null
bash "$pull" verify-recent >/dev/null
[[ -f "$backup.verified" ]]
manifest="$backup.manifest"
IFS=$'\t' read -r created size sha name < "$manifest"
printf '%s\t%s\t%s\t%s\n' "$((created - 49 * 3600))" "$size" "$sha" "$name" > "$manifest"
if bash "$pull" verify-recent >/dev/null 2>&1; then exit 1; fi
printf '%s\t%s\t%s\t%s\n' "$created" "$size" "$sha" "$name" > "$manifest"
rm -f "$TMP/local/$name.proof"
if FAIL_SCP=1 bash "$pull" pull-latest >/dev/null 2>&1; then exit 1; fi
if FAIL_CHECK=1 bash "$pull" pull-latest >/dev/null 2>&1; then exit 1; fi
printf 'corrupt' >> "$backup"
if bash "$pull" pull-latest >/dev/null 2>&1; then exit 1; fi

cat > "$TMP/bin/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/bin/launchctl"
cp "$SKILL_DIR/templates/install_sqlite_backup_schedule.sh" "$TMP/project/deploy/aliyun/scripts/"
cp "$SKILL_DIR/templates/sqlite_backup.sh" "$TMP/project/deploy/aliyun/scripts/"
mkdir -p "$TMP/home"
HOME="$TMP/home" bash "$TMP/project/deploy/aliyun/scripts/install_sqlite_backup_schedule.sh" local >/dev/null
plist="$TMP/home/Library/LaunchAgents/com.aliyun.sqlite-backup.remote.plist"
plutil -lint "$plist" >/dev/null
export TEST_ETC="$TMP/etc" PO_REMOTE_RUN_USER="$(id -un)"
bash "$TMP/project/deploy/aliyun/scripts/install_sqlite_backup_schedule.sh" remote >/dev/null
[[ -f "$TMP/etc/remote/sqlite-backup.conf" ]]
grep -Fq 'OnCalendar=*-*-* 03:00:00' "$TMP/etc/systemd/system/remote-sqlite-backup.timer"

root="$TMP/remote"
old="$root/releases/old"
new="$root/releases/new"
mkdir -p "$old" "$root/web" "$root/admin-web" "$TMP/package/web"
mkdir -p "$TMP/package/deploy/aliyun"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/package/deploy/aliyun/configure_nginx_site.sh"
printf 'old\n' > "$root/web/index.html"
printf 'new\n' > "$TMP/package/web/index.html"
ln -s "$old" "$root/current"
tar -czf "$TMP/new.tgz" -C "$TMP/package" .
printf 'PORT=8181\n' > "$TMP/api.env"
printf '[Service]\n' > "$TMP/app.service"
export TEST_CURRENT="$root/current" TEST_NEW="$new"
export TEST_ETC="$TMP/etc"
export REMOTE_ROOT="$root" REMOTE_RELEASES_DIR="$root/releases" REMOTE_RELEASE_DIR="$new"
export REMOTE_CURRENT_DIR="$root/current" REMOTE_WEB_DIR="$root/web" REMOTE_ADMIN_WEB_DIR="$root/admin-web"
export REMOTE_DATA_DIR="$root/data" REMOTE_UPLOADS_DIR="$root/uploads" REMOTE_LOG_DIR="$root/logs"
export REMOTE_ENV_DIR="$TMP/etc" REMOTE_ENV_FILE="$TMP/etc/app.env"
export REMOTE_SERVICE_NAME=app.service REMOTE_RUN_USER="$(id -un)" REMOTE_ARTIFACT="$TMP/new.tgz"
export REMOTE_UPLOAD_ENV_FILE="$TMP/api.env" REMOTE_SERVICE_FILE="$TMP/app.service"
export RUNTIME_INSTALL_CMD=true APP_PORT=8181 HEALTH_PATH=/health PROJECT_DOMAIN=example.invalid
export PROJECT_NAME=app
export NGINX_SETUP_MODE=skip REMOTE_NGINX_SITES_DIR="$TMP/nginx" REMOTE_NGINX_INCLUDE_CONF="$TMP/include.conf"
export REMOTE_NGINX_CONF="$TMP/nginx/app.conf" CERTBOT_WEBROOT="$TMP/certbot"
export NGINX_TEMPLATE_BASENAME=app.conf
export HAS_WEB=1 HAS_ADMIN=0 REMOTE_DEPLOY_TIMEOUT_SEC=10 HEALTH_TIMEOUT_SEC=1
export REMOTE_RELEASE_KEEP_COUNT=2
if FAIL_WEB_HEALTH=1 DB_CHANGE_SCOPE=web bash "$SKILL_DIR/templates/remote_release.sh" >/dev/null 2>&1; then exit 1; fi
[[ "$(readlink "$root/current")" == "$old" && "$(cat "$root/web/index.html")" == old ]]
DB_CHANGE_SCOPE=web bash "$SKILL_DIR/templates/remote_release.sh" >/dev/null
[[ "$(readlink "$root/current")" == "$old" && "$(cat "$root/web/index.html")" == new ]]
printf 'old\n' > "$root/web/index.html"
if RUNTIME_INSTALL_CMD=false DB_CHANGE_SCOPE=backend bash "$SKILL_DIR/templates/remote_release.sh" >/dev/null 2>&1; then exit 1; fi
[[ "$(readlink "$root/current")" == "$old" && "$(cat "$root/web/index.html")" == old ]]
if FAIL_NEW_HEALTH=1 DB_CHANGE_SCOPE=backend bash "$SKILL_DIR/templates/remote_release.sh" >/dev/null 2>&1; then exit 1; fi
[[ "$(readlink "$root/current")" == "$old" && "$(cat "$root/web/index.html")" == old ]]
if env -u PROJECT_NAME DB_CHANGE_SCOPE=backend bash "$SKILL_DIR/templates/remote_release.sh" >/dev/null 2>&1; then exit 1; fi
[[ "$(readlink "$root/current")" == "$old" && "$(cat "$root/web/index.html")" == old ]]
DB_CHANGE_SCOPE=backend bash "$SKILL_DIR/templates/remote_release.sh" >/dev/null
[[ "$(readlink "$root/current")" == "$new" && "$(cat "$root/web/index.html")" == new ]]
echo 'SQLite release scope and rollback passed'
