#!/usr/bin/env bash

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
cleanup() {
  local status="$?"
  if [[ "${KEEP_TEST_ROOT:-0}" == "1" ]]; then
    echo "保留测试目录: $TEST_ROOT" >&2
    exit "$status"
  fi
  rm -rf "$TEST_ROOT"
  exit "$status"
}
trap cleanup EXIT

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "预期命令失败但成功: $*" >&2
    exit 1
  fi
}

PROJECT="$TEST_ROOT/project"
OUTPUT_DIR="$PROJECT/deploy/aliyun/scripts"
mkdir -p "$OUTPUT_DIR" "$PROJECT/dist/api"
printf '{"name":"smoke-app","version":"1.0.0"}\n' > "$PROJECT/package.json"
printf 'PORT=8123\n' > "$PROJECT/api.env"
printf '[Service]\n' > "$PROJECT/app.service"
printf 'server { listen 80; server_name smoke.example.com; }\n' > "$PROJECT/app.conf"
printf 'baseline\n' > "$PROJECT/app.txt"

(
  cd "$PROJECT"
  bash "$SKILL_DIR/scripts/render_release_scripts.sh" \
    --output-dir "$OUTPUT_DIR" \
    --project-slug smoke-app \
    --project-domain smoke.example.com \
    --app-port 8123 \
    --api-build-cmd true \
    --api-dist-path dist/api \
    --start-entry dist/api/server.js \
    --env-template "$PROJECT/api.env" \
    --service-template "$PROJECT/app.service" \
    --nginx-template "$PROJECT/app.conf" \
    --ssh-auth-method agent >/dev/null
)

APPROVAL_TOOL="$OUTPUT_DIR/manage_git_release_commit.mjs"
SYNC_TOOL="$OUTPUT_DIR/sync_git_release.sh"
DEPLOY_TOOL="$OUTPUT_DIR/deploy_release.sh"
APPROVAL_FILE="$PROJECT/deploy/aliyun/.git-release-approval.local.json"
MESSAGE_FILE="$TEST_ROOT/message.txt"
PATHS_FILE="$TEST_ROOT/paths.txt"
TAG="v1.0.1-build.1"

grep -Fqx '/deploy/aliyun/.git-release-approval.local.json' "$PROJECT/.gitignore"
node --check "$APPROVAL_TOOL"
bash -n "$SYNC_TOOL" "$DEPLOY_TOOL"
if rg -i 'openai|deepseek|anthropic|https?://|fetch\(' "$APPROVAL_TOOL" >/dev/null; then
  echo "审批工具不应包含模型 API 或网络调用" >&2
  exit 1
fi

VERIFY_LINE="$(grep -n 'manage_git_release_commit.mjs" verify' "$DEPLOY_TOOL" | cut -d: -f1)"
UPLOAD_LINE="$(grep -n '上传发布包' "$DEPLOY_TOOL" | cut -d: -f1)"
[[ "$VERIFY_LINE" -lt "$UPLOAD_LINE" ]]

git -C "$PROJECT" init -b main >/dev/null
git -C "$PROJECT" config user.name "Release Test"
git -C "$PROJECT" config user.email "release-test@example.com"
git -C "$PROJECT" add .
git -C "$PROJECT" commit -m "chore: baseline" >/dev/null
printf 'approved change\n' > "$PROJECT/app.txt"
printf 'leave untracked\n' > "$PROJECT/note.txt"
printf 'app.txt\n' > "$PATHS_FILE"

cat > "$MESSAGE_FILE" <<'EOF'
fix(release): 自动生成结构化审批并阻止清单外提交

问题/需求：发布脚本会使用固定标题直接提交。
实现结果：增加提交信息校验、文件确认和工作区漂移门禁。
影响范围：阿里云发布后的 Git 提交与推送流程。
验证方式：`git diff --check`，结果：通过（exit 0）。
关联任务：无
风险与回滚：删除审批文件并恢复旧同步脚本可回滚。
EOF

expect_failure env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY node "$APPROVAL_TOOL" verify \
  --approval-file "$APPROVAL_FILE" --git-tag "$TAG"

INVALID_MESSAGE="$TEST_ROOT/invalid-message.txt"
sed 's/验证方式：.*/验证方式：计划稍后测试。/' "$MESSAGE_FILE" > "$INVALID_MESSAGE"
expect_failure node "$APPROVAL_TOOL" approve \
  --message-file "$INVALID_MESSAGE" --paths-file "$PATHS_FILE" --git-tag "$TAG"

EMPTY_CORE_MESSAGE="$TEST_ROOT/empty-core-message.txt"
sed -e 's/^问题\/需求：.*/问题\/需求：无/' -e 's/^实现结果：.*/实现结果：无/' "$MESSAGE_FILE" > "$EMPTY_CORE_MESSAGE"
expect_failure node "$APPROVAL_TOOL" approve \
  --message-file "$EMPTY_CORE_MESSAGE" --paths-file "$PATHS_FILE" --git-tag "$TAG"

printf 'app.txt\nnote.txt\n' > "$TEST_ROOT/paths-with-untracked.txt"
expect_failure node "$APPROVAL_TOOL" approve \
  --message-file "$MESSAGE_FILE" --paths-file "$TEST_ROOT/paths-with-untracked.txt" --git-tag "$TAG"

env -u OPENAI_API_KEY -u DEEPSEEK_API_KEY node "$APPROVAL_TOOL" approve \
  --message-file "$MESSAGE_FILE" --paths-file "$PATHS_FILE" --git-tag "$TAG" >/dev/null
[[ "$(stat -f '%Lp' "$APPROVAL_FILE" 2>/dev/null || stat -c '%a' "$APPROVAL_FILE")" == "600" ]]
node "$APPROVAL_TOOL" verify --approval-file "$APPROVAL_FILE" --git-tag "$TAG" >/dev/null
expect_failure node "$APPROVAL_TOOL" verify --approval-file "$APPROVAL_FILE" --git-tag "v9.9.9-build.9"

printf 'drifted\n' > "$PROJECT/app.txt"
expect_failure node "$APPROVAL_TOOL" verify --approval-file "$APPROVAL_FILE" --git-tag "$TAG"
printf 'approved change\n' > "$PROJECT/app.txt"
node "$APPROVAL_TOOL" verify --approval-file "$APPROVAL_FILE" --git-tag "$TAG" >/dev/null

REMOTE="$TEST_ROOT/remote.git"
git init --bare "$REMOTE" >/dev/null
git -C "$PROJECT" remote add origin "$REMOTE"
node -e 'const fs=require("fs"); const p=process.argv[1]; const v=JSON.parse(fs.readFileSync(p)); v.version="1.0.1"; fs.writeFileSync(p, JSON.stringify(v, null, 2)+"\n");' "$PROJECT/package.json"
mkdir -p "$PROJECT/deploy/aliyun"
printf '{"semver":"1.0.1","buildCount":1}\n' > "$PROJECT/deploy/aliyun/release-version.json"

git -C "$PROJECT" add note.txt
expect_failure env PO_GITHUB_REMOTE_NAME=origin bash "$SYNC_TOOL" \
  --git-tag "$TAG" \
  --display-version "1.0.1 (1)" \
  --release-type-zh "修复优化" \
  --approval-file "$APPROVAL_FILE"
git -C "$PROJECT" reset -- note.txt

PO_GITHUB_REMOTE_NAME=origin bash "$SYNC_TOOL" \
  --git-tag "$TAG" \
  --display-version "1.0.1 (1)" \
  --release-type-zh "修复优化" \
  --approval-file "$APPROVAL_FILE" >/dev/null

test ! -e "$APPROVAL_FILE"
[[ "$(git -C "$PROJECT" status --short -- note.txt)" == "?? note.txt" ]]
git -C "$PROJECT" show -s --format=%B HEAD | grep -Fq '问题/需求：发布脚本会使用固定标题直接提交。'
git -C "$PROJECT" show -s --format=%B HEAD | grep -Fq '验证方式：`git diff --check`，结果：通过（exit 0）。'
git --git-dir="$REMOTE" rev-parse "refs/tags/$TAG" >/dev/null

INITIAL="$TEST_ROOT/initial"
INITIAL_TOOL_DIR="$INITIAL/deploy/aliyun/scripts"
mkdir -p "$INITIAL_TOOL_DIR"
cp "$APPROVAL_TOOL" "$INITIAL_TOOL_DIR/"
printf '/deploy/aliyun/.git-release-approval.local.json\n' > "$INITIAL/.gitignore"
printf '{"name":"initial-app","version":"1.0.0"}\n' > "$INITIAL/package.json"
printf 'initial\n' > "$INITIAL/app.txt"
cat > "$TEST_ROOT/initial-paths.txt" <<'EOF'
.gitignore
app.txt
deploy/aliyun/scripts/manage_git_release_commit.mjs
package.json
EOF
cp "$MESSAGE_FILE" "$TEST_ROOT/initial-message.txt"

expect_failure node "$INITIAL_TOOL_DIR/manage_git_release_commit.mjs" approve \
  --message-file "$TEST_ROOT/initial-message.txt" \
  --paths-file "$TEST_ROOT/initial-paths.txt" \
  --git-tag "$TAG"
node "$INITIAL_TOOL_DIR/manage_git_release_commit.mjs" approve \
  --message-file "$TEST_ROOT/initial-message.txt" \
  --paths-file "$TEST_ROOT/initial-paths.txt" \
  --git-tag "$TAG" \
  --allow-initial-all true >/dev/null
git -C "$INITIAL" rev-parse --is-inside-work-tree >/dev/null
node "$INITIAL_TOOL_DIR/manage_git_release_commit.mjs" verify \
  --approval-file "$INITIAL/deploy/aliyun/.git-release-approval.local.json" \
  --git-tag "$TAG" >/dev/null

MULTI="$TEST_ROOT/multi"
MULTI_SCRIPTS="$MULTI/deploy/aliyun/scripts"
mkdir -p "$MULTI_SCRIPTS" "$MULTI/dist/api" "$MULTI/dist/web" "$MULTI/dist/admin"
printf '{"name":"multi-app","version":"2.0.0"}\n' > "$MULTI/package.json"
printf 'console.log("api");\n' > "$MULTI/dist/api/server.js"
printf '<html>web</html>\n' > "$MULTI/dist/web/index.html"
printf '<html>admin</html>\n' > "$MULTI/dist/admin/index.html"
printf 'PORT=8234\n' > "$MULTI/api.env"
printf '[Service]\n' > "$MULTI/app.service"
printf 'server { listen 80; server_name multi.example.com; }\n' > "$MULTI/app.conf"
(
  cd "$MULTI"
  bash "$SKILL_DIR/scripts/render_release_scripts.sh" \
    --output-dir "$MULTI_SCRIPTS" \
    --project-slug multi-app \
    --project-domain multi.example.com \
    --app-port 8234 \
    --api-build-cmd true \
    --api-dist-path dist/api \
    --start-entry dist/api/server.js \
    --env-template "$MULTI/api.env" \
    --service-template "$MULTI/app.service" \
    --nginx-template "$MULTI/app.conf" \
    --web-build-cmd true \
    --web-dist-path dist/web \
    --admin-build-cmd true \
    --admin-dist-path dist/admin \
    --ssh-auth-method agent >/dev/null
  PO_RELEASE_TYPE_ZH=修复优化 bash "$MULTI_SCRIPTS/package_release.sh" smoke >/dev/null
)
bash -n "$MULTI_SCRIPTS/"*.sh
node --check "$MULTI_SCRIPTS/manage_release_version.mjs"
node --check "$MULTI_SCRIPTS/manage_git_release_commit.mjs"
MULTI_ARCHIVE="$MULTI/deploy/aliyun/release/multi-app-smoke.tgz"
tar -tzf "$MULTI_ARCHIVE" | grep -Fq './deploy/aliyun/manage_git_release_commit.mjs'
tar -tzf "$MULTI_ARCHIVE" | grep -Fq './web/index.html'
tar -tzf "$MULTI_ARCHIVE" | grep -Fq './admin-web/index.html'

echo "git release confirmation workflow passed"
