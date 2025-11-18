#!/usr/bin/env bash
# 一行命令安装 godeploy：
#   curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash
set -euo pipefail
IFS=$'\n\t'

# ===== 基本配置 =====
GODEPLOY_REPO="${GODEPLOY_REPO:-terobox/godeploy}"   # GitHub 仓库
GODEPLOY_REF="${GODEPLOY_REF:-main}"                 # 分支或 tag
GODEPLOY_NAME="${GODEPLOY_NAME:-godeploy}"           # 安装后的命令名
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-/usr/local/bin}" # 安装路径

RAW_BASE="https://raw.githubusercontent.com/${GODEPLOY_REPO}/${GODEPLOY_REF}"

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
command -v curl >/dev/null 2>&1 || die "缺少依赖命令: curl"

log "开始安装 ${GODEPLOY_NAME}（来自 ${GODEPLOY_REPO}@${GODEPLOY_REF}）"

# ===== 下载 deploy.sh 并安装为全局命令 =====
mkdir -p "${INSTALL_BIN_DIR}"
TARGET_BIN="${INSTALL_BIN_DIR}/${GODEPLOY_NAME}"
TMP_BIN="${TARGET_BIN}.tmp"
URL="${RAW_BASE}/deploy.sh"

if [[ -f "${TARGET_BIN}" ]]; then
  log "检测到已存在的 ${TARGET_BIN}，将进行覆盖安装。"
fi

log "从 ${URL} 下载 deploy.sh -> ${TMP_BIN}"
curl -fsSL "${URL}" -o "${TMP_BIN}" || die "下载 deploy.sh 失败，请检查仓库/分支是否正确。"

chmod +x "${TMP_BIN}"
mv -f "${TMP_BIN}" "${TARGET_BIN}"

log "已安装命令: ${TARGET_BIN}"

# 尝试显示版本（如果支持 --version）
if "${TARGET_BIN}" --version >/dev/null 2>&1; then
  log "版本信息：$(${TARGET_BIN} --version)"
fi

# ===== 使用说明（简版） =====
cat <<EOF

[godeploy 安装完成]

命令路径:
  ${TARGET_BIN}

常用用法示例（在你的应用部署目录中）：

  # 1. 在当前目录准备本地配置文件 ./godeploy.env，示例内容：
  #      REPO="terobox/workflow"
  #      GITHUB_TOKEN="ghp_xxx..."
  #      APP_NAME="wf-backend"
  #      ASSET_NAME="wf-backend-linux-arm64"
  #      SYSTEMD_UNIT="wf-backend.service"
  #
  # 2. 部署指定版本（对应 GitHub Releases 的 tag）
  cd /srv/app/workflow/backend
  godeploy v0.0.1.3

  # 3. 或显式指定配置文件位置
  godeploy -c /srv/app/workflow/backend/godeploy.env v0.0.1.3

查看帮助：
  godeploy -h

EOF
