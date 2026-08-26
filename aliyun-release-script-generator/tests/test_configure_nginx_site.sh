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

PROJECT_ROOT="$TEST_ROOT/project"
OUTPUT_DIR="$PROJECT_ROOT/deploy/aliyun/scripts"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_LOG="$TEST_ROOT/commands.log"
FAKE_NGINX_DUMP="$TEST_ROOT/nginx.dump"
mkdir -p "$OUTPUT_DIR" "$FAKE_BIN"
touch "$PROJECT_ROOT/api.env.example" "$PROJECT_ROOT/app.service" "$FAKE_LOG" "$FAKE_NGINX_DUMP"

cat > "$PROJECT_ROOT/app.conf" <<'NGINX'
server {
        listen 80;
        server_name smoke.example.com;
        location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://$host$request_uri; }
}
server {
        listen 443 ssl;
        server_name smoke.example.com;
        ssl_certificate /etc/letsencrypt/live/smoke.example.com/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/smoke.example.com/privkey.pem;
        location / { return 200; }
}
NGINX

bash "$SKILL_DIR/scripts/render_release_scripts.sh" \
  --output-dir "$OUTPUT_DIR" \
  --project-slug smoke-app \
  --project-domain smoke.example.com \
  --app-port 8123 \
  --api-build-cmd "npm run build:api" \
  --api-dist-path "dist/api" \
  --start-entry "dist/api/server.js" \
  --env-template "$PROJECT_ROOT/api.env.example" \
  --service-template "$PROJECT_ROOT/app.service" \
  --nginx-template "$PROJECT_ROOT/app.conf" \
  --ssh-auth-method agent >/dev/null

cat > "$FAKE_BIN/nginx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nginx %s\n' "$*" >> "$FAKE_LOG"
if [[ "${FAKE_NGINX_TEST_FAIL:-0}" == "1" && "${1:-}" == "-t" ]]; then
  exit 1
fi
if [[ "${FAKE_NGINX_DUMP_FAIL:-0}" == "1" && "${1:-}" == "-T" ]]; then
  exit 1
fi
if [[ "${1:-}" == "-T" && -f "$FAKE_NGINX_DUMP" ]]; then
  cat "$FAKE_NGINX_DUMP"
fi
EOF

cat > "$FAKE_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "$FAKE_LOG"
EOF

cat > "$FAKE_BIN/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'getent %s\n' "$*" >> "$FAKE_LOG"
[[ "${FAKE_DNS_FAIL:-0}" != "1" ]]
EOF

cat > "$FAKE_BIN/certbot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'certbot %s\n' "$*" >> "$FAKE_LOG"
if [[ "${1:-}" == "show_account" ]]; then
  [[ "${FAKE_CERTBOT_ACCOUNT_FAIL:-0}" != "1" ]]
  exit
fi
if [[ "${FAKE_CERTBOT_FAIL:-0}" == "1" ]]; then
  exit 1
fi
mkdir -p "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN"
touch \
  "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/fullchain.pem" \
  "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/privkey.pem"
EOF

chmod +x "$FAKE_BIN/nginx" "$FAKE_BIN/systemctl" "$FAKE_BIN/getent" "$FAKE_BIN/certbot"

export PATH="$FAKE_BIN:$PATH"
export FAKE_LOG FAKE_NGINX_DUMP
export PO_NGINX_TEST_MODE=1
export PO_PROJECT_NAME=smoke-app
export PO_PROJECT_DOMAIN=smoke.example.com
export PO_NGINX_FINAL_TEMPLATE="$PROJECT_ROOT/app.conf"

reset_case() {
  local name="$1"
  export CASE_ROOT="$TEST_ROOT/cases/$name"
  export PO_REMOTE_NGINX_SITES_DIR="$CASE_ROOT/projects.d"
  export PO_REMOTE_NGINX_INCLUDE_CONF="$CASE_ROOT/conf.d/00-managed-projects.conf"
  export PO_REMOTE_NGINX_CONF="$PO_REMOTE_NGINX_SITES_DIR/smoke-app.conf"
  export PO_CERTBOT_WEBROOT="$CASE_ROOT/certbot"
  export PO_LETSENCRYPT_LIVE_DIR="$CASE_ROOT/letsencrypt/live"
  export PO_LETSENCRYPT_RENEWAL_HOOK_DIR="$CASE_ROOT/letsencrypt/renewal-hooks/deploy"
  mkdir -p "$CASE_ROOT"
  : > "$FAKE_LOG"
  : > "$FAKE_NGINX_DUMP"
  unset FAKE_NGINX_TEST_FAIL FAKE_NGINX_DUMP_FAIL FAKE_DNS_FAIL FAKE_CERTBOT_FAIL FAKE_CERTBOT_ACCOUNT_FAIL
}

assert_contains() {
  grep -Fq "$2" "$1" || {
    echo "断言失败，$1 缺少: $2" >&2
    exit 1
  }
}

assert_not_contains() {
  if grep -Fq "$2" "$1"; then
    echo "断言失败，$1 不应包含: $2" >&2
    exit 1
  fi
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "预期命令失败但成功: $*" >&2
    exit 1
  fi
}

CONFIGURE_SCRIPT="$OUTPUT_DIR/configure_nginx_site.sh"

reset_case first
"$CONFIGURE_SCRIPT" >/dev/null
assert_contains "$PO_REMOTE_NGINX_INCLUDE_CONF" "include $PO_REMOTE_NGINX_SITES_DIR/*.conf;"
assert_contains "$PO_REMOTE_NGINX_CONF" "# managed-phase: final"
assert_contains "$FAKE_LOG" "certbot certonly"
assert_contains "$FAKE_LOG" "systemctl reload nginx"
test -x "$PO_LETSENCRYPT_RENEWAL_HOOK_DIR/10-reload-nginx.sh"

SITE_HASH="$(shasum -a 256 "$PO_REMOTE_NGINX_CONF" | awk '{print $1}')"
: > "$FAKE_LOG"
"$CONFIGURE_SCRIPT" >/dev/null
test "$SITE_HASH" = "$(shasum -a 256 "$PO_REMOTE_NGINX_CONF" | awk '{print $1}')"
assert_not_contains "$FAKE_LOG" "certbot"
assert_not_contains "$FAKE_LOG" "systemctl reload nginx"
assert_contains "$FAKE_LOG" "nginx -t"

reset_case existing-certificate
mkdir -p "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN"
touch "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/fullchain.pem" "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/privkey.pem"
"$CONFIGURE_SCRIPT" >/dev/null
assert_contains "$PO_REMOTE_NGINX_CONF" "# managed-phase: final"
assert_not_contains "$FAKE_LOG" "certbot"

reset_case certbot-failure
export FAKE_CERTBOT_FAIL=1
expect_failure "$CONFIGURE_SCRIPT"
assert_contains "$PO_REMOTE_NGINX_CONF" "# managed-phase: http-bootstrap"
assert_not_contains "$PO_REMOTE_NGINX_CONF" "# managed-phase: final"

reset_case certbot-account-missing
export FAKE_CERTBOT_ACCOUNT_FAIL=1
expect_failure "$CONFIGURE_SCRIPT"
test ! -e "$PO_REMOTE_NGINX_INCLUDE_CONF"
test ! -e "$PO_REMOTE_NGINX_CONF"

reset_case dns-missing
export FAKE_DNS_FAIL=1
expect_failure "$CONFIGURE_SCRIPT"
test ! -e "$PO_REMOTE_NGINX_INCLUDE_CONF"
test ! -e "$PO_REMOTE_NGINX_CONF"

reset_case external
mkdir -p "$(dirname "$PO_REMOTE_NGINX_CONF")"
printf 'server { listen 80; }\n' > "$PO_REMOTE_NGINX_CONF"
EXTERNAL_HASH="$(shasum -a 256 "$PO_REMOTE_NGINX_CONF" | awk '{print $1}')"
expect_failure "$CONFIGURE_SCRIPT"
test "$EXTERNAL_HASH" = "$(shasum -a 256 "$PO_REMOTE_NGINX_CONF" | awk '{print $1}')"

reset_case duplicate
printf '    server_name smoke.example.com;\n' > "$FAKE_NGINX_DUMP"
expect_failure "$CONFIGURE_SCRIPT"
test ! -e "$PO_REMOTE_NGINX_CONF"

reset_case nginx-dump-failure
export FAKE_NGINX_DUMP_FAIL=1
expect_failure "$CONFIGURE_SCRIPT"
test ! -e "$PO_REMOTE_NGINX_CONF"

reset_case include-conflict
mkdir -p "$(dirname "$PO_REMOTE_NGINX_INCLUDE_CONF")"
printf 'include /etc/nginx/other/*.conf;\n' > "$PO_REMOTE_NGINX_INCLUDE_CONF"
expect_failure "$CONFIGURE_SCRIPT"
assert_contains "$PO_REMOTE_NGINX_INCLUDE_CONF" "include /etc/nginx/other/*.conf;"

reset_case skip
PO_NGINX_SETUP_MODE=skip "$CONFIGURE_SCRIPT" >/dev/null
test ! -e "$PO_REMOTE_NGINX_CONF"
assert_contains "$FAKE_LOG" "nginx -t"
assert_not_contains "$FAKE_LOG" "systemctl reload nginx"

reset_case force
mkdir -p "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN" "$(dirname "$PO_REMOTE_NGINX_CONF")"
touch "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/fullchain.pem" "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/privkey.pem"
printf '# managed-by: aliyun-release-script-generator\n# managed-phase: final\nold\n' > "$PO_REMOTE_NGINX_CONF"
PO_NGINX_SETUP_MODE=force "$CONFIGURE_SCRIPT" >/dev/null
assert_contains "$PO_REMOTE_NGINX_CONF" "server_name smoke.example.com;"
assert_contains "$FAKE_LOG" "systemctl reload nginx"

reset_case existing-hook
mkdir -p "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN" "$PO_LETSENCRYPT_RENEWAL_HOOK_DIR"
touch "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/fullchain.pem" "$PO_LETSENCRYPT_LIVE_DIR/$PO_PROJECT_DOMAIN/privkey.pem"
printf 'keep-this-hook\n' > "$PO_LETSENCRYPT_RENEWAL_HOOK_DIR/10-reload-nginx.sh"
"$CONFIGURE_SCRIPT" >/dev/null
assert_contains "$PO_LETSENCRYPT_RENEWAL_HOOK_DIR/10-reload-nginx.sh" "keep-this-hook"

reset_case invalid-domain
PO_PROJECT_DOMAIN='invalid_domain' expect_failure "$CONFIGURE_SCRIPT"
test ! -e "$PO_REMOTE_NGINX_CONF"

echo "configure_nginx_site state matrix passed"
