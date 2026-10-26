#!/usr/bin/env bash
set -Eeuo pipefail

scope="${DB_CHANGE_SCOPE:?DB_CHANGE_SCOPE is required}"
[[ "$scope" == web || "$scope" == backend || "$scope" == data ]] || exit 1
root="${REMOTE_ROOT:?REMOTE_ROOT is required}"
release="${REMOTE_RELEASE_DIR:?REMOTE_RELEASE_DIR is required}"
current="${REMOTE_CURRENT_DIR:?REMOTE_CURRENT_DIR is required}"
web="${REMOTE_WEB_DIR:?REMOTE_WEB_DIR is required}"
admin="${REMOTE_ADMIN_WEB_DIR:?REMOTE_ADMIN_WEB_DIR is required}"
service="${REMOTE_SERVICE_NAME:?REMOTE_SERVICE_NAME is required}"
timeout_sec="${REMOTE_DEPLOY_TIMEOUT_SEC:-1800}"
health_sec="${HEALTH_TIMEOUT_SEC:-60}"
[[ "$timeout_sec" =~ ^[1-9][0-9]*$ && "$health_sec" =~ ^[1-9][0-9]*$ ]] || exit 1
[[ ! -e "$current" || -L "$current" ]] || { echo "Current path is not a symlink: $current" >&2; exit 1; }
if [[ "$scope" == web && ! -L "$current" ]]; then
  echo 'Web-only release requires an existing backend deployment' >&2
  exit 1
fi
if [[ "$scope" == web && "${HAS_WEB:-0}" != 1 ]]; then
  echo 'Web-only release requires a static web artifact' >&2
  exit 1
fi

sudo mkdir -p "$root" "$REMOTE_RELEASES_DIR" "$REMOTE_DATA_DIR" "$REMOTE_UPLOADS_DIR" "$REMOTE_LOG_DIR" "$REMOTE_ENV_DIR" "$web" "$admin"
sudo chown "$REMOTE_RUN_USER:$REMOTE_RUN_USER" "$root" "$REMOTE_RELEASES_DIR" "$REMOTE_DATA_DIR" "$REMOTE_UPLOADS_DIR" "$REMOTE_LOG_DIR" "$web" "$admin"
exec 9>"$root/.release-backup.lock"
flock -w 30 9 || { echo 'Backup/release lock is busy' >&2; exit 1; }

previous_current=""
[[ ! -L "$current" ]] || previous_current="$(readlink "$current")"
web_next="$root/.web-next-$$"
admin_next="$root/.admin-next-$$"
web_previous="$root/web-previous"
admin_previous="$root/admin-web-previous"
env_previous="$root/.env-previous-$$"
service_previous="$root/.service-previous-$$"
had_env=0
had_service=0
switched_current=0
switched_web=0
switched_admin=0
installed_env=0
installed_service=0
finished=0

health_api() {
  [[ -n "${HEALTH_PATH:-}" ]] || { echo 'Backend health path is required' >&2; return 1; }
  local end=$((SECONDS + health_sec))
  while (( SECONDS < end )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:${APP_PORT:?APP_PORT is required}$HEALTH_PATH" >/dev/null; then return 0; fi
    sleep 2
  done
  echo 'Backend health check timed out' >&2
  return 1
}

health_web() {
  local end=$((SECONDS + health_sec))
  while (( SECONDS < end )); do
    if curl -kfsS --max-time 5 --resolve "$PROJECT_DOMAIN:443:127.0.0.1" "https://$PROJECT_DOMAIN/" >/dev/null; then return 0; fi
    sleep 2
  done
  echo 'Web health check timed out' >&2
  return 1
}

rollback() {
  local failed_web="$root/.failed-web-$$" failed_admin="$root/.failed-admin-$$"
  if (( switched_admin )); then
    [[ ! -e "$admin" ]] || mv "$admin" "$failed_admin"
    mv "$admin_previous" "$admin"
    [[ ! -e "$failed_admin" ]] || rm -rf "$failed_admin"
  fi
  if (( switched_web )); then
    [[ ! -e "$web" ]] || mv "$web" "$failed_web"
    mv "$web_previous" "$web"
    [[ ! -e "$failed_web" ]] || rm -rf "$failed_web"
  fi
  if (( switched_current )); then
    if [[ -n "$previous_current" ]]; then
      ln -s "$previous_current" "$root/.current-rollback-$$"
      mv -Tf "$root/.current-rollback-$$" "$current"
    else
      rm -f "$current"
    fi
  fi
  if (( installed_env )); then
    if (( had_env )); then sudo cp -p "$env_previous" "$REMOTE_ENV_FILE"; else sudo rm -f "$REMOTE_ENV_FILE"; fi
  fi
  if (( installed_service )); then
    if (( had_service )); then sudo cp -p "$service_previous" "/etc/systemd/system/$service"; else sudo rm -f "/etc/systemd/system/$service"; fi
    sudo systemctl daemon-reload
  fi
  if (( switched_current )); then
    if [[ -n "$previous_current" ]]; then sudo systemctl restart "$service" && health_api || echo 'Old service recovery requires attention' >&2
    else sudo systemctl stop "$service" || true; fi
  fi
}

on_exit() {
  local status="$?"
  trap - EXIT
  if (( finished == 0 )); then
    status=1
    rollback || echo 'Rollback requires manual attention' >&2
  fi
  rm -rf "$web_next" "$admin_next"
  rm -f "$root/.current-next-$$" "$root/.current-rollback-$$"
  sudo rm -f "$env_previous" "$service_previous"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 143' TERM INT

if [[ -e "$release" ]]; then
  [[ "$release" != "$previous_current" ]] || { echo 'Refusing to overwrite current release' >&2; exit 1; }
  rm -rf "$release"
fi
mkdir -p "$release"
tar -xzf "$REMOTE_ARTIFACT" -C "$release"

if [[ "${HAS_WEB:-0}" == 1 ]]; then
  [[ -f "$release/web/index.html" ]] || exit 1
  mkdir -p "$web_next"
  cp -R "$release/web/." "$web_next/"
fi
if [[ "${HAS_ADMIN:-0}" == 1 ]]; then
  [[ -f "$release/admin-web/index.html" ]] || exit 1
  mkdir -p "$admin_next"
  cp -R "$release/admin-web/." "$admin_next/"
fi

if [[ "$scope" != web ]]; then
  (cd "$release" && bash -lc "$RUNTIME_INSTALL_CMD")
  if [[ -f "$REMOTE_ENV_FILE" ]]; then sudo cp -p "$REMOTE_ENV_FILE" "$env_previous"; had_env=1; fi
  if [[ -f "/etc/systemd/system/$service" ]]; then sudo cp -p "/etc/systemd/system/$service" "$service_previous"; had_service=1; fi
  sudo install -o "$REMOTE_RUN_USER" -g "$REMOTE_RUN_USER" -m 600 "$REMOTE_UPLOAD_ENV_FILE" "$REMOTE_ENV_FILE"
  installed_env=1
  sudo install -m 644 "$REMOTE_SERVICE_FILE" "/etc/systemd/system/$service"
  installed_service=1
  sudo systemctl daemon-reload
  sudo systemctl enable "$service" >/dev/null
  ln -s "$release" "$root/.current-next-$$"
  mv -Tf "$root/.current-next-$$" "$current"
  switched_current=1
fi

if [[ "${HAS_WEB:-0}" == 1 ]]; then
  rm -rf "$web_previous"
  mv "$web" "$web_previous"
  switched_web=1
  mv "$web_next" "$web"
fi
if [[ "${HAS_ADMIN:-0}" == 1 ]]; then
  rm -rf "$admin_previous"
  mv "$admin" "$admin_previous"
  switched_admin=1
  mv "$admin_next" "$admin"
fi

if [[ "$scope" != web ]]; then
  sudo systemctl restart "$service"
  health_api
  sudo env \
    PO_PROJECT_NAME="$PROJECT_NAME" PO_PROJECT_DOMAIN="$PROJECT_DOMAIN" \
    PO_NGINX_SETUP_MODE="$NGINX_SETUP_MODE" \
    PO_REMOTE_NGINX_SITES_DIR="$REMOTE_NGINX_SITES_DIR" \
    PO_REMOTE_NGINX_INCLUDE_CONF="$REMOTE_NGINX_INCLUDE_CONF" \
    PO_REMOTE_NGINX_CONF="$REMOTE_NGINX_CONF" PO_CERTBOT_WEBROOT="$CERTBOT_WEBROOT" \
    PO_NGINX_FINAL_TEMPLATE="$current/deploy/aliyun/$NGINX_TEMPLATE_BASENAME" \
    bash "$current/deploy/aliyun/configure_nginx_site.sh"
  if [[ -n "${REMOTE_DATABASE_FILE:-}" ]]; then
    [[ -f "$REMOTE_DATABASE_FILE" ]] || { echo "SQLite database missing after service health: $REMOTE_DATABASE_FILE" >&2; exit 1; }
    PO_REMOTE_ROOT="$root" PO_REMOTE_DATABASE_FILE="$REMOTE_DATABASE_FILE" \
      PO_REMOTE_BACKUP_DIR="$REMOTE_BACKUP_DIR" PO_REMOTE_RUN_USER="$REMOTE_RUN_USER" \
      bash "$current/deploy/aliyun/install_sqlite_backup_schedule.sh" remote
  fi
fi
if [[ "${HAS_WEB:-0}" == 1 ]]; then health_web; fi

finished=1
keep="${REMOTE_RELEASE_KEEP_COUNT:-2}"
[[ "$keep" =~ ^[1-9][0-9]*$ ]] || keep=2
count=0
while IFS= read -r old; do
  count=$((count + 1))
  (( count > keep )) || continue
  [[ "$old" != "$previous_current" && "$old" != "$(readlink "$current" 2>/dev/null || true)" ]] || continue
  rm -rf "$old" || echo "Old release cleanup failed: $old" >&2
done < <(find "$REMOTE_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | sort -r)
echo "Remote release healthy: $release"
