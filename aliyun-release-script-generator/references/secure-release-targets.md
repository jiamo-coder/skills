# 项目化 SSH 发布目标

在每个项目选择一份本机私有目标文件，用 `PO_DEPLOY_ENV_FILE=/absolute/path/to/production.local.sh` 或预览文件明确选择。Agent 在发布摘要中写出环境、主机、账号、目录、服务、发布入口和发布范围，再把六项目标参数传给 `manage_git_release_commit.mjs approve`；生成的审批文件为本机私有文件。不要把目标环境作为脚本的隐式默认值。参考 [脱敏配置](deploy-target.example.sh)。

新目标只支持 `key` 或明确选定公钥的 `agent`。管理员经可信渠道提供主机 Ed25519 公钥和 SHA-256 指纹，操作者将其写入私有目标文件；首次连接与轮换都不能从连接失败提示、`ssh-keyscan` 或 `accept-new` 自行采信。`ssh_transport.sh` 先比较配置中的公钥与指纹，再使用专用 `known_hosts`、`StrictHostKeyChecking=yes`、禁用密码回退。旧口令目标必须同时写 `PO_SSH_AUTH_METHOD=password` 和 `PO_LEGACY_PASSWORD_AUTH=1`；不能由密钥失败自动回退。

## 管理员维护的发布入口

普通发布账号不得改写 `PO_REMOTE_RELEASE_ENTRY`、其父目录、sudoers、systemd 单元或运行时环境文件。管理员在服务器上安装 root 持有、组/其他不可写的固定入口，并以最小 sudoers 规则只授权该入口。入口必须自己把项目、账号、环境、根目录、服务和发布范围与管理员持有的 allowlist 比较，不相信上传包内的脚本、命令或任意路径参数；拒绝越权。`preflight <project> <scope> <root> <service>` 必须只读验证目标目录、文件替换与服务操作权限。未通过时在上传前拒绝。

应用入口调用形态为 `deploy <project> <web|backend|data> <root> <service> <artifact> <sha256> <env-file> <service-file> <tag> <domain>`。入口验证 SHA-256、允许的目标和输入后，按原项目的备份/迁移/健康/回退策略操作；成功时只输出 `PO_RELEASE_OK:<tag>:<sha256>:healthy:rollback-not-needed`。失败时必须回退并给出可核对状态；不允许执行上传的 `.sh` 文件，也不允许给发布账号泛化的 `sudo bash`/`sudo env`。数据库迁移的回退仍以项目的兼容方案为准，不能自动用旧库覆盖在线数据。

文件入口调用形态为 `deploy-static <project> <target-dir> <stage-dir> <apk-name> <apk-sha256> <manifest-name> <manifest-sha256> <release-id>`，须只允许核准的两个上传文件及目录：先校验两份哈希，保留旧 APK 与旧清单，原子替换 APK，最后原子替换清单，验证下载入口。若业务另需带版本号的 APK 副本，只能由管理员入口按经校验的清单元数据推导固定文件名并复制，不能接受客户端任意第三个路径。成功输出 `PO_STATIC_OK:<release-id>:<apk-sha256>:<manifest-sha256>:healthy`。`rollback-static <project> <target-dir> <release-id>` 必须恢复旧下载入口，验证后输出 `PO_STATIC_ROLLBACK_OK:<release-id>`。客户端上传的文件和脚本一律不能作为 root 可执行内容。

静态发布由 Agent 根据本次授权先写本机 `deploy/aliyun/.static-release-approval.local.json`，权限 `600`，24 小时有效。字段为 `schemaVersion:1`、`confirmed:true`、`action:deploy|rollback`、`releaseId`、`target:{env,host,user,port,root,entry,auth,keyRef,hostFingerprint}`、`apkName`、`manifestName`、`apkSha256`、`manifestSha256`、`approvedAt`（ISO 时间）；回退时两个哈希为空字符串。脚本先比对目标、文件名和实际文件哈希，缺失或变化时连接前停止。APK-only 不套用应用的 `web/backend/data` 审批；仍需展示目标与拟替换文件，不自动扩大生产授权。

## 项目兼容复核

- **Hub / IntegrationHub**：当前 `transfer.sh`、`remote_root.sh` 使用口令；`remote_root.sh` 把上传内容通过 `sudo bash -s` 执行，正式发布及迁移回退均经过它。上线密钥前要由管理员提供固定迁移/回退入口，随后统一改造这三处。仅改 `-i` 不能满足权限隔离。
- **Geetimer**：应用发布和预览脚本已有 `key|agent|password` 分支，但凭系统全局 known_hosts 且未绑定独立指纹；`ssh_privileged.sh` 可执行上传的 `remote_release.sh`，须改为管理员入口。当前独立副本未定位到单独 APK/清单发布脚本；实际文件发布可能位于其他副本，先确认入口。
- **小算盘**：`Harness-xiaosuanpan-bot-store` 有类似的应用脚本；`native_downloads.mjs` 管理 `geetimer.apk`、版本化 APK 和 `geetimer-native-latest.json`，目前作为应用包内静态下载文件继承。若此次仅变更 APK/清单，应走独立文件发布，管理员入口从校验过的 manifest 推导版本化副本；不能顺带重启应用或触发数据库流程。`Budget` 的 `deploy_release.sh` 和 `pull_sqlite_backup.sh` 仍使用 `accept-new`，且有未提交的项目定制改动；升级时保留这些改动，备份拉取也改用同一受信任主机配置。

这些项目不得直接用通用生成器覆盖现有定制脚本。管理员入口、可信主机身份、项目账户和允许目录未确认前，只能完成只读分析与本机测试，不得上传或生产发布。

## 首次成功发布后的飞书登记

目标是 [各服务数据库信息](https://ucnrmsg6xuey.feishu.cn/wiki/SxFxwUerXiCOcdkp6gGc6q9EnVb)。Agent 在该项目完成升级后的**首次成功生产发布**后，若本机 `deploy/aliyun/.first-publish-doc.local.json` 不存在，读取现有对应系统条目，写入已核实的服务器主机/IP、ECS 区域或机房位置、业务端口、项目目录、服务名和业务访问地址；已有条目做定点更新，不创建重复条目。不要写 SSH 私钥路径、口令、Token 或环境变量值。写入后重新读取并核对，再将文档 ID、发布 tag 和登记时间写入权限 `600` 的本机标记。缺少地域、文档权限或发布成功证据时，不写标记并报告“生产发布成功，文档登记待补”；预览发布不改生产条目。

## 本机隔离验证回执（2026-11-25）

- `bash -n` 检查生成器、全部 Shell 模板和测试脚本：通过。
- `test_git_release_confirmation.sh`：旧审批目标拒绝在上传前继续；目标和密钥引用不一致拒绝；失败不推进版本和 tag。
- `test_configure_nginx_site.sh`：已有 Nginx/Certbot 状态矩阵通过。
- `test_sqlite_release_scope.sh`：SQLite 备份、拉取校验、三类范围及回退桩通过。
- `test_ssh_release_targets.sh`：固定主机指纹、指定密钥、登录、权限拒绝、APK/清单顺序、静态回退和证据文件通过。
- 未连接真实 ECS；未验证管理员入口的实际 allowlist/sudoers、真实域名健康检查或飞书写入。以上回执不能替代各项目的隔离环境验收。
