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
echo 'PASS: repeat-install preservation, Machine ID checks, partial-install guard, candidate validation'
