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
- 用 `scp` / `ssh` 上传并部署
- 切换 `current` 到某个 `release`
- 把 `web` 与 `admin-web` 同步到远端静态目录
- 安装生产依赖
- 重启 `systemd`
- 调用本地 health endpoint 验证

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
