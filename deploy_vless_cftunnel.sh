
#!/bin/bash

echo "====== Cloudflare Tunnel + V2Ray 部署开始 ======"

read -rp "请输入你的子域名（如 v2.example.com）: " DOMAIN
read -rp "请输入你想命名的 Tunnel 名称（如 v2ray-tunnel）: " TUNNEL_NAME

# Step 1: 安装 cloudflared
echo "📦 安装 cloudflared..."
wget -O cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb

# Step 2: 登录 Cloudflare 授权
echo "🔑 登录 Cloudflare 账号授权..."
cloudflared tunnel login

# Step 3: 创建 Tunnel
echo "🔧 创建 Tunnel：$TUNNEL_NAME"
cloudflared tunnel create $TUNNEL_NAME

# 获取 Tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
CRED_FILE="/root/.cloudflared/${TUNNEL_ID}.json"

# Step 4: 写入配置文件
echo "📝 生成 config.yml 配置..."
mkdir -p /root/.cloudflared
cat <<EOF > /root/.cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: $CRED_FILE

ingress:
  - hostname: $DOMAIN
    service: http://localhost:8080
  - service: http_status:404
EOF

# Step 5: 绑定子域名 DNS
echo "🌐 配置 DNS 到 Tunnel..."
cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN

# Step 6: 安装 V2Ray 并配置为监听 localhost:8080
echo "🚀 安装并配置 V2Ray..."
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
        "email": "cf@domain.local"
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

# Step 7: 创建并启动 Cloudflared systemd 服务
echo "🛠️ 创建 cloudflared systemd 服务..."
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

# Step 8: 输出连接信息
echo ""
echo "✅ 部署完成！请将以下链接导入客户端使用："
echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&type=ws&host=$DOMAIN&path=%2Ftunnel#CF-VLESS"
