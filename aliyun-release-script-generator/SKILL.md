---
name: aliyun-release-script-generator
description: 为当前项目生成阿里云 ECS 发布脚本，并补齐发布版本管理与 GitHub 自动同步能力，包括 package_release.sh、deploy_release.sh、start-prod.sh、server-bootstrap.sh、manage_release_version.mjs、sync_git_release.sh。用户一旦提到阿里云、ECS、发布脚本、deploy_release.sh、package_release.sh、start-prod.sh、版本号管理、自动建仓、GitHub 发布、上线脚本、打包脚本、部署脚手架，就优先使用这个 skill。这个 skill 必须先读取当前项目的 package.json、工作区、构建命令、dist 产物、启动入口和健康检查，再生成脚本，绝不能只凭项目名或拍脑袋假设目录结构。
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
- 生成或更新 `deploy/aliyun/scripts/sync_git_release.sh`

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
- `deploy/aliyun/scripts/sync_git_release.sh`

除非用户明确要求只输出文本，否则优先直接在当前项目里创建或更新这些文件。

回答顺序固定为：

1. 简短总结你识别到的项目结构
2. 说明已生成或更新哪些脚本
3. 提醒用户仍需自己提供的内容，例如真实域名、真实 env secrets、Nginx / systemd 文件、GitHub 认证
4. 说明你跑过的最小验证

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

生成时必须根据当前项目决定：

- 发布包里必须校验哪些路径
- 健康检查请求地址是什么
- 远端要不要同步 `admin-web`
- `start-prod.sh` 要从哪里启动服务
- 远端 release 默认保留几个版本
- GitHub 远端仓默认如何创建

默认行为：

- 远端 release 目录默认保留最新 `2` 个版本
- 支持通过 `PO_REMOTE_RELEASE_KEEP_COUNT` 覆盖
- 无论如何至少保留 `1` 个版本
- 部署成功后才真正写回版本文件并执行 git push

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
- 提交版本文件、打 tag、push 分支与 tag

默认行为：

- GitHub repo 名默认等于 `project_name`
- remote 名默认 `origin`
- 默认分支优先 `main`
- 默认创建 private repo

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
