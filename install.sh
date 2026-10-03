#!/bin/sh
set -eu

# VLESS + REALITY one-click installer
# Supports Alpine/OpenRC and Debian/Ubuntu/systemd
# Designed to work with: curl -fsSL URL | sh

SNI="${SNI:-www.microsoft.com}"
LOCAL_PORT="${LOCAL_PORT:-8443}"
NODE_NAME="${NODE_NAME:-VLESS-Reality}"

die() {
    echo "Error: $*" >&2
    exit 1
}

ask() {
    prompt="$1"
    default="${2:-}"
    if [ -r /dev/tty ]; then
        if [ -n "$default" ]; then
            printf "%s [%s]: " "$prompt" "$default" > /dev/tty
        else
            printf "%s: " "$prompt" > /dev/tty
        fi
        IFS= read -r answer < /dev/tty || answer=""
    else
        answer=""
    fi
    if [ -z "$answer" ]; then
        answer="$default"
    fi
    printf '%s' "$answer"
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行。"

# Detect OS
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

# Detect architecture
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    armv7l|armv7) XRAY_ARCH="arm32-v7a" ;;
    *) die "暂不支持 CPU 架构：$ARCH" ;;
esac

echo "检测系统：${OS_NAME:-$OS_ID}"
echo "检测架构：$ARCH"

# curl may not exist yet, so install minimal dependencies first.
if [ "$PKG_FAMILY" = "alpine" ]; then
    apk add --no-cache curl ca-certificates >/dev/null
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y curl ca-certificates >/dev/null
fi

# Auto-detect public IPv4 using multiple providers.
PUBLIC_IP=""
for URL in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip"
do
    IP="$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$URL" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$IP" in
        ''|*[!0-9.]*)
            ;;
        *)
            PUBLIC_IP="$IP"
            break
            ;;
    esac
done

if [ -n "$PUBLIC_IP" ]; then
    echo "检测公网 IPv4：$PUBLIC_IP"
else
    echo "公网 IPv4 自动获取失败。"
    PUBLIC_IP="$(ask "请输入公网 IP 或域名")"
    [ -n "$PUBLIC_IP" ] || die "公网 IP/域名不能为空。"
fi

PUBLIC_PORT="$(ask "请输入公网/NAT端口" "$LOCAL_PORT")"
LOCAL_PORT="$(ask "请输入 Xray 内部监听端口" "$LOCAL_PORT")"
NODE_NAME="$(ask "请输入节点名称" "$NODE_NAME")"

case "$PUBLIC_PORT" in
    ''|*[!0-9]*) die "公网端口必须是数字。" ;;
esac
case "$LOCAL_PORT" in
    ''|*[!0-9]*) die "内部监听端口必须是数字。" ;;
esac
[ "$PUBLIC_PORT" -ge 1 ] && [ "$PUBLIC_PORT" -le 65535 ] || die "公网端口范围必须为 1-65535。"
[ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ] || die "内部端口范围必须为 1-65535。"

echo
echo "=================================================="
echo "公网地址：$PUBLIC_IP:$PUBLIC_PORT"
echo "内部监听：0.0.0.0:$LOCAL_PORT"
echo "节点名称：$NODE_NAME"
echo "=================================================="
echo

echo "[1/7] 安装依赖..."
if [ "$PKG_FAMILY" = "alpine" ]; then
    apk add --no-cache curl unzip ca-certificates openssl iproute2 >/dev/null
else
    apt-get update >/dev/null
    apt-get install -y curl unzip ca-certificates openssl iproute2 >/dev/null
fi

echo "[2/7] 下载并安装最新版 Xray..."
TMPDIR_XRAY="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_XRAY"; }
trap cleanup EXIT INT TERM

curl -fL --retry 3 --connect-timeout 15 \
    -o "$TMPDIR_XRAY/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p "$TMPDIR_XRAY/xray"
unzip -oq "$TMPDIR_XRAY/xray.zip" -d "$TMPDIR_XRAY/xray"
install -m 755 "$TMPDIR_XRAY/xray/xray" /usr/local/bin/xray
mkdir -p /usr/local/etc/xray /usr/local/share/xray

[ -f "$TMPDIR_XRAY/xray/geoip.dat" ] && install -m 644 "$TMPDIR_XRAY/xray/geoip.dat" /usr/local/share/xray/geoip.dat
[ -f "$TMPDIR_XRAY/xray/geosite.dat" ] && install -m 644 "$TMPDIR_XRAY/xray/geosite.dat" /usr/local/share/xray/geosite.dat

echo "[3/7] 生成 UUID、Reality 密钥和 Short ID..."
UUID="$(xray uuid)"
KEYS="$(xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^Password (PublicKey):[[:space:]]*//p')"
[ -n "$PUBLIC_KEY" ] || PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PublicKey:[[:space:]]*//p')"
SHORT_ID="$(openssl rand -hex 8)"

[ -n "$PRIVATE_KEY" ] || die "Reality PrivateKey 生成失败。"
[ -n "$PUBLIC_KEY" ] || die "Reality PublicKey 解析失败。"

if [ -f /usr/local/etc/xray/config.json ]; then
    BACKUP="/usr/local/etc/xray/config.json.bak.$(date +%Y%m%d%H%M%S)"
    cp /usr/local/etc/xray/config.json "$BACKUP"
    echo "已备份原配置：$BACKUP"
fi

echo "[4/7] 写入 Xray 配置..."
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $LOCAL_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

echo "[5/7] 检查 Xray 配置..."
xray run -test -config /usr/local/etc/xray/config.json

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
After=network-online.target
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

echo "[7/7] 检查服务..."
sleep 2

if [ "$INIT_SYSTEM" = "openrc" ]; then
    rc-service xray status >/dev/null 2>&1 || die "Xray 启动失败。请查看 /var/log/xray-error.log"
else
    systemctl is-active --quiet xray || die "Xray 启动失败。请运行 journalctl -u xray -n 100 --no-pager"
fi

if ss -lntp 2>/dev/null | grep -q ":${LOCAL_PORT}"; then
    echo "Xray 已正常监听：0.0.0.0:${LOCAL_PORT}"
else
    echo "警告：Xray 服务已启动，但未检测到 ${LOCAL_PORT} 监听。"
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
