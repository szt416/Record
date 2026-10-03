#!/bin/sh
set -eu

# VLESS + REALITY one-click installer for Alpine Linux / OpenRC
# Interactive:
#   sh install.sh
# Arguments:
#   sh install.sh PUBLIC_IP PUBLIC_PORT [LOCAL_PORT] [NODE_NAME]

PUBLIC_IP="${1:-}"
PUBLIC_PORT="${2:-}"
LOCAL_PORT="${3:-8443}"
NODE_NAME="${4:-VLESS-Reality}"
SNI="${SNI:-www.microsoft.com}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: please run as root."
    exit 1
fi

if [ ! -f /etc/alpine-release ]; then
    echo "Error: this installer currently supports Alpine Linux only."
    exit 1
fi

if [ -z "$PUBLIC_IP" ]; then
    printf "请输入公网 IP: "
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

case "$PUBLIC_PORT" in
    ''|*[!0-9]*) echo "Error: 公网端口必须是数字。"; exit 1 ;;
esac
case "$LOCAL_PORT" in
    ''|*[!0-9]*) echo "Error: 内部端口必须是数字。"; exit 1 ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) XRAY_ARCH="64" ;;
    aarch64|arm64) XRAY_ARCH="arm64-v8a" ;;
    *) echo "Error: 暂不支持架构 $ARCH"; exit 1 ;;
esac

echo "[1/7] 安装依赖..."
apk add --no-cache curl unzip ca-certificates openssl iproute2

echo "[2/7] 下载并安装最新版 Xray..."
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

curl -fL --retry 3 \
    -o "$TMPDIR/xray.zip" \
    "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XRAY_ARCH}.zip"

mkdir -p "$TMPDIR/xray"
unzip -oq "$TMPDIR/xray.zip" -d "$TMPDIR/xray"

install -m 755 "$TMPDIR/xray/xray" /usr/local/bin/xray
mkdir -p /usr/local/etc/xray /usr/local/share/xray

[ -f "$TMPDIR/xray/geoip.dat" ] && \
    install -m 644 "$TMPDIR/xray/geoip.dat" /usr/local/share/xray/geoip.dat
[ -f "$TMPDIR/xray/geosite.dat" ] && \
    install -m 644 "$TMPDIR/xray/geosite.dat" /usr/local/share/xray/geosite.dat

echo "[3/7] 自动生成 UUID、Reality 密钥和 Short ID..."
UUID="$(xray uuid)"
KEYS="$(xray x25519)"
PRIVATE_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PrivateKey:[[:space:]]*//p')"
PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^Password (PublicKey):[[:space:]]*//p')"

# 兼容不同版本的输出名称
if [ -z "$PUBLIC_KEY" ]; then
    PUBLIC_KEY="$(printf '%s\n' "$KEYS" | sed -n 's/^PublicKey:[[:space:]]*//p')"
fi

SHORT_ID="$(openssl rand -hex 8)"

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "Error: Reality 密钥解析失败。"
    printf '%s\n' "$KEYS"
    exit 1
fi

# 已有配置时先备份
if [ -f /usr/local/etc/xray/config.json ]; then
    cp /usr/local/etc/xray/config.json \
       "/usr/local/etc/xray/config.json.bak.$(date +%Y%m%d%H%M%S)"
fi

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

echo "[5/7] 检查配置..."
xray run -test -config /usr/local/etc/xray/config.json

echo "[6/7] 创建 OpenRC 服务..."
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

# 停掉可能存在的旧实例，确保新配置生效
rc-service xray stop >/dev/null 2>&1 || true
rc-service xray start

echo "[7/7] 检查监听端口..."
sleep 1

if ss -lntp 2>/dev/null | grep -q ":${LOCAL_PORT}"; then
    echo "Xray 已正常监听内部端口 ${LOCAL_PORT}。"
else
    echo "警告：暂未检测到 ${LOCAL_PORT} 监听。"
    echo "请执行：rc-service xray status"
    echo "错误日志：tail -n 50 /var/log/xray-error.log"
fi

LINK="vless://${UUID}@${PUBLIC_IP}:${PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NODE_NAME}"

echo
echo "=================================================="
echo "        VLESS + Reality 安装完成"
echo "=================================================="
echo "公网 IP:       $PUBLIC_IP"
echo "公网/NAT端口:  $PUBLIC_PORT"
echo "内部监听端口:  $LOCAL_PORT"
echo "UUID:          $UUID"
echo "PublicKey:     $PUBLIC_KEY"
echo "Short ID:      $SHORT_ID"
echo "SNI:           $SNI"
echo
echo "VLESS 分享链接："
echo "$LINK"
echo "=================================================="
