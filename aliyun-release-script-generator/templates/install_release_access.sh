#!/usr/bin/env bash
# Administrator-reviewed, one-time sudoers grant for an existing fixed release entry.
set -euo pipefail

usage() {
  echo '用法: install_release_access.sh --account RELEASE_USER --entry /usr/local/sbin/PROJECT-release [--render|--install]' >&2
  exit 2
}

account='' entry='' action='render'
while (($#)); do
  case "$1" in
    --account) (($# >= 2)) || usage; account="$2"; shift 2 ;;
    --entry) (($# >= 2)) || usage; entry="$2"; shift 2 ;;
    --render) action=render; shift ;;
    --install) action=install; shift ;;
    *) usage ;;
  esac
done

[[ "$account" =~ ^[a-z_][a-z0-9_-]*$ && "$account" != root ]] || { echo '发布账号无效或为 root' >&2; exit 2; }
[[ "$entry" =~ ^/([A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+$ ]] || { echo '入口必须是无软链接、无点路径的绝对路径' >&2; exit 2; }

rule="$account ALL=(root) NOPASSWD: $entry"
if [[ "$action" == render ]]; then
  printf '%s\n' "$rule"
  exit 0
fi

[[ "$(id -u)" == 0 ]] || { echo '安装授权必须由管理员以 root 身份执行一次' >&2; exit 1; }
[[ -d /etc/sudoers.d && ! -L /etc/sudoers.d && "$(stat -c %u /etc/sudoers.d)" == 0 ]] || { echo '缺少安全的 /etc/sudoers.d' >&2; exit 1; }
sudoers_mode="$(stat -c %a /etc/sudoers.d)"
(( (8#$sudoers_mode & 8#22) == 0 )) || { echo '/etc/sudoers.d 可被非 root 写入' >&2; exit 1; }
command -v visudo >/dev/null || { echo '缺少 visudo' >&2; exit 1; }

p="$entry"
while [[ "$p" != / ]]; do
  [[ ! -L "$p" && -e "$p" ]] || { echo "入口或父目录缺失/为软链接: $p" >&2; exit 1; }
  [[ "$(stat -c %u -- "$p")" == 0 ]] || { echo "入口或父目录非 root 持有: $p" >&2; exit 1; }
  mode="$(stat -c %a -- "$p")"
  (( (8#$mode & 8#22) == 0 )) || { echo "入口或父目录可被组/其他人写入: $p" >&2; exit 1; }
  p="$(dirname -- "$p")"
done
[[ -f "$entry" && -x "$entry" ]] || { echo '固定发布入口必须是可执行的普通文件' >&2; exit 1; }

name="po-release-${account}-$(basename "$entry")"
target="/etc/sudoers.d/$name"
if [[ -e "$target" || -L "$target" ]]; then
  [[ ! -L "$target" && -f "$target" && "$(stat -c %u -- "$target")" == 0 ]] || { echo '已有规则文件不安全，拒绝覆盖' >&2; exit 1; }
  if [[ "$(cat "$target")" == "$rule" ]]; then
    echo "授权已存在，无需修改: $target"
    exit 0
  fi
  echo "已有不同授权，拒绝覆盖: $target" >&2
  exit 1
fi

tmp="$(mktemp /etc/sudoers.d/.po-release-XXXXXXXX)"
trap 'rm -f -- "$tmp"' EXIT
printf '%s\n' "$rule" > "$tmp"
chmod 0440 "$tmp"
visudo -cf "$tmp" >/dev/null || { echo 'sudoers 语法校验失败，未安装' >&2; exit 1; }
mv -n -- "$tmp" "$target"
[[ -f "$target" && "$(cat "$target")" == "$rule" ]] || { echo '授权安装失败' >&2; exit 1; }
visudo -cf /etc/sudoers >/dev/null || { rm -f -- "$target"; echo '全局 sudoers 校验失败，已撤销新规则' >&2; exit 1; }
trap - EXIT
echo "已安装最小授权: $target"
