#!/usr/bin/env bash
# Save as deploy/aliyun/.deploy.local.sh (production) or
# deploy/aliyun/.deploy.preview.local.sh (preview). Never commit either file.
export PO_DEPLOY_ENV=production
export PO_DEPLOY_HOST=ecs.example.internal
export PO_DEPLOY_PORT=22
export PO_DEPLOY_USER=release_myapp
export PO_SSH_AUTH_METHOD=key
export PO_SSH_KEY_FILE="$HOME/.ssh/myapp-release"
# For agent mode instead: PO_SSH_AUTH_METHOD=agent and set the selected .pub path.
export PO_SSH_AGENT_PUBLIC_KEY_FILE=
# Obtain both values from an independently verified administrator channel.
export PO_SSH_HOST_PUBLIC_KEY='ssh-ed25519 REPLACE_WITH_VERIFIED_HOST_PUBLIC_KEY'
export PO_SSH_HOST_FINGERPRINT='SHA256:REPLACE_WITH_VERIFIED_HOST_FINGERPRINT'
export PO_PROJECT_NAME=myapp
export PO_PROJECT_DOMAIN=myapp.example.com
export PO_APP_PORT=8018
export PO_REMOTE_ROOT=/service/myapp
export PO_REMOTE_SERVICE_NAME=myapp.service
export PO_REMOTE_RELEASE_ENTRY=/usr/local/sbin/myapp-release
export PO_SERVER_LOCATION='cn-hangzhou / zone-id-from-ECS'
# APK-only project: admin entry must separately approve these exact target paths.
export PO_STATIC_TARGET_DIR=/service/myapp/downloads
export PO_STATIC_APK_NAME=myapp.apk
export PO_STATIC_MANIFEST_NAME=manifest.json
