---
name: aliyun-release-script-generator
description: 为当前项目生成阿里云 ECS 发布脚本、按环境固定的 SSH 密钥与主机身份预检、独立 Nginx/Certbot 初始化、SQLite 分级备份与回退、版本管理及结构化 Git 审批。用于阿里云、ECS、发布脚本、APK 文件发布、SQLite 备份或上线脚手架；先读取项目真实构建、产物、启动和健康检查结构。
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
- 生成或更新 `sqlite_backup.sh`、`pull_sqlite_backup.sh`、`install_sqlite_backup_schedule.sh` 和 `remote_release.sh`
- 生成或更新 `ssh_transport.sh` 和 `deploy_static_files.sh`；新发布默认密钥登录并固定主机身份
- 生成 `install_release_access.sh`，供管理员一次性安装项目专属的免密码 sudo 授权；日常发布绝不索取 root/sudo 口令
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
16. SQLite 实际路径、迁移入口、后台写入与现有备份/异地恢复方式
17. 目标是生产还是预览，授权账号、可信主机指纹、私钥或选定 agent 公钥、管理员维护的发布入口及允许操作范围
18. 是否仅发布 APK 和清单；若是，识别精确文件名、目标目录、下载入口及回退方式

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
- `deploy/aliyun/scripts/sqlite_backup.sh`
- `deploy/aliyun/scripts/pull_sqlite_backup.sh`
- `deploy/aliyun/scripts/install_sqlite_backup_schedule.sh`
- `deploy/aliyun/scripts/remote_release.sh`
- `deploy/aliyun/scripts/ssh_transport.sh`
- `deploy/aliyun/scripts/deploy_static_files.sh`
- `deploy/aliyun/scripts/install_release_access.sh`（只用于一次性管理员配置，发布脚本不上传/执行）
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
- `PO_DEPLOY_ENV`：当前目标环境，例如 `production`、`preview`
- `PO_SSH_AGENT_PUBLIC_KEY_FILE`：agent 模式明确选定的公钥文件
- `PO_SSH_HOST_PUBLIC_KEY`、`PO_SSH_HOST_FINGERPRINT`：经可信渠道核实的主机身份，不自动采信首次连接
- `PO_REMOTE_RELEASE_ENTRY`：管理员维护且发布账号不可改的固定发布入口
- `PO_PROJECT_DOMAIN`：项目公网域名
- `PO_APP_PORT`：后端服务监听端口
- `PO_REMOTE_NGINX_SITES_DIR`：默认 `/etc/nginx/projects.d`
- `PO_REMOTE_NGINX_INCLUDE_CONF`：默认 `/etc/nginx/conf.d/00-managed-projects.conf`
- `PO_CERTBOT_WEBROOT`：默认 `/var/www/certbot`
- `PO_NGINX_SETUP_MODE`：`auto | skip | force`，默认 `auto`
- 项目的远端根目录、env、systemd、Nginx、静态目录和 release 保留数
- `PO_REMOTE_DATABASE_FILE`：从项目实际配置识别的 SQLite 绝对路径；不能确认时不得猜测
- `PO_REMOTE_BACKUP_DIR`、备份/校验/部署/健康检查超时和保留天数

执行约束：

- 非敏感信息缺失时，可以一次询问服务器 IP、SSH 账号、SSH 端口和认证方式。
- 不要让用户在聊天里发送密码或私钥内容。密码应通过 `init_deploy_config.sh` 的隐藏输入写入，或由用户在本机文件中填写。
- 创建前先检查旧文件；存在时只复用，不覆盖。
- 创建后执行 `chmod 600 deploy/aliyun/.deploy.local.sh`。
- 自动把 `/deploy/aliyun/.deploy.local.sh` 加入项目根 `.gitignore`，并确认未被 Git 跟踪。
- 生成器必须接收或从 env 模板提取 `--app-port`，并可接收 `--deploy-host`、`--deploy-user`、`--deploy-port`、`--ssh-auth-method`、`--ssh-key-file`；无服务器连接值时也要落下完整字段，发布前再补齐。
- 生产、预览各使用独立的本机私有目标文件，由 `PO_DEPLOY_ENV_FILE` 显式选择；不要把一个环境的主机/账号/密钥引用覆盖成另一个。密钥与主机身份、管理员入口的契约见 [项目化 SSH 发布目标](references/secure-release-targets.md)，脱敏示例见 [deploy-target.example.sh](references/deploy-target.example.sh)。
- 旧环境口令认证只有同时明确设置 `PO_SSH_AUTH_METHOD=password` 与 `PO_LEGACY_PASSWORD_AUTH=1` 才允许；新环境的密钥失败绝不回退口令。

## 一次配置、日常一键发布

- 每个项目/环境明确配置发布账号、SSH 密钥引用、可信主机身份、目标目录及 `PO_REMOTE_RELEASE_ENTRY`。账号可以在同一 ECS 上共存，但授权只覆盖各自的固定入口和 allowlist。
- 管理员**一次性**审核并安装 root 持有、发布账号不可改的项目入口；先在本机运行 `bash deploy/aliyun/scripts/install_release_access.sh --account <发布账号> --entry <固定入口> --render` 查看最小 sudoers 规则。管理员确认入口代码和项目 allowlist 后，在服务器可信位置安装该工具，再以 root 运行相同参数加 `--install`。管理员不应从同事可写的上传目录直接以 root 执行脚本。
- 工具只为已经存在的固定入口安装 `NOPASSWD` 规则，安装前检查入口及父目录的所有权、写权限和软链接，并用 `visudo` 验证。不会创建入口、改写已有不同授权，也不会授予 `sudo bash`、`sudo systemctl`、任意脚本或任意命令权限。
- 正式发布前 `po_check_login` 和 `po_check_release_entry` 以非交互方式检查密钥、主机、入口和当前范围；缺配置、入口不安全、免密码规则缺失或 allowlist 拒绝时在上传前停止，并指出管理员需要补哪一项。
- 一次性配置验收通过后，用户明确要求发布时 Agent 可自动完成打包、审批元数据、上传、健康检查、回退和版本/Git 同步，不再安排每次人工输入管理员密码；不得把“没有密码提示”解释为跳过数据库、生产授权或回退门禁。`--render` 仅是预览，不代表已经完成服务器授权。
- 旧脚本若每次生成执行脚本并 `sudo bash`，先迁移为调用固定入口；若本机直接拼接 `ssh sudo` 命令，改为统一使用 `ssh_transport.sh`。保留项目原有的发布/回退语义，不能只替换认证方式。迁移步骤见 [项目化 SSH 发布目标](references/secure-release-targets.md)。

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
- 在上传前验证目标授权、主机身份、密钥登录和管理员维护的发布入口，再由固定入口切换 release
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
- 仅显式标记的旧口令目标保持兼容；禁止仅凭旧密码变量自动降级

默认行为：

- 远端 release 目录默认保留最新 `2` 个版本
- 支持通过 `PO_REMOTE_RELEASE_KEEP_COUNT` 覆盖
- 无论如何至少保留 `1` 个版本
- 部署成功后才真正写回版本文件并执行 git push
- Nginx/证书初始化失败属于部署失败，不写回版本号、不提交、不打 tag
- 上传发布包前必须验证与当前 release plan 匹配的 Git 发布审批；缺失、tag 不一致或梳理后工作区变化时立即停止
- 发布审批还必须绑定环境、主机、账号、端口、项目根目录、管理员入口、认证方式、密钥引用和主机指纹；任何不一致都在上传前停止
- 禁止把上传的脚本传给 `root` / `sudo bash` 执行。管理员入口未就绪时明确说明缺项，不绕过预检。固定入口与回执协议见 [项目化 SSH 发布目标](references/secure-release-targets.md)。
- `remote_release.sh` 保留作旧项目逻辑对照，不是新服务器上的特权入口；新生成的 `deploy_release.sh` 不上传也不执行它。项目原有的健康检查、Nginx/证书和回退行为需要由管理员入口按同等门禁实现并在隔离环境验证。
- `--health-path` 必须对应真实可请求的后端健康端点；SQLite 项目生成时传入 `--sqlite-db-path`，并核对本机私有配置

### SQLite Release Scope And Backup

- Agent 根据实际 diff、迁移入口和生产数据操作，写入审批参数 `--db-change-scope web|backend|data`；证据不足按 `data`，用户明确指定范围时遵从。审批文件将范围和原有 tag/工作区指纹一起绑定，缺失或非法时发布前停止。
- `web` 仅切换静态文件、保留旧前端，不重启 API、不做数据库门禁；首次部署没有旧后端时不能选择 `web`。
- `backend` 在上传前检查 48 小时内的本机已验证备份证明，并与服务器备份清单比对；不为每次发布重新备份。
- `data` 在切换前用 SQLite `.backup` 创建新副本，限时拉到本机，校验 SHA-256 和 `quick_check` 后继续；生产机不执行 `quick_check`。失败或超时保持旧版本。
- 仅在远端 `current` 和数据库文件均不存在时按首次空库部署跳过旧库备份；已有服务但数据库文件缺失必须停止。
- 远端切换和健康检查限时执行；失败时恢复旧代码、静态文件、env 和 service，并核实旧服务。数据库迁移不能自动回滚数据，发布前必须检查前后兼容性或项目提供的恢复方案。
- 独立 systemd timer 每天生成一致性备份；本机 macOS launchd 每日及登录后补拉、验证。默认服务器保留 7 天、本机 30 天；未获异地验证回执的服务器副本不清理，始终至少保留两份。备份生成和本机验证分别记录，不把文件存在视为可恢复。
- 已生成的项目脚本不会自动升级；再次调用本 Skill 时须保留该项目的自定义部署逻辑，逐项整合新门禁。
- 仅 APK 与清单时使用 `deploy_static_files.sh`，不打包整个应用、不重启服务、不执行数据库门禁；上传目标只允许核准的两个文件，清单最后生效，回退恢复旧下载入口。
- 静态发布前由 Agent 按本次授权、目标和实际文件哈希写权限 `600` 的 `.static-release-approval.local.json`；手工脚本缺少有效审批时在 SSH 前停止。结构见 [项目化 SSH 发布目标](references/secure-release-targets.md)。

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
  --git-tag <version-plan.gitTag> \
  --db-change-scope <web|backend|data> \
  --target-env <production|preview> --target-host <host> \
  --target-user <account> --target-port <port> \
  --target-root </service/project> --release-entry </admin/owned/entry> \
  --target-auth <key|agent|password> --key-ref <private-key-path|agent-public-key-path|legacy-password> \
  --host-fingerprint <verified-SHA256-fingerprint>
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

## 首次成功发布后的系统登记

在项目使用本次升级后的流程首次**成功发布到生产**后，如果本机私有的 `deploy/aliyun/.first-publish-doc.local.json` 不存在，用飞书文档能力打开 [各服务数据库信息](https://ucnrmsg6xuey.feishu.cn/wiki/SxFxwUerXiCOcdkp6gGc6q9EnVb)，定位系统已有条目并更新：服务器主机/IP、ECS 区域或机房位置、业务端口、服务器项目目录和服务名、业务访问地址。以真实目标配置和发布回执为依据，不猜测位置，不写任何凭据。写入后读回核对，再以权限 `600` 写入本机标记（文档 ID、发布 tag、登记时间；禁止记录凭据）。文档失败不写标记，明确报告“发布成功、文档登记待补”；预览发布不更新生产条目。详见 [项目化 SSH 发布目标](references/secure-release-targets.md)。

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
