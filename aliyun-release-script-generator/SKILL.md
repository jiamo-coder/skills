---
name: aliyun-release-script-generator
description: 为当前项目生成阿里云 ECS 发布脚本、本机服务器连接配置、独立 Nginx/Certbot 首次初始化、发布版本管理、结构化 Git 自动审批与 GitHub 同步能力。用户提到阿里云、ECS、发布脚本、Nginx、Certbot、版本管理、自动提交、GitHub 发布或上线脚手架时优先使用；必须先读取项目真实构建、产物、启动和健康检查结构。
---

# Aliyun Release Script Generator

这个 skill 用来为当前项目定制阿里云发布脚本。

它的职责是：

- 读取当前 repo 的真实结构
- 提取构建命令和产物路径
- 生成或更新 `deploy/aliyun/scripts/package_release.sh`
- 生成或更新 `deploy/aliyun/scripts/deploy_release.sh`
- 生成或更新 `deploy/aliyun/scripts/start-prod.sh`
- 生成或更新 `deploy/aliyun/scripts/server-bootstrap.sh`
- 生成或更新 `deploy/aliyun/scripts/manage_release_version.mjs`
- 生成或更新 `deploy/aliyun/scripts/manage_git_release_commit.mjs`
- 生成或更新 `deploy/aliyun/scripts/sync_git_release.sh`
- 生成或更新 `deploy/aliyun/scripts/init_deploy_config.sh`
- 生成或更新 `deploy/aliyun/scripts/configure_nginx_site.sh`
- 首次调用时自动创建本机私有的 `deploy/aliyun/.deploy.local.sh`

这个 skill 不应该跳过 repo 探查。脚本是否可用，完全取决于是否先读清楚当前项目。

## Mandatory Discovery

动手前先检查这些信息：

1. 根目录 `package.json`
2. workspace / app 目录布局
3. 后端构建命令
4. 前端构建命令
5. 后端产物目录
6. 前端产物目录
7. 后端启动入口
8. 健康检查路径
9. 是否存在第二个静态前端，例如 `admin-web`
10. 现有 `deploy/aliyun` 目录是否已经存在
11. 当前项目是否已经有 git 仓和远端
12. 当前项目是否已经有版本号或发布元数据
13. 是否已有 `deploy/aliyun/.deploy.local.sh`，以及它是否已经被 Git 忽略
14. 服务器 IP/Host、SSH 用户、SSH 端口与认证方式是否已有本机记录
15. 项目域名、Nginx 模板和当前远端 Nginx 管理方式

优先使用这些命令：

```bash
rg --files
rg -n "build|start|health|dist|vite|taro|next|express|fastify|koa"
sed -n '1,220p' package.json
find . -maxdepth 3 -type f -name 'package.json'
```

如果 repo 中已经有部署脚本或部署目录，先读懂再改，不要重写成另一套风格。

## Questions To Answer From The Repo

在生成脚本前，先自己回答这些问题：

- 后端是怎么构建的
- 需要打包哪些 `package.json` / lockfile
- 运行时需要哪些产物
- 前端是否只有一个静态站点，还是还有后台前端
- 后端入口是 `dist/.../server.js`、`build/index.js`，还是别的
- 健康检查是 `/health`、`/api/health`，还是根本没有

只有这些问题在 repo 里都找不到时，才向用户追问。

## Output Contract

默认目标文件是：

- `deploy/aliyun/scripts/package_release.sh`
- `deploy/aliyun/scripts/deploy_release.sh`
- `deploy/aliyun/scripts/start-prod.sh`
- `deploy/aliyun/scripts/server-bootstrap.sh`
- `deploy/aliyun/scripts/manage_release_version.mjs`
- `deploy/aliyun/scripts/manage_git_release_commit.mjs`
- `deploy/aliyun/scripts/sync_git_release.sh`
- `deploy/aliyun/scripts/init_deploy_config.sh`
- `deploy/aliyun/scripts/configure_nginx_site.sh`
- `deploy/aliyun/.deploy.local.sh`（首次生成，权限 `600`，禁止提交）
- `deploy/aliyun/.git-release-approval.local.json`（每次发布前由 Agent 梳理后自动生成，权限 `600`，禁止提交）

除非用户明确要求只输出文本，否则优先直接在当前项目里创建或更新这些文件。

回答顺序固定为：

1. 简短总结你识别到的项目结构
2. 说明已生成或更新哪些脚本
3. 提醒用户仍需自己提供的内容，例如真实域名、真实 env secrets、Nginx / systemd 文件、GitHub 认证
4. 说明你跑过的最小验证

## First-Run Server Config

首次在一个项目调用本 skill 时，如果 `deploy/aliyun/.deploy.local.sh` 不存在，必须自动创建，不能只在回答里展示模板。

配置至少包含：

- `PO_DEPLOY_HOST`：服务器 IP 或域名
- `PO_DEPLOY_USER`：SSH 账号
- `PO_DEPLOY_PORT`：SSH 端口，默认 `22`
- `PO_SSH_AUTH_METHOD`：`password | key | agent`
- `PO_SSH_PASSWORD`：仅密码认证使用
- `PO_SSH_KEY_FILE`：仅私钥认证使用
- `PO_PROJECT_DOMAIN`：项目公网域名
- `PO_APP_PORT`：后端服务监听端口
- `PO_REMOTE_NGINX_SITES_DIR`：默认 `/etc/nginx/projects.d`
- `PO_REMOTE_NGINX_INCLUDE_CONF`：默认 `/etc/nginx/conf.d/00-managed-projects.conf`
- `PO_CERTBOT_WEBROOT`：默认 `/var/www/certbot`
- `PO_NGINX_SETUP_MODE`：`auto | skip | force`，默认 `auto`
- 项目的远端根目录、env、systemd、Nginx、静态目录和 release 保留数

执行约束：

- 非敏感信息缺失时，可以一次询问服务器 IP、SSH 账号、SSH 端口和认证方式。
- 不要让用户在聊天里发送密码或私钥内容。密码应通过 `init_deploy_config.sh` 的隐藏输入写入，或由用户在本机文件中填写。
- 创建前先检查旧文件；存在时只复用，不覆盖。
- 创建后执行 `chmod 600 deploy/aliyun/.deploy.local.sh`。
- 自动把 `/deploy/aliyun/.deploy.local.sh` 加入项目根 `.gitignore`，并确认未被 Git 跟踪。
- 生成器必须接收或从 env 模板提取 `--app-port`，并可接收 `--deploy-host`、`--deploy-user`、`--deploy-port`、`--ssh-auth-method`、`--ssh-key-file`；无服务器连接值时也要落下完整字段，发布前再补齐。

## Generation Rules

### package_release.sh

这个脚本负责：

- 构建后端
- 构建一个或多个前端
- 生成本次发布的版本计划 sidecar
- 创建 stage 目录
- 复制运行所需文件
- 打包为 `deploy/aliyun/release/<project>-<stamp>.tgz`

生成时必须根据当前项目的真实结构决定：

- 哪些 `npm run build` 命令需要执行
- 是否需要在构建时注入前端环境变量
- 后端产物是整个 `dist` 目录还是其中某个子目录
- 是否需要 `web/` 和 `admin-web/` 两套静态目录
- 版本计划文件应该如何与发布包关联

### deploy_release.sh

这个脚本负责：

- 读取 `.deploy.local.sh`
- 校验发布包内容
- 上传发布包和配置文件
- 在远端切换 release
- 清理更老的远端 release
- 在本地成功写回发布版本
- 自动同步到 GitHub 仓
- 安装生产依赖
- 重启服务
- 执行健康检查
- 在应用健康检查成功后按服务器真实状态初始化或校验独立 Nginx 站点

生成时必须根据当前项目决定：

- 发布包里必须校验哪些路径
- 健康检查请求地址是什么
- 远端要不要同步 `admin-web`
- `start-prod.sh` 要从哪里启动服务
- 远端 release 默认保留几个版本
- GitHub 远端仓默认如何创建
- SSH 认证方式是密码、私钥还是 agent；旧项目只有 `PO_SSH_PASSWORD` 时保持兼容

默认行为：

- 远端 release 目录默认保留最新 `2` 个版本
- 支持通过 `PO_REMOTE_RELEASE_KEEP_COUNT` 覆盖
- 无论如何至少保留 `1` 个版本
- 部署成功后才真正写回版本文件并执行 git push
- Nginx/证书初始化失败属于部署失败，不写回版本号、不提交、不打 tag
- 上传发布包前必须验证与当前 release plan 匹配的 Git 发布审批；缺失、tag 不一致或梳理后工作区变化时立即停止

## Structured Git Auto Approval

每次发布前，当前 Codex Agent 必须先读取 `git status --short`、`git diff` 和版本计划，并至少执行一项真实检查。直接使用当前 Agent 生成简介，不调用模型 API，不要求配置 OpenAI、DeepSeek 或其他模型 Token。

提交信息固定为：

```text
<type>(<scope>): <明确的实现结果>

问题/需求：
实现结果：
影响范围：
验证方式：
关联任务：
风险与回滚：
```

规则：

- `type` 仅使用 `feat | fix | refactor | perf | docs | test | build | ci | chore`。
- 标题必须写清对象、动作和实现结果，`scope` 根据项目或模块推断。
- 正文六个字段必须全部保留；“问题/需求”和“实现结果”至少一项有效。
- “验证方式”只能记录本次实际运行的命令和结果，命令使用反引号包裹；禁止把计划执行写成已经通过。
- “关联任务”支持小葡萄任务 ID、项目链接、Gitee Issue/PR；没有时写“无”。
- Agent 必须同时展示拟提交文件清单。已有仓库默认包含全部已跟踪改动和版本文件，未跟踪文件默认排除并在摘要中说明。
- Agent 梳理并展示结构化正文和文件清单后，即视为本次发布审批完成；不要停下来请求“确认提交”或等待第二次回复。
- 展示摘要后立即调用 `manage_git_release_commit.mjs approve` 写入本机审批文件，再继续执行发布、提交、tag 和 push。
- 如果用户在本次请求中明确要求“只预览”“先别提交”或“让我修改”，才暂停自动审批并等待用户调整。
- 未跟踪文件只有在 Agent 判断属于本次实现、完成敏感信息检查并明确列入摘要时，才使用 `--allow-untracked true` 自动授权。
- 首次建仓必须审计并展示全部非忽略文件；确认没有凭证、私钥或本机配置后使用 `--allow-initial-all true`，不再请求二次人工确认。
- 手工直接运行 `deploy_release.sh` 且没有有效审批文件时必须失败，不能自动生成提交信息或回退到终端确认。

自动审批命令：

```bash
node deploy/aliyun/scripts/manage_git_release_commit.mjs approve \
  --message-file /tmp/release-commit-message.txt \
  --paths-file /tmp/release-commit-paths.txt \
  --git-tag <version-plan.gitTag>
```

当摘要明确纳入未跟踪文件时增加 `--allow-untracked true`；首次建仓审计通过后增加 `--allow-initial-all true`。

### configure_nginx_site.sh

这个脚本负责服务器侧独立站点初始化。每个新项目配置为 `/etc/nginx/projects.d/<project_name>.conf`，统一入口 `/etc/nginx/conf.d/00-managed-projects.conf` 只能包含 `include /etc/nginx/projects.d/*.conf;`。

首次初始化顺序固定为：

1. 检查 Nginx、Certbot、`certbot show_account`、域名解析和配置冲突
2. 创建全局 include 与 `/var/www/certbot`
3. 安装带受管标记的 HTTP-bootstrap 配置
4. 执行 `nginx -t` 并 reload
5. 执行 `certbot certonly --webroot --non-interactive --agree-tos`
6. 校验证书文件，原子替换为最终 HTTPS 配置
7. 再次 `nginx -t` 并 reload
8. 若续期 deploy hook 不存在，则创建 `10-reload-nginx.sh`；已有文件不覆盖

`PO_NGINX_SETUP_MODE` 规则：

- `auto`：配置和证书齐全只做只读 `nginx -t`；证书已有但配置缺失时直接安装 HTTPS；受管 bootstrap 存在且证书缺失时恢复签发；两者缺失时完整初始化。
- `skip`：只做 `nginx -t`，不上传、不安装、不 reload；用于人工维护或旧式 `/etc/nginx/conf.d/<project>.conf` 项目。
- `force`：仅允许覆盖带本 skill 受管标记的配置，用于域名或端口变化；未带标记的配置即使 force 也拒绝覆盖。

证书签发失败时必须保留可用的 HTTP-bootstrap 配置并返回失败，禁止用 `|| true` 吞掉错误。已有 `/etc/nginx/conf.d/*.conf` 不迁移；旧 `.deploy.local.sh` 未设置模式且明确使用旧式 `conf.d` 项目路径时，生成脚本应兼容为 `skip`。

本 skill 不操作阿里云 DNS。自动签发前要求域名 A 记录已生效、80/443 可达、服务器已安装 Nginx/Certbot 并存在可复用的 Certbot 账户。

### manage_release_version.mjs

这个脚本负责：

- 读取根目录 `package.json`
- 读取或初始化 `deploy/aliyun/release-version.json`
- 根据中文发布类型生成版本计划
- 在部署成功后写回 `semver + buildCount`

发布类型固定使用中文三选一：

- `大改版`：架构级调整、技术栈切换、模块边界重组、明显影响多个子系统
- `新功能`：新增用户可感知能力、页面、接口、业务流程
- `修复优化`：bug 修复、性能优化、交互微调、兼容性修复、已有能力改良

版本规则固定为：

- `大改版` => major +1，minor/patch 归零
- `新功能` => minor +1，patch 归零
- `修复优化` => patch +1
- `buildCount` 每次成功发布后全局 +1
- `package.json.version` 只保存 `semver`
- 展示版本使用 `x.y.z (buildCount)`
- Git tag 使用 `v<semver>-build.<buildCount>`

### sync_git_release.sh

这个脚本负责：

- 检查本地 `.git`
- 如有需要自动 `git init`
- 如果远端不存在则优先通过 `gh repo create` 创建 GitHub private repo
- 从 Agent 自动生成的本机审批文件读取结构化提交正文和精确文件清单
- 只提交确认清单、`package.json` 和 `deploy/aliyun/release-version.json`
- 拒绝暂存区中未列入摘要的文件
- 使用 `git commit -F` 提交，成功 push 后消费本次审批文件
- 打 tag、push 分支与 tag

默认行为：

- GitHub repo 名默认等于 `project_name`
- remote 名默认 `origin`
- 默认分支优先 `main`
- 默认创建 private repo

### init_deploy_config.sh

这个脚本负责：

- 首次创建 `deploy/aliyun/.deploy.local.sh`
- 交互收集服务器 IP、SSH 账号、端口和认证方式
- 对密码使用隐藏输入，不在 stdout 输出
- 以 shell-safe 方式写入变量并设置权限 `600`
- 自动补齐根 `.gitignore`
- 已有配置时拒绝覆盖，只修正权限与 ignore 规则

如果健康检查路径不存在：

- 不要悄悄假设成 `/health`
- 先指出 repo 中未发现健康检查
- 给出最小兼容方案，例如暂时跳过 HTTP health check，改为只校验进程启动，或提示用户补接口

### start-prod.sh

这个脚本必须只做一件事：

- 切到项目根目录
- 用正确的 Node 入口启动服务

不要强行假设入口是 `apps/api/dist/apps/api/src/server.js`，必须从当前项目读取。

### server-bootstrap.sh

这个脚本负责初始化服务目录。必须根据是否存在多前端决定是否创建：

- `web`
- `admin-web`

同时保留：

- `data`
- `uploads`
- `logs`

## Prefer Reuse

如果当前项目已经有以下内容，优先复用：

- `deploy/aliyun/nginx/*.conf`
- `deploy/aliyun/systemd/*.service`
- `deploy/aliyun/env/*.env*`
- `.deploy.local.sh`

如果这些文件不存在，也不要阻塞脚本生成；只要在回答里明确说明脚本仍依赖它们即可。

## Optional Helper Script

如果需要减少重复样板，可调用本 skill 目录下的脚本：

```bash
bash /Users/jiamo/Documents/Skills/aliyun-release-script-generator/scripts/render_release_scripts.sh --help
```

使用方式：

- 先从 repo 中提取构建命令、产物路径、启动入口、health path 等值
- 再把这些值传给 helper script
- 生成骨架后，按当前项目实际情况做最后微调

不要在没有完成 repo 探查前直接调用 helper script。

## References

- 读取 [references/reference-pattern.md](./references/reference-pattern.md) 了解参考项目的发布模式
- 读取 [references/checklist.md](./references/checklist.md) 作为探查清单
- 读取 [evals/evals.json](./evals/evals.json) 获取推荐测试提示

## Guardrails

- 不要只靠 `project_name` 生成脚本。
- 不要假设所有项目都有 `admin-web`。
- 不要假设所有项目都用 npm workspace，但如果 repo 明显在用，就顺着现有方式生成。
- 不要引入 Docker、PM2、pnpm、yarn，除非当前项目已经在用。
- 不要改写用户已有的部署架构，只做同风格补全和定制。
- 不要让用户直接选择英文 `major/minor/patch` 或 `architecture/feature/fix`；优先用中文三选一。
- 不要把真实 SSH 密码、私钥内容或 token 写进 skill 输出、命令参数、日志、示例或 Git 历史。
- 不要调用 OpenAI、DeepSeek 或其他外部模型来生成提交简介；当前 Agent 直接根据真实 diff 和验证结果生成。
- 梳理并展示提交内容后直接创建审批文件并继续发布，不要额外请求人工确认；但用户明确要求预览或暂停时必须停止。
