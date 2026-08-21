#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  render_release_scripts.sh \
    --output-dir <dir> \
    --project-slug <slug> \
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
    [--release-prefix <prefix>]
EOF
}

shell_quote() {
  printf "%q" "$1"
}

OUTPUT_DIR=""
PROJECT_SLUG=""
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --project-slug) PROJECT_SLUG="$2"; shift 2 ;;
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
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OUTPUT_DIR" || -z "$PROJECT_SLUG" || -z "$API_BUILD_CMD" || -z "$API_DIST_PATH" || -z "$START_ENTRY" || -z "$ENV_TEMPLATE" || -z "$SERVICE_TEMPLATE" || -z "$NGINX_TEMPLATE" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$RELEASE_PREFIX" ]]; then
  RELEASE_PREFIX="$PROJECT_SLUG"
fi

mkdir -p "$OUTPUT_DIR"

PACKAGE_SCRIPT="$OUTPUT_DIR/package_release.sh"
DEPLOY_SCRIPT="$OUTPUT_DIR/deploy_release.sh"
START_SCRIPT="$OUTPUT_DIR/start-prod.sh"
BOOTSTRAP_SCRIPT="$OUTPUT_DIR/server-bootstrap.sh"
VERSION_SCRIPT="$OUTPUT_DIR/manage_release_version.mjs"
GIT_SYNC_SCRIPT="$OUTPUT_DIR/sync_git_release.sh"

API_DIST_PARENT="$(dirname "$API_DIST_PATH")"
ENV_TEMPLATE_Q="$(shell_quote "$ENV_TEMPLATE")"
SERVICE_TEMPLATE_Q="$(shell_quote "$SERVICE_TEMPLATE")"
NGINX_TEMPLATE_Q="$(shell_quote "$NGINX_TEMPLATE")"
API_DIST_PATH_Q="$(shell_quote "$API_DIST_PATH")"
API_DIST_PARENT_Q="$(shell_quote "$API_DIST_PARENT")"
START_ENTRY_Q="$(shell_quote "$START_ENTRY")"
RUNTIME_INSTALL_CMD_Q="$(shell_quote "$RUNTIME_INSTALL_CMD")"

PACKAGE_BUILD_BLOCK="$API_BUILD_CMD"
if [[ -n "$WEB_BUILD_CMD" ]]; then
  PACKAGE_BUILD_BLOCK+=$'\n'"$WEB_BUILD_CMD"
fi
if [[ -n "$ADMIN_BUILD_CMD" ]]; then
  PACKAGE_BUILD_BLOCK+=$'\n'"$ADMIN_BUILD_CMD"
fi

PACKAGE_STAGE_COPY_BLOCK=""
REQUIRED_PATHS_BLOCK=$'\n'"  required_paths+=(\"deploy/aliyun/manage_release_version.mjs\")"$'\n'"  required_paths+=(\"deploy/aliyun/sync_git_release.sh\")"
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
APP_PORT=\${PORT:-8001}
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
cp "\$DEPLOY_DIR/scripts/sync_git_release.sh" "\$STAGE_DIR/deploy/aliyun/sync_git_release.sh"

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
REMOTE_NGINX_CONF="\${PO_REMOTE_NGINX_CONF:-/etc/nginx/conf.d/$PROJECT_SLUG.conf}"
REMOTE_WEB_DIR="\${PO_REMOTE_WEB_DIR:-\$REMOTE_ROOT/web}"
REMOTE_ADMIN_WEB_DIR="\${PO_REMOTE_ADMIN_WEB_DIR:-\$REMOTE_ROOT/admin-web}"
REMOTE_RUN_USER="\${PO_REMOTE_RUN_USER:-\$DEPLOY_USER}"

if [[ -n "\$STAMP" ]]; then
  ARTIFACT="\$RELEASE_DIR/$RELEASE_PREFIX-\$STAMP.tgz"
else
  ARTIFACT="\$(latest_artifact)"
fi
VERSION_PLAN_FILE="\${ARTIFACT%.tgz}.version-plan.json"

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

run_scp() {
  local source_path="\$1"
  local remote_path="\$2"

  if [[ -n "\$SSH_PASSWORD" ]]; then
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
    scp -P "\$DEPLOY_PORT" -o StrictHostKeyChecking=accept-new "\$source_path" "\$DEPLOY_USER@\$DEPLOY_HOST:\$remote_path"
  fi
}

run_ssh() {
  local remote_command="\$1"

  if [[ -n "\$SSH_PASSWORD" ]]; then
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
    ssh -p "\$DEPLOY_PORT" -o StrictHostKeyChecking=accept-new "\$DEPLOY_USER@\$DEPLOY_HOST" "\$remote_command"
  fi
}

TMP_DIR="\$(mktemp -d)"
cleanup() {
  rm -rf "\$TMP_DIR"
}
trap cleanup EXIT

ENV_BASENAME="\$(basename "\$REMOTE_ENV_FILE")"
cp "\$ENV_TEMPLATE" "\$TMP_DIR/\$ENV_BASENAME"
if ! grep -q '^PORT=' "\$TMP_DIR/\$ENV_BASENAME"; then
  printf 'PORT=8001\n' >> "\$TMP_DIR/\$ENV_BASENAME"
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
REMOTE_NGINX_FILE="/tmp/\$(basename "\$REMOTE_NGINX_CONF")"
RELEASE_NAME="\$(basename "\$ARTIFACT" .tgz)"
REMOTE_RELEASE_DIR="\$REMOTE_RELEASES_DIR/\$RELEASE_NAME"

echo "[$PROJECT_SLUG] 上传发布包..."
run_scp "\$ARTIFACT" "\$REMOTE_ARTIFACT"
run_scp "\$TMP_DIR/\$ENV_BASENAME" "\$REMOTE_UPLOAD_ENV_FILE"
run_scp "\$LOCAL_SERVICE_FILE" "\$REMOTE_SERVICE_FILE"
run_scp "\$NGINX_TEMPLATE" "\$REMOTE_NGINX_FILE"

REMOTE_CMD=\$(cat <<'REMOTE_EOF'
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
sudo install -m 644 "\$REMOTE_NGINX_FILE" "\$REMOTE_NGINX_CONF"
sudo systemctl daemon-reload
sudo systemctl enable "\$REMOTE_SERVICE_NAME" >/dev/null
sudo systemctl restart "\$REMOTE_SERVICE_NAME"
mapfile -t OLD_RELEASES < <(find "\$REMOTE_RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | xargs -r ls -1dt | tail -n +\$((KEEP_COUNT + 1)))
if [[ "\${#OLD_RELEASES[@]}" -gt 0 ]]; then
  printf "清理旧版本 release: %s\n" "\${OLD_RELEASES[@]}"
  sudo rm -rf "\${OLD_RELEASES[@]}"
fi
set -a
source "\$REMOTE_ENV_FILE"
set +a
$HEALTH_CHECK_BLOCK
sudo nginx -t
sudo systemctl reload nginx
'
REMOTE_EOF
)

run_ssh "\$REMOTE_CMD"

VERSION_ENV_OUTPUT="\$(node "\$DEPLOY_DIR/scripts/manage_release_version.mjs" apply --plan-file "\$VERSION_PLAN_FILE" --format env)"
eval "\$VERSION_ENV_OUTPUT"

bash "\$DEPLOY_DIR/scripts/sync_git_release.sh" \\
  --git-tag "\$RELEASE_GIT_TAG" \\
  --display-version "\$RELEASE_DISPLAY_VERSION" \\
  --release-type-zh "\$RELEASE_TYPE_ZH"

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

cat > "$GIT_SYNC_SCRIPT" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sync_git_release.sh --git-tag <tag> --display-version <version> --release-type-zh <type>
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --git-tag) GIT_TAG="$2"; shift 2 ;;
    --display-version) DISPLAY_VERSION="$2"; shift 2 ;;
    --release-type-zh) RELEASE_TYPE_ZH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      fail "未知参数: $1"
      ;;
  esac
done

if [[ -z "$GIT_TAG" || -z "$DISPLAY_VERSION" || -z "$RELEASE_TYPE_ZH" ]]; then
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
HAS_COMMITS=0
if git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
  HAS_COMMITS=1
fi

if [[ "$HAS_COMMITS" -eq 0 ]]; then
  git -C "$ROOT_DIR" add .
else
  git -C "$ROOT_DIR" add package.json deploy/aliyun/release-version.json
fi

if ! git -C "$ROOT_DIR" diff --cached --quiet; then
  git -C "$ROOT_DIR" commit -m "chore(release): ${GIT_TAG} ${RELEASE_TYPE_ZH}" >/dev/null
fi

BRANCH_NAME="$(ensure_current_branch)"
ensure_remote

if ! git -C "$ROOT_DIR" rev-parse "$GIT_TAG" >/dev/null 2>&1; then
  git -C "$ROOT_DIR" tag -a "$GIT_TAG" -m "Release ${DISPLAY_VERSION}" >/dev/null
fi

git -C "$ROOT_DIR" push -u "$REMOTE_NAME" "$BRANCH_NAME"
git -C "$ROOT_DIR" push "$REMOTE_NAME" "$GIT_TAG"

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

chmod +x "$PACKAGE_SCRIPT" "$DEPLOY_SCRIPT" "$START_SCRIPT" "$BOOTSTRAP_SCRIPT" "$VERSION_SCRIPT" "$GIT_SYNC_SCRIPT"

echo "Generated:"
echo "  $PACKAGE_SCRIPT"
echo "  $DEPLOY_SCRIPT"
echo "  $VERSION_SCRIPT"
echo "  $GIT_SYNC_SCRIPT"
echo "  $START_SCRIPT"
echo "  $BOOTSTRAP_SCRIPT"
