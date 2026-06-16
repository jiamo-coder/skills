# Discovery Checklist

在当前项目里生成阿里云发布脚本前，至少确认下面这些项。

## Core Repo Facts

- 根目录 `package.json`
- lockfile 类型
- 是否是 monorepo
- app / package 目录结构
- 是否已有 `deploy/aliyun`

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

## Packaging Facts

- 发布包文件名格式
- 发布包必须包含的校验路径
- stage 目录布局
- 远端 release 目录布局

## Output Files

默认生成：

- `deploy/aliyun/scripts/package_release.sh`
- `deploy/aliyun/scripts/deploy_release.sh`
- `deploy/aliyun/scripts/start-prod.sh`
- `deploy/aliyun/scripts/server-bootstrap.sh`

可选依赖但不一定由这个 skill 生成：

- `deploy/aliyun/nginx/*.conf`
- `deploy/aliyun/systemd/*.service`
- `deploy/aliyun/env/*.env*`
- `deploy/aliyun/.deploy.local.sh`
