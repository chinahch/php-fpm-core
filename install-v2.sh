#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="php-fpm"
INSTALL_ROOT="/etc/php-fpm"
CONFIG_FILE="${INSTALL_ROOT}/config.yml"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
META_FILE="${INSTALL_ROOT}/install-meta.json"
BINARY_PATH="/usr/local/bin/php-fpm"
CLI_PATH="/usr/local/bin/xbctl"
SERVICE_NAME="php-fpm.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
DEFAULT_HEALTH_PORT="65530"
DEFAULT_KERNEL="singbox"
# 确保这个基础地址正确
DOWNLOAD_BASE="https://raw.githubusercontent.com/chinahch/php-fpm-core/main"

MODE=""
PANEL_URL=""
TOKEN=""
MACHINE_ID=""
NODE_ID=""
NODE_TYPE=""
KERNEL_TYPE="${DEFAULT_KERNEL}"
HEALTH_PORT="${DEFAULT_HEALTH_PORT}"

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) MODE="$2"; shift 2 ;;
      --panel|-a|--api) PANEL_URL="$2"; shift 2 ;;
      --token|-t) TOKEN="$2"; shift 2 ;;
      --machine-id) MACHINE_ID="$2"; shift 2 ;;
      --node-id|-n) NODE_ID="$2"; shift 2 ;;
      --node-type|-T) NODE_TYPE="$2"; shift 2 ;;
      --kernel|-k) KERNEL_TYPE="$2"; shift 2 ;;
      --health-port) HEALTH_PORT="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$MODE" ]; then
    if [ -n "$MACHINE_ID" ]; then
      MODE="machine"
    else
      MODE="node"
    fi
  fi
}

check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Please run as root"
    exit 1
  fi
}

detect_arch() {
  local machine_arch
  machine_arch="$(uname -m)"
  case "${machine_arch}" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) err "Unsupported architecture: ${machine_arch}"; exit 1 ;;
  esac
}

install_deps() {
  log "Installing dependencies..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar ca-certificates >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar ca-certificates >/dev/null
  fi
}

validate_args() {
  [ -z "$PANEL_URL" ] && { err "--panel is required"; exit 1; }
  [ -z "$TOKEN" ] && { err "--token is required"; exit 1; }

  if [ "$MODE" = "machine" ]; then
    [ -z "$MACHINE_ID" ] && { err "--machine-id is required"; exit 1; }
  elif [ "$MODE" = "node" ]; then
    [ -z "$NODE_ID" ] && { err "--node-id is required"; exit 1; }
  fi
}

download_and_install_binary() {
  local arch tmp package_url
  arch="$(detect_arch)"
  # 使用 TMPDIR 环境变量，如果不存在则使用 /tmp
  local base_tmp="${TMPDIR:-/tmp}"
  tmp="$(mktemp -d "${base_tmp}/php-fpm-XXXXXX")"
  
  package_url="${DOWNLOAD_BASE}/php-fpm-linux-${arch}.tar.gz"

  log "Detected architecture: ${arch}"
  log "Downloading package: ${package_url}"
  
  curl -fsSL "$package_url" -o "${tmp}/package.tar.gz"
  tar -xzvf "${tmp}/package.tar.gz" -C "$tmp" >/dev/null

  install -m 755 "${tmp}/php-fpm" "$BINARY_PATH"
  install -m 755 "${tmp}/xbctl" "$CLI_PATH"
  ln -sf "$CLI_PATH" /usr/bin/xbctl 2>/dev/null || true

  rm -rf "$tmp"
}

render_config() {
  mkdir -p "$INSTALL_ROOT"
  log "Generating configuration..."

  local args=(
    config init
    --mode "$MODE"
    --panel-url "$PANEL_URL"
    --kernel "$KERNEL_TYPE"
    --health-port "$HEALTH_PORT"
    --token "$TOKEN"
    --version latest
    --output "$CONFIG_FILE"
    --credentials-out "$CREDENTIALS_FILE"
    --meta "$META_FILE"
    --install-root "$INSTALL_ROOT"
  )

  if [ "$MODE" = "machine" ]; then
    args+=(--machine-id "$MACHINE_ID")
  else
    args+=(--node-id "$NODE_ID")
    [ -n "$NODE_TYPE" ] && args+=(--node-type "$NODE_TYPE")
  fi

  "$CLI_PATH" "${args[@]}"
  chmod 600 "$CONFIG_FILE" "$CREDENTIALS_FILE"
}

write_service() {
  log "Creating systemd service..."
  cat > "$SERVICE_PATH" <<EOF_SERVICE
[Unit]
Description=PHP-FPM Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_ROOT}
EnvironmentFile=-${CREDENTIALS_FILE}
ExecStart=${BINARY_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

start_service() {
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null
  systemctl restart "$SERVICE_NAME"
  log "Service started."
}

main() {
  parse_args "$@"
  check_root
  validate_args
  install_deps

  log "Installing ${APP_NAME} in ${MODE} mode"
  download_and_install_binary
  render_config
  write_service
  start_service

  log "Installation complete!"
}

main "$@"
