# Templates

这个文件保存 `aliyun-multi-app-deploy` skill 使用的 4 段模板。

占位符规则：

- `{{DOMAIN}}`
- `{{PORT}}`
- `{{PROJECT_NAME}}`

## nginx.conf

```nginx
server {
        listen       443 ssl;
        server_name  {{DOMAIN}};

        ssl_certificate /etc/letsencrypt/live/{{DOMAIN}}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN}}/privkey.pem;

        ssl_session_cache shared:SSL:1m;
        ssl_session_timeout 5m;
        ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE:ECDH:AES:HIGH:!NULL:!aNULL:!MD5:!ADH:!RC4:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;

        location ~ /\.(?!well-known).* {
                deny all;
                return 404;
        }
        location = /.env { return 404; }
        location = /.env.local { return 404; }
        location = /.env.prod { return 404; }
        location = /.env.dev { return 404; }
        location ~ /\. { return 404; }

        location /api/ {
                proxy_pass http://127.0.0.1:{{PORT}}/;
                proxy_set_header Host $http_host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header REMOTE-HOST $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /media/ {
                proxy_pass http://127.0.0.1:{{PORT}}/media/;
                proxy_set_header Host $http_host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header REMOTE-HOST $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
        }

        location / {
                root /service/{{PROJECT_NAME}}/web;
                index index.html;
                try_files $uri $uri/ /index.html;
        }
}
```

## api.env.example

```dotenv
PORT={{PORT}}
DATABASE_URL=/service/{{PROJECT_NAME}}/data/{{PROJECT_NAME}}.sqlite
UPLOAD_DIR=/service/{{PROJECT_NAME}}/uploads
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=replace_me
AUTH_SESSION_TTL_MS=604800000
```

## systemd service

```ini
[Unit]
Description={{PROJECT_NAME}} API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/service/{{PROJECT_NAME}}/current
Environment=NODE_ENV=production
EnvironmentFile=/etc/{{PROJECT_NAME}}/{{PROJECT_NAME}}.env
ExecStart=/usr/bin/env bash /service/{{PROJECT_NAME}}/current/deploy/aliyun/start-prod.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## .deploy.local.sh

```bash
#!/usr/bin/env bash

export PO_DEPLOY_HOST=""
export PO_DEPLOY_USER="root"
export PO_DEPLOY_PORT="22"
export PO_SSH_PASSWORD=""

export PO_REMOTE_ROOT="/service/{{PROJECT_NAME}}"
export PO_REMOTE_CURRENT_DIR="$PO_REMOTE_ROOT/current"
export PO_REMOTE_RELEASES_DIR="$PO_REMOTE_ROOT/releases"
export PO_REMOTE_SHARED_DIR="$PO_REMOTE_ROOT/shared"
export PO_REMOTE_DATA_DIR="$PO_REMOTE_ROOT/data"
export PO_REMOTE_UPLOADS_DIR="$PO_REMOTE_ROOT/uploads"
export PO_REMOTE_LOG_DIR="$PO_REMOTE_ROOT/logs"
export PO_REMOTE_ENV_DIR="/etc/{{PROJECT_NAME}}"
export PO_REMOTE_ENV_FILE="$PO_REMOTE_ENV_DIR/{{PROJECT_NAME}}.env"
export PO_REMOTE_SERVICE_NAME="{{PROJECT_NAME}}.service"
export PO_REMOTE_NGINX_CONF="/etc/nginx/conf.d/{{PROJECT_NAME}}.conf"
export PO_REMOTE_WEB_DIR="$PO_REMOTE_ROOT/web"
export PO_REMOTE_ADMIN_WEB_DIR="$PO_REMOTE_ROOT/admin-web"
export PO_REMOTE_RUN_USER="root"
```
