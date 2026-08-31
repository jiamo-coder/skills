#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  render_release_scripts.sh \
    --output-dir <dir> \
    --project-slug <slug> \
    --project-domain <domain> \
    --app-port <port> \
    --api-build-cmd <cmd> \
    --api-dist-path <path> \
    --start-entry <path> \
    --env-template <path> \
    --service-template <path> \
    --nginx-template <path> \
    [--web-build-cmd <cmd>] \
    [--web-dist-path <path>] \
    [--admin-build-cmd <cmd>] \
    [--admin-dist-path <path>] \
    [--health-path <path>] \
    [--runtime-install-cmd <cmd>] \
    [--release-prefix <prefix>] \
    [--deploy-host <host>] \
    [--deploy-user <user>] \
    [--deploy-port <port>] \
    [--ssh-auth-method <password|key|agent>] \
    [--ssh-key-file <path>]
EOF
}

shell_quote() {
  printf "%q" "$1"
}

OUTPUT_DIR=""
PROJECT_SLUG=""
PROJECT_DOMAIN=""
APP_PORT=""
API_BUILD_CMD=""
API_DIST_PATH=""
START_ENTRY=""
ENV_TEMPLATE=""
SERVICE_TEMPLATE=""
NGINX_TEMPLATE=""
WEB_BUILD_CMD=""
WEB_DIST_PATH=""
ADMIN_BUILD_CMD=""
ADMIN_DIST_PATH=""
HEALTH_PATH=""
RUNTIME_INSTALL_CMD="npm install --omit=dev --legacy-peer-deps"
RELEASE_PREFIX=""
DEPLOY_HOST=""
DEPLOY_USER="root"
DEPLOY_PORT="22"
SSH_AUTH_METHOD=""
SSH_KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --project-slug) PROJECT_SLUG="$2"; shift 2 ;;
    --project-domain) PROJECT_DOMAIN="$2"; shift 2 ;;
    --app-port) APP_PORT="$2"; shift 2 ;;
    --api-build-cmd) API_BUILD_CMD="$2"; shift 2 ;;
    --api-dist-path) API_DIST_PATH="$2"; shift 2 ;;
    --start-entry) START_ENTRY="$2"; shift 2 ;;
    --env-template) ENV_TEMPLATE="$2"; shift 2 ;;
    --service-template) SERVICE_TEMPLATE="$2"; shift 2 ;;
    --nginx-template) NGINX_TEMPLATE="$2"; shift 2 ;;
    --web-build-cmd) WEB_BUILD_CMD="$2"; shift 2 ;;
    --web-dist-path) WEB_DIST_PATH="$2"; shift 2 ;;
    --admin-build-cmd) ADMIN_BUILD_CMD="$2"; shift 2 ;;
    --admin-dist-path) ADMIN_DIST_PATH="$2"; shift 2 ;;
    --health-path) HEALTH_PATH="$2"; shift 2 ;;
    --runtime-install-cmd) RUNTIME_INSTALL_CMD="$2"; shift 2 ;;
    --release-prefix) RELEASE_PREFIX="$2"; shift 2 ;;
    --deploy-host) DEPLOY_HOST="$2"; shift 2 ;;
    --deploy-user) DEPLOY_USER="$2"; shift 2 ;;
    --deploy-port) DEPLOY_PORT="$2"; shift 2 ;;
    --ssh-auth-method) SSH_AUTH_METHOD="$2"; shift 2 ;;
    --ssh-key-file) SSH_KEY_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_DIR" || -z "$PROJECT_SLUG" || -z "$PROJECT_DOMAIN" || -z "$API_BUILD_CMD" || -z "$API_DIST_PATH" || -z "$START_ENTRY" || -z "$ENV_TEMPLATE" || -z "$SERVICE_TEMPLATE" || -z "$NGINX_TEMPLATE" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$APP_PORT" && -f "$ENV_TEMPLATE" ]]; then
  APP_PORT="$(awk -F= '/^[[:space:]]*PORT[[:space:]]*=/ { value=$0; sub(/^[^=]*=/, "", value); gsub(/^[[:space:]\"'\'']+|[[:space:]\"'\'']+$/, "", value); print value; exit }' "$ENV_TEMPLATE")"
fi
if [[ ! "$APP_PORT" =~ ^[0-9]+$ || "$APP_PORT" -lt 1 || "$APP_PORT" -gt 65535 ]]; then
  echo "app port must be provided with --app-port or a numeric PORT in the env template" >&2
  exit 1
fi

if [[ -z "$RELEASE_PREFIX" ]]; then
  RELEASE_PREFIX="$PROJECT_SLUG"
fi

if [[ ! "$DEPLOY_PORT" =~ ^[0-9]+$ ]]; then
  echo "deploy port must be numeric" >&2
  exit 1
fi

if [[ -n "$SSH_AUTH_METHOD" && "$SSH_AUTH_METHOD" != "password" && "$SSH_AUTH_METHOD" != "key" && "$SSH_AUTH_METHOD" != "agent" ]]; then
  echo "ssh auth method must be password, key, or agent" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

PACKAGE_SCRIPT="$OUTPUT_DIR/package_release.sh"
DEPLOY_SCRIPT="$OUTPUT_DIR/deploy_release.sh"
START_SCRIPT="$OUTPUT_DIR/start-prod.sh"
BOOTSTRAP_SCRIPT="$OUTPUT_DIR/server-bootstrap.sh"
VERSION_SCRIPT="$OUTPUT_DIR/manage_release_version.mjs"
GIT_COMMIT_SCRIPT="$OUTPUT_DIR/manage_git_release_commit.mjs"
GIT_SYNC_SCRIPT="$OUTPUT_DIR/sync_git_release.sh"
CONFIG_INIT_SCRIPT="$OUTPUT_DIR/init_deploy_config.sh"
NGINX_CONFIG_SCRIPT="$OUTPUT_DIR/configure_nginx_site.sh"

API_DIST_PARENT="$(dirname "$API_DIST_PATH")"
ENV_TEMPLATE_Q="$(shell_quote "$ENV_TEMPLATE")"
SERVICE_TEMPLATE_Q="$(shell_quote "$SERVICE_TEMPLATE")"
NGINX_TEMPLATE_Q="$(shell_quote "$NGINX_TEMPLATE")"
NGINX_TEMPLATE_BASENAME="$(basename "$NGINX_TEMPLATE")"
API_DIST_PATH_Q="$(shell_quote "$API_DIST_PATH")"
API_DIST_PARENT_Q="$(shell_quote "$API_DIST_PARENT")"
START_ENTRY_Q="$(shell_quote "$START_ENTRY")"
RUNTIME_INSTALL_CMD_Q="$(shell_quote "$RUNTIME_INSTALL_CMD")"
DEPLOY_HOST_Q="$(shell_quote "$DEPLOY_HOST")"
DEPLOY_USER_Q="$(shell_quote "$DEPLOY_USER")"
DEPLOY_PORT_Q="$(shell_quote "$DEPLOY_PORT")"
SSH_AUTH_METHOD_Q="$(shell_quote "$SSH_AUTH_METHOD")"
SSH_KEY_FILE_Q="$(shell_quote "$SSH_KEY_FILE")"
PROJECT_DOMAIN_Q="$(shell_quote "$PROJECT_DOMAIN")"
APP_PORT_Q="$(shell_quote "$APP_PORT")"

PACKAGE_BUILD_BLOCK="$API_BUILD_CMD"
if [[ -n "$WEB_BUILD_CMD" ]]; then
  PACKAGE_BUILD_BLOCK+=$'\n'"$WEB_BUILD_CMD"
fi
if [[ -n "$ADMIN_BUILD_CMD" ]]; then
  PACKAGE_BUILD_BLOCK+=$'\n'"$ADMIN_BUILD_CMD"
fi

PACKAGE_STAGE_COPY_BLOCK=""
REQUIRED_PATHS_BLOCK=$'\n'"  required_paths+=(\"deploy/aliyun/manage_release_version.mjs\")"$'\n'"  required_paths+=(\"deploy/aliyun/manage_git_release_commit.mjs\")"$'\n'"  required_paths+=(\"deploy/aliyun/sync_git_release.sh\")"$'\n'"  required_paths+=(\"deploy/aliyun/configure_nginx_site.sh\")"
REMOTE_MKDIR_ARGS='"$REMOTE_RELEASES_DIR" "$REMOTE_SHARED_DIR" "$REMOTE_DATA_DIR" "$REMOTE_UPLOADS_DIR" "$REMOTE_LOG_DIR" "$REMOTE_ENV_DIR"'
REMOTE_SYNC_BLOCK=""
BOOTSTRAP_DIRS=(
  '  "${PROJECT_DIR}/data"'
  '  "${PROJECT_DIR}/uploads"'
  '  "${PROJECT_DIR}/logs"'
  '  "$(dirname "${ENV_TARGET}")"'
)

if [[ -n "$WEB_DIST_PATH" ]]; then
  WEB_DIST_PATH_Q="$(shell_quote "$WEB_DIST_PATH")"
  PACKAGE_STAGE_COPY_BLOCK+=$'\n'"mkdir -p \"\$STAGE_DIR/web\""
  PACKAGE_STAGE_COPY_BLOCK+=$'\n'"cp -R $WEB_DIST_PATH_Q/. \"\$STAGE_DIR/web/\""
  REQUIRED_PATHS_BLOCK+=$'\n'"  required_paths+=(\"web/index.html\")"
  REMOTE_MKDIR_ARGS+=' "$REMOTE_WEB_DIR"'
  REMOTE_SYNC_BLOCK+=$'\n'"find \"\$REMOTE_WEB_DIR\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
  REMOTE_SYNC_BLOCK+=$'\n'"cp -R \"\$REMOTE_CURRENT_DIR/web/.\" \"\$REMOTE_WEB_DIR/\""
  BOOTSTRAP_DIRS+=('  "${PROJECT_DIR}/web"')
fi

if [[ -n "$ADMIN_DIST_PATH" ]]; then
  ADMIN_DIST_PATH_Q="$(shell_quote "$ADMIN_DIST_PATH")"
  PACKAGE_STAGE_COPY_BLOCK+=$'\n'"mkdir -p \"\$STAGE_DIR/admin-web\""
  PACKAGE_STAGE_COPY_BLOCK+=$'\n'"cp -R $ADMIN_DIST_PATH_Q/. \"\$STAGE_DIR/admin-web/\""
  REQUIRED_PATHS_BLOCK+=$'\n'"  required_paths+=(\"admin-web/index.html\")"
  REMOTE_MKDIR_ARGS+=' "$REMOTE_ADMIN_WEB_DIR"'
  REMOTE_SYNC_BLOCK+=$'\n'"find \"\$REMOTE_ADMIN_WEB_DIR\" -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
  REMOTE_SYNC_BLOCK+=$'\n'"cp -R \"\$REMOTE_CURRENT_DIR/admin-web/.\" \"\$REMOTE_ADMIN_WEB_DIR/\""
  BOOTSTRAP_DIRS+=('  "${PROJECT_DIR}/admin-web"')
fi

BOOTSTRAP_MKDIR_BLOCK=""
for i in "${!BOOTSTRAP_DIRS[@]}"; do
  line="${BOOTSTRAP_DIRS[$i]}"
  if (( i < ${#BOOTSTRAP_DIRS[@]} - 1 )); then
    BOOTSTRAP_MKDIR_BLOCK+="${line} \\"$'\n'
  else
    BOOTSTRAP_MKDIR_BLOCK+="${line}"
  fi
done

HEALTH_CHECK_BLOCK='echo "未配置 HTTP 健康检查，请确认服务已成功启动。"'
if [[ -n "$HEALTH_PATH" ]]; then
  HEALTH_CHECK_BLOCK=$(cat <<EOF
APP_PORT=\${PORT:?REMOTE_ENV_FILE must define PORT}
for _ in {1..20}; do
  if curl -fsS "http://127.0.0.1:\$APP_PORT$HEALTH_PATH" >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:\$APP_PORT$HEALTH_PATH"
EOF
)
fi

cat > "$CONFIG_INIT_SCRIPT" <<EOF
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="\$(cd "\${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_DIR="\$ROOT_DIR/deploy/aliyun"
CONFIG_FILE="\${PO_DEPLOY_ENV_FILE:-\$DEPLOY_DIR/.deploy.local.sh}"
PROJECT_SLUG=$PROJECT_SLUG
PROJECT_DOMAIN=$PROJECT_DOMAIN_Q
APP_PORT=$APP_PORT_Q
DEPLOY_HOST=$DEPLOY_HOST_Q
DEPLOY_USER=$DEPLOY_USER_Q
DEPLOY_PORT=$DEPLOY_PORT_Q
SSH_AUTH_METHOD=$SSH_AUTH_METHOD_Q
SSH_KEY_FILE=$SSH_KEY_FILE_Q
NON_INTERACTIVE=0

usage() {
  cat <<'USAGE'
Usage:
  init_deploy_config.sh [--host <ip-or-host>] [--user <ssh-user>] [--port <ssh-port>]
                        [--auth <password|key|agent>] [--key-file <path>]
                        [--domain <domain>] [--app-port <port>]
                        [--non-interactive]

Password authentication is read with hidden input. For non-interactive setup,
set PO_INIT_SSH_PASSWORD in the local environment or fill PO_SSH_PASSWORD later.
USAGE
}

shell_export() {
  local key="\$1"
  local value="\$2"
  printf 'export %s=%q\n' "\$key" "\$value"
}

ensure_gitignore_entry() {
  local ignore_file="\$ROOT_DIR/.gitignore"
  local entries=(
    "/deploy/aliyun/.deploy.local.sh"
    "/deploy/aliyun/.git-release-approval.local.json"
  )
  touch "\$ignore_file"
  local entry
  for entry in "\${entries[@]}"; do
    if ! grep -Fqx "\$entry" "\$ignore_file"; then
      printf '\n# Local Aliyun release state\n%s\n' "\$entry" >> "\$ignore_file"
    fi
  done
}

ensure_not_tracked() {
  if ! git -C "\$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi
  local private_path
  for private_path in \
    "deploy/aliyun/.deploy.local.sh" \
    "deploy/aliyun/.git-release-approval.local.json"; do
    if git -C "\$ROOT_DIR" ls-files --error-unmatch "\$private_path" >/dev/null 2>&1; then
      echo "安全错误: \$private_path 已被 Git 跟踪，请先从 Git 索引移除。" >&2
      exit 1
    fi
  done
}

while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --host) DEPLOY_HOST="\$2"; shift 2 ;;
    --user) DEPLOY_USER="\$2"; shift 2 ;;
    --port) DEPLOY_PORT="\$2"; shift 2 ;;
    --auth) SSH_AUTH_METHOD="\$2"; shift 2 ;;
    --key-file) SSH_KEY_FILE="\$2"; shift 2 ;;
    --domain) PROJECT_DOMAIN="\$2"; shift 2 ;;
    --app-port) APP_PORT="\$2"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: \$1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -f "\$CONFIG_FILE" ]]; then
  chmod 600 "\$CONFIG_FILE"
  ensure_gitignore_entry
  ensure_not_tracked
  echo "服务器配置已存在，未覆盖: \$CONFIG_FILE"
  exit 0
fi

if [[ "\$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
  if [[ -z "\$DEPLOY_HOST" ]]; then
    read -r -p "服务器 IP 或域名: " DEPLOY_HOST
  fi
  if [[ -z "\$PROJECT_DOMAIN" ]]; then
    read -r -p "项目访问域名: " PROJECT_DOMAIN
  fi
  if [[ -z "\$APP_PORT" ]]; then
    read -r -p "后端服务端口: " APP_PORT
  fi
  read -r -p "SSH 账号 [\$DEPLOY_USER]: " input_user
  DEPLOY_USER="\${input_user:-\$DEPLOY_USER}"
  read -r -p "SSH 端口 [\$DEPLOY_PORT]: " input_port
  DEPLOY_PORT="\${input_port:-\$DEPLOY_PORT}"
  if [[ -z "\$SSH_AUTH_METHOD" ]]; then
    read -r -p "认证方式 password/key/agent [key]: " SSH_AUTH_METHOD
    SSH_AUTH_METHOD="\${SSH_AUTH_METHOD:-key}"
  fi
fi

if [[ -z "\$SSH_AUTH_METHOD" ]]; then
  SSH_AUTH_METHOD="key"
fi
if [[ ! "\$DEPLOY_PORT" =~ ^[0-9]+$ ]]; then
  echo "SSH 端口必须是数字" >&2
  exit 1
fi
if [[ ! "\$APP_PORT" =~ ^[0-9]+$ || "\$APP_PORT" -lt 1 || "\$APP_PORT" -gt 65535 ]]; then
  echo "后端服务端口必须是 1-65535 的数字" >&2
  exit 1
fi
case "\$SSH_AUTH_METHOD" in
  password|key|agent) ;;
  *) echo "认证方式必须是 password、key 或 agent" >&2; exit 1 ;;
esac

SSH_PASSWORD="\${PO_INIT_SSH_PASSWORD:-}"
if [[ "\$SSH_AUTH_METHOD" == "password" && -z "\$SSH_PASSWORD" && "\$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
  read -r -s -p "SSH 密码: " SSH_PASSWORD
  printf '\n'
fi
if [[ "\$SSH_AUTH_METHOD" == "key" && -z "\$SSH_KEY_FILE" && "\$NON_INTERACTIVE" -eq 0 && -t 0 ]]; then
  read -r -p "SSH 私钥绝对路径: " SSH_KEY_FILE
fi

mkdir -p "\$(dirname "\$CONFIG_FILE")"
umask 077
TEMP_FILE="\$(mktemp "\${CONFIG_FILE}.tmp.XXXXXX")"
trap 'rm -f "\$TEMP_FILE"' EXIT
{
  printf '#!/usr/bin/env bash\n\n'
  printf '# 本文件仅保存在本机，禁止提交到 Git。\n'
  shell_export PO_DEPLOY_HOST "\$DEPLOY_HOST"
  shell_export PO_DEPLOY_USER "\$DEPLOY_USER"
  shell_export PO_DEPLOY_PORT "\$DEPLOY_PORT"
  shell_export PO_SSH_AUTH_METHOD "\$SSH_AUTH_METHOD"
  shell_export PO_SSH_PASSWORD "\$SSH_PASSWORD"
  shell_export PO_SSH_KEY_FILE "\$SSH_KEY_FILE"
  printf '\n'
  shell_export PO_PROJECT_DOMAIN "\$PROJECT_DOMAIN"
  shell_export PO_APP_PORT "\$APP_PORT"
  shell_export PO_REMOTE_ROOT "/service/\$PROJECT_SLUG"
  printf 'export PO_REMOTE_CURRENT_DIR="\$PO_REMOTE_ROOT/current"\n'
  printf 'export PO_REMOTE_RELEASES_DIR="\$PO_REMOTE_ROOT/releases"\n'
  printf 'export PO_REMOTE_SHARED_DIR="\$PO_REMOTE_ROOT/shared"\n'
  printf 'export PO_REMOTE_DATA_DIR="\$PO_REMOTE_ROOT/data"\n'
  printf 'export PO_REMOTE_UPLOADS_DIR="\$PO_REMOTE_ROOT/uploads"\n'
  printf 'export PO_REMOTE_LOG_DIR="\$PO_REMOTE_ROOT/logs"\n'
  shell_export PO_REMOTE_ENV_DIR "/etc/\$PROJECT_SLUG"
  printf 'export PO_REMOTE_ENV_FILE="\$PO_REMOTE_ENV_DIR/%s.env"\n' "\$PROJECT_SLUG"
  shell_export PO_REMOTE_SERVICE_NAME "\$PROJECT_SLUG.service"
  shell_export PO_REMOTE_NGINX_SITES_DIR "/etc/nginx/projects.d"
  shell_export PO_REMOTE_NGINX_INCLUDE_CONF "/etc/nginx/conf.d/00-managed-projects.conf"
  printf 'export PO_REMOTE_NGINX_CONF="\$PO_REMOTE_NGINX_SITES_DIR/%s.conf"\n' "\$PROJECT_SLUG"
  shell_export PO_CERTBOT_WEBROOT "/var/www/certbot"
  shell_export PO_NGINX_SETUP_MODE "auto"
  printf 'export PO_REMOTE_WEB_DIR="\$PO_REMOTE_ROOT/web"\n'
  printf 'export PO_REMOTE_ADMIN_WEB_DIR="\$PO_REMOTE_ROOT/admin-web"\n'
  shell_export PO_REMOTE_RUN_USER "\$DEPLOY_USER"
  shell_export PO_REMOTE_RELEASE_KEEP_COUNT "2"
} > "\$TEMP_FILE"
mv "\$TEMP_FILE" "\$CONFIG_FILE"
trap - EXIT
chmod 600 "\$CONFIG_FILE"
ensure_gitignore_entry
ensure_not_tracked

echo "服务器配置已创建: \$CONFIG_FILE"
if [[ -z "\$DEPLOY_HOST" ]]; then
  echo "请在发布前填写 PO_DEPLOY_HOST。" >&2
fi
if [[ -z "\$PROJECT_DOMAIN" ]]; then
  echo "请在发布前填写 PO_PROJECT_DOMAIN。" >&2
fi
if [[ "\$SSH_AUTH_METHOD" == "password" && -z "\$SSH_PASSWORD" ]]; then
  echo "请在发布前在该本机文件中填写 PO_SSH_PASSWORD。" >&2
fi
if [[ "\$SSH_AUTH_METHOD" == "key" && -z "\$SSH_KEY_FILE" ]]; then
  echo "请在发布前填写 PO_SSH_KEY_FILE，或改用 agent 认证。" >&2
fi
EOF

cat > "$NGINX_CONFIG_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

MANAGED_MARKER="# managed-by: aliyun-release-script-generator"
BOOTSTRAP_MARKER="# managed-phase: http-bootstrap"
FINAL_MARKER="# managed-phase: final"
PROJECT_NAME="${PO_PROJECT_NAME:-}"
PROJECT_DOMAIN="${PO_PROJECT_DOMAIN:-}"
NGINX_SETUP_MODE="${PO_NGINX_SETUP_MODE:-auto}"
NGINX_SITES_DIR="${PO_REMOTE_NGINX_SITES_DIR:-/etc/nginx/projects.d}"
NGINX_INCLUDE_CONF="${PO_REMOTE_NGINX_INCLUDE_CONF:-/etc/nginx/conf.d/00-managed-projects.conf}"
NGINX_SITE_CONF="${PO_REMOTE_NGINX_CONF:-${NGINX_SITES_DIR}/${PROJECT_NAME}.conf}"
CERTBOT_WEBROOT="${PO_CERTBOT_WEBROOT:-/var/www/certbot}"
LETSENCRYPT_LIVE_DIR="${PO_LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}"
RENEWAL_HOOK_DIR="${PO_LETSENCRYPT_RENEWAL_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
FINAL_TEMPLATE="${PO_NGINX_FINAL_TEMPLATE:-}"
TEST_MODE="${PO_NGINX_TEST_MODE:-0}"

usage() {
  cat <<'USAGE'
Usage:
  configure_nginx_site.sh [--mode <auto|skip|force>]

Required environment:
  PO_PROJECT_NAME, PO_PROJECT_DOMAIN, PO_NGINX_FINAL_TEMPLATE
USAGE
}

fail() {
  echo "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少服务器命令: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) NGINX_SETUP_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "未知参数: $1" ;;
  esac
done

case "$NGINX_SETUP_MODE" in
  auto|skip|force) ;;
  *) fail "PO_NGINX_SETUP_MODE 仅支持 auto / skip / force" ;;
esac

require_cmd nginx
if [[ "$NGINX_SETUP_MODE" == "skip" ]]; then
  nginx -t
  echo "Nginx 配置由外部维护，本次发布未修改或 reload。"
  exit 0
fi

if [[ "$TEST_MODE" != "1" && "$(id -u)" -ne 0 ]]; then
  fail "configure_nginx_site.sh 必须以 root 运行"
fi
if [[ -z "$PROJECT_NAME" || ! "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  fail "PO_PROJECT_NAME 为空或格式非法"
fi
if [[ -z "$PROJECT_DOMAIN" || ! "$PROJECT_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
  fail "PO_PROJECT_DOMAIN 为空或格式非法"
fi
if [[ -z "$FINAL_TEMPLATE" || ! -f "$FINAL_TEMPLATE" ]]; then
  fail "缺少最终 Nginx 模板: $FINAL_TEMPLATE"
fi
case "$NGINX_SITES_DIR|$NGINX_INCLUDE_CONF|$NGINX_SITE_CONF|$CERTBOT_WEBROOT" in
  *$'\n'*|*"'"*|*'"'*) fail "Nginx 路径包含不安全字符" ;;
esac

require_cmd install
require_cmd mktemp
require_cmd systemctl
require_cmd awk

TMP_DIR="$(mktemp -d)"
GLOBAL_INCLUDE_CHANGED=0
cleanup() {
  local status="$?"
  rm -rf "$TMP_DIR"
  exit "$status"
}
trap cleanup EXIT

is_managed_site() {
  [[ -f "$NGINX_SITE_CONF" ]] && grep -Fqx "$MANAGED_MARKER" "$NGINX_SITE_CONF"
}

site_phase() {
  if [[ ! -f "$NGINX_SITE_CONF" ]]; then
    printf 'missing'
  elif ! is_managed_site; then
    printf 'external'
  elif grep -Fqx "$BOOTSTRAP_MARKER" "$NGINX_SITE_CONF"; then
    printf 'http-bootstrap'
  elif grep -Fqx "$FINAL_MARKER" "$NGINX_SITE_CONF"; then
    printf 'final'
  else
    printf 'managed-unknown'
  fi
}

certificate_exists() {
  [[ -f "$LETSENCRYPT_LIVE_DIR/$PROJECT_DOMAIN/fullchain.pem" && -f "$LETSENCRYPT_LIVE_DIR/$PROJECT_DOMAIN/privkey.pem" ]]
}

ensure_global_include() {
  local expected="include ${NGINX_SITES_DIR}/*.conf;"
  local actual=""
  install -d -m 0755 "$NGINX_SITES_DIR" "$CERTBOT_WEBROOT" "$(dirname "$NGINX_INCLUDE_CONF")"
  if [[ -f "$NGINX_INCLUDE_CONF" ]]; then
    actual="$(sed '/^[[:space:]]*$/d' "$NGINX_INCLUDE_CONF")"
    [[ "$actual" == "$expected" ]] || fail "全局 Nginx include 已存在但内容不一致: $NGINX_INCLUDE_CONF"
    return
  fi
  printf '%s\n' "$expected" > "$TMP_DIR/global-include.conf"
  install -m 0644 "$TMP_DIR/global-include.conf" "$NGINX_INCLUDE_CONF"
  GLOBAL_INCLUDE_CHANGED=1
}

check_duplicate_server_name() {
  local nginx_dump="$TMP_DIR/nginx.dump"
  nginx -T > "$nginx_dump" 2>/dev/null || fail "无法读取现有 Nginx 配置，请先修复 nginx -T"
  if awk -v domain="$PROJECT_DOMAIN" '
    {
      in_server_name = 0
      for (field_no = 1; field_no <= NF; field_no += 1) {
        token = $field_no
        if (token == "server_name") {
          in_server_name = 1
          continue
        }
        if (in_server_name) {
          gsub(/;/, "", token)
          if (token == domain) found = 1
          if ($field_no ~ /;/) in_server_name = 0
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$nginx_dump"; then
    fail "其他 Nginx 配置已声明 server_name ${PROJECT_DOMAIN}，拒绝创建重复站点"
  fi
}

validate_final_template() {
  local escaped_domain="${PROJECT_DOMAIN//./\\.}"
  grep -E "server_name[[:space:]]+[^;]*${escaped_domain}([[:space:];])" "$FINAL_TEMPLATE" >/dev/null || \
    fail "最终 Nginx 模板未声明 server_name $PROJECT_DOMAIN"
  grep -F "/etc/letsencrypt/live/$PROJECT_DOMAIN/fullchain.pem" "$FINAL_TEMPLATE" >/dev/null || \
    fail "最终 Nginx 模板证书路径与项目域名不一致"
}

write_bootstrap_config() {
  cat > "$TMP_DIR/bootstrap.conf" <<BOOTSTRAP
$MANAGED_MARKER
$BOOTSTRAP_MARKER
server {
        listen 80;
        server_name $PROJECT_DOMAIN;

        location ^~ /.well-known/acme-challenge/ {
                root $CERTBOT_WEBROOT;
                default_type text/plain;
        }

        location / {
                return 503;
        }
}
BOOTSTRAP
}

write_final_config() {
  {
    printf '%s\n%s\n' "$MANAGED_MARKER" "$FINAL_MARKER"
    sed -e "/^${MANAGED_MARKER//\//\\/}$/d" -e "/^${FINAL_MARKER//\//\\/}$/d" "$FINAL_TEMPLATE"
  } > "$TMP_DIR/final.conf"
}

install_and_reload() {
  local source_file="$1"
  local previous_file="$TMP_DIR/previous.conf"
  local had_previous=0
  if [[ -f "$NGINX_SITE_CONF" ]]; then
    cp -p "$NGINX_SITE_CONF" "$previous_file"
    had_previous=1
  fi
  install -m 0644 "$source_file" "$NGINX_SITE_CONF"
  if ! nginx -t; then
    if [[ "$had_previous" -eq 1 ]]; then
      install -m 0644 "$previous_file" "$NGINX_SITE_CONF"
    else
      rm -f "$NGINX_SITE_CONF"
    fi
    nginx -t >/dev/null 2>&1 || true
    fail "Nginx 配置测试失败，已恢复上一份配置"
  fi
  systemctl reload nginx
}

ensure_renewal_hook() {
  local hook_dir="$RENEWAL_HOOK_DIR"
  local hook_file="$hook_dir/10-reload-nginx.sh"
  if [[ -e "$hook_file" ]]; then
    return
  fi
  install -d -m 0755 "$hook_dir"
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '%q -t\n' "$(command -v nginx)"
    printf '%q reload nginx\n' "$(command -v systemctl)"
  } > "$TMP_DIR/reload-nginx.sh"
  install -m 0755 "$TMP_DIR/reload-nginx.sh" "$hook_file"
}

PHASE="$(site_phase)"
if [[ "$PHASE" == "external" || "$PHASE" == "managed-unknown" ]]; then
  fail "项目 Nginx 配置不是可识别的受管配置，拒绝覆盖: $NGINX_SITE_CONF"
fi
if [[ "$PHASE" == "missing" ]]; then
  check_duplicate_server_name
fi

validate_final_template

if [[ "$NGINX_SETUP_MODE" == "auto" && "$PHASE" == "final" ]]; then
  certificate_exists || fail "受管 HTTPS 配置存在但证书缺失，请人工检查后再发布"
  ensure_global_include
  nginx -t
  if [[ "$GLOBAL_INCLUDE_CHANGED" -eq 1 ]]; then
    systemctl reload nginx
    echo "已修复全局 Nginx include，并保留现有项目 HTTPS 配置。"
  else
    echo "Nginx 与证书已完成初始化，本次发布未修改或 reload。"
  fi
  exit 0
fi

if certificate_exists; then
  ensure_global_include
  ensure_renewal_hook
  write_final_config
  install_and_reload "$TMP_DIR/final.conf"
  echo "Nginx HTTPS 配置已安装: $NGINX_SITE_CONF"
  exit 0
fi

require_cmd certbot
require_cmd getent
certbot show_account >/dev/null 2>&1 || fail "Certbot 尚无可复用账户，请先在服务器完成账户注册"
getent ahosts "$PROJECT_DOMAIN" >/dev/null 2>&1 || fail "域名尚未解析: $PROJECT_DOMAIN"

ensure_global_include
write_bootstrap_config
install_and_reload "$TMP_DIR/bootstrap.conf"

certbot certonly \
  --webroot \
  --webroot-path "$CERTBOT_WEBROOT" \
  --cert-name "$PROJECT_DOMAIN" \
  -d "$PROJECT_DOMAIN" \
  --non-interactive \
  --agree-tos

certificate_exists || fail "Certbot 返回成功但证书文件不存在: $PROJECT_DOMAIN"
ensure_renewal_hook
write_final_config
install_and_reload "$TMP_DIR/final.conf"
echo "Nginx 与 HTTPS 证书初始化完成: $PROJECT_DOMAIN"
EOF

cat > "$PACKAGE_SCRIPT" <<EOF
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../../.." && pwd)"
DEPLOY_DIR="\$ROOT_DIR/deploy/aliyun"
ENV_FILE=$ENV_TEMPLATE_Q
RELEASE_DIR="\$DEPLOY_DIR/release"
STAGE_DIR="\$(mktemp -d)"
STAMP="\${1:-\$(date +%Y%m%d-%H%M%S)}"
ARTIFACT="\$RELEASE_DIR/$RELEASE_PREFIX-\$STAMP.tgz"
VERSION_PLAN_FILE="\${ARTIFACT%.tgz}.version-plan.json"
RELEASE_TYPE_ZH="\${PO_RELEASE_TYPE_ZH:-}"

cleanup() {
  rm -rf "\$STAGE_DIR"
}
trap cleanup EXIT

require_cmd() {
  if ! command -v "\$1" >/dev/null 2>&1; then
    echo "缺少命令: \$1" >&2
    exit 1
  fi
}

require_file() {
  local file="\$1"
  if [[ ! -f "\$file" ]]; then
    echo "缺少文件: \$file" >&2
    exit 1
  fi
}

require_file "\$ENV_FILE"
require_cmd node

set -a
source "\$ENV_FILE"
set +a

if [[ -z "\$RELEASE_TYPE_ZH" ]]; then
  echo "缺少环境变量: PO_RELEASE_TYPE_ZH（可选值：大改版 / 新功能 / 修复优化）" >&2
  exit 1
fi

mkdir -p "\$RELEASE_DIR"
mkdir -p "\$STAGE_DIR/deploy/aliyun" "\$STAGE_DIR/$API_DIST_PARENT_Q"

cd "\$ROOT_DIR"

node "\$DEPLOY_DIR/scripts/manage_release_version.mjs" plan \\
  --release-type-zh "\$RELEASE_TYPE_ZH" \\
  --output "\$VERSION_PLAN_FILE"

$PACKAGE_BUILD_BLOCK

cp package.json "\$STAGE_DIR/"
if [[ -f package-lock.json ]]; then
  cp package-lock.json "\$STAGE_DIR/"
fi
cp -R $API_DIST_PATH_Q "\$STAGE_DIR/$API_DIST_PATH_Q"$PACKAGE_STAGE_COPY_BLOCK

cp $SERVICE_TEMPLATE_Q "\$STAGE_DIR/deploy/aliyun/"
cp $NGINX_TEMPLATE_Q "\$STAGE_DIR/deploy/aliyun/"
cp "\$DEPLOY_DIR/scripts/server-bootstrap.sh" "\$STAGE_DIR/deploy/aliyun/server-bootstrap.sh"
cp "\$DEPLOY_DIR/scripts/start-prod.sh" "\$STAGE_DIR/deploy/aliyun/start-prod.sh"
cp "\$DEPLOY_DIR/scripts/manage_release_version.mjs" "\$STAGE_DIR/deploy/aliyun/manage_release_version.mjs"
cp "\$DEPLOY_DIR/scripts/manage_git_release_commit.mjs" "\$STAGE_DIR/deploy/aliyun/manage_git_release_commit.mjs"
cp "\$DEPLOY_DIR/scripts/sync_git_release.sh" "\$STAGE_DIR/deploy/aliyun/sync_git_release.sh"
cp "\$DEPLOY_DIR/scripts/configure_nginx_site.sh" "\$STAGE_DIR/deploy/aliyun/configure_nginx_site.sh"

tar -czf "\$ARTIFACT" -C "\$STAGE_DIR" .

echo "发布包已生成: \$ARTIFACT"
echo "版本计划文件已生成: \$VERSION_PLAN_FILE"
EOF

cat > "$DEPLOY_SCRIPT" <<EOF
#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../../.." && pwd)"
DEPLOY_DIR="\$ROOT_DIR/deploy/aliyun"
ENV_TEMPLATE=$ENV_TEMPLATE_Q
SERVICE_TEMPLATE=$SERVICE_TEMPLATE_Q
NGINX_TEMPLATE=$NGINX_TEMPLATE_Q
DEFAULT_DEPLOY_ENV_FILE="\$DEPLOY_DIR/.deploy.local.sh"
DEPLOY_ENV_FILE="\${PO_DEPLOY_ENV_FILE:-\$DEFAULT_DEPLOY_ENV_FILE}"
RELEASE_DIR="\$DEPLOY_DIR/release"
STAMP="\${1:-}"

require_cmd() {
  if ! command -v "\$1" >/dev/null 2>&1; then
    echo "缺少命令: \$1" >&2
    exit 1
  fi
}

require_env() {
  local key="\$1"
  if [[ -z "\${!key:-}" ]]; then
    echo "缺少环境变量: \$key" >&2
    exit 1
  fi
}

latest_artifact() {
  local artifacts=()
  local artifact
  shopt -s nullglob
  for artifact in "\$RELEASE_DIR"/$RELEASE_PREFIX-*.tgz; do
    artifacts+=("\$artifact")
  done
  shopt -u nullglob
  if [[ \${#artifacts[@]} -eq 0 ]]; then
    return 0
  fi
  ls -1t "\${artifacts[@]}" | head -n 1
}

validate_artifact() {
  local artifact="\$1"
  local required_paths=(
    "package.json"
    "$API_DIST_PATH"
    "deploy/aliyun/$(basename "$SERVICE_TEMPLATE")"
    "deploy/aliyun/$(basename "$NGINX_TEMPLATE")"
  )$REQUIRED_PATHS_BLOCK
  local required_path
  for required_path in "\${required_paths[@]}"; do
    if ! tar -tzf "\$artifact" "\$required_path" >/dev/null 2>&1; then
      echo "发布包内容不完整，缺少: \$required_path" >&2
      exit 1
    fi
  done
}

if [[ -f "\$DEPLOY_ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "\$DEPLOY_ENV_FILE"
fi

DEPLOY_HOST="\${PO_DEPLOY_HOST:-}"
DEPLOY_USER="\${PO_DEPLOY_USER:-}"
DEPLOY_PORT="\${PO_DEPLOY_PORT:-22}"
SSH_PASSWORD="\${PO_SSH_PASSWORD:-}"
SSH_KEY_FILE="\${PO_SSH_KEY_FILE:-}"
SSH_AUTH_METHOD="\${PO_SSH_AUTH_METHOD:-}"
REMOTE_RELEASE_KEEP_COUNT="\${PO_REMOTE_RELEASE_KEEP_COUNT:-2}"
REMOTE_ROOT="\${PO_REMOTE_ROOT:-/service/$PROJECT_SLUG}"
REMOTE_CURRENT_DIR="\${PO_REMOTE_CURRENT_DIR:-\$REMOTE_ROOT/current}"
REMOTE_RELEASES_DIR="\${PO_REMOTE_RELEASES_DIR:-\$REMOTE_ROOT/releases}"
REMOTE_SHARED_DIR="\${PO_REMOTE_SHARED_DIR:-\$REMOTE_ROOT/shared}"
REMOTE_DATA_DIR="\${PO_REMOTE_DATA_DIR:-\$REMOTE_ROOT/data}"
REMOTE_UPLOADS_DIR="\${PO_REMOTE_UPLOADS_DIR:-\$REMOTE_ROOT/uploads}"
REMOTE_LOG_DIR="\${PO_REMOTE_LOG_DIR:-\$REMOTE_ROOT/logs}"
REMOTE_ENV_DIR="\${PO_REMOTE_ENV_DIR:-/etc/$PROJECT_SLUG}"
REMOTE_ENV_FILE="\${PO_REMOTE_ENV_FILE:-\$REMOTE_ENV_DIR/$PROJECT_SLUG.env}"
REMOTE_SERVICE_NAME="\${PO_REMOTE_SERVICE_NAME:-$PROJECT_SLUG.service}"
PROJECT_DOMAIN="\${PO_PROJECT_DOMAIN:-$PROJECT_DOMAIN}"
APP_PORT="\${PO_APP_PORT:-$APP_PORT}"
REMOTE_NGINX_SITES_DIR="\${PO_REMOTE_NGINX_SITES_DIR:-/etc/nginx/projects.d}"
REMOTE_NGINX_INCLUDE_CONF="\${PO_REMOTE_NGINX_INCLUDE_CONF:-/etc/nginx/conf.d/00-managed-projects.conf}"
REMOTE_NGINX_CONF="\${PO_REMOTE_NGINX_CONF:-\$REMOTE_NGINX_SITES_DIR/$PROJECT_SLUG.conf}"
CERTBOT_WEBROOT="\${PO_CERTBOT_WEBROOT:-/var/www/certbot}"
NGINX_SETUP_MODE="\${PO_NGINX_SETUP_MODE:-}"
REMOTE_WEB_DIR="\${PO_REMOTE_WEB_DIR:-\$REMOTE_ROOT/web}"
REMOTE_ADMIN_WEB_DIR="\${PO_REMOTE_ADMIN_WEB_DIR:-\$REMOTE_ROOT/admin-web}"
REMOTE_RUN_USER="\${PO_REMOTE_RUN_USER:-\$DEPLOY_USER}"

if [[ -z "\$NGINX_SETUP_MODE" ]]; then
  case "\$REMOTE_NGINX_CONF" in
    /etc/nginx/conf.d/*.conf) NGINX_SETUP_MODE="skip" ;;
    *) NGINX_SETUP_MODE="auto" ;;
  esac
fi

if [[ -z "\$SSH_AUTH_METHOD" ]]; then
  if [[ -n "\$SSH_PASSWORD" ]]; then
    SSH_AUTH_METHOD="password"
  elif [[ -n "\$SSH_KEY_FILE" ]]; then
    SSH_AUTH_METHOD="key"
  else
    SSH_AUTH_METHOD="agent"
  fi
fi
case "\$SSH_AUTH_METHOD" in
  password)
    if [[ -z "\$SSH_PASSWORD" ]]; then
      echo "PO_SSH_AUTH_METHOD=password 时必须在本机配置 PO_SSH_PASSWORD" >&2
      exit 1
    fi
    ;;
  key)
    if [[ -z "\$SSH_KEY_FILE" || ! -f "\$SSH_KEY_FILE" ]]; then
      echo "PO_SSH_AUTH_METHOD=key 时必须配置存在的 PO_SSH_KEY_FILE" >&2
      exit 1
    fi
    ;;
  agent) ;;
  *)
    echo "PO_SSH_AUTH_METHOD 仅支持 password / key / agent" >&2
    exit 1
    ;;
esac

case "\$NGINX_SETUP_MODE" in
  auto|skip|force) ;;
  *)
    echo "PO_NGINX_SETUP_MODE 仅支持 auto / skip / force" >&2
    exit 1
    ;;
esac
if [[ "\$NGINX_SETUP_MODE" != "skip" && -z "\$PROJECT_DOMAIN" ]]; then
  echo "自动配置 Nginx 时必须设置 PO_PROJECT_DOMAIN" >&2
  exit 1
fi
if [[ ! "\$APP_PORT" =~ ^[0-9]+$ || "\$APP_PORT" -lt 1 || "\$APP_PORT" -gt 65535 ]]; then
  echo "PO_APP_PORT 必须是 1-65535 的数字端口" >&2
  exit 1
fi

if [[ -n "\$STAMP" ]]; then
  ARTIFACT="\$RELEASE_DIR/$RELEASE_PREFIX-\$STAMP.tgz"
else
  ARTIFACT="\$(latest_artifact)"
fi
VERSION_PLAN_FILE="\${ARTIFACT%.tgz}.version-plan.json"
GIT_APPROVAL_FILE="\${PO_GIT_RELEASE_APPROVAL_FILE:-\$DEPLOY_DIR/.git-release-approval.local.json}"

if [[ ! -f "\${ARTIFACT:-}" ]]; then
  echo "未找到发布包，请先执行 package_release.sh" >&2
  exit 1
fi

if [[ ! -f "\$VERSION_PLAN_FILE" ]]; then
  echo "未找到版本计划文件: \$VERSION_PLAN_FILE" >&2
  echo "请重新执行 package_release.sh 生成与发布包匹配的版本计划文件" >&2
  exit 1
fi

require_cmd ssh
require_cmd scp
require_cmd sed
require_cmd tar
require_cmd node
require_env DEPLOY_HOST
require_env DEPLOY_USER
validate_artifact "\$ARTIFACT"

RELEASE_GIT_TAG="\$(node -e 'const fs=require("fs"); const plan=JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (!plan.gitTag) process.exit(1); process.stdout.write(plan.gitTag);' "\$VERSION_PLAN_FILE")"
node "\$DEPLOY_DIR/scripts/manage_git_release_commit.mjs" verify \\
  --approval-file "\$GIT_APPROVAL_FILE" \\
  --git-tag "\$RELEASE_GIT_TAG"

run_scp() {
  local source_path="\$1"
  local remote_path="\$2"

  if [[ "\$SSH_AUTH_METHOD" == "password" ]]; then
    require_cmd expect
    DEPLOY_HOST="\$DEPLOY_HOST" \\
    DEPLOY_USER="\$DEPLOY_USER" \\
    DEPLOY_PORT="\$DEPLOY_PORT" \\
    SSH_PASSWORD="\$SSH_PASSWORD" \\
    SOURCE_PATH="\$source_path" \\
    REMOTE_PATH="\$remote_path" \\
    expect <<'EXPECT_EOF'
set timeout -1
set password \$env(SSH_PASSWORD)
set host \$env(DEPLOY_HOST)
set user \$env(DEPLOY_USER)
set port \$env(DEPLOY_PORT)
set source \$env(SOURCE_PATH)
set target \$env(REMOTE_PATH)
spawn scp -P \$port -o StrictHostKeyChecking=accept-new \$source "\$user@\$host:\$target"
expect {
  -re {.*yes/no.*} { send "yes\r"; exp_continue }
  -re {.*[Pp]assword:.*} { send "\$password\r"; exp_continue }
  -re {.*\[sudo\].*[Pp]assword.*} { send "\$password\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EXPECT_EOF
  else
    local scp_args=(-P "\$DEPLOY_PORT" -o StrictHostKeyChecking=accept-new)
    if [[ "\$SSH_AUTH_METHOD" == "key" ]]; then
      scp_args+=(-o IdentitiesOnly=yes -i "\$SSH_KEY_FILE")
    fi
    scp "\${scp_args[@]}" "\$source_path" "\$DEPLOY_USER@\$DEPLOY_HOST:\$remote_path"
  fi
}

run_ssh() {
  local remote_command="\$1"

  if [[ "\$SSH_AUTH_METHOD" == "password" ]]; then
    require_cmd expect
    DEPLOY_HOST="\$DEPLOY_HOST" \\
    DEPLOY_USER="\$DEPLOY_USER" \\
    DEPLOY_PORT="\$DEPLOY_PORT" \\
    SSH_PASSWORD="\$SSH_PASSWORD" \\
    REMOTE_COMMAND="\$remote_command" \\
    expect <<'EXPECT_EOF'
set timeout -1
set password \$env(SSH_PASSWORD)
set host \$env(DEPLOY_HOST)
set user \$env(DEPLOY_USER)
set port \$env(DEPLOY_PORT)
set command \$env(REMOTE_COMMAND)
spawn ssh -tt -p \$port -o StrictHostKeyChecking=accept-new "\$user@\$host" \$command
expect {
  -re {.*yes/no.*} { send "yes\r"; exp_continue }
  -re {.*[Pp]assword:.*} { send "\$password\r"; exp_continue }
  -re {.*\[sudo\].*[Pp]assword.*} { send "\$password\r"; exp_continue }
  eof
}
catch wait result
exit [lindex \$result 3]
EXPECT_EOF
  else
    local ssh_args=(-p "\$DEPLOY_PORT" -o StrictHostKeyChecking=accept-new)
    if [[ "\$SSH_AUTH_METHOD" == "key" ]]; then
      ssh_args+=(-o IdentitiesOnly=yes -i "\$SSH_KEY_FILE")
    fi
    ssh "\${ssh_args[@]}" "\$DEPLOY_USER@\$DEPLOY_HOST" "\$remote_command"
  fi
}

TMP_DIR="\$(mktemp -d)"
cleanup() {
  rm -rf "\$TMP_DIR"
}
trap cleanup EXIT

ENV_BASENAME="\$(basename "\$REMOTE_ENV_FILE")"
cp "\$ENV_TEMPLATE" "\$TMP_DIR/\$ENV_BASENAME"
if grep -q '^PORT=' "\$TMP_DIR/\$ENV_BASENAME"; then
  sed -e "s|^PORT=.*$|PORT=\$APP_PORT|" "\$TMP_DIR/\$ENV_BASENAME" > "\$TMP_DIR/\$ENV_BASENAME.next"
  mv "\$TMP_DIR/\$ENV_BASENAME.next" "\$TMP_DIR/\$ENV_BASENAME"
else
  printf 'PORT=%s\n' "\$APP_PORT" >> "\$TMP_DIR/\$ENV_BASENAME"
fi
if ! grep -q '^DATABASE_URL=' "\$TMP_DIR/\$ENV_BASENAME"; then
  printf 'DATABASE_URL=%s/$PROJECT_SLUG.sqlite\n' "\$REMOTE_DATA_DIR" >> "\$TMP_DIR/\$ENV_BASENAME"
fi
if ! grep -q '^UPLOAD_DIR=' "\$TMP_DIR/\$ENV_BASENAME"; then
  printf 'UPLOAD_DIR=%s\n' "\$REMOTE_UPLOADS_DIR" >> "\$TMP_DIR/\$ENV_BASENAME"
fi

LOCAL_SERVICE_FILE="\$TMP_DIR/\$REMOTE_SERVICE_NAME"
sed \\
  -e "s|__RUN_USER__|\$REMOTE_RUN_USER|g" \\
  -e "s|__REMOTE_CURRENT_DIR__|\$REMOTE_CURRENT_DIR|g" \\
  -e "s|__REMOTE_ENV_FILE__|\$REMOTE_ENV_FILE|g" \\
  "\$SERVICE_TEMPLATE" > "\$LOCAL_SERVICE_FILE"

REMOTE_ARTIFACT="/tmp/\$(basename "\$ARTIFACT")"
REMOTE_UPLOAD_ENV_FILE="/tmp/\$ENV_BASENAME"
REMOTE_SERVICE_FILE="/tmp/\$REMOTE_SERVICE_NAME"
RELEASE_NAME="\$(basename "\$ARTIFACT" .tgz)"
REMOTE_RELEASE_DIR="\$REMOTE_RELEASES_DIR/\$RELEASE_NAME"

echo "[$PROJECT_SLUG] 上传发布包..."
run_scp "\$ARTIFACT" "\$REMOTE_ARTIFACT"
run_scp "\$TMP_DIR/\$ENV_BASENAME" "\$REMOTE_UPLOAD_ENV_FILE"
run_scp "\$LOCAL_SERVICE_FILE" "\$REMOTE_SERVICE_FILE"

REMOTE_ENV_PREFIX=""
append_remote_env() {
  local key="\$1"
  local value="\$2"
  local quoted=""
  printf -v quoted '%q' "\$value"
  REMOTE_ENV_PREFIX+="\$key=\$quoted "
}

append_remote_env PROJECT_NAME "$PROJECT_SLUG"
append_remote_env PROJECT_DOMAIN "\$PROJECT_DOMAIN"
append_remote_env REMOTE_RELEASE_KEEP_COUNT "\$REMOTE_RELEASE_KEEP_COUNT"
append_remote_env REMOTE_ROOT "\$REMOTE_ROOT"
append_remote_env REMOTE_CURRENT_DIR "\$REMOTE_CURRENT_DIR"
append_remote_env REMOTE_RELEASES_DIR "\$REMOTE_RELEASES_DIR"
append_remote_env REMOTE_SHARED_DIR "\$REMOTE_SHARED_DIR"
append_remote_env REMOTE_DATA_DIR "\$REMOTE_DATA_DIR"
append_remote_env REMOTE_UPLOADS_DIR "\$REMOTE_UPLOADS_DIR"
append_remote_env REMOTE_LOG_DIR "\$REMOTE_LOG_DIR"
append_remote_env REMOTE_ENV_DIR "\$REMOTE_ENV_DIR"
append_remote_env REMOTE_ENV_FILE "\$REMOTE_ENV_FILE"
append_remote_env REMOTE_SERVICE_NAME "\$REMOTE_SERVICE_NAME"
append_remote_env REMOTE_WEB_DIR "\$REMOTE_WEB_DIR"
append_remote_env REMOTE_ADMIN_WEB_DIR "\$REMOTE_ADMIN_WEB_DIR"
append_remote_env REMOTE_RUN_USER "\$REMOTE_RUN_USER"
append_remote_env REMOTE_ARTIFACT "\$REMOTE_ARTIFACT"
append_remote_env REMOTE_UPLOAD_ENV_FILE "\$REMOTE_UPLOAD_ENV_FILE"
append_remote_env REMOTE_SERVICE_FILE "\$REMOTE_SERVICE_FILE"
append_remote_env REMOTE_RELEASE_DIR "\$REMOTE_RELEASE_DIR"
append_remote_env REMOTE_NGINX_SITES_DIR "\$REMOTE_NGINX_SITES_DIR"
append_remote_env REMOTE_NGINX_INCLUDE_CONF "\$REMOTE_NGINX_INCLUDE_CONF"
append_remote_env REMOTE_NGINX_CONF "\$REMOTE_NGINX_CONF"
append_remote_env CERTBOT_WEBROOT "\$CERTBOT_WEBROOT"
append_remote_env NGINX_SETUP_MODE "\$NGINX_SETUP_MODE"

REMOTE_CMD="\$REMOTE_ENV_PREFIX\$(cat <<'REMOTE_EOF'
bash -lc '
set -euo pipefail
KEEP_COUNT="\$REMOTE_RELEASE_KEEP_COUNT"
if ! [[ "\$KEEP_COUNT" =~ ^[0-9]+$ ]] || [[ "\$KEEP_COUNT" -lt 1 ]]; then
  KEEP_COUNT=2
fi
sudo mkdir -p $REMOTE_MKDIR_ARGS
sudo chown -R "\$REMOTE_RUN_USER":"\$REMOTE_RUN_USER" "\$REMOTE_ROOT"
rm -rf "\$REMOTE_RELEASE_DIR"
mkdir -p "\$REMOTE_RELEASE_DIR"
tar -xzf "\$REMOTE_ARTIFACT" -C "\$REMOTE_RELEASE_DIR"
cd "\$REMOTE_RELEASE_DIR"
$RUNTIME_INSTALL_CMD
rm -rf "\$REMOTE_CURRENT_DIR"
ln -sfn "\$REMOTE_RELEASE_DIR" "\$REMOTE_CURRENT_DIR"$REMOTE_SYNC_BLOCK
sudo install -o "\$REMOTE_RUN_USER" -g "\$REMOTE_RUN_USER" -m 600 "\$REMOTE_UPLOAD_ENV_FILE" "\$REMOTE_ENV_FILE"
sudo install -m 644 "\$REMOTE_SERVICE_FILE" "/etc/systemd/system/\$REMOTE_SERVICE_NAME"
sudo systemctl daemon-reload
sudo systemctl enable "\$REMOTE_SERVICE_NAME" >/dev/null
sudo systemctl restart "\$REMOTE_SERVICE_NAME"
set -a
source "\$REMOTE_ENV_FILE"
set +a
$HEALTH_CHECK_BLOCK
sudo env \
  PO_PROJECT_NAME="\$PROJECT_NAME" \
  PO_PROJECT_DOMAIN="\$PROJECT_DOMAIN" \
  PO_NGINX_SETUP_MODE="\$NGINX_SETUP_MODE" \
  PO_REMOTE_NGINX_SITES_DIR="\$REMOTE_NGINX_SITES_DIR" \
  PO_REMOTE_NGINX_INCLUDE_CONF="\$REMOTE_NGINX_INCLUDE_CONF" \
  PO_REMOTE_NGINX_CONF="\$REMOTE_NGINX_CONF" \
  PO_CERTBOT_WEBROOT="\$CERTBOT_WEBROOT" \
  PO_NGINX_FINAL_TEMPLATE="\$REMOTE_CURRENT_DIR/deploy/aliyun/$NGINX_TEMPLATE_BASENAME" \
  bash "\$REMOTE_CURRENT_DIR/deploy/aliyun/configure_nginx_site.sh"
mapfile -t OLD_RELEASES < <(find "\$REMOTE_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | xargs -r ls -1dt | tail -n +\$((KEEP_COUNT + 1)))
if [[ "\${#OLD_RELEASES[@]}" -gt 0 ]]; then
  printf "清理旧版本 release: %s\n" "\${OLD_RELEASES[@]}"
  sudo rm -rf "\${OLD_RELEASES[@]}"
fi
'
REMOTE_EOF
)"

run_ssh "\$REMOTE_CMD"

VERSION_ENV_OUTPUT="\$(node "\$DEPLOY_DIR/scripts/manage_release_version.mjs" apply --plan-file "\$VERSION_PLAN_FILE" --format env)"
eval "\$VERSION_ENV_OUTPUT"

bash "\$DEPLOY_DIR/scripts/sync_git_release.sh" \\
  --git-tag "\$RELEASE_GIT_TAG" \\
  --display-version "\$RELEASE_DISPLAY_VERSION" \\
  --release-type-zh "\$RELEASE_TYPE_ZH" \\
  --approval-file "\$GIT_APPROVAL_FILE"

echo "[$PROJECT_SLUG] 版本已同步: \$RELEASE_DISPLAY_VERSION"
echo "[$PROJECT_SLUG] 发布完成"
EOF

cat > "$VERSION_SCRIPT" <<'EOF'
#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../../..');
const packageJsonPath = path.join(repoRoot, 'package.json');
const versionFilePath = path.join(repoRoot, 'deploy', 'aliyun', 'release-version.json');

const releaseTypeMap = {
  '大改版': 'major',
  '新功能': 'minor',
  '修复优化': 'patch',
};

function fail(message) {
  console.error(message);
  process.exit(1);
}

function usage() {
  console.log(`Usage:
  node deploy/aliyun/scripts/manage_release_version.mjs plan --release-type-zh <大改版|新功能|修复优化> --output <file>
  node deploy/aliyun/scripts/manage_release_version.mjs apply --plan-file <file> [--format env|json|text]`);
}

function parseArgs(argv) {
  const result = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith('--')) {
      fail(`未知参数: ${key}`);
    }
    const value = argv[i + 1];
    if (value == null || value.startsWith('--')) {
      fail(`参数缺少值: ${key}`);
    }
    result[key.slice(2)] = value;
    i += 1;
  }
  return result;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function parseSemver(value) {
  if (typeof value !== 'string') {
    return null;
  }
  const match = value.trim().match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) {
    return null;
  }
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}

function formatSemver(semver) {
  return `${semver.major}.${semver.minor}.${semver.patch}`;
}

function bumpSemver(semver, releaseTypeKey) {
  if (releaseTypeKey === 'major') {
    return { major: semver.major + 1, minor: 0, patch: 0 };
  }
  if (releaseTypeKey === 'minor') {
    return { major: semver.major, minor: semver.minor + 1, patch: 0 };
  }
  return { major: semver.major, minor: semver.minor, patch: semver.patch + 1 };
}

function getCurrentState() {
  if (!fs.existsSync(packageJsonPath)) {
    fail(`未找到 package.json: ${packageJsonPath}`);
  }

  const packageJson = readJson(packageJsonPath);
  const versionMeta = fs.existsSync(versionFilePath) ? readJson(versionFilePath) : {};
  const metaSemver = parseSemver(versionMeta.semver);
  const packageSemver = parseSemver(packageJson.version);
  const semver = metaSemver ?? packageSemver;
  const buildCount = Number.isInteger(versionMeta.buildCount) && versionMeta.buildCount >= 0
    ? versionMeta.buildCount
    : 0;

  return {
    packageJson,
    semver,
    semverString: semver ? formatSemver(semver) : null,
    buildCount,
  };
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function makePlan(releaseTypeZh) {
  const releaseTypeKey = releaseTypeMap[releaseTypeZh];
  if (!releaseTypeKey) {
    fail(`不支持的发布类型: ${releaseTypeZh}（可选值：大改版 / 新功能 / 修复优化）`);
  }

  const state = getCurrentState();
  const nextSemver = state.semver ? bumpSemver(state.semver, releaseTypeKey) : { major: 1, minor: 0, patch: 0 };
  const nextSemverString = formatSemver(nextSemver);
  const nextBuildCount = state.buildCount + 1;

  return {
    schemaVersion: 1,
    projectName: state.packageJson.name ?? path.basename(repoRoot),
    releaseTypeZh,
    releaseTypeKey,
    baseSemver: state.semverString,
    previousBuildCount: state.buildCount,
    nextSemver: nextSemverString,
    nextBuildCount,
    displayVersion: `${nextSemverString} (${nextBuildCount})`,
    gitTag: `v${nextSemverString}-build.${nextBuildCount}`,
    plannedAt: new Date().toISOString(),
  };
}

function printApplyResult(plan, format) {
  if (format === 'json') {
    process.stdout.write(`${JSON.stringify(plan)}\n`);
    return;
  }

  if (format === 'env') {
    process.stdout.write([
      `RELEASE_SEMVER=${shellQuote(plan.nextSemver)}`,
      `RELEASE_BUILD_COUNT=${shellQuote(String(plan.nextBuildCount))}`,
      `RELEASE_DISPLAY_VERSION=${shellQuote(plan.displayVersion)}`,
      `RELEASE_GIT_TAG=${shellQuote(plan.gitTag)}`,
      `RELEASE_TYPE_ZH=${shellQuote(plan.releaseTypeZh)}`,
    ].join('\n'));
    process.stdout.write('\n');
    return;
  }

  console.log(`版本已更新为 ${plan.displayVersion}`);
}

const [command, ...restArgs] = process.argv.slice(2);
if (!command || command === '-h' || command === '--help') {
  usage();
  process.exit(command ? 0 : 1);
}

const args = parseArgs(restArgs);

if (command === 'plan') {
  if (!args['release-type-zh']) {
    fail('plan 缺少参数: --release-type-zh');
  }
  if (!args.output) {
    fail('plan 缺少参数: --output');
  }

  const plan = makePlan(args['release-type-zh']);
  writeJson(path.resolve(args.output), plan);
  console.log(`计划发布版本: ${plan.displayVersion}`);
  process.exit(0);
}

if (command === 'apply') {
  if (!args['plan-file']) {
    fail('apply 缺少参数: --plan-file');
  }

  const format = args.format ?? 'text';
  if (!['text', 'env', 'json'].includes(format)) {
    fail(`不支持的输出格式: ${format}`);
  }

  const planFilePath = path.resolve(args['plan-file']);
  if (!fs.existsSync(planFilePath)) {
    fail(`未找到版本计划文件: ${planFilePath}`);
  }

  const plan = readJson(planFilePath);
  const currentState = getCurrentState();
  if (currentState.semverString !== (plan.baseSemver ?? null) || currentState.buildCount !== plan.previousBuildCount) {
    fail('当前版本状态已变化，请重新执行 package_release.sh 生成新的版本计划文件。');
  }

  const packageJson = currentState.packageJson;
  packageJson.version = plan.nextSemver;
  writeJson(packageJsonPath, packageJson);

  writeJson(versionFilePath, {
    schemaVersion: 1,
    semver: plan.nextSemver,
    buildCount: plan.nextBuildCount,
    displayVersion: plan.displayVersion,
    lastReleaseTypeZh: plan.releaseTypeZh,
    lastReleasedAt: new Date().toISOString(),
    lastGitTag: plan.gitTag,
  });

  printApplyResult(plan, format);
  process.exit(0);
}

fail(`未知命令: ${command}`);
EOF

cat > "$GIT_COMMIT_SCRIPT" <<'EOF'
#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../../..');
const defaultApprovalFile = path.join(repoRoot, 'deploy', 'aliyun', '.git-release-approval.local.json');
const allowedTypes = 'feat|fix|refactor|perf|docs|test|build|ci|chore';
const fieldLabels = ['问题/需求', '实现结果', '影响范围', '验证方式', '关联任务', '风险与回滚'];

function fail(message) {
  console.error(message);
  process.exit(1);
}

function usage() {
  console.log(`Usage:
  manage_git_release_commit.mjs approve --message-file <file> --paths-file <file> --git-tag <tag>
    [--approval-file <file>] [--allow-untracked true] [--allow-initial-all true]
  manage_git_release_commit.mjs verify --approval-file <file> --git-tag <tag>
  manage_git_release_commit.mjs materialize --approval-file <file> --git-tag <tag>
    --message-output <file> --paths-output <file>`);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith('--')) fail(`未知参数: ${key}`);
    const value = argv[index + 1];
    if (value == null || value.startsWith('--')) fail(`参数缺少值: ${key}`);
    result[key.slice(2)] = value;
    index += 1;
  }
  return result;
}

function runGit(args, { allowFailure = false } = {}) {
  const result = spawnSync('git', ['-C', repoRoot, ...args], {
    encoding: null,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (result.error) fail(`无法执行 git: ${result.error.message}`);
  if (result.status !== 0 && !allowFailure) {
    fail(Buffer.from(result.stderr ?? '').toString('utf8').trim() || `git ${args.join(' ')} 执行失败`);
  }
  return result;
}

function isGitRepo() {
  return runGit(['rev-parse', '--is-inside-work-tree'], { allowFailure: true }).status === 0;
}

function ensureGitRepo() {
  if (isGitRepo()) return;
  if (!fs.existsSync(path.join(repoRoot, '.gitignore'))) {
    fail('当前项目还不是 Git 仓库且缺少 .gitignore，拒绝创建首次发布审批。');
  }
  runGit(['init']);
  runGit(['checkout', '-B', process.env.PO_GITHUB_DEFAULT_BRANCH || 'main']);
}

function hasHead() {
  return runGit(['rev-parse', '--verify', 'HEAD'], { allowFailure: true }).status === 0;
}

function nullList(buffer) {
  return Buffer.from(buffer ?? '').toString('utf8').split('\0').filter(Boolean);
}

function trackedChangePaths() {
  if (!hasHead()) return [];
  return [...new Set([
    ...nullList(runGit(['diff', '--name-only', '-z', 'HEAD']).stdout),
    ...nullList(runGit(['diff', '--cached', '--name-only', '-z']).stdout),
  ])].sort();
}

function untrackedPaths() {
  return nullList(runGit(['ls-files', '--others', '--exclude-standard', '-z']).stdout).sort();
}

function normalizeRepoPath(value) {
  const normalized = value.trim().replaceAll('\\', '/');
  if (!normalized || path.isAbsolute(normalized) || normalized === '..' || normalized.startsWith('../') || normalized.includes('/../')) {
    fail(`非法提交路径: ${value}`);
  }
  return normalized.replace(/^\.\//, '');
}

function readPaths(filePath) {
  if (!fs.existsSync(filePath)) fail(`未找到提交文件清单: ${filePath}`);
  const paths = fs.readFileSync(filePath, 'utf8').split(/\r?\n/).filter((line) => line.trim()).map(normalizeRepoPath);
  if (new Set(paths).size !== paths.length) fail('提交文件清单包含重复路径。');
  return paths.sort();
}

function validateMessage(message) {
  const normalized = message.replaceAll('\r\n', '\n').trim();
  const lines = normalized.split('\n');
  const titleMatch = lines[0]?.match(new RegExp(`^(${allowedTypes})\\(([A-Za-z0-9._/-]+)\\): (\\S.+)$`));
  if (!titleMatch) {
    fail('提交标题必须使用 <type>(<scope>): <明确的实现结果>，并使用允许的 type。');
  }

  const fields = {};
  let previousIndex = 0;
  for (let fieldIndex = 0; fieldIndex < fieldLabels.length; fieldIndex += 1) {
    const label = fieldLabels[fieldIndex];
    const matches = lines.map((line, index) => line.startsWith(`${label}：`) ? index : -1).filter((index) => index >= 0);
    if (matches.length !== 1 || matches[0] <= previousIndex) fail(`提交正文必须按固定顺序包含且仅包含一次“${label}：”。`);
    const start = matches[0];
    const nextLabel = fieldLabels[fieldIndex + 1];
    const end = nextLabel ? lines.findIndex((line, index) => index > start && line.startsWith(`${nextLabel}：`)) : lines.length;
    fields[label] = [lines[start].slice(label.length + 1), ...lines.slice(start + 1, end)].join('\n').trim();
    previousIndex = start;
  }

  const hasMeaningfulValue = (value) => Boolean(value) && !/^(无|none|n\/a)$/i.test(value.trim());
  if (!hasMeaningfulValue(fields['问题/需求']) && !hasMeaningfulValue(fields['实现结果'])) {
    fail('“问题/需求”和“实现结果”至少填写一项有效内容。');
  }
  if (!fields['验证方式'] || !/`[^`\n]+`/.test(fields['验证方式']) || !/(结果|通过|成功|失败|exit\s*0|passed|failed)/i.test(fields['验证方式'])) {
    fail('“验证方式”必须包含反引号包裹的实际命令及明确结果。');
  }
  return normalized;
}

function workspaceFingerprint() {
  const paths = [...new Set([...trackedChangePaths(), ...untrackedPaths()])].sort();
  const hash = crypto.createHash('sha256');
  for (const relativePath of paths) {
    const absolutePath = path.join(repoRoot, relativePath);
    hash.update(relativePath);
    hash.update('\0');
    if (!fs.existsSync(absolutePath)) {
      hash.update('deleted');
    } else {
      const stat = fs.lstatSync(absolutePath);
      hash.update(`mode:${stat.mode}`);
      hash.update('\0');
      if (stat.isSymbolicLink()) {
        hash.update(`link:${fs.readlinkSync(absolutePath)}`);
      } else if (stat.isFile()) {
        hash.update(fs.readFileSync(absolutePath));
      } else {
        hash.update(`mode:${stat.mode}`);
      }
    }
    hash.update('\0');
  }
  return { hash: hash.digest('hex'), paths };
}

function readApproval(filePath, gitTag) {
  if (!fs.existsSync(filePath)) {
    fail(`缺少 Git 发布审批信息: ${filePath}。请先通过 Codex Skill 梳理提交内容并自动生成审批文件。`);
  }
  const approval = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  if (approval.schemaVersion !== 1 || approval.confirmed !== true) fail('Git 发布审批文件无效。');
  if (approval.gitTag !== gitTag) fail('Git 发布审批对应的 tag 与当前 release plan 不一致，请重新梳理并生成。');
  validateMessage(approval.message);
  if (!Array.isArray(approval.approvedPaths)) fail('Git 发布确认文件缺少提交路径。');
  return approval;
}

function writePrivate(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, { mode: 0o600 });
  fs.chmodSync(filePath, 0o600);
}

const [command, ...rest] = process.argv.slice(2);
if (!command || command === '-h' || command === '--help') {
  usage();
  process.exit(command ? 0 : 1);
}
const args = parseArgs(rest);
const approvalFile = path.resolve(args['approval-file'] || defaultApprovalFile);

if (command === 'approve') {
  if (!args['message-file'] || !args['paths-file'] || !args['git-tag']) fail('approve 缺少 message-file、paths-file 或 git-tag。');
  ensureGitRepo();
  const message = validateMessage(fs.readFileSync(path.resolve(args['message-file']), 'utf8'));
  const approvedPaths = readPaths(path.resolve(args['paths-file']));
  const tracked = trackedChangePaths();
  const untracked = untrackedPaths();
  const approved = new Set(approvedPaths);
  const initialRepo = !hasHead();

  if (initialRepo) {
    if (args['allow-initial-all'] !== 'true') fail('首次建仓必须显式设置 --allow-initial-all true。');
    if (approvedPaths.length === 0) fail('首次建仓的确认清单不能为空。');
    const missing = untracked.filter((item) => !approved.has(item));
    const extra = approvedPaths.filter((item) => !untracked.includes(item));
    if (missing.length || extra.length) fail('首次建仓的确认清单必须与全部非忽略文件完全一致。');
  } else {
    const missingTracked = tracked.filter((item) => !approved.has(item));
    if (missingTracked.length) fail(`确认清单缺少已跟踪改动: ${missingTracked.join(', ')}`);
    const approvedUntracked = approvedPaths.filter((item) => untracked.includes(item));
    if (approvedUntracked.length && args['allow-untracked'] !== 'true') {
      fail('审批清单包含未跟踪文件，必须由 Agent 在提交摘要中明确列出后设置 --allow-untracked true。');
    }
    const valid = new Set([...tracked, ...(args['allow-untracked'] === 'true' ? untracked : [])]);
    const invalid = approvedPaths.filter((item) => !valid.has(item));
    if (invalid.length) fail(`确认清单包含无改动或未授权路径: ${invalid.join(', ')}`);
  }

  const fingerprint = workspaceFingerprint();
  writePrivate(approvalFile, `${JSON.stringify({
    schemaVersion: 1,
    confirmed: true,
    gitTag: args['git-tag'],
    message,
    approvedPaths,
    workspaceFingerprint: fingerprint.hash,
    workspacePaths: fingerprint.paths,
    approvedAt: new Date().toISOString(),
  }, null, 2)}\n`);
  console.log(`Git 发布信息已自动审批: ${approvalFile}`);
  process.exit(0);
}

if (command === 'verify') {
  if (!args['git-tag']) fail('verify 缺少 --git-tag。');
  ensureGitRepo();
  const approval = readApproval(approvalFile, args['git-tag']);
  const fingerprint = workspaceFingerprint();
  if (fingerprint.hash !== approval.workspaceFingerprint || JSON.stringify(fingerprint.paths) !== JSON.stringify(approval.workspacePaths)) {
    fail('梳理后工作区或文件清单已变化，请重新梳理并生成 Git 提交信息。');
  }
  console.log('Git 发布确认校验通过。');
  process.exit(0);
}

if (command === 'materialize') {
  if (!args['git-tag'] || !args['message-output'] || !args['paths-output']) {
    fail('materialize 缺少 git-tag、message-output 或 paths-output。');
  }
  const approval = readApproval(approvalFile, args['git-tag']);
  writePrivate(path.resolve(args['message-output']), `${approval.message}\n`);
  writePrivate(path.resolve(args['paths-output']), `${approval.approvedPaths.join('\n')}\n`);
  process.exit(0);
}

fail(`未知命令: ${command}`);
EOF

cat > "$GIT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sync_git_release.sh --git-tag <tag> --display-version <version> --release-type-zh <type> \
    --approval-file <file>
USAGE
}

fail() {
  echo "$1" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "缺少命令: $1"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE_NAME="${PO_GITHUB_REMOTE_NAME:-origin}"
REPO_NAME="${PO_GITHUB_REPO_NAME:-$(basename "$ROOT_DIR")}"
VISIBILITY="${PO_GITHUB_VISIBILITY:-private}"
DEFAULT_BRANCH="${PO_GITHUB_DEFAULT_BRANCH:-main}"
GIT_TAG=""
DISPLAY_VERSION=""
RELEASE_TYPE_ZH=""
APPROVAL_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-tag) GIT_TAG="$2"; shift 2 ;;
    --display-version) DISPLAY_VERSION="$2"; shift 2 ;;
    --release-type-zh) RELEASE_TYPE_ZH="$2"; shift 2 ;;
    --approval-file) APPROVAL_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      fail "未知参数: $1"
      ;;
  esac
done

if [[ -z "$GIT_TAG" || -z "$DISPLAY_VERSION" || -z "$RELEASE_TYPE_ZH" || -z "$APPROVAL_FILE" ]]; then
  usage >&2
  exit 1
fi

require_cmd git

ensure_git_repo() {
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return
  fi

  if [[ ! -f "$ROOT_DIR/.gitignore" ]]; then
    fail "当前项目还不是 git 仓，且缺少 .gitignore。请先补 .gitignore 再重试。"
  fi

  git -C "$ROOT_DIR" init >/dev/null
  git -C "$ROOT_DIR" checkout -B "$DEFAULT_BRANCH" >/dev/null 2>&1
}

ensure_current_branch() {
  local branch
  branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    git -C "$ROOT_DIR" checkout -B "$DEFAULT_BRANCH" >/dev/null 2>&1
    branch="$DEFAULT_BRANCH"
  fi
  printf '%s' "$branch"
}

ensure_remote() {
  if git -C "$ROOT_DIR" remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    return
  fi

  require_cmd gh
  if ! gh auth status >/dev/null 2>&1; then
    fail "GitHub CLI 尚未认证，请先执行 gh auth login。"
  fi

  case "$VISIBILITY" in
    private|public|internal) ;;
    *)
      fail "PO_GITHUB_VISIBILITY 仅支持 private / public / internal"
      ;;
  esac

  gh repo create "$REPO_NAME" --"$VISIBILITY" --source "$ROOT_DIR" --remote "$REMOTE_NAME" >/dev/null
}

ensure_git_repo
BRANCH_NAME="$(ensure_current_branch)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MESSAGE_FILE="$TMP_DIR/commit-message.txt"
PATHS_FILE="$TMP_DIR/approved-paths.txt"

node "$SCRIPT_DIR/manage_git_release_commit.mjs" materialize \
  --approval-file "$APPROVAL_FILE" \
  --git-tag "$GIT_TAG" \
  --message-output "$MESSAGE_FILE" \
  --paths-output "$PATHS_FILE"

APPROVED_PATHS=()
while IFS= read -r approved_path; do
  [[ -n "$approved_path" ]] && APPROVED_PATHS+=("$approved_path")
done < "$PATHS_FILE"
if [[ "${#APPROVED_PATHS[@]}" -gt 0 ]]; then
  git -C "$ROOT_DIR" add -- "${APPROVED_PATHS[@]}"
fi
git -C "$ROOT_DIR" add -- package.json deploy/aliyun/release-version.json

while IFS= read -r -d '' staged_path; do
  allowed=0
  if [[ "$staged_path" == "package.json" || "$staged_path" == "deploy/aliyun/release-version.json" ]]; then
    allowed=1
  else
    for approved_path in "${APPROVED_PATHS[@]}"; do
      if [[ "$staged_path" == "$approved_path" ]]; then allowed=1; break; fi
    done
  fi
  [[ "$allowed" -eq 1 ]] || fail "暂存区包含未经确认的文件: $staged_path"
done < <(git -C "$ROOT_DIR" diff --cached --name-only -z)

git -C "$ROOT_DIR" diff --cached --quiet && fail "没有可提交的已审批改动。"
git -C "$ROOT_DIR" commit -F "$MESSAGE_FILE" >/dev/null

BRANCH_NAME="$(ensure_current_branch)"
ensure_remote

if ! git -C "$ROOT_DIR" rev-parse "$GIT_TAG" >/dev/null 2>&1; then
  git -C "$ROOT_DIR" tag -a "$GIT_TAG" -m "Release ${DISPLAY_VERSION}" >/dev/null
fi

git -C "$ROOT_DIR" push -u "$REMOTE_NAME" "$BRANCH_NAME"
git -C "$ROOT_DIR" push "$REMOTE_NAME" "$GIT_TAG"

rm -f "$APPROVAL_FILE"
echo "GitHub 已同步: ${DISPLAY_VERSION} (${GIT_TAG})"
EOF

cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="\$(cd "\${SCRIPT_DIR}/../.." && pwd)"

cd "\$PROJECT_ROOT"
exec /usr/bin/node $START_ENTRY_Q
EOF

cat > "$BOOTSTRAP_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="\${1:-/service/$PROJECT_SLUG}"
ENV_TARGET="\${2:-/etc/$PROJECT_SLUG/$PROJECT_SLUG.env}"

mkdir -p \\
$BOOTSTRAP_MKDIR_BLOCK

touch \\
  "\${PROJECT_DIR}/logs/api.stdout.log" \\
  "\${PROJECT_DIR}/logs/api.stderr.log"

echo "Server directories prepared under \${PROJECT_DIR}"
EOF

chmod +x "$PACKAGE_SCRIPT" "$DEPLOY_SCRIPT" "$START_SCRIPT" "$BOOTSTRAP_SCRIPT" "$VERSION_SCRIPT" "$GIT_COMMIT_SCRIPT" "$GIT_SYNC_SCRIPT" "$CONFIG_INIT_SCRIPT" "$NGINX_CONFIG_SCRIPT"

"$CONFIG_INIT_SCRIPT" --non-interactive

echo "Generated:"
echo "  $PACKAGE_SCRIPT"
echo "  $DEPLOY_SCRIPT"
echo "  $VERSION_SCRIPT"
echo "  $GIT_COMMIT_SCRIPT"
echo "  $GIT_SYNC_SCRIPT"
echo "  $START_SCRIPT"
echo "  $BOOTSTRAP_SCRIPT"
echo "  $CONFIG_INIT_SCRIPT"
echo "  $NGINX_CONFIG_SCRIPT"
