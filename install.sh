#!/usr/bin/env bash
# 安装 godeploy 命令的安装脚本
# 支持：
#   1) 本地目录执行：  sudo ./install.sh
#   2) 一行命令安装：  curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/deploy/install.sh | sudo bash
set -euo pipefail
IFS=$'\n\t'

# ===== 基本配置（根据自己仓库修改） =====
GODEPLOY_REPO="${GODEPLOY_REPO:-terobox/godeploy}"   # GitHub 仓库
GODEPLOY_REF="${GODEPLOY_REF:-main}"                 # 分支或 tag
GODEPLOY_NAME="${GODEPLOY_NAME:-godeploy}"           # 安装后的命令名

INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-/usr/local/bin}" # 安装路径
CONFIG_DIR="${CONFIG_DIR:-/etc/godeploy}"            # 全局配置目录

RAW_BASE="https://raw.githubusercontent.com/${GODEPLOY_REPO}/${GODEPLOY_REF}/deploy"

# 计算脚本所在目录（用于“本地安装模式”）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-"."}")" && pwd)"

log()  { echo "[godeploy-install] $*"; }
err()  { echo "[godeploy-install][ERROR] $*" >&2; }
die()  { err "$@"; exit 1; }

# ===== 权限检查 =====
if [[ "$(id -u)" -ne 0 ]]; then
  err "请使用 root 权限运行（例如在前面加 sudo）。"
  err "示例：curl -fsSL ${RAW_BASE}/install.sh | sudo bash"
  exit 1
fi

# ===== 检查依赖命令 =====
for cmd in curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "缺少依赖命令: $cmd"
done

log "开始安装 ${GODEPLOY_NAME}"

# ===== 1. 安装可执行文件到 /usr/local/bin/godeploy =====
mkdir -p "${INSTALL_BIN_DIR}"
TARGET_BIN="${INSTALL_BIN_DIR}/${GODEPLOY_NAME}"

# 尝试本地 deploy.sh 优先
LOCAL_DEPLOY_SH="${SCRIPT_DIR}/deploy.sh"

if [[ -f "${LOCAL_DEPLOY_SH}" ]]; then
  log "检测到本地 deploy.sh: ${LOCAL_DEPLOY_SH}，优先使用本地文件安装。"
  cp "${LOCAL_DEPLOY_SH}" "${TARGET_BIN}.tmp"
else
  log "本地未找到 deploy.sh，尝试从 GitHub 下载：${RAW_BASE}/deploy.sh"
  curl -fsSL "${RAW_BASE}/deploy.sh" -o "${TARGET_BIN}.tmp" \
    || die "下载 deploy.sh 失败，请检查仓库/分支是否正确。"
fi

chmod +x "${TARGET_BIN}.tmp"
mv "${TARGET_BIN}.tmp" "${TARGET_BIN}"

log "已安装命令: ${TARGET_BIN}"
log "版本检测：$(${TARGET_BIN} --version || echo '（无法读取版本）')"

# ===== 2. 安装全局配置模板到 /etc/godeploy =====
mkdir -p "${CONFIG_DIR}"

CONFIG_EXAMPLE="${CONFIG_DIR}/godeploy.env.example"
CONFIG_MAIN="${CONFIG_DIR}/godeploy.env"

# 尝试本地 godeploy.env.example 优先
LOCAL_ENV_EXAMPLE="${SCRIPT_DIR}/godeploy.env.example"

if [[ ! -f "${CONFIG_EXAMPLE}" ]]; then
  if [[ -f "${LOCAL_ENV_EXAMPLE}" ]]; then
    log "检测到本地 godeploy.env.example，复制到 ${CONFIG_EXAMPLE}"
    cp "${LOCAL_ENV_EXAMPLE}" "${CONFIG_EXAMPLE}"
  else
    log "本地未找到 godeploy.env.example，尝试从 GitHub 下载。"
    if curl -fsSL "${RAW_BASE}/godeploy.env.example" -o "${CONFIG_EXAMPLE}.tmp"; then
      mv "${CONFIG_EXAMPLE}.tmp" "${CONFIG_EXAMPLE}"
    else
      log "未找到远程 godeploy.env.example（可忽略，如果你不用全局模板）。"
    fi
  fi
else
  log "检测到已存在的配置模板: ${CONFIG_EXAMPLE}，跳过。"
fi

if [[ ! -f "${CONFIG_MAIN}" ]]; then
  log "你可以基于 ${CONFIG_EXAMPLE} 创建 ${CONFIG_MAIN}，作为全局默认配置。"
fi

# ===== 3. 输出使用说明 =====
cat <<EOF

[godeploy 安装完成]

命令路径:
  ${TARGET_BIN}

全局配置目录（可选）:
  ${CONFIG_DIR}
    - godeploy.env.example  示例配置
    - godeploy.env         全局默认配置（需要你手动创建）

常用用法：
  # 在某个部署目录中准备一个本地配置文件
  cd /srv/app/workflow/backend
  cp ${CONFIG_EXAMPLE} ./godeploy.env   # 按需修改 REPO / APP_NAME 等

  # 部署指定版本（来自 GitHub Releases 的 tag）
  ${GODEPLOY_NAME} v0.0.1.3

  # 也可以显式指定配置文件：
  ${GODEPLOY_NAME} -c ./godeploy.env v0.0.1.3

环境变量/高级用法：
  - 可以通过环境变量覆盖安装行为：
      INSTALL_BIN_DIR=/opt/bin \\
      CONFIG_DIR=/opt/godeploy \\
      GODEPLOY_REF=v0.1.0 \\
      curl -fsSL ${RAW_BASE}/install.sh | sudo bash

EOF
