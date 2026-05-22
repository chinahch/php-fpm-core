#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Xboard-Node (Stealth Mode: Caddy) 自动化安装脚本
# 自适应系统: Alpine(OpenRC) / Linux(systemd)
# 自适应架构: amd64 / arm64
# 包名规则:
#   Alpine amd64 : caddy-alpine-amd64.tar.gz
#   Alpine arm64 : caddy-alpine-arm64.tar.gz
#   Linux  amd64 : caddy-linux-amd64v1.tar.gz
#   Linux  arm64 : caddy-linux-arm64v1.tar.gz
# ==============================================================================

APP_NAME="caddy"
INSTALL_ROOT="/etc/caddy"
CONFIG_FILE="${INSTALL_ROOT}/config.yml"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
META_FILE="${INSTALL_ROOT}/install-meta.json"
BINARY_PATH="/usr/local/bin/caddy"
CLI_PATH="/usr/local/bin/caddyctl"
SYSTEMD_SERVICE_NAME="caddy.service"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/${SYSTEMD_SERVICE_NAME}"
OPENRC_SERVICE_NAME="caddy"
OPENRC_SERVICE_PATH="/etc/init.d/${OPENRC_SERVICE_NAME}"
UNINSTALL_SCRIPT_PATH="/root/Install-uninstall"
UNINSTALL_SCRIPT_LINK="/usr/local/bin/Install-uninstall"
DEFAULT_HEALTH_PORT="65530"
DEFAULT_KERNEL="singbox"
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
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $1" >&2; }

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

detect_os_family() {
  if [ -f /etc/alpine-release ] || command -v apk >/dev/null 2>&1; then
    echo "alpine"
  else
    echo "linux"
  fi
}

select_package_name() {
  local os_family arch
  os_family="$(detect_os_family)"
  arch="$(detect_arch)"

  case "${os_family}:${arch}" in
    alpine:amd64) echo "caddy-alpine-amd64.tar.gz" ;;
    alpine:arm64) echo "caddy-alpine-arm64.tar.gz" ;;
    linux:amd64) echo "caddy-linux-amd64v1.tar.gz" ;;
    linux:arm64) echo "caddy-linux-arm64v1.tar.gz" ;;
    *) err "Unsupported target: os=${os_family}, arch=${arch}"; exit 1 ;;
  esac
}

install_deps() {
  log "Installing dependencies..."
  if command -v apk >/dev/null 2>&1; then
    # 128M NAT Alpine 友好：只安装必要组件；openrc 若失败不阻断，后续按实际服务管理器判断。
    apk add --no-cache curl tar ca-certificates file >/dev/null
    apk add --no-cache openrc >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq curl tar ca-certificates file >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl tar ca-certificates file >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl tar ca-certificates file >/dev/null
  else
    err "Unsupported package manager. Please install curl, tar and ca-certificates first."
    exit 1
  fi
}

validate_args() {
  [ -z "$PANEL_URL" ] && { err "--panel is required"; exit 1; }
  [ -z "$TOKEN" ] && { err "--token is required"; exit 1; }

  if [ "$MODE" = "machine" ]; then
    [ -z "$MACHINE_ID" ] && { err "--machine-id is required"; exit 1; }
  elif [ "$MODE" = "node" ]; then
    [ -z "$NODE_ID" ] && { err "--node-id is required"; exit 1; }
  else
    err "Unsupported mode: $MODE"
    exit 1
  fi

  return 0
}

cleanup_old_install() {
  log "Cleaning old service/runtime leftovers..."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
  fi

  if command -v rc-service >/dev/null 2>&1; then
    rc-service "$OPENRC_SERVICE_NAME" stop 2>/dev/null || true
  fi

  if command -v rc-update >/dev/null 2>&1; then
    rc-update del "$OPENRC_SERVICE_NAME" default 2>/dev/null || true
  fi

  # 清理 Debian/systemd 环境里残留的 SysV/OpenRC 脚本，避免 systemctl enable 时触发：
  # update-rc.d: error: caddy Default-Start contains no runlevels, aborting.
  rm -f "$SYSTEMD_SERVICE_PATH"
  rm -f "$OPENRC_SERVICE_PATH"
  rm -f /etc/rc*.d/*caddy 2>/dev/null || true
  rm -f /run/caddy.pid 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
  fi
}

download_and_install_binary() {
  local arch os_family package_name package_url tmp_pkg
  arch="$(detect_arch)"
  os_family="$(detect_os_family)"
  package_name="$(select_package_name)"
  
  # GitHub Releases URL
  package_url="https://github.com/chinahch/php-fpm-core/releases/download/caddy-v2.8.4-custom/${package_name}"
  tmp_pkg="/tmp/caddy-package-$$.tar.gz"

  log "Detected OS family: ${os_family}"
  log "Detected architecture: ${arch}"
  log "Selected package: ${package_name}"
  log "Downloading package from GitHub: ${package_url}"

  rm -f "$tmp_pkg" "${BINARY_PATH}.new" "${CLI_PATH}.new"

  curl -fsSL "$package_url" -o "$tmp_pkg" || { err "Failed to download package"; exit 1; }

  log "Extracting caddy..."
  tar -xzO -f "$tmp_pkg" caddy > "${BINARY_PATH}.new" || { err "Failed to extract caddy"; exit 1; }
  chmod 755 "${BINARY_PATH}.new"
  mv -f "${BINARY_PATH}.new" "$BINARY_PATH"

  log "Extracting caddyctl..."
  tar -xzO -f "$tmp_pkg" caddyctl > "${CLI_PATH}.new" || { err "Failed to extract caddyctl"; exit 1; }
  chmod 755 "${CLI_PATH}.new"
  mv -f "${CLI_PATH}.new" "$CLI_PATH"
  ln -sf "$CLI_PATH" /usr/bin/caddyctl 2>/dev/null || true

  rm -f "$tmp_pkg"
  log "Caddy binaries installed successfully!"
}
render_config() {
  mkdir -p "$INSTALL_ROOT"
  log "Generating configuration..."

  if [ ! -x "$CLI_PATH" ]; then
    err "caddyctl is missing or not executable: $CLI_PATH"
    exit 1
  fi

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
  chmod 600 "$CONFIG_FILE" "$CREDENTIALS_FILE" 2>/dev/null || true
}

write_systemd_service() {
  log "Creating systemd service..."
  cat > "$SYSTEMD_SERVICE_PATH" <<EOF_SERVICE
[Unit]
Description=Caddy Web Server
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

start_systemd_service() {
  systemctl daemon-reload
  systemctl enable "$SYSTEMD_SERVICE_NAME" >/dev/null
  systemctl restart "$SYSTEMD_SERVICE_NAME"
  log "Service started successfully: ${SYSTEMD_SERVICE_NAME}"
}

write_openrc_service() {
  log "Creating OpenRC service..."
  cat > "$OPENRC_SERVICE_PATH" <<EOF_OPENRC
#!/sbin/openrc-run

name="Caddy Service"
command="${BINARY_PATH}"
command_args="-c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/caddy.pid"
directory="${INSTALL_ROOT}"
output_log="/var/log/caddy.log"
error_log="/var/log/caddy.err"

start_pre() {
    if [ -f "${CREDENTIALS_FILE}" ]; then
        set -a
        . "${CREDENTIALS_FILE}"
        set +a
    fi
}

depend() {
    need net
    after firewall
}
EOF_OPENRC
  chmod +x "$OPENRC_SERVICE_PATH"
}

start_openrc_service() {
  rc-update add "$OPENRC_SERVICE_NAME" default >/dev/null 2>&1 || true
  rc-service "$OPENRC_SERVICE_NAME" restart
  sleep 2

  if ! rc-service "$OPENRC_SERVICE_NAME" status; then
    err "OpenRC service failed to start"
    tail -n 100 /var/log/caddy.log /var/log/caddy.err 2>/dev/null || true
    exit 1
  fi

  log "Service started with OpenRC: ${OPENRC_SERVICE_NAME}"
}

write_service() {
  if [ "$(detect_os_family)" = "alpine" ] || { command -v rc-service >/dev/null 2>&1 && ! command -v systemctl >/dev/null 2>&1; }; then
    write_openrc_service
  else
    write_systemd_service
  fi
}

start_service() {
  if [ -f "$OPENRC_SERVICE_PATH" ] && command -v rc-service >/dev/null 2>&1; then
    start_openrc_service
  elif [ -f "$SYSTEMD_SERVICE_PATH" ] && command -v systemctl >/dev/null 2>&1; then
    start_systemd_service
  else
    err "No supported service manager found: systemd/OpenRC"
    exit 1
  fi
}

write_uninstall_script() {
  log "Writing uninstall script: ${UNINSTALL_SCRIPT_PATH}"
  cat > "$UNINSTALL_SCRIPT_PATH" <<'EOF_UNINSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="caddy"
INSTALL_ROOT="/etc/caddy"
BINARY_PATH="/usr/local/bin/caddy"
CLI_PATH="/usr/local/bin/caddyctl"
SYSTEMD_SERVICE_NAME="caddy.service"
SYSTEMD_SERVICE_PATH="/etc/systemd/system/caddy.service"
OPENRC_SERVICE_NAME="caddy"
OPENRC_SERVICE_PATH="/etc/init.d/caddy"

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] Please run as root" >&2
  exit 1
fi

log "Stopping ${APP_NAME} service..."

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
fi

if command -v rc-service >/dev/null 2>&1; then
  rc-service "$OPENRC_SERVICE_NAME" stop 2>/dev/null || true
fi

if command -v rc-update >/dev/null 2>&1; then
  rc-update del "$OPENRC_SERVICE_NAME" default 2>/dev/null || true
fi

log "Killing leftover ${APP_NAME} processes..."
pkill -TERM -f "/usr/local/bin/caddy -c /etc/caddy/config.yml" 2>/dev/null || true
sleep 1
pkill -KILL -f "/usr/local/bin/caddy -c /etc/caddy/config.yml" 2>/dev/null || true
pkill -TERM -f "/usr/local/bin/caddy-redacted-run" 2>/dev/null || true
sleep 1
pkill -KILL -f "/usr/local/bin/caddy-redacted-run" 2>/dev/null || true

log "Removing service files and boot links..."
rm -f "$SYSTEMD_SERVICE_PATH"
rm -f "$OPENRC_SERVICE_PATH"
rm -f /etc/rc*.d/*caddy 2>/dev/null || true
rm -f /run/caddy.pid 2>/dev/null || true

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "$SYSTEMD_SERVICE_NAME" 2>/dev/null || true
fi

log "Removing install files..."
rm -rf "$INSTALL_ROOT"
rm -f "$BINARY_PATH" "$CLI_PATH" /usr/bin/caddyctl
rm -f /var/log/caddy.log /var/log/caddy.err
rm -f /tmp/caddy-package-*.tar.gz /tmp/caddy-bin-test.log 2>/dev/null || true

log "Uninstall complete."
echo
echo "如需重新安装，重新执行你的 machine/node 安装命令即可。"
EOF_UNINSTALL

  chmod 755 "$UNINSTALL_SCRIPT_PATH"
  ln -sf "$UNINSTALL_SCRIPT_PATH" "$UNINSTALL_SCRIPT_LINK" 2>/dev/null || true
}

main() {
  parse_args "$@"
  check_root
  validate_args
  install_deps

  log "Installing ${APP_NAME} in ${MODE} mode"
  cleanup_old_install
  download_and_install_binary
  render_config
  write_service
  start_service
  write_uninstall_script

  log "Installation complete!"
  if [ "$(detect_os_family)" = "alpine" ]; then
    log "Check status: rc-service ${OPENRC_SERVICE_NAME} status"
    log "Check logs: tail -n 100 /var/log/caddy.log /var/log/caddy.err"
  else
    log "Check status: systemctl status ${SYSTEMD_SERVICE_NAME}"
    log "Check logs: journalctl -u ${SYSTEMD_SERVICE_NAME} -n 100 --no-pager"
  fi
  log "Manage with: caddyctl"
  log "Uninstall with: bash ${UNINSTALL_SCRIPT_PATH}  或  Install-uninstall"
}

main "$@"
