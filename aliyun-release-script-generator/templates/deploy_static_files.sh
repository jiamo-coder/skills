#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

usage() { echo 'Usage: deploy_static_files.sh deploy <apk> <manifest> <release-id> | rollback <release-id>' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
action="$1"; shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export PO_DEPLOY_ENV_FILE="${PO_DEPLOY_ENV_FILE:-$DEPLOY_DIR/.deploy.local.sh}"
[[ -f "$PO_DEPLOY_ENV_FILE" ]] || { echo '缺少项目私有部署配置' >&2; exit 1; }
source "$PO_DEPLOY_ENV_FILE"
source "$SCRIPT_DIR/ssh_transport.sh"
: "${PO_DEPLOY_ENV:?缺少目标环境}" "${PO_DEPLOY_HOST:?缺少目标主机}" "${PO_DEPLOY_USER:?缺少发布账号}" "${PO_DEPLOY_PORT:?缺少 SSH 端口}"
: "${PO_REMOTE_RELEASE_ENTRY:?缺少管理员发布入口}" "${PO_SSH_HOST_FINGERPRINT:?缺少可信主机指纹}"
[[ "${PO_PROJECT_NAME:-}" =~ ^[a-z0-9-]+$ ]] || { echo '缺少项目名'; exit 1; }
[[ "${PO_STATIC_TARGET_DIR:-}" =~ ^/[A-Za-z0-9_./-]+$ ]] || { echo '缺少静态文件目标目录' >&2; exit 1; }
[[ "${PO_STATIC_APK_NAME:-}" =~ ^[A-Za-z0-9_.-]+\.apk$ && "${PO_STATIC_MANIFEST_NAME:-}" =~ ^[A-Za-z0-9_.-]+\.json$ ]] || { echo '必须配置核准的 APK 与清单文件名' >&2; exit 1; }
[[ "$action" == deploy || "$action" == rollback ]] || usage
if [[ "$action" == deploy ]]; then
  [[ $# == 3 ]] || usage
  apk="$1"; manifest="$2"
  [[ -f "$apk" && ! -L "$apk" && "$(basename "$apk")" == "$PO_STATIC_APK_NAME" ]] || { echo 'APK 不在核准文件清单内' >&2; exit 1; }
  [[ -f "$manifest" && ! -L "$manifest" && "$(basename "$manifest")" == "$PO_STATIC_MANIFEST_NAME" ]] || { echo '下载清单不在核准文件清单内' >&2; exit 1; }
  apk_sha="$(shasum -a 256 "$apk" | awk '{print $1}')"
  manifest_sha="$(shasum -a 256 "$manifest" | awk '{print $1}')"
else
  [[ $# == 1 ]] || usage
  apk_sha=''
  manifest_sha=''
fi
release_id="${@: -1}"
[[ "$release_id" =~ ^[A-Za-z0-9._-]+$ ]] || usage
approval_file="${PO_STATIC_APPROVAL_FILE:-$DEPLOY_DIR/.static-release-approval.local.json}"
[[ -f "$approval_file" ]] || { echo '缺少本次静态文件发布审批，禁止连接服务器' >&2; exit 1; }
case "${PO_SSH_AUTH_METHOD:-key}" in
  key) key_ref="${PO_SSH_KEY_FILE:-}" ;;
  agent) key_ref="${PO_SSH_AGENT_PUBLIC_KEY_FILE:-}" ;;
  password) key_ref=legacy-password ;;
  *) echo '无效认证方式' >&2; exit 1 ;;
esac
PO_STATIC_EXPECTED_TARGET="$PO_DEPLOY_ENV|$PO_DEPLOY_HOST|$PO_DEPLOY_USER|$PO_DEPLOY_PORT|$PO_STATIC_TARGET_DIR|$PO_REMOTE_RELEASE_ENTRY|${PO_SSH_AUTH_METHOD:-key}|$key_ref|$PO_SSH_HOST_FINGERPRINT" \
PO_STATIC_EXPECTED_FILES="$PO_STATIC_APK_NAME|$PO_STATIC_MANIFEST_NAME" \
node - "$approval_file" "$action" "$release_id" "$apk_sha" "$manifest_sha" <<'NODE'
const fs = require('node:fs');
const [file, action, releaseId, apkSha, manifestSha] = process.argv.slice(2);
if (fs.lstatSync(file).isSymbolicLink()) { console.error('静态发布审批文件不能是软链接'); process.exit(1); }
const a = JSON.parse(fs.readFileSync(file, 'utf8'));
const mode = fs.statSync(file).mode & 0o777;
const target = [a.target?.env, a.target?.host, a.target?.user, a.target?.port, a.target?.root, a.target?.entry, a.target?.auth, a.target?.keyRef, a.target?.hostFingerprint].join('|');
const files = [a.apkName, a.manifestName].join('|');
const age = Date.now() - Date.parse(a.approvedAt);
if (mode & 0o077 || a.schemaVersion !== 1 || a.confirmed !== true || a.action !== action || a.releaseId !== releaseId ||
    target !== process.env.PO_STATIC_EXPECTED_TARGET || files !== process.env.PO_STATIC_EXPECTED_FILES ||
    a.apkSha256 !== apkSha || a.manifestSha256 !== manifestSha || !Number.isFinite(age) || age < 0 || age > 24 * 3600 * 1000) {
  console.error('静态发布审批与目标或制品不一致，或审批已过期'); process.exit(1);
}
NODE
PO_APPROVED_DEPLOY_ENV="$PO_DEPLOY_ENV"
evidence_dir="$DEPLOY_DIR/release"
mkdir -p "$evidence_dir"
evidence_file="$evidence_dir/static-$release_id.execution.json"
stage_name=preflight
rollback_state=not-started
record_evidence() {
  local status="$1"
  PO_EVIDENCE_FILE="$evidence_file" PO_EVIDENCE_ACTION="$action" PO_EVIDENCE_STAGE="$stage_name" \
    PO_EVIDENCE_STATUS="$status" PO_EVIDENCE_ROLLBACK="$rollback_state" \
    PO_EVIDENCE_ENV="$PO_DEPLOY_ENV" PO_EVIDENCE_HOST="$PO_DEPLOY_HOST" \
    PO_EVIDENCE_USER="$PO_DEPLOY_USER" PO_EVIDENCE_ID="$release_id" \
    PO_EVIDENCE_APK_SHA="$apk_sha" PO_EVIDENCE_MANIFEST_SHA="$manifest_sha" \
    node -e 'const fs=require("fs"),e=process.env,p=e.PO_EVIDENCE_FILE;const old=fs.existsSync(p)?JSON.parse(fs.readFileSync(p)):{};const stageStatus=e.PO_EVIDENCE_STATUS==="stage-ok"?"success":e.PO_EVIDENCE_STATUS==="0"?"success":"failed";const d={...old,action:e.PO_EVIDENCE_ACTION,targetEnvironment:e.PO_EVIDENCE_ENV,host:e.PO_EVIDENCE_HOST,account:e.PO_EVIDENCE_USER,accountRole:"static-release",releaseId:e.PO_EVIDENCE_ID,apkSha256:e.PO_EVIDENCE_APK_SHA,manifestSha256:e.PO_EVIDENCE_MANIFEST_SHA,stage:e.PO_EVIDENCE_STAGE,stages:{...old.stages,[e.PO_EVIDENCE_STAGE]:stageStatus},status:e.PO_EVIDENCE_STATUS==="stage-ok"?"pending":stageStatus,rollback:e.PO_EVIDENCE_ROLLBACK,updatedAt:new Date().toISOString()};fs.writeFileSync(p,JSON.stringify(d,null,2)+"\n",{mode:0o600});fs.chmodSync(p,0o600)'
}
trap 'status=$?; record_evidence "$status" || true' EXIT
po_transport_init
po_check_login
po_check_release_entry "$PO_PROJECT_NAME" static "$PO_STATIC_TARGET_DIR" static-files
record_evidence stage-ok

if [[ "$action" == rollback ]]; then
  [[ $# == 1 && "$1" =~ ^[A-Za-z0-9._-]+$ ]] || usage
  stage_name=remote-rollback
  printf -v command 'sudo -n -- %q rollback-static %q %q %q' "$PO_REMOTE_RELEASE_ENTRY" "$PO_PROJECT_NAME" "$PO_STATIC_TARGET_DIR" "$1"
  receipt="$(po_ssh "$command")" || { echo '静态文件回退失败，需管理员检查下载入口' >&2; exit 1; }
  [[ "$receipt" == "PO_STATIC_ROLLBACK_OK:$1" ]] || { echo '静态文件回退缺少验证回执' >&2; exit 1; }
  rollback_state=verified
  stage_name=complete
  echo "$receipt"
  exit 0
fi
[[ "$action" == deploy ]] || usage
stage_name=upload
stage="$(po_ssh 'mktemp -d /tmp/po-static.XXXXXXXX')"
[[ "$stage" =~ ^/tmp/po-static\.[A-Za-z0-9]+$ ]] || { echo '服务器暂存目录无效' >&2; exit 1; }
cleanup() { printf -v command 'rm -f -- %q %q; rmdir -- %q' "$stage/$PO_STATIC_APK_NAME" "$stage/$PO_STATIC_MANIFEST_NAME" "$stage"; po_ssh "$command" >/dev/null 2>&1 || true; }
trap 'status=$?; cleanup; record_evidence "$status" || true' EXIT
po_scp "$apk" "$PO_SSH_TARGET:$stage/$PO_STATIC_APK_NAME"
po_scp "$manifest" "$PO_SSH_TARGET:$stage/$PO_STATIC_MANIFEST_NAME"
record_evidence stage-ok
stage_name=remote-switch-health
printf -v command 'sudo -n -- %q deploy-static %q %q %q %q %q %q %q %q' "$PO_REMOTE_RELEASE_ENTRY" "$PO_PROJECT_NAME" "$PO_STATIC_TARGET_DIR" "$stage" "$PO_STATIC_APK_NAME" "$apk_sha" "$PO_STATIC_MANIFEST_NAME" "$manifest_sha" "$release_id"
receipt="$(po_ssh "$command")" || { echo '静态发布失败，管理员入口须保留旧下载入口或回退' >&2; exit 1; }
[[ "$receipt" == "PO_STATIC_OK:$release_id:$apk_sha:$manifest_sha:healthy" ]] || { echo '静态发布缺少健康与回退回执' >&2; exit 1; }
record_evidence stage-ok
rollback_state=not-needed
stage_name=complete
echo "$receipt"
