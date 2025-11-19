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
# 作者：terobox
# 平台：Ubuntu (systemd)
#
set -euo pipefail
IFS=$'\n\t'

# 当前版本（大版本更新，请同步修改此处）
# GODEPLOY_VERSION="0.0.1"

# 版本号 (由 install.sh 在安装时自动注入)
GODEPLOY_VERSION="%%GODEPLOY_VERSION%%"

print_help() {
  cat <<EOF
godeploy ${GODEPLOY_VERSION} - GitHub Release 部署工具

Usage:
  godeploy [options] [<version>]
  godeploy init [env|service]

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
  # 0. 在当前目录初始化默认模板（同时生成 godeploy.env 和 godeploy.service）
  godeploy init

  # 0.1 只生成 env 模板
  godeploy init env

  # 0.2 只生成 service 模板
  godeploy init service

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
# Step 0: 预解析特殊命令 (init) 和早期选项 (--config / --help / --version)
########################################

# 新增：处理 init 命令（支持：init / init env / init service）
if [[ "${1:-}" == "init" ]]; then
  INIT_TARGET="${2:-all}"   # env | service | all(默认)

  case "$INIT_TARGET" in
    env|service|all)
      ;;
    *)
      echo "[ERROR] Unknown init target: '$INIT_TARGET'"
      echo "Usage: godeploy init [env|service]"
      exit 1
      ;;
  esac

  # 如果是默认 all，需要保证没有“脏文件”（两个都不能存在）
  if [[ "$INIT_TARGET" == "all" ]]; then
    if [[ -f "./godeploy.env" || -f "./godeploy.service" ]]; then
      echo "[ERROR] Detected existing files in current directory:"
      [[ -f "./godeploy.env" ]] && echo "  - ./godeploy.env"
      [[ -f "./godeploy.service" ]] && echo "  - ./godeploy.service"
      echo "[HINT] 请先移动/删除它们，或使用："
      echo "       godeploy init env"
      echo "       godeploy init service"
      exit 1
    fi
  fi

  # 生成 godeploy.env
  if [[ "$INIT_TARGET" == "env" || "$INIT_TARGET" == "all" ]]; then
    if [[ -f "./godeploy.env" ]]; then
      echo "[ERROR] ./godeploy.env already exists in the current directory. Aborting."
      exit 1
    fi
    cat <<'EOF' > ./godeploy.env
# === GitHub 配置 ===
# GitHub 仓库路径 (例如: "owner/repo")
REPO="owner/repo"

# 用于访问 GitHub API 的 Personal Access Token
GITHUB_TOKEN="ghp_xxx_your_token_here"

# === 应用核心配置 ===
# 应用名称, 将作为二进制文件名和 systemd 服务名 (默认)
APP_NAME="my-app"

# 要部署的版本 tag (例如: "v1.0.0")
# 如果留空, 脚本会尝试获取最新的 Release
# 注意: 命令行传入的版本号优先级最高
# VERSION=""

# === 高级/覆盖配置 (可选) ===
# 部署模式:
#   - "binary" (默认): Go 等后端二进制
#   - "static": Node.js / React 构建好的静态前端 (tar.gz)
# DEPLOY_MODE="static"

# 如果 Release 中的资产 (asset) 名称与 APP_NAME 不同, 在此指定
# ASSET_NAME="my-app-linux-amd64"

# 如果 systemd 服务单元 (unit) 名称不是 "APP_NAME.service", 在此指定
# SYSTEMD_UNIT="my-app.service"

# 应用部署的根目录, 默认为执行脚本的当前目录
# DEPLOY_ROOT="/srv/app/my-app"
EOF
    echo "[SUCCESS] Created ./godeploy.env. Please edit it with your configuration."
  fi

  # 生成 godeploy.service
  if [[ "$INIT_TARGET" == "service" || "$INIT_TARGET" == "all" ]]; then
    if [[ -f "./godeploy.service" ]]; then
      echo "[ERROR] ./godeploy.service already exists in the current directory. Aborting."
      exit 1
    fi
    cat <<'EOF' > ./godeploy.service
# godeploy systemd unit template
# 建议修改内容后拷贝到 /etc/systemd/system/my-app.service
# 然后加载一遍配置 sudo systemctl daemon-reload

[Unit]
Description=My App Service
After=network.target
# (可选) 如果你的服务依赖数据库，可以加上
# After=network.target mysql.service postgresql.service

[Service]
User=youruser
Group=youruser
WorkingDirectory=/srv/app/my-app/current
ExecStart=/srv/app/my-app/current/my-app
EnvironmentFile=/srv/app/my-app/.env
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    echo "[SUCCESS] Created ./godeploy.service. Please modify as needed and copy to /etc/systemd/system/."
  fi

  exit 0
fi

# 处理其他选项
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
# 优先级：CLI > 配置文件 > 环境变量 (由 .env source 引入)
VERSION="${VERSION_CLI:-${VERSION:-}}"

# 新增：部署模式（默认 binary，前端静态资源用 static）
DEPLOY_MODE="${DEPLOY_MODE:-binary}"

# 如果是静态前端模式，且没有显式指定 ASSET_NAME，
# 默认使用 "<APP_NAME>-<VERSION>.tar.gz" 作为 Release 资产名称
if [[ "$DEPLOY_MODE" == "static" && -z "$ASSET_NAME_CLI" && "$ASSET_NAME" == "$APP_NAME" ]]; then
  ASSET_NAME="${APP_NAME}-${VERSION}.tar.gz"
fi

if [[ -n "${DEPLOY_ROOT_CLI:-}" ]]; then
  DEPLOY_ROOT="$DEPLOY_ROOT_CLI"
else
  DEPLOY_ROOT="${DEPLOY_ROOT:-$(pwd)}"
fi

# 只有非 static 模式才自动填充 systemd unit
if [[ "$DEPLOY_MODE" != "static" && -z "$SYSTEMD_UNIT" && -n "$APP_NAME" ]]; then
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

# 只有非 static 模式才要求必须有 systemd unit
if [[ "$DEPLOY_MODE" != "static" && -z "$SYSTEMD_UNIT" ]]; then
  echo "[ERROR] SYSTEMD_UNIT resolved empty."
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  echo "[ERROR] VERSION is not set. Provide it as a positional argument"
  echo "        or define VERSION in the config file."
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
echo "[INFO] DEPLOY_MODE  : $DEPLOY_MODE"   # 新增
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

echo "===== Step 2: Download and verify binary/static asset ====="

# 通用基底路径（对 binary 是文件名，对 static 是目录名）
TARGET_BASE="${RELEASES_DIR}/${APP_NAME}-${VERSION}"
TARGET_PATH=""

if [[ "$DEPLOY_MODE" == "static" ]]; then
  # Node.js / React 静态前端: tar.gz 解压到目录
  TARGET_PATH="$TARGET_BASE"          # 解压后的目录
  TARGET_TAR="${TARGET_BASE}.tar.gz"  # 本地缓存的 tar 包

  if [[ -d "$TARGET_PATH" ]]; then
    echo "[INFO] Static release directory already exists: $TARGET_PATH"
  else
    echo "[INFO] Static release directory does not exist. Preparing to download & extract..."

    # 若本地没有 tar.gz，先从 GitHub 下载
    if [[ ! -f "$TARGET_TAR" ]]; then
      echo "[INFO] Querying GitHub API for release asset (static)..."

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
      echo "[INFO] Downloading static asset to: $TARGET_TAR"

      DOWNLOAD_URL="https://api.github.com/repos/${REPO}/releases/assets/${ASSET_ID}"

      curl -sSL \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/octet-stream" \
        -o "$TARGET_TAR" \
        "$DOWNLOAD_URL"
    else
      echo "[INFO] Reusing cached tarball: $TARGET_TAR"
    fi

    echo "[INFO] Extracting tarball to: $TARGET_PATH"
    mkdir -p "$TARGET_PATH"
    # 你的构建是 "tar -zcvf xxx.tar.gz dist"，这里 strip 掉外层 dist 目录
    tar -xzf "$TARGET_TAR" -C "$TARGET_PATH" --strip-components=1
  fi
else
  # 原有 Go 二进制逻辑：保持不变
  TARGET_PATH="$TARGET_BASE"

  if [[ -f "$TARGET_PATH" ]]; then
    echo "[INFO] Binary already exists locally: $TARGET_PATH"
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
    echo "[INFO] Downloading asset to: $TARGET_PATH"

    DOWNLOAD_URL="https://api.github.com/repos/${REPO}/releases/assets/${ASSET_ID}"

    curl -sSL \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/octet-stream" \
      -o "$TARGET_PATH" \
      "$DOWNLOAD_URL"

    chmod +x "$TARGET_PATH"

    FILE_TYPE=$(file "$TARGET_PATH")
    echo "[INFO] Downloaded file type: $FILE_TYPE"

    if [[ "$FILE_TYPE" != *"executable"* ]]; then
      echo "[ERROR] Downloaded file does not look like an executable!"
      head "$TARGET_PATH" || true
      rm -f "$TARGET_PATH"
      exit 1
    fi
  fi
fi

########################################
# Step 9: 更新 current 下的软链（只处理二进制）
########################################

echo "===== Step 3: Updating symlink ====="

ln -sfn "$TARGET_PATH" "${CURRENT_DIR}/${APP_NAME}"
echo "[INFO] Symlink updated: ${CURRENT_DIR}/${APP_NAME} -> ${TARGET_PATH}"

########################################
# Step 10: 重启 systemd 服务
########################################

# static 模式下，不做任何 systemd 操作，直接结束
if [[ "$DEPLOY_MODE" == "static" ]]; then
  echo "===== Step 4: Static mode detected, skipping systemd operations ====="
  echo "[INFO] Static files deployed to ${CURRENT_DIR}/${APP_NAME}"
  echo "[INFO] Please reload/restart Nginx or your web server manually if needed."
  echo "[SUCCESS] Deployed ${APP_NAME} version ${VERSION} to ${DEPLOY_ROOT}"
  echo "===== godeploy finished (static mode) ====="
  exit 0
fi

echo "===== Step 4: Restarting systemd unit ====="

systemctl daemon-reload

# 使用 LoadState 判断 unit 是否存在/已加载，避免 list-unit-files 误判
LOAD_STATE=$(systemctl show -p LoadState --value "${SYSTEMD_UNIT}" 2>/dev/null || echo "not-found")

if [[ "$LOAD_STATE" == "loaded" ]]; then
  # --- 新增行在这里 ---
  echo "[INFO] Ensuring unit '${SYSTEMD_UNIT}' is enabled for boot..."
  systemctl enable "$SYSTEMD_UNIT"
  # --- 新增结束 ---
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

########################################
# Step 5: Post-deployment Information
########################################
echo
echo "===== Service Management Commands ====="
echo "You can now manage your service using:"
echo
echo "# View service status and recent logs:"
echo "sudo systemctl status ${SYSTEMD_UNIT}"
echo
echo "# Follow logs in real-time:"
echo "sudo journalctl -u ${SYSTEMD_UNIT} -f"
echo
echo "# Stop the service:"
echo "sudo systemctl stop ${SYSTEMD_UNIT}"
echo
echo "# Start the service:"
echo "sudo systemctl start ${SYSTEMD_UNIT}"
echo
echo "# Enable the service to start on boot:"
echo "sudo systemctl enable ${SYSTEMD_UNIT}"
echo
echo "======================================="