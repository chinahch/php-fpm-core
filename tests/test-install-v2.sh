#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Source functions only; never execute the installer's main.
sed '$d' install-v2.sh > "$tmp/functions.sh"
# shellcheck disable=SC1090
source "$tmp/functions.sh"
INSTALL_ROOT="$tmp/etc-caddy"
CONFIG_FILE="$INSTALL_ROOT/config.yml"
CREDENTIALS_FILE="$INSTALL_ROOT/credentials.env"
META_FILE="$INSTALL_ROOT/install-meta.json"
BINARY_PATH="$tmp/bin/caddy"
CLI_PATH="$tmp/bin/caddyctl"
MODE=machine
MACHINE_ID=19
mkdir -p "$INSTALL_ROOT" "$tmp/bin"
cat > "$BINARY_PATH" <<'EOF'
#!/bin/sh
echo 'xboard-node custom-0a29338-dual-ip-v2'
EOF
chmod +x "$BINARY_PATH"
printf '%s\n' 'instances:' '  - id: demo' '    machine:' '      machine_id: 19' '    kernel:' '      ip_family:' '        singbox: ipv4_only' '        xray: prefer_ipv6' > "$CONFIG_FILE"
printf 'SECRET=unchanged\n' > "$CREDENTIALS_FILE"
cp "$CONFIG_FILE" "$tmp/config-before"
cp "$CREDENTIALS_FILE" "$tmp/credentials-before"
preserve_existing_install
cmp "$CONFIG_FILE" "$tmp/config-before"
cmp "$CREDENTIALS_FILE" "$tmp/credentials-before"
if ( MACHINE_ID=20; preserve_existing_install ) >/dev/null 2>&1; then
  echo 'FAIL: mismatched Machine ID accepted' >&2
  exit 1
fi
rm "$CREDENTIALS_FILE"
if ( preserve_existing_install ) >/dev/null 2>&1; then
  echo 'FAIL: partial installation accepted' >&2
  exit 1
fi
rm -f "$BINARY_PATH" "$CONFIG_FILE"
mkdir -p "$tmp/candidate"
cat > "$tmp/candidate/caddy" <<'EOF'
#!/bin/sh
echo 'xboard-node custom-0a29338-dual-ip-v2'
EOF
cat > "$tmp/candidate/caddyctl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/candidate/"*
tar -czf "$tmp/candidate.tar.gz" -C "$tmp/candidate" caddy caddyctl
CADDY_PACKAGE_URL='file://test'
CADDY_REQUIRED_VERSION='dual-ip-v2'
select_package_name() { echo caddy-alpine-amd64.tar.gz; }
curl() { cp "$tmp/candidate.tar.gz" "$3"; }
# Curl's final argument is -o output; use a realistic mock that handles args.
curl() {
  local last=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then shift; last="$1"; break; fi
    shift
  done
  [ -n "$last" ] && cp "$tmp/candidate.tar.gz" "$last"
}
download_and_install_binary
"$BINARY_PATH" -v | grep -Fq dual-ip-v2
# Invalid package must not overwrite installed working candidate.
printf '%s\n' '#!/bin/sh' 'echo old-invalid' > "$tmp/candidate/caddy"
chmod +x "$tmp/candidate/caddy"
tar -czf "$tmp/candidate.tar.gz" -C "$tmp/candidate" caddy caddyctl
if ( download_and_install_binary ) >/dev/null 2>&1; then
  echo 'FAIL: invalid version accepted' >&2
  exit 1
fi
"$BINARY_PATH" -v | grep -Fq dual-ip-v2

# Existing v1/dev Machine: same panel command upgrades safely without touching YAML/credentials.
cp "$tmp/config-before" "$CONFIG_FILE"
cp "$tmp/credentials-before" "$CREDENTIALS_FILE"
rm -f "$BINARY_PATH" "$CLI_PATH"
mkdir -p "$tmp/service"
SYSTEMD_SERVICE_PATH="$tmp/service/caddy.service"
printf '[Service]\nExecStart=/fake/caddy\n' > "$SYSTEMD_SERVICE_PATH"
cat > "$BINARY_PATH" <<'EOF'
#!/bin/sh
echo 'xboard-node dev (built unknown)'
EOF
cat > "$CLI_PATH" <<'EOF'
#!/bin/sh
echo 'old cli'
EOF
chmod +x "$BINARY_PATH" "$CLI_PATH"
printf '%s\n' '#!/bin/sh' 'echo "xboard-node custom-0a29338-dual-ip-v2"' > "$tmp/candidate/caddy"
cat > "$tmp/candidate/caddyctl" <<'EOF'
#!/bin/sh
if [ "${MOCK_FAIL_HEALTH:-0}" = 1 ]; then
  echo "machine_id=19 unhealthy"
else
  echo "machine_id=19 active ok"
fi
EOF
chmod +x "$tmp/candidate/"*
tar -czf "$tmp/candidate.tar.gz" -C "$tmp/candidate" caddy caddyctl
cp "$CONFIG_FILE" "$tmp/config-expected"
cp "$CREDENTIALS_FILE" "$tmp/creds-expected"
CADDY_BACKUP_ROOT="$tmp/backups"
CADDY_HEALTH_ATTEMPTS=2
mkdir -p "$CADDY_BACKUP_ROOT"
systemctl() {
  case "$1" in
    is-active) return 0 ;;
    stop|start) return 0 ;;
    *) echo "unexpected systemctl: $*" >&2; return 1 ;;
  esac
}
upgrade_existing_machine
"$BINARY_PATH" -v | grep -Fq dual-ip-v2
cmp "$CONFIG_FILE" "$tmp/config-expected"
cmp "$CREDENTIALS_FILE" "$tmp/creds-expected"
# A newer desired package that never becomes healthy must restore old binaries.
printf '%s\n' '#!/bin/sh' 'echo "xboard-node dev (built unknown)"' > "$BINARY_PATH"
printf '%s\n' '#!/bin/sh' 'echo "old cli"' > "$CLI_PATH"
chmod +x "$BINARY_PATH" "$CLI_PATH"
if ( export MOCK_FAIL_HEALTH=1; upgrade_existing_machine ) >/dev/null 2>&1; then
  echo "FAIL: failed health check did not reject upgrade" >&2
  exit 1
fi
"$BINARY_PATH" -v | grep -Fq 'dev (built unknown)'
cmp "$CONFIG_FILE" "$tmp/config-expected"
cmp "$CREDENTIALS_FILE" "$tmp/creds-expected"

echo 'PASS: repeat-install preservation, Machine ID checks, partial-install guard, candidate validation'
