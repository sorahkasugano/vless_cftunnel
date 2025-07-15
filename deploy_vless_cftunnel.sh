#!/bin/bash

echo "====== Cloudflare Tunnel + V2Ray + 可选 Shadowsocks 一键部署脚本 ======"

# Step 0: 交互式参数输入
read -rp "请输入 VLESS 子域名（如 v2.example.com）: " VLESS_DOMAIN
read -rp "请输入 SS 子域名（如 ss.example.com，留空则跳过部署 SS）: " SS_DOMAIN
read -rp "请输入你想命名的 Tunnel 名称（如 v2ray-tunnel）: " TUNNEL_NAME

# Step 1: 安装 cloudflared
echo "📦 安装 cloudflared..."
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb

# Step 2: 登录 CF
echo "🔑 登录 Cloudflare 账号授权..."
cloudflared tunnel login

# Step 3: 创建 tunnel
echo "🔧 创建 Tunnel：$TUNNEL_NAME"
cloudflared tunnel create $TUNNEL_NAME

TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"
mkdir -p /root/.cloudflared

# Step 4: 安装 V2Ray 并配置
echo "🚀 安装 V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)
UUID=$(cat /proc/sys/kernel/random/uuid)

cat <<EOF > /usr/local/etc/v2ray/config.json
{
  "inbounds": [{
    "port": 8080,
    "listen": "127.0.0.1",
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "level": 0,
        "email": "cf@vless.local"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/tunnel"
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom"
  }]
}
EOF

systemctl enable v2ray --now

# Step 5: 可选安装 Shadowsocks
if [[ -n "$SS_DOMAIN" ]]; then
  echo "📦 安装 Shadowsocks-libev..."
  apt install -y shadowsocks-libev

  echo "📝 配置 Shadowsocks..."
  cat <<EOF > /etc/shadowsocks-libev/config.json
{
    "server": "127.0.0.1",
    "server_port": 8388,
    "password": "ss_password",
    "timeout": 300,
    "method": "aes-128-gcm",
    "no_delay": true
}
EOF

  systemctl enable shadowsocks-libev --now
fi

# Step 6: 写入 cloudflared 配置
echo "📝 写入 cloudflared config.yml 配置..."
cat <<EOF > /root/.cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $VLESS_DOMAIN
    service: http://localhost:8080
EOF

if [[ -n "$SS_DOMAIN" ]]; then
cat <<EOF >> /root/.cloudflared/config.yml
  - hostname: $SS_DOMAIN
    service: socks5://localhost:8388
EOF
fi

cat <<EOF >> /root/.cloudflared/config.yml
  - service: http_status:404
EOF

# Step 7: 配置 DNS
cloudflared tunnel route dns $TUNNEL_NAME $VLESS_DOMAIN
if [[ -n "$SS_DOMAIN" ]]; then
  cloudflared tunnel route dns $TUNNEL_NAME $SS_DOMAIN
fi

# Step 8: 创建并启动 cloudflared systemd 服务
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --config /root/.cloudflared/config.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable cloudflared --now

# Step 9: 输出节点信息
echo -e "\\n✅ 部署完成！请使用以下节点信息：\\n"

echo "🔗 VLESS 节点："
echo "vless://$UUID@$VLESS_DOMAIN:443?encryption=none&security=tls&type=ws&host=$VLESS_DOMAIN&path=%2Ftunnel#CF-VLESS"

if [[ -n "$SS_DOMAIN" ]]; then
  echo -e "\\n🔗 Shadowsocks 节点："
  SS_BASE64=$(echo -n "aes-128-gcm:ss_password@$SS_DOMAIN:443" | base64)
  echo "ss://$SS_BASE64#CF-SS"
fi
