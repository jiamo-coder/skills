# Reference Pattern

这个 skill 参考的基线项目是：

- `/Users/jiamo/Documents/Widgets/product-opportunity-miniapp`

它的发布模式有这些关键特点：

## package_release.sh

- 在项目根目录执行多个 workspace build
- 创建一个临时 stage 目录
- 复制运行时需要的 `package.json` / `package-lock.json`
- 复制后端编译产物
- 复制一个或两个静态前端产物
- 把 `deploy/aliyun` 下的 service / nginx / start-prod / bootstrap 文件一起打包

## deploy_release.sh

- 从 `.deploy.local.sh` 读取远端变量
- 找到最新发布包或按时间戳选择
- 旧参考项目用 `scp` / `ssh` 上传；新生成脚本先用固定主机密钥和项目专用账号做只读预检，上传与执行复用同一连接模块
- 切换 `current` 到某个 `release`
- 把 `web` 与 `admin-web` 同步到远端静态目录
- 安装生产依赖
- 重启 `systemd`
- 调用本地 health endpoint 验证
- 旧参考项目在健康检查成功后调用 `configure_nginx_site.sh`；新服务器须由管理员固定入口完成或预置这一受控操作，不能运行上传的 root 脚本
- 新生成脚本按 `web/backend/data` 范围切换：前端不重启后端，后端核对近期异地验证，数据变更先做新备份并在本机校验；远端失败恢复旧版本
- 仅 APK 和清单走独立文件发布，管理员入口把清单最后生效并负责可验证回退

## start-prod.sh

- 进入 release 根目录
- 只执行一个 Node 入口

## server-bootstrap.sh

- 初始化 `/service/<project>` 下的数据目录、上传目录、日志目录和静态目录

## Important Adaptation Rule

这个参考项目只能提供“结构模式”，不能直接照抄路径和命令。

生成新项目脚本时必须替换：

- 项目名
- build 命令
- 产物目录
- 启动入口
- 健康检查路径
- 是否存在 `admin-web`

## Extended Release Management

版本管理和 GitHub 自动同步不是参考项目原有能力，而是这个 skill 新增的统一扩展层。

扩展规则固定为：

- 发布时使用中文发布类型：`大改版` / `新功能` / `修复优化`
- 版本存储在 `package.json.version` 和 `deploy/aliyun/release-version.json`
- 发布成功后才真正写回版本号
- Git tag 形态为 `v<semver>-build.<buildCount>`
- 若本地已有 git 结构，优先做增量复用，不重建仓库
- 提交信息由当前 Codex Agent 根据真实 diff 和检查结果生成，不依赖外部模型 Token
- 发布前必须展示结构化提交正文和精确文件清单，展示后立即由 Agent 创建本机审批 sidecar，不等待二次人工确认
- 审批与 release tag、工作区指纹绑定；梳理后发生变化必须重新生成
- 发布成功后只提交审批清单和版本文件，禁止静默加入其他未跟踪文件

## Local Server Connection Config

- 首次生成脚本时创建 `deploy/aliyun/.deploy.local.sh`
- 文件记录服务器 IP/Host、SSH 用户、端口、认证方式、密码或私钥路径及远端目录
- 密码只通过隐藏输入或本机手工填写，不在对话或命令参数中传递
- 文件权限必须为 `600`，并加入根 `.gitignore`
- 旧项目已有配置时复用，禁止自动覆盖

## Managed Nginx And Certbot

- 新项目配置固定为 `/etc/nginx/projects.d/<project>.conf`
- `/etc/nginx/conf.d/00-managed-projects.conf` 只放一条 projects include
- 首次先用 HTTP-bootstrap 提供 webroot challenge，再申请证书并原子切换 HTTPS
- 最终配置保留 80 端口 challenge 与 HTTPS 跳转，支持 Certbot 续期
- 受管配置与证书齐全时，后续发布只做 `nginx -t`，不调用 Certbot、不 reload
- 未带受管标记的现有配置绝不覆盖；旧 `conf.d` 项目默认按 `skip` 兼容
- 证书失败必须终止部署，因此版本写回和 Git 同步不会发生
- 不负责阿里云 DNS；80/443、Nginx、Certbot 和 Certbot 账户是服务器前置条件
