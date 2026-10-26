# Discovery Checklist

在当前项目里生成阿里云发布脚本前，至少确认下面这些项。

## Core Repo Facts

- 根目录 `package.json`
- lockfile 类型
- 是否是 monorepo
- app / package 目录结构
- 是否已有 `deploy/aliyun`
- 是否已有 `.git`
- 是否已有 git remote
- 当前 `package.json.version`
- 是否已有 `deploy/aliyun/release-version.json`
- 是否已有 `deploy/aliyun/.deploy.local.sh`
- `.deploy.local.sh` 是否已被 `.gitignore` 忽略、权限是否为 `600`

## Build Facts

- 后端 build 命令
- 静态前端 build 命令
- 是否有第二个前端
- build 时是否依赖环境变量

## Runtime Facts

- Node 启动入口
- 是否需要 `npm install --omit=dev`
- 健康检查路径
- 是否需要上传额外运行时资源
- 发布后是否需要自动同步 GitHub
- 服务器 IP/Host、SSH 用户、SSH 端口、认证方式
- 后端监听端口，以及 env、Nginx upstream、健康检查三处是否一致
- 项目公网域名及其 A 记录是否已指向目标服务器
- 服务器 80/443 是否可达，Nginx、Certbot 和 Certbot 账户是否就绪
- 项目 Nginx 是新式受管配置、旧式 `conf.d` 配置还是人工维护配置
- SQLite 文件实际路径、迁移/批量数据写入入口、健康端点及数据库权限
- 48 小时内本机已校验备份和远端清单是否对应；异地拉取调度是否运行

## Packaging Facts

- 发布包文件名格式
- 发布包必须包含的校验路径
- stage 目录布局
- 远端 release 目录布局
- 版本计划 sidecar 文件格式
- Git tag 命名规则
- 当前已跟踪改动、未跟踪文件和已有暂存区内容
- 结构化 Git 提交草稿、实际验证命令与结果
- 小葡萄任务 ID、项目链接、Gitee Issue/PR 等关联任务
- Agent 是否已展示结构化正文和精确文件清单，并自动生成本次审批

## Output Files

默认生成：

- `deploy/aliyun/scripts/package_release.sh`
- `deploy/aliyun/scripts/deploy_release.sh`
- `deploy/aliyun/scripts/start-prod.sh`
- `deploy/aliyun/scripts/server-bootstrap.sh`
- `deploy/aliyun/scripts/manage_release_version.mjs`
- `deploy/aliyun/scripts/manage_git_release_commit.mjs`
- `deploy/aliyun/scripts/sync_git_release.sh`
- `deploy/aliyun/scripts/init_deploy_config.sh`
- `deploy/aliyun/scripts/configure_nginx_site.sh`
- `deploy/aliyun/scripts/sqlite_backup.sh`、`pull_sqlite_backup.sh`、`install_sqlite_backup_schedule.sh`、`remote_release.sh`
- `deploy/aliyun/.deploy.local.sh`（首次自动创建，本机私有）
- `deploy/aliyun/.git-release-approval.local.json`（梳理后自动创建，本机私有）

可选依赖但不一定由这个 skill 生成：

- `deploy/aliyun/nginx/*.conf`
- `deploy/aliyun/systemd/*.service`
- `deploy/aliyun/env/*.env*`

新项目的 Nginx 模板应使用 `/etc/nginx/projects.d/<project>.conf`，全局入口只使用 `/etc/nginx/conf.d/00-managed-projects.conf`。现有旧项目不自动迁移。
