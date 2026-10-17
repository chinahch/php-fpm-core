#!/bin/sh
# Second-stage Caddy audit installer. Run the panel's machine-N.sh first.
# SAFE DEFAULT: untested ARM64 requires explicit approval; check-only never replaces the service.
set -eu

BIN=/usr/local/bin/caddy
CONFIG=/etc/caddy/config.yml
ENVFILE=/etc/caddy/credentials.env
AUDIT_DIR=/var/log/caddy/domain-audit
AUDIT_ZIP=https://raw.githubusercontent.com/chinahch/php-fpm-core/main/caddy-linux-amd64v1-yuming.zip
ARM64_RELEASE=https://github.com/chinahch/php-fpm-core/releases/download/caddy-audit-0a29338/caddy-linux-arm64v1.tar.gz

MODE=install
ENABLE_AUDIT=0
ALLOW_ARM64=0
PACKAGE_URL=
PACKAGE_FILE=
GOMEMLIMIT_SETTING=

usage() {
  cat <<'HELP'
Usage: sh install-caddy-audit.sh [--check-only] [--enable-audit]
          [--package-url HTTPS_URL | --package-file PATH]
          [--experimental-arm64] [--go-memlimit 64MiB]

  --check-only          Download, inspect and execute caddy -v twice; DO NOT replace binaries or restart Caddy.
  --enable-audit        Explicit opt-in: record numeric user IDs + destination domain/IP for seven days.
  --experimental-arm64  Only for controlled testing: previous ARM64 production deployment segfaulted!
  --go-memlimit NMiB    Optional soft Go heap/runtime limit; does not cap RSS or prevent crashes.
Run the XBoard panel's original machine installation command first.
This installer is not a proven production fix for ARM64. Run detached for tests; keep console access.
HELP
}
die(){ echo "ERROR: $*" >&2; exit 1; }
msg(){ echo "[audit-install] $*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
  --check-only) MODE=check; shift;;
  --enable-audit) ENABLE_AUDIT=1; shift;;
  --experimental-arm64) ALLOW_ARM64=1; shift;;
  --go-memlimit)
    [ "$#" -ge 2 ] || die "--go-memlimit requires a value"
    GOMEMLIMIT_SETTING=$2
    case "$GOMEMLIMIT_SETTING" in
      *MiB) case "${GOMEMLIMIT_SETTING%MiB}" in
              ''|*[!0-9]*) die "Use integer MiB, e.g. 64MiB";;
             esac;;
      *) die "Use integer MiB, e.g. 64MiB";;
    esac
    shift 2;;
  --package-url) [ "$#" -ge 2 ] || die "--package-url requires a URL"; PACKAGE_URL=$2; shift 2;;
  --package-file) [ "$#" -ge 2 ] || die "--package-file requires a path"; PACKAGE_FILE=$2; shift 2;;
  -h|--help) usage; exit 0;;
  *) die "Unknown option: $1";;
  esac
done
[ "$(id -u)" -eq 0 ] || die "Run as root"
[ -z "$PACKAGE_URL" ] || [ -z "$PACKAGE_FILE" ] || die "Choose only one package source"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64;;
  aarch64|arm64) ARCH=arm64;;
  *) die "Unsupported architecture $(uname -m)";;
esac

if [ -z "$PACKAGE_URL" ] && [ -z "$PACKAGE_FILE" ]; then
  if [ "$ARCH" = amd64 ]; then PACKAGE_URL=$AUDIT_ZIP
  else PACKAGE_URL=$ARM64_RELEASE
  fi
fi
if [ -n "$PACKAGE_URL" ]; then
  case "$PACKAGE_URL" in https://*) :;; *) die "Only HTTPS package URLs are accepted";; esac
  command -v curl >/dev/null 2>&1 || die "curl is missing"
fi
command -v tar >/dev/null 2>&1 || die "tar is missing"

memory_limit=unknown
if [ -r /sys/fs/cgroup/memory.max ]; then
  memory_limit=$(cat /sys/fs/cgroup/memory.max)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
  memory_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
fi
msg "Architecture=$ARCH mode=$MODE cgroup_memory_max=$memory_limit"
if [ "$ARCH" = arm64 ] && [ "$MODE" = install ] && [ "$ALLOW_ARM64" -ne 1 ]; then
  die "ARM64 build was observed to segfault in production; use --check-only first. For a CONTROLLED test with console access, explicitly pass --experimental-arm64."
fi
if [ "$ARCH" = arm64 ] && [ "$MODE" = install ]; then
  case "$memory_limit" in
    ''|*[!0-9]*) :;;
    *) if [ "$memory_limit" -le 201326592 ]; then
         msg "WARNING: ARM64 container has <=192 MiB cgroup budget; previous 128 MiB installation crashed. This test may interrupt connections."
       fi;;
  esac
fi

if [ "$MODE" = install ]; then
  [ -f "$CONFIG" ] || die "Missing $CONFIG; first run the panel machine installer"
  [ -f "$ENVFILE" ] || die "Missing $ENVFILE; first run the panel machine installer"
  [ -x "$BIN" ] || die "Missing $BIN"
  if command -v systemctl >/dev/null 2>&1 && systemctl cat caddy.service >/dev/null 2>&1; then
    SERVICE=systemd
  elif command -v rc-service >/dev/null 2>&1 && [ -f /etc/init.d/caddy ]; then
    SERVICE=openrc
  else
    die "Existing Caddy systemd/OpenRC service was not found"
  fi
fi

WORK=$(mktemp -d)
BACKUP=
SWAPPED=0
cleanup(){ rm -rf "$WORK"; }
restart_service(){
  if [ "$SERVICE" = systemd ]; then systemctl restart caddy.service
  else rc-service caddy restart; fi
}
service_ok(){
  # OpenRC 'started' may mean only supervise-daemon survived a crashed caddy.
  if [ "$SERVICE" = systemd ]; then
    systemctl is-active --quiet caddy.service || return 1
  else
    rc-service caddy status >/dev/null 2>&1 || return 1
  fi
  command -v pidof >/dev/null 2>&1 || return 1
  pidof caddy >/dev/null 2>&1
}
rollback(){
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$SWAPPED" -eq 1 ] && [ -n "$BACKUP" ]; then
    msg "ROLLBACK: restoring backed-up Caddy and environment ($BACKUP)"
    if install -m 755 "$BACKUP/caddy" "$WORK/caddy.rollback"; then
      mv -f "$WORK/caddy.rollback" "$BIN" || msg "ERROR: could not restore executable"
      if [ -f "$BACKUP/credentials.env" ]; then
        install -m 600 "$BACKUP/credentials.env" "$ENVFILE" || msg "ERROR: could not restore environment"
      fi
      restart_service || msg "WARNING: original service failed to restart; inspect logs"
    else
      msg "ERROR: could not stage rollback executable"
    fi
  fi
  cleanup
  exit "$status"
}
trap 'rollback' EXIT
trap 'exit 1' HUP INT TERM

if [ -n "$PACKAGE_FILE" ]; then
  [ -f "$PACKAGE_FILE" ] || die "File not found: $PACKAGE_FILE"
  cp "$PACKAGE_FILE" "$WORK/package"
else
  msg "Downloading $PACKAGE_URL"
  curl --fail --location --retry 3 --silent --show-error "$PACKAGE_URL" -o "$WORK/package" || die "Download failed"
fi

# ZIP created by GitHub Actions wraps the tar.gz. Direct release is a tar.gz.
magic=$(od -An -tx1 -N2 "$WORK/package" | tr -d ' \n')
if [ "$magic" = 504b ]; then
  command -v unzip >/dev/null 2>&1 || die "ZIP package: install unzip then retry"
  mkdir "$WORK/unpacked"
  unzip -oq "$WORK/package" -d "$WORK/unpacked" || die "Invalid ZIP"
  count=$(find "$WORK/unpacked" -type f -name '*.tar.gz' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || die "ZIP must contain exactly one .tar.gz"
  TARBALL=$(find "$WORK/unpacked" -type f -name '*.tar.gz')
else
  TARBALL=$WORK/package
fi
mkdir "$WORK/files"
tar -xzf "$TARBALL" -C "$WORK/files" || die "Invalid tar.gz"
[ -f "$WORK/files/caddy" ] || die "Package missing caddy executable"
chmod 755 "$WORK/files/caddy"

msg "Smoke-testing architecture binary (-v, twice), no service changes yet"
i=1
while [ "$i" -le 2 ]; do
  v=$("$WORK/files/caddy" -v 2>&1) || die "Caddy -v crashed or failed during check $i: $v"
  case "$v" in *custom-audit-*) :;; *) die "Not an audited Caddy build: $v";; esac
  msg "check $i: $v"
  i=$((i+1))
done
if [ "$MODE" = check ]; then
  msg "Check-only PASSED. This DOES NOT guarantee startup with the machine config."
  exit 0
fi

BACKUP=/root/caddy-audit-backup-$(date +%Y%m%d-%H%M%S)
mkdir -m 700 "$BACKUP"
cp -p "$BIN" "$BACKUP/caddy"
cp -p "$CONFIG" "$BACKUP/config.yml"
cp -p "$ENVFILE" "$BACKUP/credentials.env"
chmod 600 "$BACKUP"/*

if [ "$ENABLE_AUDIT" -eq 1 ] || [ -n "$GOMEMLIMIT_SETTING" ]; then
  sed '/^XBOARD_AUDIT_ENABLED=/d; /^XBOARD_AUDIT_DIR=/d; /^XBOARD_AUDIT_RETENTION_DAYS=/d; /^GOMEMLIMIT=/d' "$ENVFILE" > "$WORK/env"
  if [ "$ENABLE_AUDIT" -eq 1 ]; then
    install -d -m 700 "$AUDIT_DIR"
    printf '\nXBOARD_AUDIT_ENABLED=1\nXBOARD_AUDIT_DIR=%s\nXBOARD_AUDIT_RETENTION_DAYS=7\n' "$AUDIT_DIR" >> "$WORK/env"
  else
    # Preserve existing audit settings when only configuring a Go memory limit.
    grep '^XBOARD_AUDIT_' "$ENVFILE" >> "$WORK/env" || true
  fi
  if [ -n "$GOMEMLIMIT_SETTING" ]; then
    printf 'GOMEMLIMIT=%s\n' "$GOMEMLIMIT_SETTING" >> "$WORK/env"
  else
    grep '^GOMEMLIMIT=' "$ENVFILE" >> "$WORK/env" || true
  fi
  install -m 600 "$WORK/env" "$ENVFILE"
fi

install -m 755 "$WORK/files/caddy" "$WORK/caddy.new"
SWAPPED=1
mv -f "$WORK/caddy.new" "$BIN"

msg "Checking installed binary before service restart"
v=$("$BIN" -v 2>&1) || die "Installed executable failed -v, rolling back: $v"
case "$v" in *custom-audit-*) :;; *) die "Installed executable is not audited, rolling back";; esac

msg "Restarting existing $SERVICE service (live connections may be interrupted)"
restart_service || die "Service restart failed"

# Must see actual caddy process, not just supervise-daemon, for 3 consecutive checks.
msg "Waiting for the real Caddy process to remain alive..."
deadline=0
stable=0
last_pid=
while [ "$deadline" -lt 25 ]; do
  sleep 1
  deadline=$((deadline+1))
  if service_ok; then
    current_pid=$(pidof caddy | awk '{print $1}')
    if [ -n "$current_pid" ] && [ "$current_pid" = "$last_pid" ]; then
      stable=$((stable+1))
    else
      stable=1
    fi
    last_pid=$current_pid
  else
    stable=0
    last_pid=
  fi
  if [ "$stable" -ge 8 ]; then break; fi
done
[ "$stable" -ge 8 ] || die "No stable Caddy process after restart; automatic rollback"

v=$("$BIN" -v 2>&1) || die "Installed executable failed -v after restart; rolling back: $v"
msg "SUCCESS: $v"
msg "Backup saved: $BACKUP"
msg "Check proxy connections, users, panel sync and audit .jsonl files manually."
SWAPPED=0
trap - EXIT HUP INT TERM
cleanup
