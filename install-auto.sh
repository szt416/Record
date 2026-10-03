#!/bin/sh
set -eu

# VLESS + REALITY one-click installer
# Supported: Alpine Linux (OpenRC), Debian/Ubuntu (systemd)
#
# Interactive:
#   sh install.sh
#
# Non-interactive:
#   sh install.sh PUBLIC_IP PUBLIC_PORT [LOCAL_PORT] [NODE_NAME]
#
# Example:
#   sh install.sh 85.149.220.138 37063 8443 NAT-VLESS

PUBLIC_IP="${1:-}"
PUBLIC_PORT="${2:-}"
LOCAL_PORT="${3:-8443}"
NODE_NAME="${4:-VLESS-Reality}"
SNI="${SNI:-www.microsoft.com}"

die() {
    echo "Error: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行。"

# -----------------------------
# Detect OS / init system
# -----------------------------
OS_ID=""
OS_NAME=""
if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | head -n1 | tr -d '"')"
    OS_NAME="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | head -n1 | tr -d '"')"
fi

case "$OS_ID" in
    alpine)
        PKG_FAMILY="alpine"
        INIT_SYSTEM="openrc"
        ;;
    debian|ubuntu)
        PKG_FAMILY="debian"
        INIT_SYSTEM="systemd"
        ;;
    *)
        die "暂不支持当前系统：${OS_NAME:-${OS_ID:-unknown}}。目前支持 Alpine / Debian / Ubuntu。"
        ;;
esac

# -----------------------------
# Parameters
# -----------------------------
if [ -z "$PUBLIC_IP" ]; then
    printf "请输入公网 IP 或域名: "
    read -r PUBLIC_IP
fi

if [ -z "$PUBLIC_PORT" ]; then
    printf "请输入公网/NAT端口: "
    read -r PUBLIC_PORT
fi

if [ $# -lt 3 ]; then
    printf "请输入 Xray 内部监听端口 [默认 8443]: "
    read -r INPUT_LOCAL
    [ -n "${INPUT_LOCAL:-}" ] && LOCAL_PORT="$INPUT_LOCAL"
fi

if [ $# -lt 4 ]; then
    printf "请输入节点名称 [默认 VLESS-Reality]: "
    read -r INPUT_NAME
    [ -n "${INPUT_NAME:-}" ] && NODE_NAME="$INPUT_NAME"
fi

[ -n "$PUBLIC_IP" ] || die "公网 IP/域名不能为空。"

case "$PUBLIC_PORT" in
    ''|*[!0-9]*) die "公网端口必须是数字。" ;;
esac
case "$LOCAL_PORT" in
    ''|*[!0-9]*) die "内部监听端口必须是数字。" ;;
esac

[ "$PUBLIC_PORT" -ge 1 ] && [ "$PUBLIC_PORT" -le 65535 ] || die "公网端口范围必须为 1-65535。"
[ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ] || die "内部端口范围必须为 1-65535。"

# -----------------------------
# Detect CPU architecture
# -----------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)
        XRAY_ARCH="64"
        ;;
    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;
    armv7l|armv7)
        XRAY_ARCH="arm32-v7a"
        ;;
    *)
        die "暂不支持 CPU 架构：$ARCH"
        ;;
esac

echo
echo "=================================================="
echo "系统：${OS_NAME:-$OS_ID}"
echo "架构：$ARCH"
echo "服务管理：$INIT_SYSTEM"
echo "公网地址：$PUBLIC_IP:$PUBLIC_PORT"
echo "Xray 监听：0.0.0.0:$LOCAL_PORT"
echo "=================================================="
echo

# -----------------------------
# Install dependencies
# -----------------------------
echo "[1/7] 安装依赖..."

if [ "$PKG_FAMILY" = "alpine" ]; then
    apk update
    apk add --no-cache curl unzip ca-certificates openssl iproute2
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl unzip ca-certificates openssl iproute2
fi

# -----------------------------
# Install Xray
# -----------------------------
echo "[2/7] 下载并安装最新版 Xray..."

TMPDIR_XRAY="$(mktemp -d)"
cleanup() {
    rm -rf "$TMPDIR_XRAY"
}
trap cleanup EXIT INT TERM

curl -fL --retry 3 --connect-timeout 15 \
    -o "$TMPDIR_XRAY/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p "$TMPDIR_XRAY/xray"
unzip -oq "$TMPDIR_XRAY/xray.zip" -d "$TMPDIR_XRAY/xray"

install -m 755 "$TMPDIR_XRAY/xray/xray" /usr/local/bin/xray
mkdir -p /usr/local/etc/xray /usr/local/share/xray

[ -f "$TMPDIR_XRAY/xray/geoip.dat" ] && \
    install -m 644 "$TMPDIR_XRAY/xray/geoip.dat" /usr/local/share/xray/geoip.dat

[ -f "$TMPDIR_XRAY/xray/geosite.dat" ] && \
    install -m 644 "$TMPDIR_XRAY/xray/geosite.dat" /usr/local/share/xray/geosite.dat

# -----------------------------
# Generate Reality credentials
# -----------------------------
echo "[3/7] 生成 UUID、Reality 密钥和 Short ID..."

UUID="$(xray uuid)"
KEYS="$(xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^Password (PublicKey):[[:space:]]*//p')"

# Compatibility with Xray versions using "PublicKey:"
if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PublicKey:[[:space:]]*//p')"
fi

SHORT_ID="$(openssl rand -hex 8)"

[ -n "$PRIVATE_KEY" ] || die "Reality PrivateKey 生成失败。"
[ -n "$PUBLIC_KEY" ] || {
    printf '%s\n' "$KEYS"
    die "Reality PublicKey 解析失败。"
}

# Backup old config
if [ -f /usr/local/etc/xray/config.json ]; then
    BACKUP="/usr/local/etc/xray/config.json.bak.$(date +%Y%m%d%H%M%S)"
    cp /usr/local/etc/xray/config.json "$BACKUP"
    echo "已备份原配置：$BACKUP"
fi

# -----------------------------
# Write config
# -----------------------------
echo "[4/7] 写入 Xray 配置..."

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $LOCAL_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": [
            "$SNI"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF

# -----------------------------
# Test config
# -----------------------------
echo "[5/7] 检查配置..."
xray run -test -config /usr/local/etc/xray/config.json

# -----------------------------
# Install service
# -----------------------------
echo "[6/7] 配置 ${INIT_SYSTEM} 服务..."

if [ "$INIT_SYSTEM" = "openrc" ]; then
    cat > /etc/init.d/xray <<'EOF'
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="/usr/local/bin/xray"
command_args="run -config /usr/local/etc/xray/config.json"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray.log"
error_log="/var/log/xray-error.log"

depend() {
    need net
    after firewall
}
EOF

    chmod +x /etc/init.d/xray
    rc-update add xray default >/dev/null 2>&1 || true
    rc-service xray stop >/dev/null 2>&1 || true
    rc-service xray start

else
    cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray >/dev/null
    systemctl restart xray
fi

# -----------------------------
# Verify
# -----------------------------
echo "[7/7] 检查服务和监听端口..."
sleep 2

SERVICE_OK=0

if [ "$INIT_SYSTEM" = "openrc" ]; then
    if rc-service xray status >/dev/null 2>&1; then
        SERVICE_OK=1
    fi
else
    if systemctl is-active --quiet xray; then
        SERVICE_OK=1
    fi
fi

if [ "$SERVICE_OK" -ne 1 ]; then
    echo "警告：Xray 服务未正常运行。"
    if [ "$INIT_SYSTEM" = "openrc" ]; then
        echo "查看状态：rc-service xray status"
        echo "查看日志：tail -n 100 /var/log/xray-error.log"
    else
        echo "查看状态：systemctl status xray --no-pager"
        echo "查看日志：journalctl -u xray -n 100 --no-pager"
    fi
    exit 1
fi

if ss -lntp 2>/dev/null | grep -q ":${LOCAL_PORT}"; then
    echo "Xray 已正常监听 0.0.0.0:${LOCAL_PORT}"
else
    echo "警告：服务正在运行，但没有检测到 ${LOCAL_PORT} 监听。"
fi

LINK="vless://${UUID}@${PUBLIC_IP}:${PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"

echo
echo "=================================================="
echo "          VLESS + Reality 安装完成"
echo "=================================================="
echo "系统：          ${OS_NAME:-$OS_ID}"
echo "公网地址：      $PUBLIC_IP"
echo "公网/NAT端口：  $PUBLIC_PORT"
echo "内部监听端口：  $LOCAL_PORT"
echo "UUID：          $UUID"
echo "PublicKey：     $PUBLIC_KEY"
echo "Short ID：      $SHORT_ID"
echo "SNI：           $SNI"
echo
echo "VLESS 分享链接："
echo "$LINK"
echo "=================================================="
echo
echo "注意：NAT VPS 请确保商家后台已设置："
echo "公网端口 ${PUBLIC_PORT} -> TCP -> 内部端口 ${LOCAL_PORT}"
