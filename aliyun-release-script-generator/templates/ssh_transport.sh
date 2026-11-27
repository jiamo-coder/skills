#!/usr/bin/env bash
# Source after the selected project's private target configuration.
set +x

po_transport_fail() { printf '发布连接预检失败：%s\n' "$*" >&2; return 1; }

po_transport_init() {
  local key_type key_body key_fingerprint agent_keys selected_key
  [[ "${PO_DEPLOY_ENV_FILE:-}" == /* ]] || { po_transport_fail '必须指定绝对路径 PO_DEPLOY_ENV_FILE'; return 1; }
  : "${PO_DEPLOY_ENV:?必须明确 PO_DEPLOY_ENV}" "${PO_APPROVED_DEPLOY_ENV:?必须明确 PO_APPROVED_DEPLOY_ENV}"
  [[ "$PO_DEPLOY_ENV" == "$PO_APPROVED_DEPLOY_ENV" ]] || { po_transport_fail '目标环境与本次授权不一致'; return 1; }
  [[ "$PO_DEPLOY_ENV" =~ ^[a-z][a-z0-9-]*$ ]] || { po_transport_fail '环境名不合法'; return 1; }
  [[ "${PO_DEPLOY_HOST:-}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { po_transport_fail '缺少或无效的目标主机'; return 1; }
  [[ "${PO_DEPLOY_USER:-}" =~ ^[a-z_][a-z0-9_-]*$ ]] || { po_transport_fail '缺少或无效的发布账号'; return 1; }
  [[ "$PO_DEPLOY_USER" != root || "${PO_LEGACY_PASSWORD_AUTH:-}" == 1 ]] || { po_transport_fail '新目标必须使用非 root 发布账号'; return 1; }
  [[ "${PO_DEPLOY_PORT:-}" =~ ^[0-9]+$ ]] && (( PO_DEPLOY_PORT >= 1 && PO_DEPLOY_PORT <= 65535 )) || { po_transport_fail 'SSH 端口不合法'; return 1; }
  [[ "${PO_SSH_HOST_FINGERPRINT:-}" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] || { po_transport_fail '缺少可信渠道核实的主机 SHA256 指纹'; return 1; }
  read -r key_type key_body _ <<< "${PO_SSH_HOST_PUBLIC_KEY:-}"
  [[ "$key_type" == ssh-ed25519 && "$key_body" =~ ^[A-Za-z0-9+/=]+$ ]] || { po_transport_fail '缺少可信渠道核实的 Ed25519 主机公钥'; return 1; }
  local state_dir="${PO_SSH_STATE_DIR:-${PO_DEPLOY_ENV_FILE%/*}/.ssh-transport.local}"
  [[ "$state_dir" == /* && ! -L "$state_dir" ]] || { po_transport_fail '连接状态目录必须是非软链接绝对路径'; return 1; }
  (umask 077; mkdir -p "$state_dir") || return 1
  local key_file="$state_dir/host-key.$PO_DEPLOY_ENV.pub" hosts_file="$state_dir/known_hosts.$PO_DEPLOY_ENV"
  printf '%s %s\n' "$key_type" "$key_body" > "$key_file" || return 1
  chmod 600 "$key_file"
  key_fingerprint="$(ssh-keygen -lf "$key_file" -E sha256 2>/dev/null | awk '{print $2}')" || return 1
  [[ "$key_fingerprint" == "$PO_SSH_HOST_FINGERPRINT" ]] || { po_transport_fail '主机公钥与已核实指纹不一致'; return 1; }
  PO_SSH_HOST_ALIAS="po-${PO_DEPLOY_ENV}-${PO_DEPLOY_HOST//./-}-${PO_DEPLOY_PORT}"
  printf '%s %s %s\n' "$PO_SSH_HOST_ALIAS" "$key_type" "$key_body" > "$hosts_file"
  chmod 600 "$hosts_file"
  PO_SSH_TARGET="${PO_DEPLOY_USER}@${PO_DEPLOY_HOST}"
  PO_SSH_OPTIONS=(-o "HostKeyAlias=$PO_SSH_HOST_ALIAS" -o "UserKnownHostsFile=$hosts_file" -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
  PO_SSH_PREFIX=(env)
  case "${PO_SSH_AUTH_METHOD:-key}" in
    key)
      [[ "${PO_SSH_KEY_FILE:-}" == /* && -f "$PO_SSH_KEY_FILE" && -r "$PO_SSH_KEY_FILE" ]] || { po_transport_fail '指定私钥不存在或不可读'; return 1; }
      PO_SSH_OPTIONS+=(-o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -i "$PO_SSH_KEY_FILE")
      ;;
    agent)
      [[ "${PO_SSH_AGENT_PUBLIC_KEY_FILE:-}" == /* && -f "$PO_SSH_AGENT_PUBLIC_KEY_FILE" ]] || { po_transport_fail 'agent 模式必须指定公钥文件'; return 1; }
      selected_key="$(awk 'NR==1 {print $1 " " $2}' "$PO_SSH_AGENT_PUBLIC_KEY_FILE")"
      [[ "$selected_key" == ssh-*' '* && -n "${SSH_AUTH_SOCK:-}" ]] || { po_transport_fail 'agent 未启动或公钥无效'; return 1; }
      agent_keys="$(ssh-add -L 2>/dev/null)" || { po_transport_fail 'agent 密钥未解锁或不可用'; return 1; }
      printf '%s\n' "$agent_keys" | awk '{print $1 " " $2}' | grep -Fxq "$selected_key" || { po_transport_fail 'agent 中没有明确选定的密钥'; return 1; }
      PO_SSH_OPTIONS+=(-o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -i "$PO_SSH_AGENT_PUBLIC_KEY_FILE")
      ;;
    password)
      [[ "${PO_LEGACY_PASSWORD_AUTH:-}" == 1 && -n "${PO_SSH_PASSWORD:-}" ]] || { po_transport_fail '仅显式声明的旧环境可使用口令'; return 1; }
      command -v sshpass >/dev/null || { po_transport_fail '旧环境缺少 sshpass'; return 1; }
      export SSHPASS="$PO_SSH_PASSWORD"
      PO_SSH_PREFIX=(sshpass -e)
      PO_SSH_OPTIONS+=(-o BatchMode=no -o PubkeyAuthentication=no -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1)
      ;;
    *) po_transport_fail '仅支持 key、agent 或显式旧环境 password'; return 1 ;;
  esac
}

po_ssh() { "${PO_SSH_PREFIX[@]}" ssh -T -p "$PO_DEPLOY_PORT" "${PO_SSH_OPTIONS[@]}" "$PO_SSH_TARGET" "$@"; }
po_scp() { "${PO_SSH_PREFIX[@]}" scp -P "$PO_DEPLOY_PORT" "${PO_SSH_OPTIONS[@]}" "$@"; }

po_check_login() {
  local actual
  actual="$(po_ssh 'id -un')" || { po_transport_fail '主机身份、密钥或 SSH 登录校验失败'; return 1; }
  [[ "$actual" == "$PO_DEPLOY_USER" ]] || { po_transport_fail '登录账号与目标配置不一致'; return 1; }
}

po_check_release_entry() {
  local project="$1" scope="$2" root="$3" service="$4" entry="${PO_REMOTE_RELEASE_ENTRY:-}"
  [[ "$project" =~ ^[a-z0-9-]+$ && "$scope" =~ ^(web|backend|data|static)$ && "$root" =~ ^/[A-Za-z0-9_./-]+$ && "$service" =~ ^[A-Za-z0-9_.@-]+$ ]] || { po_transport_fail '发布范围或目标路径无效'; return 1; }
  [[ "$entry" =~ ^/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+$ ]] || { po_transport_fail '未配置安全的绝对路径发布入口 PO_REMOTE_RELEASE_ENTRY'; return 1; }
  local command suffix status
  printf -v command 'entry=%q; test -f "$entry" && test -x "$entry" || exit 31; p="$entry"; while [ "$p" != / ]; do test ! -L "$p" && test ! -w "$p" && test "$(stat -c %%u "$p")" -eq 0 && test "$(( 0$(stat -c %%a "$p") & 022 ))" -eq 0 || exit 32; p="$(dirname "$p")"; done; ' "$entry"
  printf -v suffix 'sudo -n -l -- %q >/dev/null 2>&1 || exit 33; sudo -n -- %q preflight %q %q %q %q >/dev/null || exit 34' "$entry" "$entry" "$project" "$scope" "$root" "$service"
  command+="$suffix"
  if po_ssh "$command"; then return 0; else status=$?; fi
  case "$status" in
    31) po_transport_fail "固定发布入口不存在或不可执行: $entry" ;;
    32) po_transport_fail "固定发布入口或父目录不是安全的 root 管理路径: $entry" ;;
    33) po_transport_fail "发布账号 $PO_DEPLOY_USER 缺少该固定入口的免密码 sudo 授权；请管理员一次性安装项目专用规则" ;;
    34) po_transport_fail "固定入口拒绝 $project/$scope 对 $root 与 $service 的发布权限；请管理员核对项目 allowlist" ;;
    *) po_transport_fail '发布权限预检失败，请检查 SSH 连接和服务器侧入口日志' ;;
  esac
  return 1
}
