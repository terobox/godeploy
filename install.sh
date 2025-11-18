#!/usr/bin/env bash
# 一行命令安装 godeploy：
#   安装最新版: curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash
#   安装指定版: curl -fsSL https://raw.githubusercontent.com/terobox/godeploy/main/install.sh | sudo bash -s v1.0.0
set -euo pipefail
IFS=$'\n\t'

# ===== 基本配置 =====
GODEPLOY_REPO="${GODEPLOY_REPO:-terobox/godeploy}"
GODEPLOY_NAME="${GODEPLOY_NAME:-godeploy}"
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-/usr/local/bin}"

log()  { echo "[godeploy-install] $*"; }
err()  { echo "[godeploy-install][ERROR] $*" >&2; }
die()  { err "$@"; exit 1; }

# ===== 权限与依赖检查 =====
if [[ "$(id -u)" -ne 0 ]]; then
  err "请使用 root 权限运行（例如在前面加 sudo）。"
  err "示例：curl ... | sudo bash"
  exit 1
fi

for cmd in curl grep sed; do
  command -v "${cmd}" >/dev/null 2>&1 || die "缺少依赖命令: ${cmd}"
done

# ===== 确定要安装的版本 (核心改动) =====
# 从脚本的第一个参数 ($1) 获取版本号。如果未提供，则为空。
TARGET_VERSION="${1:-}"

if [[ -z "${TARGET_VERSION}" ]]; then
  log "未指定版本，正在从 GitHub API 获取最新版本..."
  # 使用 GitHub API 获取最新 release 的 tag name
  # - 通过 grep 找到 "tag_name" 所在行
  # - 通过 sed 提取出 tag name (例如 "v1.0.0")
  # - 通过 head -n 1 确保只取第一个匹配项
  LATEST_TAG=$(curl -s "https://api.github.com/repos/${GODEPLOY_REPO}/releases/latest" | \
               grep '"tag_name":' | \
               sed -E 's/.*"([^"]+)".*/\1/' | \
               head -n 1)

  if [[ -z "${LATEST_TAG}" ]]; then
    die "无法获取最新的 release tag。请检查仓库 '${GODEPLOY_REPO}' 是否有 release 发布。"
  fi
  TARGET_VERSION="${LATEST_TAG}"
  log "检测到最新版本为：${TARGET_VERSION}"
else
  log "准备安装指定版本：${TARGET_VERSION}"
fi

# ===== 下载并安装 =====
GODEPLOY_REF="${TARGET_VERSION}" # 用我们确定的版本号作为 Git ref
RAW_BASE="https://raw.githubusercontent.com/${GODEPLOY_REPO}/${GODEPLOY_REF}"
URL="${RAW_BASE}/deploy.sh"

log "开始安装 ${GODEPLOY_NAME} (version: ${TARGET_VERSION})"
mkdir -p "${INSTALL_BIN_DIR}"
TARGET_BIN="${INSTALL_BIN_DIR}/${GODEPLOY_NAME}"
TMP_BIN="${TARGET_BIN}.tmp"

if [[ -f "${TARGET_BIN}" ]]; then
  log "检测到已存在的 ${TARGET_BIN}，将进行覆盖安装。"
fi

log "从 ${URL} 下载 deploy.sh -> ${TMP_BIN}"
if ! curl -fsSL "${URL}" -o "${TMP_BIN}"; then
  # 下载失败时给出更友好的提示
  err "下载 deploy.sh 失败。"
  err "请检查：1. 版本号 '${TARGET_VERSION}' 是否存在。 2. 网络是否正常。"
  exit 1
fi
# --- 新增：注入版本号 ---
log "Injecting version '${TARGET_VERSION}' into the script..."
sed -i "s/%%GODEPLOY_VERSION%%/${TARGET_VERSION}/g" "${TMP_BIN}"
chmod +x "${TMP_BIN}"
mv -f "${TMP_BIN}" "${TARGET_BIN}"
log "已成功安装 ${GODEPLOY_NAME} 到: ${TARGET_BIN}"

# ===== 使用说明 =====
cat <<EOF

[godeploy 安装完成]

版本: ${TARGET_VERSION}
路径: ${TARGET_BIN}

常用用法示例（在你的应用部署目录中）：

  # 1. 准备本地配置文件 ./godeploy.env
  # 2. 部署指定版本
  cd /srv/app/workflow/backend
  ${GODEPLOY_NAME} v0.0.1.3

查看帮助：
  ${GODEPLOY_NAME} -h

EOF
