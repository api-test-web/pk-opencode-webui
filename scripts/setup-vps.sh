#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sudo sh scripts/setup-vps.sh [opencode_version]

Installs the OpenCode backend, this Web UI, and cloudflared on an Ubuntu/Debian
VPS. It starts them as systemd services and prints a Cloudflare quick-tunnel URL.
The quick-tunnel URL is public and may change when cloudflared restarts.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root, for example: sudo sh scripts/setup-vps.sh" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This setup script currently supports Ubuntu and Debian (apt-get required)." >&2
  exit 1
fi

opencode_version=${1:-1.19.3}
case "$opencode_version" in
  ''|*[!0-9A-Za-z.-]*)
    echo "Invalid OpenCode version: $opencode_version" >&2
    exit 2
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64)
    oc_arch=x64
    tunnel_arch=amd64
    ;;
  aarch64|arm64)
    oc_arch=arm64
    tunnel_arch=arm64
    ;;
  *)
    echo "Unsupported CPU architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

app_dir=/opt/opencode-webui
data_dir=/var/lib/opencode-webui
install -d "$app_dir" "$data_dir/workspace"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git tar

if ! id opencode >/dev/null 2>&1; then
  useradd --system --user-group --create-home --home-dir /var/lib/opencode-webui \
    --shell /usr/sbin/nologin opencode
fi
chown -R opencode:opencode "$data_dir"

if [ ! -x /usr/local/bin/bun ]; then
  curl -fsSL https://bun.sh/install | bash
  install -m 0755 /root/.bun/bin/bun /usr/local/bin/bun
fi

if [ ! -d "$app_dir/.git" ]; then
  git clone --depth 1 https://github.com/api-test-web/pk-opencode-webui.git "$app_dir"
else
  git -C "$app_dir" pull --ff-only
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

curl -fsSL \
  "https://github.com/anomalyco/opencode/releases/download/v${opencode_version}/opencode-linux-${oc_arch}.tar.gz" \
  -o "$tmp_dir/opencode.tar.gz"
mkdir "$tmp_dir/opencode"
tar -xzf "$tmp_dir/opencode.tar.gz" -C "$tmp_dir/opencode"
install -m 0755 "$tmp_dir/opencode/opencode" /usr/local/bin/opencode

curl -fsSL \
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${tunnel_arch}" \
  -o "$tmp_dir/cloudflared"
install -m 0755 "$tmp_dir/cloudflared" /usr/local/bin/cloudflared

cd "$app_dir/app-prefixable"
/usr/local/bin/bun install
/usr/local/bin/bun run build

cat > /etc/systemd/system/opencode-api.service <<EOF
[Unit]
Description=OpenCode API server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=opencode
Group=opencode
WorkingDirectory=$data_dir/workspace
ExecStart=/usr/local/bin/opencode serve --hostname 127.0.0.1 --port 4096 --print-logs
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/opencode-webui.service <<EOF
[Unit]
Description=OpenCode Web UI
After=opencode-api.service
Requires=opencode-api.service

[Service]
Type=simple
User=opencode
Group=opencode
WorkingDirectory=$app_dir
Environment=PORT=3000
Environment=API_URL=http://127.0.0.1:4096
Environment=DIST_DIR=$app_dir/app-prefixable/dist
ExecStart=/usr/local/bin/bun run docker/serve-ui.ts
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/opencode-tunnel.service <<'EOF'
[Unit]
Description=Cloudflare quick tunnel for OpenCode Web UI
After=opencode-webui.service
Requires=opencode-webui.service

[Service]
Type=simple
User=opencode
Group=opencode
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:3000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now opencode-api.service opencode-webui.service opencode-tunnel.service

echo "Waiting for the Cloudflare quick-tunnel URL..." >&2
url=
for _ in $(seq 1 60); do
  url=$(journalctl -u opencode-tunnel.service --no-pager -n 100 \
    | grep -oE 'https://[A-Za-z0-9.-]+\.trycloudflare\.com' \
    | head -1 || true)
  [ -n "$url" ] && break
  sleep 2
done

if [ -z "$url" ]; then
  echo "Tunnel URL did not appear. Check: journalctl -u opencode-tunnel.service -n 100" >&2
  exit 1
fi

printf '%s\n' "$url"
echo "Services installed. Check them with: systemctl status opencode-api opencode-webui opencode-tunnel" >&2
