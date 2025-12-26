#!/bin/bash
set -euo pipefail
set -o errtrace

trap 'err "命令执行失败: '\''${BASH_COMMAND}'\'' (退出码 $?)，位于第 ${LINENO} 行"' ERR

if [[ ${DEBUG_TRACE:-0} -eq 1 ]]; then
  set -x
fi

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

CERT_DIR="/etc/ssl/$DEPLOY_DOMAIN"
CERT_PATH="$CERT_DIR/cert.pem"
KEY_PATH="$CERT_DIR/key.pem"

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
  apt install -y curl wget tar socat cron openssl uuid-runtime iptables
}

open_firewall_ports() {
  local ports=("$@")
  log "检测并放行防火墙端口: ${ports[*]}..."

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    for p in "${ports[@]}"; do
      ufw allow "${p}"/tcp || err "UFW 放行端口 ${p} 失败，请手动检查。"
    done
    return
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${p}/tcp" || err "firewalld 放行端口 ${p} 失败，请手动检查。"
    done
    firewall-cmd --reload >/dev/null 2>&1 || true
    return
  fi

  if command -v iptables >/dev/null 2>&1; then
    for p in "${ports[@]}"; do
      if ! iptables -C INPUT -p tcp --dport "${p}" -j ACCEPT >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "${p}" -j ACCEPT || err "iptables 放行端口 ${p} 失败，请手动检查。"
      fi
    done
  else
    log "未检测到常用防火墙（ufw/firewalld/iptables），跳过自动放行。"
  fi
}

install_acme() {
  local reload_cmd renew_margin need_issue
  reload_cmd="sh -c 'if systemctl cat ${PROTO}.service >/dev/null 2>&1; then systemctl reload ${PROTO}.service >/dev/null 2>&1 || true; fi'"
  renew_margin=${CERT_RENEW_MARGIN:-2592000} # 默认 30 天

  if [[ ! -d "$HOME/.acme.sh" ]]; then
    log "安装 acme.sh..."
    curl https://get.acme.sh | sh ${CERT_EMAIL:+-s email=$CERT_EMAIL}
  fi
  source "$HOME/.acme.sh/acme.sh.env"
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  mkdir -p "$CERT_DIR"

  need_issue=1
  if [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]]; then
    if openssl x509 -checkend "$renew_margin" -noout -in "$CERT_PATH" >/dev/null 2>&1; then
      log "检测到未过期的证书，跳过重新申请。"
      need_issue=0
    else
      log "证书即将过期或无效，尝试重新申请..."
    fi
  fi

  if [[ $need_issue -eq 1 ]]; then
    log "申请证书..."
    ~/.acme.sh/acme.sh --issue -d "$DEPLOY_DOMAIN" --standalone --force --keylength ec-256
  fi

  log "安装证书，若已存在对应服务则尝试 reload..."
  ~/.acme.sh/acme.sh --install-cert -d "$DEPLOY_DOMAIN" \
    --ecc --fullchain-file "$CERT_DIR/cert.pem" \
    --key-file "$CERT_DIR/key.pem" --reloadcmd "$reload_cmd"
}

install_hysteria2() {
  local version release_json download_url fallback_version fallback_url
  fallback_version="app/v2.6.5"
  fallback_url="https://github.com/apernet/hysteria/releases/download/${fallback_version}/hysteria-linux-${ARCH}"
  release_json=$(curl -fsSL https://api.github.com/repos/apernet/hysteria/releases/latest || true)

  # 解析最新版本与下载地址，若接口不可用则使用回退版本。
  set +o pipefail
  version=$(echo "$release_json" | grep -m1 '"tag_name":' | cut -d '"' -f4 || true)
  version=${version:-$fallback_version}
  download_url=$(echo "$release_json" | grep -o "https://[^\"]*hysteria-linux-${ARCH}\\.tar\\.gz" | head -n1 || true)

  # 新版发布的资产为裸二进制（无 .tar.gz 后缀），若未找到压缩包则尝试匹配裸二进制。
  if [[ -z "$download_url" ]]; then
    download_url=$(echo "$release_json" | grep -o "https://[^\"]*hysteria-linux-${ARCH}\\b" | head -n1 || true)
  fi
  set -o pipefail

  if [[ -z "$download_url" ]]; then
    log "未能解析最新发布地址，回退到固定版本 ${fallback_version}。"
    version="$fallback_version"
    download_url="$fallback_url"
  fi

  log "下载 Hysteria2（版本: ${version}）..."
  TMP_DIR=$(mktemp -d)
  pushd "$TMP_DIR" >/dev/null
  FILE=$(basename "$download_url")
  if ! wget -q -O "$FILE" "$download_url"; then
    err "无法从 ${download_url} 获取二进制包，尝试回退下载..."
    download_url="$fallback_url"
    version="$fallback_version"
    log "回退到固定版本 ${fallback_version} 下载..."
    FILE=$(basename "$download_url")
    if ! wget -q -O "$FILE" "$download_url"; then
      err "回退版本（${fallback_version}）下载失败，请检查网络或发布页面。"
      exit 1
    fi
  fi
  log "已下载来源: ${download_url}"

  if [[ "$FILE" == *.tar.gz ]]; then
    tar -xzf "$FILE"
    install -m 755 hysteria /usr/local/bin/hysteria
  else
    install -m 755 "$FILE" /usr/local/bin/hysteria
  fi
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
open_firewall_ports 80 "$PORT"
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
