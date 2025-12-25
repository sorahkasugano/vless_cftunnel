#!/bin/bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "❌ 请以 root 权限运行此脚本。"
  exit 1
fi

log() { echo -e "[+] $1"; }
err() { echo -e "[!] $1" >&2; }

DEFAULT_PORT=443
read -rp "选择协议 (1: Hysteria2, 2: TUIC) [1]: " proto_choice
TARGET_PROTO=${proto_choice:-1}

read -rp "请输入用于 TLS 的域名 (需已解析到本机): " DEPLOY_DOMAIN
if [[ -z "$DEPLOY_DOMAIN" ]]; then
  err "域名不能为空。"
  exit 1
fi

read -rp "请输入申请证书用的邮箱 (可选，留空则使用 acme 默认): " CERT_EMAIL
read -rp "监听端口 [${DEFAULT_PORT}]: " INPUT_PORT
PORT=${INPUT_PORT:-$DEFAULT_PORT}

random_password() {
  openssl rand -hex 16
}

case "$TARGET_PROTO" in
  1)
    PROTO="hysteria2"
    HYSTERIA_PASSWORD=$(random_password)
    read -rp "Hysteria2 密码 (默认随机生成): " INPUT_HY_PASS
    HYSTERIA_PASSWORD=${INPUT_HY_PASS:-$HYSTERIA_PASSWORD}
    ;;
  2)
    PROTO="tuic"
    TUIC_UUID=$(uuidgen)
    TUIC_PASSWORD=$(random_password)
    read -rp "TUIC 用户 UUID (默认自动生成): " INPUT_UUID
    TUIC_UUID=${INPUT_UUID:-$TUIC_UUID}
    read -rp "TUIC 用户密码 (默认随机生成): " INPUT_TUIC_PASS
    TUIC_PASSWORD=${INPUT_TUIC_PASS:-$TUIC_PASSWORD}
    ;;
  *)
    err "无效选择，输入 1 或 2。"
    exit 1
    ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    ARCH=amd64
    ;;
  aarch64|arm64)
    ARCH=arm64
    ;;
  *)
    err "暂不支持的架构: $ARCH"
    exit 1
    ;;
esac

ensure_deps() {
  log "安装基础依赖..."
  apt update
  apt install -y curl wget tar socat cron openssl uuid-runtime
}

install_acme() {
  if [[ ! -d "$HOME/.acme.sh" ]]; then
    log "安装 acme.sh..."
    curl https://get.acme.sh | sh ${CERT_EMAIL:+-s email=$CERT_EMAIL}
  fi
  source "$HOME/.acme.sh/acme.sh.env"
  log "申请证书..."
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
  ~/.acme.sh/acme.sh --issue -d "$DEPLOY_DOMAIN" --standalone --force --keylength ec-256
  CERT_DIR="/etc/ssl/$DEPLOY_DOMAIN"
  mkdir -p "$CERT_DIR"
  ~/.acme.sh/acme.sh --install-cert -d "$DEPLOY_DOMAIN" \
    --ecc --fullchain-file "$CERT_DIR/cert.pem" \
    --key-file "$CERT_DIR/key.pem" --reloadcmd "systemctl reload ${PROTO}.service || true"
  CERT_PATH="$CERT_DIR/cert.pem"
  KEY_PATH="$CERT_DIR/key.pem"
}

install_hysteria2() {
  local version
  version=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep tag_name | head -1 | cut -d '"' -f4)
  version=${version:-v2.5.2}
  log "下载 Hysteria2 ${version}..."
  TMP_DIR=$(mktemp -d)
  pushd "$TMP_DIR" >/dev/null
  FILE="hysteria-linux-${ARCH}.tar.gz"
  wget -q "https://github.com/apernet/hysteria/releases/download/${version}/${FILE}"
  tar -xzf "$FILE"
  install -m 755 hysteria /usr/local/bin/hysteria
  popd >/dev/null
  rm -rf "$TMP_DIR"

  log "写入配置..."
  mkdir -p /etc/hysteria
  cat <<EOF >/etc/hysteria/config.yaml
listen: :$PORT
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
auth:
  type: password
  password: $HYSTERIA_PASSWORD
masquerade:
  type: http
  listen: 127.0.0.1:80
  rewrite:
    - location: /
      body: |
        <html><body><h1>It works!</h1></body></html>
transport:
  udp:
    hop_interval: 30s
EOF

  cat <<EOF >/etc/systemd/system/hysteria2.service
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable hysteria2 --now
}

install_tuic() {
  local version
  version=$(curl -s https://api.github.com/repos/EAimTY/tuic/releases/latest | grep tag_name | head -1 | cut -d '"' -f4)
  version=${version:-v1.0.0-rc.6}
  log "下载 TUIC ${version}..."
  TMP_DIR=$(mktemp -d)
  pushd "$TMP_DIR" >/dev/null
  FILE="tuic-server-${ARCH}-unknown-linux-gnu"
  wget -q "https://github.com/EAimTY/tuic/releases/download/${version}/${FILE}"
  install -m 755 "$FILE" /usr/local/bin/tuic-server
  popd >/dev/null
  rm -rf "$TMP_DIR"

  log "写入配置..."
  mkdir -p /etc/tuic
  cat <<EOF >/etc/tuic/config.json
{
  "server": "0.0.0.0:${PORT}",
  "users": {
    "${TUIC_UUID}": "${TUIC_PASSWORD}"
  },
  "certificate": "$CERT_PATH",
  "private_key": "$KEY_PATH",
  "congestion_control": "bbr",
  "alpn": ["h3"],
  "log_level": "info"
}
EOF

  cat <<EOF >/etc/systemd/system/tuic.service
[Unit]
Description=TUIC Server
After=network.target

[Service]
ExecStart=/usr/local/bin/tuic-server -c /etc/tuic/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable tuic --now
}

ensure_deps
install_acme

if [[ "$PROTO" == "hysteria2" ]]; then
  install_hysteria2
  echo -e "\n✅ Hysteria2 部署完成！"
  echo "节点信息："
  echo "协议: hysteria2"
  echo "地址: $DEPLOY_DOMAIN:$PORT"
  echo "密码: $HYSTERIA_PASSWORD"
  echo "ALPN: h3"
else
  install_tuic
  echo -e "\n✅ TUIC 部署完成！"
  echo "节点信息："
  echo "协议: tuic"
  echo "地址: $DEPLOY_DOMAIN:$PORT"
  echo "UUID: $TUIC_UUID"
  echo "密码: $TUIC_PASSWORD"
  echo "ALPN: h3"
fi

echo -e "\n证书路径: $CERT_PATH"
echo "私钥路径: $KEY_PATH"
log "如需修改配置，可编辑对应的 /etc/hysteria 或 /etc/tuic 下的配置文件后运行 systemctl reload/ restart。"
