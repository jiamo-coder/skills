---
name: aliyun-multi-app-deploy
description: 为阿里云 ECS 上的 Node API + SQLite + 静态前端项目生成可直接使用的部署配置。用户只需要确认域名、端口、项目名，你就要输出 Nginx、API env、systemd、.deploy.local.sh 变量块。只要用户提到阿里云、ECS、Nginx、systemd、env、部署配置、同机多项目、反向代理、SSL 证书、上线配置，就优先使用这个 skill，即使用户没有明确说“skill”。
---

# Aliyun Multi-App Deploy

为同一台阿里云 ECS 上的多个项目生成一套统一的服务器侧部署配置。

这个 skill 的目标很窄也很明确：

- 只处理服务器侧配置
- 只收集 `domain`、`port`、`project_name`
- 只输出用户可以直接复制的配置内容

不要替用户发明项目自己的构建命令、打包目录或启动方式。如果用户需要完整的 `package_release.sh` 或 `deploy_release.sh`，先说明这需要读取当前项目的真实目录结构和启动命令，不能只靠这 3 个值安全推断。

## Inputs

始终围绕这 3 个值工作：

- `domain`: 对外域名，例如 `productop.qiaokiai.com`
- `port`: 后端服务监听端口，例如 `8001`
- `project_name`: 阿里云上的项目路径名，例如 `product-opportunity`

把 `project_name` 直接视为部署 slug，用它派生目录名、服务名和配置文件名，不做自动改写。

## Interaction

1. 先从用户消息中提取这 3 个值。
2. 缺什么只问什么，不要追问其他偏好。
3. 值齐全后，先用一小段摘要回显确认：
   - 域名
   - 端口
   - 项目名
4. 然后一次性输出完整配置。

除非用户明确缩小范围，否则默认输出完整服务器侧配置，而不是只给 Nginx。

## Derived Values

拿到 `project_name` 后，固定按下面的规则派生：

- `REMOTE_ROOT=/service/<project_name>`
- `REMOTE_CURRENT_DIR=/service/<project_name>/current`
- `REMOTE_RELEASES_DIR=/service/<project_name>/releases`
- `REMOTE_SHARED_DIR=/service/<project_name>/shared`
- `REMOTE_DATA_DIR=/service/<project_name>/data`
- `REMOTE_UPLOADS_DIR=/service/<project_name>/uploads`
- `REMOTE_LOG_DIR=/service/<project_name>/logs`
- `REMOTE_WEB_DIR=/service/<project_name>/web`
- `REMOTE_ADMIN_WEB_DIR=/service/<project_name>/admin-web`
- `REMOTE_ENV_DIR=/etc/<project_name>`
- `REMOTE_ENV_FILE=/etc/<project_name>/<project_name>.env`
- `REMOTE_SERVICE_NAME=<project_name>.service`
- `REMOTE_NGINX_CONF=/etc/nginx/conf.d/<project_name>.conf`

## Output Contract

最终回答固定顺序如下：

1. 配置摘要
2. `nginx.conf`
3. `api.env.example`
4. `systemd service`
5. `.deploy.local.sh` 变量块

要求：

- `nginx.conf` 必须是完整代码块，可直接复制粘贴，不要夹杂解释。
- 所有 secrets 一律使用占位符，例如 `replace_me`、`cli_xxx`。
- 不生成项目专属 `package_release.sh` 或 `deploy_release.sh`。
- 在 4 段配置之后，用一句话提醒：`构建脚本需按当前项目结构单独维护。`

## Nginx Shape

Nginx 必须使用最终成品模板，而不是解释性示例。固定包含这些部分：

- `listen 443 ssl;`
- `server_name <domain>;`
- `ssl_certificate /etc/letsencrypt/live/<domain>/fullchain.pem;`
- `ssl_certificate_key /etc/letsencrypt/live/<domain>/privkey.pem;`
- `.env` 与隐藏文件拦截
- `/api/` 反代到 `http://127.0.0.1:<port>/`
- `/media/` 反代到 `http://127.0.0.1:<port>/media/`
- `/` 下的 `root /service/<project_name>/web;`
- `try_files $uri $uri/ /index.html;`

## Scripted Rendering

如果本 skill 目录下存在 `scripts/render_configs.sh`，优先调用它生成配置，减少手写替换时的遗漏。

命令格式：

```bash
bash /Users/jiamo/Documents/Skills/aliyun-multi-app-deploy/scripts/render_configs.sh "<domain>" "<port>" "<project_name>"
```

如果无法运行脚本，再按 [templates.md](./references/templates.md) 的模板手动替换。

## References

- 读取 [templates.md](./references/templates.md) 获取 4 段模板
- 读取 [evals.json](./evals/evals.json) 获取推荐 smoke test 提示

## Guardrails

- 不输出真实密钥、证书内容或 `.env` 实值。
- 不改动用户的路径规则，除非用户明确要求偏离默认约定。
- 不把 `/srv/apps/...` 和 `/service/...` 混用；默认始终使用 `/service/<project_name>`。
- 不额外发明 PM2、Docker、Supervisor 或 CI/CD 方案，除非用户明确要求。
