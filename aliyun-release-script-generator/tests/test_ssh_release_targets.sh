#!/usr/bin/env bash
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/project/deploy/aliyun/scripts"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/id_release" >/dev/null
host_key="$(cat "$TMP/id_release.pub")"
host_fp="$(ssh-keygen -lf "$TMP/id_release.pub" -E sha256 | awk '{print $2}')"
cp "$SKILL_DIR/templates/ssh_transport.sh" "$TMP/project/deploy/aliyun/scripts/"
cp "$SKILL_DIR/templates/deploy_static_files.sh" "$TMP/project/deploy/aliyun/scripts/"
cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CALLS"
cmd="${*: -1}"
case "$cmd" in
  'id -un') [[ "${FAIL_LOGIN:-0}" == 0 ]] || exit 255; echo release_user ;;
  *' preflight '*) [[ "${ALLOW_PERMISSION:-0}" == 1 ]] ;;
  *'mktemp -d /tmp/po-static.'*) mktemp -d /tmp/po-static.XXXXXXXX ;;
  *'deploy-static '*)
    set -- $cmd
    echo "PO_STATIC_OK:${@: -1}:${@: -4:1}:${@: -2:1}:healthy" ;;
  *'rollback-static '*) echo "PO_STATIC_ROLLBACK_OK:${cmd##* }" ;;
  *) exit 1 ;;
esac
SH
cat > "$TMP/bin/scp" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_SCP_CALLS"
src="${*: -2:1}"; dst="${*: -1}"
cp -- "$src" "${dst#*:}"
SH
chmod +x "$TMP/bin/ssh" "$TMP/bin/scp"
export PATH="$TMP/bin:$PATH" TEST_CALLS="$TMP/calls" TEST_SCP_CALLS="$TMP/scp-calls"
config="$TMP/project/deploy/aliyun/.deploy.local.sh"
cat > "$config" <<EOF
export PO_DEPLOY_ENV=production
export PO_DEPLOY_HOST=host.example
export PO_DEPLOY_PORT=22
export PO_DEPLOY_USER=release_user
export PO_SSH_AUTH_METHOD=key
export PO_SSH_KEY_FILE='$TMP/id_release'
export PO_SSH_HOST_PUBLIC_KEY='$host_key'
export PO_SSH_HOST_FINGERPRINT='$host_fp'
export PO_REMOTE_RELEASE_ENTRY=/usr/local/sbin/myapp-release
export PO_PROJECT_NAME=myapp
export PO_STATIC_TARGET_DIR=/service/myapp/downloads
export PO_STATIC_APK_NAME=myapp.apk
export PO_STATIC_MANIFEST_NAME=manifest.json
EOF
export PO_DEPLOY_ENV_FILE="$config"
source "$config"
source "$SKILL_DIR/templates/ssh_transport.sh"
PO_APPROVED_DEPLOY_ENV=production
po_transport_init
po_check_login
grep -Fq 'StrictHostKeyChecking=yes' "$TEST_CALLS"
grep -Fq 'PasswordAuthentication=no' "$TEST_CALLS"
if po_check_release_entry myapp static /service/myapp/downloads static-files >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$TEST_SCP_CALLS" ]]
ALLOW_PERMISSION=1; export ALLOW_PERMISSION
po_check_release_entry myapp static /service/myapp/downloads static-files
grep -Fq 'p="$(dirname "$p")"' "$TEST_CALLS"
grep -Fq 'exit 33' "$TEST_CALLS"
rule="$(bash "$SKILL_DIR/templates/install_release_access.sh" --account release_user --entry /usr/local/sbin/myapp-release --render)"
[[ "$rule" == 'release_user ALL=(root) NOPASSWD: /usr/local/sbin/myapp-release' ]]
if bash "$SKILL_DIR/templates/install_release_access.sh" --account root --entry /usr/local/sbin/myapp-release --render >/dev/null 2>&1; then exit 1; fi
if bash "$SKILL_DIR/templates/install_release_access.sh" --account release_user --entry /tmp/../myapp-release --render >/dev/null 2>&1; then exit 1; fi
PO_SSH_HOST_FINGERPRINT=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
if po_transport_init >/dev/null 2>&1; then exit 1; fi
source "$config"
PO_SSH_KEY_FILE=/missing/key
if po_transport_init >/dev/null 2>&1; then exit 1; fi
source "$config"
PO_SSH_AUTH_METHOD=agent
PO_SSH_AGENT_PUBLIC_KEY_FILE=/missing/selected.pub
if po_transport_init >/dev/null 2>&1; then exit 1; fi
source "$config"
PO_SSH_AUTH_METHOD=password
if po_transport_init >/dev/null 2>&1; then exit 1; fi
source "$config"
PO_APPROVED_DEPLOY_ENV=preview
if po_transport_init >/dev/null 2>&1; then exit 1; fi
PO_APPROVED_DEPLOY_ENV=production
FAIL_LOGIN=1; export FAIL_LOGIN
po_transport_init
if po_check_login >/dev/null 2>&1; then exit 1; fi
FAIL_LOGIN=0; export FAIL_LOGIN
printf 'apk bytes\n' > "$TMP/myapp.apk"
printf '{"version":1}\n' > "$TMP/manifest.json"
if bash "$TMP/project/deploy/aliyun/scripts/deploy_static_files.sh" deploy "$TMP/myapp.apk" "$TMP/manifest.json" release-1 >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$TEST_SCP_CALLS" ]]
approval="$TMP/project/deploy/aliyun/.static-release-approval.local.json"
apk_sha="$(shasum -a 256 "$TMP/myapp.apk" | awk '{print $1}')"
manifest_sha="$(shasum -a 256 "$TMP/manifest.json" | awk '{print $1}')"
node - "$approval" "$apk_sha" "$manifest_sha" "$host_fp" "$TMP/id_release" <<'NODE'
const fs=require('node:fs');
const [file,apkSha256,manifestSha256,hostFingerprint,keyRef]=process.argv.slice(2);
const a={schemaVersion:1,confirmed:true,action:'deploy',releaseId:'release-1',target:{env:'production',host:'host.example',user:'release_user',port:'22',root:'/service/myapp/downloads',entry:'/usr/local/sbin/myapp-release',auth:'key',keyRef,hostFingerprint},apkName:'myapp.apk',manifestName:'manifest.json',apkSha256,manifestSha256,approvedAt:new Date().toISOString()};
fs.writeFileSync(file,JSON.stringify(a),{mode:0o600});
NODE
bash "$TMP/project/deploy/aliyun/scripts/deploy_static_files.sh" deploy "$TMP/myapp.apk" "$TMP/manifest.json" release-1 >/dev/null
node -e 'const d=require(process.argv[1]); if(d.status!=="success"||d.stage!=="complete"||d.targetEnvironment!=="production"||!d.apkSha256||d.stages.upload!=="success"||d.stages["remote-switch-health"]!=="success") process.exit(1)' "$TMP/project/deploy/aliyun/release/static-release-1.execution.json"
[[ "$(wc -l < "$TEST_SCP_CALLS" | tr -d ' ')" == 2 ]]
[[ "$(tail -n 1 "$TEST_SCP_CALLS")" == *manifest.json* ]]
node - "$approval" <<'NODE'
const fs=require('node:fs'),file=process.argv[2],a=JSON.parse(fs.readFileSync(file));a.action='rollback';a.apkSha256='';a.manifestSha256='';a.approvedAt=new Date().toISOString();fs.writeFileSync(file,JSON.stringify(a),{mode:0o600});
NODE
bash "$TMP/project/deploy/aliyun/scripts/deploy_static_files.sh" rollback release-1 >/dev/null
node -e 'const d=require(process.argv[1]); if(d.status!=="success"||d.rollback!=="verified") process.exit(1)' "$TMP/project/deploy/aliyun/release/static-release-1.execution.json"
echo 'SSH target, permission, static deploy and rollback tests passed'
