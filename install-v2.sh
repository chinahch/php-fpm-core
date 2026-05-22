cat > install-v2.sh <<'EOF'
#!/bin/sh
# 安装脚本 v2，自动从 GitHub Releases 下载自定义 Caddy 包
DEFAULT_KERNEL="s"
RELEASE_TAG="${RELEASE_TAG:-caddy-v2.8.4-custom}"
DOWNLOAD_BASE="${DOWNLOAD_BASE:-https://github.com/chinahch/php-fpm-core/releases/download/${RELEASE_TAG}}"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "[INFO] Detected architecture: $ARCH"
echo "[INFO] Using kernel type: $DEFAULT_KERNEL"
echo "[INFO] Release tag: $RELEASE_TAG"
echo "[INFO] Download base: $DOWNLOAD_BASE"

# 下载 caddy 和 caddyctl
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

CADDY_URL="${DOWNLOAD_BASE}/caddy-linux-${ARCH}.tar.gz"
echo "[INFO] Downloading $CADDY_URL"
curl -fsSL "$CADDY_URL" -o "$TMPDIR/caddy.tar.gz"

echo "[INFO] Extracting..."
tar -xzvf "$TMPDIR/caddy.tar.gz" -C "$TMPDIR"

echo "[INFO] Installing..."
install -m 755 "$TMPDIR/caddy" /usr/local/bin/caddy
install -m 755 "$TMPDIR/caddyctl" /usr/local/bin/caddyctl

echo "[INFO] Installation complete!"
caddy -v
caddyctl version
EOF
