#!/usr/bin/env bash
# godeploy - GitHub Releases 部署工具
#
# 功能：
#   - 从 GitHub Releases 拉取指定 tag 的二进制资产
#   - 以 releases/ + current/ 目录结构部署
#   - 使用 systemd 重启/启动服务
#
# 版本控制：
#   - GODEPLOY_VERSION 由 Git 仓库 + Tag 管理
#   - 可通过 `godeploy --version` 查看
#
# 作者：你自己（terobox）
# 平台：Ubuntu (systemd)
#
set -euo pipefail
IFS=$'\n\t'

# 当前版本（大版本更新，请同步修改此处）
GODEPLOY_VERSION="0.0.1"

print_help() {
  cat <<EOF
godeploy ${GODEPLOY_VERSION} - GitHub Release 部署工具

Usage:
  godeploy [options] <version>

Options:
  -c, --config FILE       指定部署配置文件（默认为 ./godeploy.env，
                           若不存在则尝试 /etc/godeploy/godeploy.env）
  -r, --repo REPO         GitHub 仓库，例如 "terobox/ha"
  -t, --token TOKEN       GitHub Token（建议写在配置文件或环境变量中）
  -n, --name APP_NAME     应用名称（二进制名），如 "ha-agent"
  --asset-name NAME       Release 资产名称（缺省时 = APP_NAME）
  --unit-name NAME        systemd unit 名称（缺省时 = APP_NAME + ".service"）
  -d, --deploy-root DIR   部署根目录（缺省为当前工作目录）
  -V, --version           显示 godeploy 的版本号并退出
  -h, --help              显示本帮助并退出

Positional arguments:
  <version>               要部署的 tag，例如 v1.0.0

配置优先级（高 -> 低）：
  1. CLI 参数
  2. 配置文件（godeploy.env）
  3. 环境变量 / 默认值

配置文件示例 (godeploy.env)：
  REPO="terobox/ha"
  GITHUB_TOKEN="ghp_xxx..."
  APP_NAME="ha-agent"
  # 可选覆盖：
  # ASSET_NAME="ha-agent-linux-amd64"
  # SYSTEMD_UNIT="ha-agent.service"
  # DEPLOY_ROOT="/srv/app/ha"

典型用法：
  # 1. 项目目录中有 godeploy.env
  godeploy v1.0.0

  # 2. 指定配置文件
  godeploy -c /srv/app/ha/godeploy.env v1.0.1

  # 3. 覆盖部分配置
  godeploy -c ./godeploy.env -d /srv/app/ha v1.0.2

Go 项目的 .env（例如 /srv/app/ha/app.env）：
  由你的 systemd unit 通过 EnvironmentFile 引用，
  godeploy 不再自动软链这个文件，职责更清晰。
EOF
}

print_version() {
  echo "godeploy ${GODEPLOY_VERSION}"
}

########################################
# Step 0: 预解析 --config / --help / --version
########################################

CONFIG_PATH=""
if [[ $# -gt 0 ]]; then
  i=1
  while [[ $i -le $# ]]; do
    arg="${!i}"
    case "$arg" in
      -c|--config)
        j=$((i + 1))
        if [[ $j -le $# ]]; then
          CONFIG_PATH="${!j}"
          i=$((i + 1))
        else
          echo "[ERROR] Missing value for $arg"
          exit 1
        fi
        ;;
      -h|--help)
        print_help
        exit 0
        ;;
      -V|--version)
        print_version
        exit 0
        ;;
    esac
    i=$((i + 1))
  done
fi

########################################
# Step 1: 解析配置文件路径并加载
########################################

if [[ -n "$CONFIG_PATH" ]]; then
  CONFIG_FILE="$CONFIG_PATH"
elif [[ -f "./godeploy.env" ]]; then
  CONFIG_FILE="./godeploy.env"
elif [[ -f "/etc/godeploy/godeploy.env" ]]; then
  CONFIG_FILE="/etc/godeploy/godeploy.env"
else
  CONFIG_FILE=""
fi

if [[ -n "$CONFIG_FILE" ]]; then
  echo "[INFO] Loading config: $CONFIG_FILE"
  # shellcheck disable=SC1090
  set -a
  . "$CONFIG_FILE"
  set +a
else
  echo "[INFO] No config file found (./godeploy.env or /etc/godeploy/godeploy.env)"
  echo "[INFO] Will rely on CLI options and environment variables."
fi

########################################
# Step 2: 正式解析所有 CLI 参数
########################################

REPO_CLI=""
TOKEN_CLI=""
APP_NAME_CLI=""
ASSET_NAME_CLI=""
UNIT_NAME_CLI=""
DEPLOY_ROOT_CLI=""
VERSION_CLI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      shift 2 ;; # 已处理过
    -r|--repo)
      REPO_CLI="$2"; shift 2 ;;
    -t|--token)
      TOKEN_CLI="$2"; shift 2 ;;
    -n|--name)
      APP_NAME_CLI="$2"; shift 2 ;;
    --asset-name)
      ASSET_NAME_CLI="$2"; shift 2 ;;
    --unit-name)
      UNIT_NAME_CLI="$2"; shift 2 ;;
    -d|--deploy-root)
      DEPLOY_ROOT_CLI="$2"; shift 2 ;;
    -V|--version)
      print_version; exit 0 ;;
    -h|--help)
      print_help; exit 0 ;;
    -*)
      echo "[ERROR] Unknown option: $1"
      echo "Use -h or --help for usage."
      exit 1 ;;
    *)
      if [[ -z "$VERSION_CLI" ]]; then
        VERSION_CLI="$1"
      else
        echo "[ERROR] Too many positional arguments: '$1'"
        echo "Use -h or --help for usage."
        exit 1
      fi
      shift ;;
  esac
done

########################################
# Step 3: 汇总最终配置（CLI > config > env > 默认）
########################################

REPO="${REPO_CLI:-${REPO:-}}"
GITHUB_TOKEN="${TOKEN_CLI:-${GITHUB_TOKEN:-}}"
APP_NAME="${APP_NAME_CLI:-${APP_NAME:-}}"
ASSET_NAME="${ASSET_NAME_CLI:-${ASSET_NAME:-${APP_NAME:-}}}"
SYSTEMD_UNIT="${UNIT_NAME_CLI:-${SYSTEMD_UNIT:-}}"
VERSION="${VERSION_CLI:-}"

if [[ -n "${DEPLOY_ROOT_CLI:-}" ]]; then
  DEPLOY_ROOT="$DEPLOY_ROOT_CLI"
else
  DEPLOY_ROOT="${DEPLOY_ROOT:-$(pwd)}"
fi

if [[ -z "$SYSTEMD_UNIT" && -n "$APP_NAME" ]]; then
  SYSTEMD_UNIT="${APP_NAME}.service"
fi

########################################
# Step 4: 参数校验
########################################

if [[ -z "$REPO" ]]; then
  echo "[ERROR] REPO is not set. Use -r/--repo or define REPO in config/env."
  exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "[ERROR] GITHUB_TOKEN is not set. Use -t/--token or define in config/env."
  exit 1
fi

if [[ -z "$APP_NAME" ]]; then
  echo "[ERROR] APP_NAME is not set. Use -n/--name or define APP_NAME in config/env."
  exit 1
fi

if [[ -z "$ASSET_NAME" ]]; then
  echo "[ERROR] ASSET_NAME resolved empty."
  exit 1
fi

if [[ -z "$SYSTEMD_UNIT" ]]; then
  echo "[ERROR] SYSTEMD_UNIT resolved empty."
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "[ERROR] VERSION is not specified. Provide it as positional arg."
  echo "Example: godeploy v1.0.0"
  exit 1
fi

########################################
# Step 5: 打印最终配置
########################################

echo "===== godeploy ${GODEPLOY_VERSION} configuration ====="
echo "[INFO] REPO         : $REPO"
echo "[INFO] APP_NAME     : $APP_NAME"
echo "[INFO] ASSET_NAME   : $ASSET_NAME"
echo "[INFO] SYSTEMD_UNIT : $SYSTEMD_UNIT"
echo "[INFO] VERSION      : $VERSION"
echo "[INFO] DEPLOY_ROOT  : $DEPLOY_ROOT"
echo "======================================================"

########################################
# Step 6: 检查依赖命令
########################################

for cmd in curl jq systemctl file; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command '$cmd' not found. Please install it."
    exit 1
  fi
done

########################################
# Step 7: 准备目录结构
########################################

RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_DIR="${DEPLOY_ROOT}/current"

echo "===== Step 1: Preparing directories ====="

if [[ ! -d "$RELEASES_DIR" ]]; then
  echo "[INFO] Creating directory: $RELEASES_DIR"
  mkdir -p "$RELEASES_DIR"
fi

if [[ ! -d "$CURRENT_DIR" ]]; then
  echo "[INFO] Creating directory: $CURRENT_DIR"
  mkdir -p "$CURRENT_DIR"
fi

########################################
# Step 8: 下载或复用 Release 资产
########################################

echo "===== Step 2: Download and verify binary ====="

TARGET_FILE="${RELEASES_DIR}/${APP_NAME}-${VERSION}"

if [[ -f "$TARGET_FILE" ]]; then
  echo "[INFO] Binary already exists locally: $TARGET_FILE"
else
  echo "[INFO] Querying GitHub API for release asset..."

  RELEASE_API_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION}"
  RELEASE_JSON=$(curl -sSL -H "Authorization: token ${GITHUB_TOKEN}" "$RELEASE_API_URL")

  if [[ -z "$RELEASE_JSON" ]] || [[ "$(echo "$RELEASE_JSON" | jq -r '.message // empty')" == "Not Found" ]]; then
    echo "[ERROR] Could not find release tag '${VERSION}' in repo '${REPO}'"
    exit 1
  fi

  ASSET_ID=$(echo "$RELEASE_JSON" | jq ".assets[] | select(.name==\"${ASSET_NAME}\") | .id" 2>/dev/null || true)

  if [[ -z "$ASSET_ID" || "$ASSET_ID" == "null" ]]; then
    echo "[ERROR] Could not find asset named '${ASSET_NAME}' in release '${VERSION}'"
    exit 1
  fi

  echo "[INFO] Found asset ID: $ASSET_ID"
  echo "[INFO] Downloading asset to: $TARGET_FILE"

  DOWNLOAD_URL="https://api.github.com/repos/${REPO}/releases/assets/${ASSET_ID}"

  curl -sSL \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -o "$TARGET_FILE" \
    "$DOWNLOAD_URL"

  chmod +x "$TARGET_FILE"

  FILE_TYPE=$(file "$TARGET_FILE")
  echo "[INFO] Downloaded file type: $FILE_TYPE"

  if [[ "$FILE_TYPE" != *"executable"* ]]; then
    echo "[ERROR] Downloaded file does not look like an executable!"
    head "$TARGET_FILE" || true
    rm -f "$TARGET_FILE"
    exit 1
  fi
fi

########################################
# Step 9: 更新 current 下的软链（只处理二进制）
########################################

echo "===== Step 3: Updating symlink ====="

ln -sfn "$TARGET_FILE" "${CURRENT_DIR}/${APP_NAME}"
echo "[INFO] Symlink updated: ${CURRENT_DIR}/${APP_NAME} -> ${TARGET_FILE}"

########################################
# Step 10: 重启 systemd 服务
########################################

echo "===== Step 4: Restarting systemd unit ====="

systemctl daemon-reload

# 使用 LoadState 判断 unit 是否存在/已加载，避免 list-unit-files 误判
LOAD_STATE=$(systemctl show -p LoadState --value "${SYSTEMD_UNIT}" 2>/dev/null || echo "not-found")

if [[ "$LOAD_STATE" == "loaded" ]]; then
  if systemctl is-active --quiet "$SYSTEMD_UNIT"; then
    echo "[INFO] Unit '${SYSTEMD_UNIT}' is active. Restarting..."
    systemctl restart "$SYSTEMD_UNIT"
  else
    echo "[INFO] Unit '${SYSTEMD_UNIT}' is not active. Starting..."
    systemctl start "$SYSTEMD_UNIT"
  fi

  echo "[INFO] Current status of ${SYSTEMD_UNIT}:"
  systemctl status "$SYSTEMD_UNIT" --no-pager -l | head -n 20 || true
else
  echo "[ERROR] systemd unit '${SYSTEMD_UNIT}' not loaded (LoadState=${LOAD_STATE})."
  echo "        Please create it under /etc/systemd/system/ 并执行 systemctl daemon-reload。"
  exit 1
fi

echo "[SUCCESS] Deployed ${APP_NAME} version ${VERSION} to ${DEPLOY_ROOT}"
echo "===== godeploy finished ====="