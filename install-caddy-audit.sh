#!/bin/sh
# Second-stage installer: run the XBoard panel's machine-N.sh first.
# Supports Linux systemd and Alpine OpenRC. Never rewrites machine credentials.
set -eu

BASE="https://raw.githubusercontent.com/chinahch/php-fpm-core/main"
AUDIT_ZIP="$BASE/caddy-linux-amd64v1-yuming.zip"
BIN="/usr/local/bin/caddy"
CONFIG="/etc/caddy/config.yml"
ENVFILE="/etc/caddy/credentials.env"
ENABLE_AUDIT=0
PACKAGE_URL=""
PACKAGE_FILE=""

usage() {
  cat <<'HELP'
Usage: sh install-caddy-audit.sh [--enable-audit] [--package-url HTTPS_URL | --package-file PATH]
Run the XBoard panel-generated machine installation command first.
Default package: verified domain-audit build for linux/amd64, works on glibc Linux and usually Alpine/musl because CGO_ENABLED=0.
For arm64, supply an audited package via --package-file or --package-url. Never uses old non-audit alpine packages.
--enable-audit is an explicit opt-in: records proxy destinations (domain/IP) and XBoard numeric user IDs, keeps logs for 7 days.
This installer does not request or modify machine credentials. The service restarts briefly.
HELP
}
die(){ printf '%s\n' "ERROR: $*" >&2; exit 1; }
msg(){ printf '%s\n' "[audit-install] $*"; }

while [ "$#" -gt 0 ]; do
 case "$1" in
 --enable-audit) ENABLE_AUDIT=1; shift;;
 --package-url) [ "$#" -ge 2 ] || die "--package-url needs a value"; PACKAGE_URL="$2"; shift 2;;
 --package-file) [ "$#" -ge 2 ] || die "--package-file needs a value"; PACKAGE_FILE="$2"; shift 2;;
 -h|--help) usage; exit 0;;
 *) die "Unknown option: $1";;
 esac
done
[ "$(id -u)" -eq 0 ] || die "Run as root"
[ -f "$CONFIG" ] || die "Missing $CONFIG: install via the panel machine script first"
[ -f "$ENVFILE" ] || die "Missing $ENVFILE: install via the panel machine script first"
[ -x "$BIN" ] || die "Missing $BIN"
[ -z "$PACKAGE_URL" ] || [ -z "$PACKAGE_FILE" ] || die "Choose only one package source"
case "$(uname -m)" in
 x86_64|amd64) ARCH=amd64;;
 aarch64|arm64) ARCH=arm64;;
 *) die "Unsupported architecture $(uname -m)";;
esac
if [ -z "$PACKAGE_FILE" ] && [ -z "$PACKAGE_URL" ]; then
 [ "$ARCH" = amd64 ] || die "No published arm64 audited URL; supply a verified --package-file or --package-url (GitHub Actions arm64 artifact)."
 PACKAGE_URL="$AUDIT_ZIP"
fi
if [ -n "$PACKAGE_URL" ]; then
 case "$PACKAGE_URL" in https://*) :;; *) die "Package URL must use https";; esac
fi
if command -v systemctl >/dev/null 2>&1 && systemctl cat caddy.service >/dev/null 2>&1; then
 SERVICE=systemd
elif command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/caddy ]; then
 SERVICE=openrc
else
 die "Cannot locate existing caddy.service (systemd) or /etc/init.d/caddy (OpenRC)"
fi
command -v tar >/dev/null 2>&1 || die "Missing tar"
command -v mktemp >/dev/null 2>&1 || die "Missing mktemp"
if [ -n "$PACKAGE_URL" ]; then command -v curl >/dev/null 2>&1 || die "Missing curl"; fi
if [ -n "$PACKAGE_URL" ] && ! command -v unzip >/dev/null 2>&1; then
 if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
  apk add --no-cache unzip >/dev/null
 else
  die "Install unzip first"
 fi
fi

WORK=$(mktemp -d)
BACKUP=""
SWAPPED=0
cleanup(){ rm -rf "$WORK"; }
restart_service(){
 if [ "$SERVICE" = systemd ]; then systemctl restart caddy.service
 else rc-service caddy restart
 fi
}
service_ok(){
 if [ "$SERVICE" = systemd ]; then systemctl is-active --quiet caddy.service
 else rc-service caddy status >/dev/null 2>&1
 fi
}
rollback(){
 code=$?
 trap - EXIT HUP INT TERM
 if [ "$SWAPPED" -eq 1 ]; then
   msg "Installation interrupted/failed; restoring prior Caddy from $BACKUP"
   if install -m 755 "$BACKUP/caddy" "$WORK/caddy.rollback"; then
     mv -f "$WORK/caddy.rollback" "$BIN" || true
     restart_service || msg "WARNING: rollback service restart failed"
   fi
 fi
 cleanup
 exit "$code"
}
trap 'rollback' EXIT
trap 'exit 1' HUP INT TERM

if [ -n "$PACKAGE_FILE" ]; then
 [ -f "$PACKAGE_FILE" ] || die "Package file not found: $PACKAGE_FILE"
 cp "$PACKAGE_FILE" "$WORK/package"
else
 msg "Downloading audited package: $PACKAGE_URL"
 curl --fail --location --retry 3 --silent --show-error "$PACKAGE_URL" -o "$WORK/package" || die "Download failed"
fi
# Accept GitHub Actions zip containing a .tar.gz, or a direct .tar.gz.
if [ "$(od -An -tx1 -N2 "$WORK/package" | tr -d ' \n')" = "504b" ]; then
 command -v unzip >/dev/null 2>&1 || die "ZIP requires unzip"
 unzip -oq "$WORK/package" -d "$WORK/unpacked" || die "Bad ZIP"
 COUNT=$(find "$WORK/unpacked" -type f -name '*.tar.gz' | wc -l | tr -d ' ')
 [ "$COUNT" -eq 1 ] || die "ZIP should contain exactly one .tar.gz"
 TARBALL=$(find "$WORK/unpacked" -type f -name '*.tar.gz')
else
 TARBALL="$WORK/package"
fi
mkdir -p "$WORK/files"
tar -xzf "$TARBALL" -C "$WORK/files" || die "Invalid tarball"
[ -f "$WORK/files/caddy" ] || die "Package must contain caddy"
chmod 755 "$WORK/files/caddy"
VERSION=$("$WORK/files/caddy" -v 2>&1) || die "Audit executable cannot run on this system"
case "$VERSION" in *custom-audit-*) :;; *) die "Package is NOT a custom-audit build: $VERSION";; esac
msg "Verified binary: $VERSION"
# Preserve existing caddyctl and panel configuration.
BACKUP="/root/caddy-audit-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -m 700 "$BACKUP"
cp -p "$BIN" "$BACKUP/caddy"
cp -p "$CONFIG" "$BACKUP/config.yml"
cp -p "$ENVFILE" "$BACKUP/credentials.env"
chmod 600 "$BACKUP"/*

if [ "$ENABLE_AUDIT" -eq 1 ]; then
 msg "Explicit opt-in selected; saving existing environment file and enabling 7-day audit retention"
 install -d -m 700 /var/log/caddy/domain-audit
 # Only replace three known settings; do not overwrite panel tokens or other variables.
 sed '/^XBOARD_AUDIT_ENABLED=/d; /^XBOARD_AUDIT_DIR=/d; /^XBOARD_AUDIT_RETENTION_DAYS=/d' "$ENVFILE" > "$WORK/env"
 printf '\nXBOARD_AUDIT_ENABLED=1\nXBOARD_AUDIT_DIR=/var/log/caddy/domain-audit\nXBOARD_AUDIT_RETENTION_DAYS=7\n' >> "$WORK/env"
 chmod 600 "$WORK/env"
 cat "$WORK/env" > "$ENVFILE"
 chmod 600 "$ENVFILE"
fi

install -m 755 "$WORK/files/caddy" "$WORK/caddy.new"
SWAPPED=1
mv -f "$WORK/caddy.new" "$BIN"
msg "Restarting Caddy (brief interruption expected)..."
restart_service || die "Service restart failed"
i=0
while [ "$i" -lt 10 ]; do
 sleep 1
 if service_ok; then break; fi
 i=$((i+1))
done
service_ok || die "Service not active"
msg "Service active; current version: $("$BIN" -v)"
msg "Backup: $BACKUP"
msg "Note: verify actual VLESS/proxy connectivity and traffic reporting; a running service does not guarantee node health."
if [ "$ENABLE_AUDIT" -eq 1 ]; then
 msg "Audit enabled for newly routed connections. Query: python3 /root/query_audit.py --user USER_ID --days 1 --show-events"
else
 msg "Audit remains disabled unless already configured in credentials.env. Add --enable-audit with authorized user notice/consent."
fi
SWAPPED=0
trap - EXIT HUP INT TERM
cleanup
