#!/bin/bash
# ==============================================================================
# OpenClaw SaaS 自動交付腳本 (Client Demo 91 專用版)
# ------------------------------------------------------------------------------
# 架構：Cloudflare Tunnel -> localhost (No Public Inbound) -> Docker Containers
# 包含：3x OpenClaw 實例 + 1x Admin Panel (18999)
# ==============================================================================

set -e

# ==============================================================================
# 1. 核心參數配置 (已寫入)
# ==============================================================================
# ⚠️ 安全警告：此腳本包含敏感 API Token，請勿上傳至公開 Git 倉庫
CF_TOKEN="94-eDawCI63c8QHGOyE-yMCzPwqKaLx8q6dJWlWN"
CF_ACCOUNT="db410229f4fb3cf11e1dff1a02123815"
CF_ZONE="3d7f7eb135bda0a96b5963d797d6e569"
DOMAIN_BASE="realvco.com"
PREFIX="client-demo-91"

# 允許透過命令列覆蓋 (如果需要的話)
while [[ $# -gt 0 ]]; do
    case $1 in
        --cf-token) CF_TOKEN="$2"; shift 2 ;;
        --cf-account) CF_ACCOUNT="$2"; shift 2 ;;
        --cf-zone) CF_ZONE="$2"; shift 2 ;;
        --domain) DOMAIN_BASE="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "未知參數: $1"; exit 1 ;;
    esac
done

# ==============================================================================
# 2. 全域變數定義
# ==============================================================================
BASE_PATH="/opt/openclaw/${PREFIX}"  # 每個客戶獨立目錄
TUNNEL_NAME="tunnel-${PREFIX}"
SWAP_SIZE="8G"

# 定義端口映射
PORT_1=18111
PORT_2=18222
PORT_3=18333
PORT_ADMIN=18999

# 定義完整域名 (Fully Qualified Domain Names)
URL_1="${PREFIX}-1.${DOMAIN_BASE}"
URL_2="${PREFIX}-2.${DOMAIN_BASE}"
URL_3="${PREFIX}-3.${DOMAIN_BASE}"
URL_ADMIN="${PREFIX}-admin.${DOMAIN_BASE}"

# 顏色輸出
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}[OpenClaw]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ==============================================================================
# 3. 系統環境準備
# ==============================================================================
log "正在準備系統環境 (Swap & Docker)..."

# 檢查 Root
if [ "$(id -u)" -ne 0 ]; then echo "請使用 sudo 運行"; exit 1; fi

# 安裝基本工具
apt-get update -qq
apt-get install -y -qq jq curl ufw openssl

# 設定 Swap
if [ ! -f /swapfile ]; then
    fallocate -l ${SWAP_SIZE} /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 安裝 Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

# 安裝 Cloudflared
if ! command -v cloudflared &> /dev/null; then
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared.deb
    rm cloudflared.deb
fi

# ==============================================================================
# 4. Cloudflare Tunnel 建置 (API 互動)
# ==============================================================================
log "正在與 Cloudflare API 溝通建立 Tunnel..."

# A. 建立 Tunnel
TUNNEL_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/tunnels" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data '{"name":"'"${TUNNEL_NAME}"'","config_src":"local"}')

TUNNEL_ID=$(echo $TUNNEL_RESP | jq -r '.result.id')
TUNNEL_TOKEN=$(echo $TUNNEL_RESP | jq -r '.result.token')

if [[ "$TUNNEL_ID" == "null" || -z "$TUNNEL_ID" ]]; then
    echo "建立 Tunnel 失敗。API 回應: $TUNNEL_RESP"
    echo "請檢查 Token 權限是否包含 Account:Tunnel:Edit"
    exit 1
fi
success "Tunnel 已建立 (ID: ${TUNNEL_ID})"

# B. 建立 DNS CNAME 記錄 (4筆)
create_dns() {
    local RECORD_NAME=$1
    log "設定 DNS: ${RECORD_NAME} -> ${TUNNEL_ID}.cfargotunnel.com"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE}/dns_records" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{
            "type": "CNAME",
            "name": "'"${RECORD_NAME}"'",
            "content": "'"${TUNNEL_ID}.cfargotunnel.com"'",
            "ttl": 1,
            "proxied": true
        }' > /dev/null
}

create_dns "${URL_1}"
create_dns "${URL_2}"
create_dns "${URL_3}"
create_dns "${URL_ADMIN}"  # 確保 Admin DNS 建立

# C. 設定本地 Ingress 路由
log "生成 Cloudflared Ingress 配置..."
mkdir -p /etc/cloudflared

cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/creds.json

ingress:
  # 實例 1
  - hostname: ${URL_1}
    service: http://localhost:${PORT_1}
  # 實例 2
  - hostname: ${URL_2}
    service: http://localhost:${PORT_2}
  # 實例 3
  - hostname: ${URL_3}
    service: http://localhost:${PORT_3}
  # Admin Panel (關鍵設定)
  - hostname: ${URL_ADMIN}
    service: http://localhost:${PORT_ADMIN}
  # 預設攔截
  - service: http_status:404
EOF

# 安裝並啟動 Tunnel 服務
cloudflared service install "${TUNNEL_TOKEN}" || true
systemctl restart cloudflared
success "Cloudflare Tunnel 服務已啟動"

# ==============================================================================
# 5. 應用部署 (Docker Compose)
# ==============================================================================
log "正在部署 OpenClaw 容器..."

mkdir -p ${BASE_PATH}
cd ${BASE_PATH}

# 生成安全 Token
TOKEN_1=$(openssl rand -hex 32)
TOKEN_2=$(openssl rand -hex 32)
TOKEN_3=$(openssl rand -hex 32)
TOKEN_ADMIN=$(openssl rand -hex 16)

# 準備目錄權限
for i in 1 2 3; do
    mkdir -p "${BASE_PATH}/data-${i}/config" "${BASE_PATH}/data-${i}/workspace"
    chown -R 1000:1000 "${BASE_PATH}/data-${i}"
    
    # 寫入設定檔 (強制 Localhost Bind)
    PORT_VAR="PORT_${i}"
    cat > "${BASE_PATH}/data-${i}/config/openclaw.json" <<JSON
{
  "gateway": {
    "mode": "local",
    "port": ${!PORT_VAR},
    "bind": "localhost",
    "auth": { "mode": "token", "token": "TOKEN_PLACEHOLDER", "allowTailscale": false },
    "controlUi": { "enabled": true }
  }
}
JSON
    # 替換 Token (sed 技巧)
    TOKEN_VAR="TOKEN_${i}"
    sed -i "s/TOKEN_PLACEHOLDER/${!TOKEN_VAR}/" "${BASE_PATH}/data-${i}/config/openclaw.json"
done

# 建立 docker-compose.yml
cat > docker-compose.yml <<EOF
services:
  openclaw-1:
    image: ghcr.io/openclaw/openclaw:latest
    restart: unless-stopped
    ports: ["127.0.0.1:${PORT_1}:${PORT_1}"]
    volumes: ["./data-1:/home/node/.openclaw"]
    environment:
      - OPENCLAW_GATEWAY_PORT=${PORT_1}
      - OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json

  openclaw-2:
    image: ghcr.io/openclaw/openclaw:latest
    restart: unless-stopped
    ports: ["127.0.0.1:${PORT_2}:${PORT_2}"]
    volumes: ["./data-2:/home/node/.openclaw"]
    environment:
      - OPENCLAW_GATEWAY_PORT=${PORT_2}
      - OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json

  openclaw-3:
    image: ghcr.io/openclaw/openclaw:latest
    restart: unless-stopped
    ports: ["127.0.0.1:${PORT_3}:${PORT_3}"]
    volumes: ["./data-3:/home/node/.openclaw"]
    environment:
      - OPENCLAW_GATEWAY_PORT=${PORT_3}
      - OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json

  admin-panel:
    image: ghcr.io/kimfull/webvco-aig-mvps-panel--private:latest
    restart: unless-stopped
    ports: ["127.0.0.1:${PORT_ADMIN}:${PORT_ADMIN}"]
    environment:
      - ADMIN_TOKEN=${TOKEN_ADMIN}
      - CONTAINER_PREFIX=openclaw-
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF

docker compose up -d
success "所有容器已啟動"

# ==============================================================================
# 6. 安全防火牆 (UFW)
# ==============================================================================
log "設定防火牆規則..."
ufw allow 22/tcp comment 'SSH'
ufw default deny incoming
ufw default allow outgoing
echo "y" | ufw enable
success "防火牆已鎖定 (僅允許 SSH)"

# ==============================================================================
# 7. 交付摘要報告
# ==============================================================================
cat <<SUMMARY

==============================================================================
 ✅ OpenClaw SaaS 部署完成！
==============================================================================
客戶訂單: ${PREFIX}
主域名:   ${DOMAIN_BASE}
Tunnel ID: ${TUNNEL_ID}
------------------------------------------------------------------------------
[交付給客戶的網址]

實例 1:
👉 https://${URL_1}/?token=${TOKEN_1}

實例 2:
👉 https://${URL_2}/?token=${TOKEN_2}

實例 3:
👉 https://${URL_3}/?token=${TOKEN_3}

------------------------------------------------------------------------------
[管理員後台] (Admin Panel)

網址:
👉 https://${URL_ADMIN}/?token=${TOKEN_ADMIN}

注意: 此面板端口 18999 透過 Tunnel 保護，外部無法直接掃描。
==============================================================================
SUMMARY