#!/usr/bin/env bash
# 安装脚本：在 Ubuntu 上安装 godeploy 到 /usr/local/bin
set -euo pipefail
IFS=$'\n\t'

GODEPLOY_VERSION="0.1.0"
TARGET_BIN="/usr/local/bin/godeploy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_BIN="${SCRIPT_DIR}/godeploy"

echo "===== godeploy installer ${GODEPLOY_VERSION} ====="

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run as root. Try:"
  echo "  sudo $0"
  exit 1
fi

if [[ ! -f "$SOURCE_BIN" ]]; then
  echo "[ERROR] godeploy script not found at: $SOURCE_BIN"
  echo "        Please make sure godeploy is in this directory."
  exit 1
fi

echo "[INFO] Installing dependencies (curl, jq, file, systemd)..."
apt-get update -y
apt-get install -y curl jq file systemd

echo "[INFO] Installing godeploy to ${TARGET_BIN}..."
cp "$SOURCE_BIN" "$TARGET_BIN"
chmod +x "$TARGET_BIN"

# 创建全局配置目录（可选）
GLOBAL_CONF_DIR="/etc/godeploy"
if [[ ! -d "$GLOBAL_CONF_DIR" ]]; then
  echo "[INFO] Creating global config directory: $GLOBAL_CONF_DIR"
  mkdir -p "$GLOBAL_CONF_DIR"
fi

# 如果有 godeploy.env.example，则拷贝一份示例
if [[ -f "${SCRIPT_DIR}/godeploy.env.example" && ! -f "${GLOBAL_CONF_DIR}/godeploy.env.example" ]]; then
  echo "[INFO] Installing example config to ${GLOBAL_CONF_DIR}/godeploy.env.example"
  cp "${SCRIPT_DIR}/godeploy.env.example" "${GLOBAL_CONF_DIR}/godeploy.env.example"
fi

echo
echo "[SUCCESS] godeploy ${GODEPLOY_VERSION} has been installed to ${TARGET_BIN}"
echo
echo "Usage examples:"
echo "  # 在应用目录中准备 godeploy.env，然后执行："
echo "  cd /srv/app/ha"
echo "  godeploy v1.0.0"
echo
echo "  # 或指定配置文件："
echo "  godeploy -c /srv/app/ha/godeploy.env v1.0.1"
echo
echo "Check version:"
echo "  godeploy --version"
echo "Show help:"
echo "  godeploy --help"
echo "==============================================="
