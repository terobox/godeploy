#!/usr/bin/env bash
# godeploy: 从 GitHub Releases 部署指定版本的二进制，并用 systemd 管理。
#
# 功能：
#   - 从 GitHub Releases 拉取指定 tag 的资产（二进制）
#   - 以 releases/ + current/ 目录结构部署
#   - 使用 systemd 重启/启动服务
#
# 配置来源优先级（高 -> 低）：
#   1. 命令行参数
#   2. 配置文件（godeploy.env 等）
#   3. 内置默认值（部分）
#
# 典型目录结构：
#   /srv/app/ha/
#     ├── godeploy.env       # 部署配置（给本命令用）
#     ├── releases/
#     │     ├── ha-agent-v1.0.0
#     │     └── ha-agent-v1.0.1
#     └── current/
#           └── ha-agent     -> ../releases/ha-agent-v1.0.1
#
# 用法示例：
#   godeploy -c ./godeploy.env v1.0.0
#   godeploy -r terobox/ha -n ha-agent -d /srv/app/ha v1.0.1
#
set -euo pipefail
IFS=$'\n\t'

########################################
# 打印帮助
########################################
print_help() {
  cat <<'EOF'
godeploy - GitHub Release 部署工具

Usage:
  godeploy [options] <version>

Options:
  -c, --config FILE        指定配置文件路径（默认 ./godeploy.env）
  -r, --repo REPO          GitHub 仓库，例如 "terobox/ha"
  -t, --token TOKEN        GitHub Token（建议放在配置文件或环境变量中）
  -n, --name APP_NAME      应用名称（也是二进制名），如 "ha-agent"
  --asset-name NAME        Release 资产名称（缺省时 = APP_NAME）
  --unit-name NAME         systemd unit 名称（缺省时 = APP_NAME + ".service"）
  -d, --deploy-root DIR    部署根目录（缺省为当前工作目录）
  -h, --help               显示本帮助并退出

Positional arguments:
  <version>                要部署的 tag，例如 v1.0.0

配置优先级（高 -> 低）：
  CLI 参数 > 配置文件 > 默认值

配置文件示例（godeploy.env）：
  REPO="terobox/ha"
  GITHUB_TOKEN="ghp_xxx..."
  APP_NAME="ha-agent"
  # 可选：
  # ASSET_NAME="ha-agent-linux-amd64"
  # SYSTEMD_UNIT="ha-agent.service"
  # DEPLOY_ROOT="/srv/app/ha"

示例：
  # 1. 只在当前目录写好 godeploy.env
  godeploy v1.0.0

  # 2. 指定配置文件
  godeploy -c /srv/app/ha/godeploy.env v1.0.1

  # 3. 覆盖配置文件中的部分设置
  godeploy -c ./godeploy.env -d /srv/app/ha v1.0.2
EOF
}

########################################
# 预解析 -c / --config 和 -h / --help
########################################
CONFIG_PATH="./godeploy.env"

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
    esac
    i=$((i + 1))
  done
fi

########################################
# 加载配置文件（如果存在）
########################################
if [[ -f "$CONFIG_PATH" ]]; then
  echo "[INFO] Loading config: $CONFIG_PATH"
  # shellcheck disable=SC1090
  set -a
  . "$CONFIG_PATH"
  set +a
else
  echo "[INFO] Config file not found: $CONFIG_PATH (will rely on CLI and env vars)"
fi

########################################
# 解析所有参数
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
      shift 2 ;; # 已提前处理，这里跳过
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
    -h|--help)
      print_help; exit 0 ;;
    -*)
      echo "[ERROR] Unknown option: $1"
      echo "Use -h or --help for usage."
      exit 1 ;;
    *)
      # 第一个非选项参数视为 VERSION
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
# 汇总最终配置（CLI > config > 默认）
########################################
REPO="${REPO_CLI:-${REPO:-}}"
GITHUB_TOKEN="${TOKEN_CLI:-${GITHUB_TOKEN:-}}"
APP_NAME="${APP_NAME_CLI:-${APP_NAME:-}}"
ASSET_NAME="${ASSET_NAME_CLI:-${ASSET_NAME:-${APP_NAME:-}}}"
SYSTEMD_UNIT="${UNIT_NAME_CLI:-${SYSTEMD_UNIT:-}}"
VERSION="${VERSION_CLI:-}"

if [[ -z "${DEPLOY_ROOT_CLI:-}" ]]; then
  DEPLOY_ROOT="${DEPLOY_ROOT:-$(pwd)}"
else
  DEPLOY_ROOT="$DEPLOY_ROOT_CLI"
fi

# 如果 SYSTEMD_UNIT 为空，则默认为 APP_NAME.service
if [[ -z "$SYSTEMD_UNIT" && -n "$APP_NAME" ]]; then
  SYSTEMD_UNIT="${APP_NAME}.service"
fi

########################################
# 参数校验
########################################
if [[ -z "$REPO" ]]; then
  echo "[ERROR] REPO is not set. Use -r/--repo or define REPO in $CONFIG_PATH"
  exit 1
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "[ERROR] GITHUB_TOKEN is not set. Use -t/--token or define GITHUB_TOKEN in $CONFIG_PATH"
  exit 1
fi

if [[ -z "$APP_NAME" ]]; then
  echo "[ERROR] APP_NAME is not set. Use -n/--name or define APP_NAME in $CONFIG_PATH"
  exit 1
fi

if [[ -z "$ASSET_NAME" ]]; then
  echo "[ERROR] ASSET_NAME resolved empty (should not happen)."
  exit 1
fi

if [[ -z "$SYSTEMD_UNIT" ]]; then
  echo "[ERROR] SYSTEMD_UNIT resolved empty (should not happen)."
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "[ERROR] VERSION is not specified. Provide it as positional arg."
  echo "Example: godeploy v1.0.0"
  exit 1
fi

########################################
# 打印最终配置
########################################
echo "===== Effective configuration ====="
echo "[INFO] REPO         : $REPO"
echo "[INFO] APP_NAME     : $APP_NAME"
echo "[INFO] ASSET_NAME   : $ASSET_NAME"
echo "[INFO] SYSTEMD_UNIT : $SYSTEMD_UNIT"
echo "[INFO] VERSION      : $VERSION"
echo "[INFO] DEPLOY_ROOT  : $DEPLOY_ROOT"
echo "==================================="

########################################
# 检查依赖命令
########################################
for cmd in curl jq systemctl file; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command '$cmd' not found. Please install it."
    exit 1
  fi
done

########################################
# 准备目录结构
########################################
RELEASES_DIR="${DEPLOY_ROOT}/releases"
CURRENT_DIR="${DEPLOY_ROOT}/current"

echo "===== Step 1: Preparing directories ====="

if [[ ! -d "$RELEASES_DIR" ]]; then
  echo "[INFO] Creating directory: $RELEASES_DIR"
  mkdir -p "$RELEASES_DIR"
else
  echo "[INFO] Directory exists: $RELEASES_DIR"
fi

if [[ ! -d "$CURRENT_DIR" ]]; then
  echo "[INFO] Creating directory: $CURRENT_DIR"
  mkdir -p "$CURRENT_DIR"
else
  echo "[INFO] Directory exists: $CURRENT_DIR"
fi

########################################
# 下载或复用 Release 资产
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
    echo "        Please ensure the release has an asset with this name."
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
# 更新 current 下的软链（仅二进制）
########################################
echo "===== Step 3: Updating symlink ====="

ln -sfn "$TARGET_FILE" "${CURRENT_DIR}/${APP_NAME}"
echo "[INFO] Symlink updated: ${CURRENT_DIR}/${APP_NAME} -> ${TARGET_FILE}"

########################################
# 重启 systemd 服务
########################################
echo "===== Step 4: Restarting systemd unit ====="

systemctl daemon-reload

# 用 LoadState 判断 unit 是否存在
LOAD_STATE=$(systemctl show -p LoadState --value "${SYSTEMD_UNIT}" 2>/dev/null || echo "not-found")

if [[ "$LOAD_STATE" == "loaded" ]]; then
  if systemctl is-active --quiet "$SYSTEMD_UNIT"; then
    echo "[INFO] Unit '${SYSTEMD_UNIT}' is active. Restarting..."
    if ! systemctl restart "$SYSTEMD_UNIT"; then
      echo "[ERROR] Failed to restart '${SYSTEMD_UNIT}'."
      echo "        Please check logs: journalctl -u ${SYSTEMD_UNIT} -n 50"
      exit 1
    fi
  else
    echo "[INFO] Unit '${SYSTEMD_UNIT}' is not active. Starting..."
    if ! systemctl start "$SYSTEMD_UNIT"; then
      echo "[ERROR] Failed to start '${SYSTEMD_UNIT}'."
      echo "        Please check logs: journalctl -u ${SYSTEMD_UNIT} -n 50"
      exit 1
    fi
  fi

  echo "[INFO] Current status of ${SYSTEMD_UNIT}:"
  systemctl status "$SYSTEMD_UNIT" --no-pager -l | head -n 20 || true
else
  echo "[WARN] systemd unit '${SYSTEMD_UNIT}' not loaded (LoadState=${LOAD_STATE})."
  echo "       Skipping restart. Make sure /etc/systemd/system/${SYSTEMD_UNIT} 存在并已 daemon-reload。"
  # 如果你希望这种情况直接失败，也可以改成：
  # exit 1
fi

echo "[SUCCESS] Deployed ${APP_NAME} version ${VERSION} to ${DEPLOY_ROOT}"
echo "===== godeploy finished ====="