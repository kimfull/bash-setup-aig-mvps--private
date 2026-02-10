#!/bin/bash
# ==============================================================================
# OpenClaw 自動安裝腳本
# 目標：在 Ubuntu 24.04 Server 上自動安裝 Docker 並建置三個完全隔離的 OpenClaw 實例
# 
# 參考官方文檔：
# - GitHub: https://github.com/openclaw/openclaw
# - Docs: https://docs.openclaw.ai/
# ==============================================================================

set -e  # 遇到錯誤立即停止

# ==============================================================================
# 命令列參數解析
# ==============================================================================
SKIP_TO_STEP=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --tailscale-key)
            TAILSCALE_AUTHKEY_ARG="$2"
            shift 2
            ;;
        --skip-to-step)
            SKIP_TO_STEP="$2"
            shift 2
            ;;
        *)
            echo "未知參數: $1"
            echo "使用方式: sudo bash ai-agent.sh [--tailscale-key tskey-auth-xxx] [--skip-to-step N]"
            exit 1
            ;;
    esac
done

# ==============================================================================
# 顏色定義與輸出函數
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ==============================================================================
# 全域配置
# ==============================================================================
BASE_PATH="/opt/openclaw"
TIMEZONE="Asia/Taipei"
SWAP_SIZE="8G"
SWAPPINESS=20

# SSH 安全設定
SSH_PORT=22

# 自動偵測 VPS 公開 IP
VPS_IP=$(hostname -I | awk '{print $1}')

# 實例配置 (名稱:端口)
INSTANCES=("openclaw-1:18111" "openclaw-2:18222" "openclaw-3:18333")

# Docker 資源限制
DOCKER_CPUS="3"
DOCKER_CPU_SHARES=1024
DOCKER_MEMORY="4g"
DOCKER_MEMORY_RESERVATION="2048m"
DOCKER_LOG_MAX_SIZE="30m"
DOCKER_LOG_MAX_FILE="10"

# Node.js 記憶體限制 (防止 OOM)
NODE_MAX_OLD_SPACE="1536"

# 儲存生成的 Token (用於摘要報告)
declare -A INSTANCE_TOKENS

# Tailscale 設定 (Auth Key 可透過 --tailscale-key 參數或互動式輸入)
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY_ARG:-}"
TAILSCALE_HOSTNAME=""

# ==============================================================================
# 前置檢查
# ==============================================================================
preflight_checks() {
    log_step "Step 0: 前置檢查"
    
    # 檢查是否以 root 身份運行
    if [ "$(id -u)" -ne 0 ]; then
        log_error "請以 root 身份運行此腳本"
        log_error "使用方式: sudo bash ai-agent.sh"
        exit 1
    fi
    log_success "已確認以 root 身份運行"
}

# ==============================================================================
# Step 1: 建立 Swap
# ==============================================================================
setup_swap() {
    log_step "Step 1: 設定 Swap (${SWAP_SIZE}, swappiness=${SWAPPINESS})"
    
    # 檢查是否已有 swap
    CURRENT_SWAP=$(free -g | grep Swap | awk '{print $2}')
    if [ "$CURRENT_SWAP" -ge 8 ]; then
        log_success "Swap 已存在且大小足夠: ${CURRENT_SWAP}GB"
    else
        # 建立 swap 檔案
        if [ -f /swapfile ]; then
            log_info "移除舊的 swapfile..."
            swapoff /swapfile 2>/dev/null || true
            rm -f /swapfile
        fi
        
        log_info "建立 ${SWAP_SIZE} swap 檔案..."
        fallocate -l ${SWAP_SIZE} /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        
        # 加入 fstab 確保重開機後自動掛載
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        
        log_success "Swap 已建立: ${SWAP_SIZE}"
    fi
    
    # 設定 swappiness
    log_info "設定 swappiness=${SWAPPINESS}..."
    sysctl vm.swappiness=${SWAPPINESS}
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf
    else
        sed -i "s/vm.swappiness=.*/vm.swappiness=${SWAPPINESS}/" /etc/sysctl.conf
    fi
    
    log_success "Swappiness 已設定為 ${SWAPPINESS}"
}

# ==============================================================================
# Step 2: 安裝 Docker
# ==============================================================================
install_docker() {
    log_step "Step 2: 安裝 Docker"
    
    if command -v docker &> /dev/null; then
        log_success "Docker 已安裝，版本: $(docker --version)"
        return 0
    fi
    
    log_info "開始安裝 Docker..."
    
    # 移除舊版本
    log_info "移除舊版本的 Docker（如果有）..."
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y $pkg 2>/dev/null || true
    done
    
    # 更新套件列表
    log_info "更新套件列表..."
    apt-get update
    
    # 安裝必要的依賴
    log_info "安裝必要的依賴..."
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        jq \
        lsb-release
    
    # 添加 Docker 官方 GPG 金鑰
    log_info "添加 Docker 官方 GPG 金鑰..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    
    # 添加 Docker 儲存庫
    log_info "添加 Docker 儲存庫..."
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # 更新套件列表並安裝 Docker
    log_info "安裝 Docker Engine..."
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # 啟動 Docker 服務
    log_info "啟動 Docker 服務..."
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker 安裝完成，版本: $(docker --version)"
}

# ==============================================================================
# Step 3: 安裝 Tailscale
# ==============================================================================
install_tailscale() {
    log_step "Step 3: 安裝 Tailscale"
    
    # 如果已透過 --tailscale-key 參數提供，則跳過互動式輸入
    if [ -n "$TAILSCALE_AUTHKEY" ]; then
        log_success "已透過命令列參數接收 Tailscale Auth Key"
    else
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}請輸入 Tailscale Auth Key${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo "請在 Tailscale 管理後台建立 Auth Key:"
        echo "  👉 https://login.tailscale.com/admin/settings/keys"
        echo ""
        echo "建議設定:"
        echo "  • Reusable: 否 (一次性使用更安全)"
        echo "  • Expiration: 1 hour (足夠完成安裝)"
        echo ""
        
        # 循環直到輸入有效的 Key
        while true; do
            read -p "請輸入 Tailscale Auth Key (tskey-auth-xxx): " TAILSCALE_AUTHKEY
            if [ -n "$TAILSCALE_AUTHKEY" ]; then
                break
            else
                log_error "Auth Key 不能為空，請重新輸入"
            fi
        done
        
        log_success "已接收 Tailscale Auth Key"
    fi
    
    # 確保 jq 已安裝
    if ! command -v jq &> /dev/null; then
        log_info "安裝 jq..."
        apt-get update && apt-get install -y jq
    fi

    # 檢查是否已安裝 Tailscale
    if command -v tailscale &> /dev/null; then
        log_success "Tailscale 已安裝，版本: $(tailscale version | head -1)"
    else
        log_info "安裝 Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        log_success "Tailscale 安裝完成"
    fi
    
    # 檢查是否已連線
    if tailscale status &> /dev/null 2>&1; then
        log_success "Tailscale 已連線"
    else
        log_info "使用 Auth Key 連線 Tailscale..."
        tailscale up --authkey="${TAILSCALE_AUTHKEY}"
        log_success "Tailscale 連線成功"
    fi
    
    # 獲取 Tailscale hostname
    TAILSCALE_HOSTNAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    log_success "Tailscale hostname: ${TAILSCALE_HOSTNAME}"
}

# ==============================================================================
# Step 4: 建立目錄結構
# ==============================================================================
create_directories() {
    log_step "Step 4: 建立目錄結構 (${BASE_PATH})"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        log_info "建立 ${NAME} 目錄結構..."
        mkdir -p "${INSTANCE_PATH}/config"
        mkdir -p "${INSTANCE_PATH}/state"
        mkdir -p "${INSTANCE_PATH}/workspace"
        
        # 設定權限給容器內的 node 使用者 (UID 1000)
        chown -R 1000:1000 "${INSTANCE_PATH}"
        
        log_success "已建立: ${INSTANCE_PATH}/{config,state,workspace}"
    done
    
    log_success "所有目錄結構已建立"
}

# ==============================================================================
# Step 5: 生成 Token 並建立設定檔
# ==============================================================================
generate_configs() {
    log_step "Step 5: 生成 Token 並建立設定檔"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        # 生成 Token
        TOKEN=$(openssl rand -hex 32)
        INSTANCE_TOKENS[$NAME]=$TOKEN
        
        log_info "生成 ${NAME} 的設定檔..."
        
        # 建立 openclaw.json 設定檔 (Tailscale 模式)
        cat > "${INSTANCE_PATH}/config/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${PORT},
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${TOKEN}",
      "allowTailscale": true
    },
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "userTimezone": "${TIMEZONE}"
    }
  }
}
EOF
        
        chmod 600 "${INSTANCE_PATH}/config/openclaw.json"
        
        # 確保 node 使用者擁有設定檔權限
        chown 1000:1000 "${INSTANCE_PATH}/config/openclaw.json"
        
        log_success "已建立: ${INSTANCE_PATH}/config/openclaw.json"
    done
    
    # 生成 docker-compose.yml
    log_info "生成 docker-compose.yml..."
    COMPOSE_FILE="${BASE_PATH}/docker-compose.yml"
    cat > "${COMPOSE_FILE}" <<'COMPOSE_HEADER'
version: "3.8"

services:
COMPOSE_HEADER
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        cat >> "${COMPOSE_FILE}" <<EOF
  ${NAME}:
    image: ghcr.io/openclaw/openclaw:latest
    container_name: ${NAME}
    restart: unless-stopped
    cpus: ${DOCKER_CPUS}
    cpu_shares: ${DOCKER_CPU_SHARES}
    mem_limit: ${DOCKER_MEMORY}
    mem_reservation: ${DOCKER_MEMORY_RESERVATION}
    logging:
      options:
        max-size: ${DOCKER_LOG_MAX_SIZE}
        max-file: "${DOCKER_LOG_MAX_FILE}"
    ports:
      - "127.0.0.1:${PORT}:${PORT}"
    volumes:
      - ${INSTANCE_PATH}:/home/node/.openclaw
    environment:
      - TZ=${TIMEZONE}
      - OPENCLAW_GATEWAY_PORT=${PORT}
      - OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json
      - OPENCLAW_STATE_DIR=/home/node/.openclaw/state
      - NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE}

EOF
    done
    
    log_success "已建立: ${COMPOSE_FILE}"
    log_success "所有設定檔已建立"
}

# ==============================================================================
# Step 6: 設定防火牆 (UFW)
# ==============================================================================
setup_firewall() {
    log_step "Step 6: 設定防火牆 (UFW)"
    
    # 確保 UFW 已安裝
    if ! command -v ufw &> /dev/null; then
        log_info "安裝 UFW..."
        apt-get install -y ufw
    fi
    
    # 允許自訂 SSH 端口 (非預設 22)
    log_info "允許 SSH 端口 ${SSH_PORT}..."
    ufw allow ${SSH_PORT}/tcp comment 'SSH custom port'
    
    # Tailscale 模式：不開放 OpenClaw 端口到公網
    # 所有實例透過 Tailscale Serve 存取
    log_info "Tailscale 模式：不開放 18111/18222/18333 到公網"
    
    # 啟用 UFW
    log_info "啟用 UFW..."
    echo "y" | ufw enable
    
    log_success "防火牆設定完成 (僅開放 SSH)"
    ufw status
}

# ==============================================================================
# Step 7: 拉取並運行 OpenClaw 容器
# ==============================================================================
run_containers() {
    log_step "Step 7: 拉取並運行 OpenClaw 容器"
    
    # 拉取最新映像檔
    log_info "拉取 OpenClaw 最新映像檔..."
    docker pull ghcr.io/openclaw/openclaw:latest
    
    # 使用 docker compose 啟動所有容器
    log_info "使用 docker compose 啟動所有容器..."
    cd ${BASE_PATH}
    docker compose down 2>/dev/null || true
    docker compose up -d
    
    log_success "所有容器已啟動 (docker compose)"
}

# ==============================================================================
# Step 8: 健康檢查
# ==============================================================================
health_check() {
    log_step "Step 8: 健康檢查"
    
    log_info "等待容器啟動 (10 秒)..."
    sleep 10
    
    local all_healthy=true
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        
        log_info "檢查 ${NAME} (Port: ${PORT})..."
        
        # 檢查容器是否運行中
        if docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
            log_success "${NAME} 容器運行中"
            
            # 嘗試 HTTP 健康檢查 (最多重試 6 次，共 30 秒)
            local retry=0
            local max_retry=6
            local healthy=false
            
            while [ $retry -lt $max_retry ]; do
                HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:${PORT}/" 2>/dev/null || echo "000")
                if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
                    log_success "${NAME} HTTP 回應正常 (HTTP ${HTTP_CODE})"
                    healthy=true
                    break
                else
                    retry=$((retry + 1))
                    log_warning "${NAME} HTTP 回應: ${HTTP_CODE}，重試 ${retry}/${max_retry}..."
                    sleep 5
                fi
            done
            
            if [ "$healthy" = false ]; then
                log_warning "${NAME} HTTP 檢查未通過，但容器正在運行"
                all_healthy=false
            fi
        else
            log_error "${NAME} 容器未運行！"
            log_error "請檢查日誌: docker logs ${NAME}"
            all_healthy=false
        fi
    done
    
    if [ "$all_healthy" = true ]; then
        log_success "所有實例健康檢查通過"
    else
        log_warning "部分實例可能需要額外檢查"
    fi
}

# ==============================================================================
# Step 9: 設定 Tailscale Serve
# ==============================================================================
setup_tailscale_serve() {
    log_step "Step 9: 設定 Tailscale Serve"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        
        log_info "設定 ${NAME} 的 Tailscale Serve (HTTPS port ${PORT})..."
        tailscale serve --bg --https ${PORT} http://127.0.0.1:${PORT}
        sleep 1  # 確保 Tailscale Serve 設定生效
        log_success "已設定: https://${TAILSCALE_HOSTNAME}:${PORT}/"
    done
    
    log_success "所有 Tailscale Serve 已設定"
    tailscale serve status
}

# ==============================================================================
# Step 10: 安全加固 (可選)
# ==============================================================================
security_hardening() {
    log_step "Step 10: 安全加固"
    
    # 修改 SSH 端口 (已註解，保留預設 Port 22)
    # log_info "修改 SSH 端口為 ${SSH_PORT}..."
    # sed -i 's/^#Port 22/Port '${SSH_PORT}'/' /etc/ssh/sshd_config
    # sed -i 's/^Port 22/Port '${SSH_PORT}'/' /etc/ssh/sshd_config
    
    # Ubuntu 24.04 使用 systemd socket activation，需要額外設定
    # mkdir -p /etc/systemd/system/ssh.socket.d
    # cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
# [Socket]
# ListenStream=
# ListenStream=${SSH_PORT}
# EOF
    # systemctl daemon-reload
    # systemctl restart ssh.socket
    # systemctl restart ssh
    # log_success "SSH 端口已修改為 ${SSH_PORT}"
    
    # 安裝 fail2ban
    log_info "安裝 fail2ban..."
    apt-get install -y fail2ban
    
    # 建立 fail2ban 自訂設定 (含累犯封鎖規則)
    log_info "設定 fail2ban (含累犯封鎖規則)..."
    cat > /etc/fail2ban/jail.local << EOF
# /etc/fail2ban/jail.local
# 自訂 fail2ban 設定

[DEFAULT]
# 預設封鎖時間：10 分鐘
bantime = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port = ${SSH_PORT}

# 累犯封鎖 (Recidive Jail)
# 如果某個 IP 在 3 小時內被封鎖超過 3 次，就封鎖 24 小時
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 24h
findtime = 3h
maxretry = 3
EOF
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    log_success "fail2ban 已安裝並啟動 (含累犯封鎖規則)"
    
    # 啟用自動安全更新
    log_info "設定自動安全更新..."
    apt-get install -y unattended-upgrades
    
    # 寫入設定檔以啟用自動更新
    echo 'APT::Periodic::Update-Package-Lists "1";' > /etc/apt/apt.conf.d/20auto-upgrades
    echo 'APT::Periodic::Unattended-Upgrade "1";' >> /etc/apt/apt.conf.d/20auto-upgrades
    log_success "自動安全更新已啟用"
}

# ==============================================================================
# Step 11: 顯示安裝摘要
# ==============================================================================
show_summary() {
    log_step "安裝完成摘要"
    
    echo ""
    echo "=============================================================================="
    echo -e "${GREEN}                    OpenClaw 安裝完成！${NC}"
    echo "=============================================================================="
    echo ""
    echo "系統配置："
    echo "  • Swap: ${SWAP_SIZE} (swappiness=${SWAPPINESS})"
    echo "  • 基礎路徑: ${BASE_PATH}"
    echo "  • SSH 端口: ${SSH_PORT}"
    echo "  • fail2ban: 已啟用 (含累犯封鎖規則)"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "Tailscale 資訊："
    echo "------------------------------------------------------------------------------"
    echo "  • Tailscale hostname: ${TAILSCALE_HOSTNAME}"
    echo "  • 存取方式: 僅限 Tailscale 網路內的設備"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "實例資訊："
    echo "------------------------------------------------------------------------------"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        TOKEN=${INSTANCE_TOKENS[$NAME]}
        
        echo ""
        echo -e "  ${CYAN}${NAME}${NC}"
        echo "  ├── 端口: ${PORT}"
        echo "  ├── 存取網址: https://${TAILSCALE_HOSTNAME}:${PORT}/"
        echo "  ├── Token: ${TOKEN} (首次登入時在設定中輸入)"
        echo "  ├── 設定檔: ${BASE_PATH}/${NAME}/config/openclaw.json"
        echo "  ├── 狀態目錄: ${BASE_PATH}/${NAME}/state/"
        echo "  └── 工作區: ${BASE_PATH}/${NAME}/workspace/"
    done
    
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "Tailscale Serve 狀態："
    echo "------------------------------------------------------------------------------"
    tailscale serve status
    
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "常用指令："
    echo "------------------------------------------------------------------------------"
    echo "  Docker Compose 指令 (在 ${BASE_PATH} 目錄下執行):"
    echo "    cd ${BASE_PATH}"
    echo "    docker compose ps                  # 查看容器狀態"
    echo "    docker compose logs openclaw-1      # 查看日誌"
    echo "    docker compose stop                 # 停止所有容器"
    echo "    docker compose restart openclaw-1   # 重啟單一容器"
    echo "    docker compose up -d                # 啟動所有容器"
    echo "    docker compose down                 # 停止並移除所有容器"
    echo ""
    echo "  進入容器:"
    echo "    docker exec -it openclaw-1 /bin/sh"
    echo ""
    echo "  Tailscale 指令:"
    echo "    tailscale status                    # 查看 Tailscale 狀態"
    echo "    tailscale serve status              # 查看 Serve 設定"
    echo "    tailscale serve --https 18111 off   # 關閉某個 Serve"
    echo ""
    echo "  OpenClaw CLI (在容器內執行):"
    echo "    docker exec -it openclaw-1 node dist/index.js onboard      # 設定精靈"
    echo "    docker exec -it openclaw-1 node dist/index.js configure    # 進階設定"
    echo "    docker exec openclaw-1 node dist/index.js config get       # 查看設定"
    echo "    docker exec openclaw-1 node dist/index.js models list      # 列出模型"
    echo ""
    echo "  設定 API Key (範例):"
    echo "    docker exec openclaw-1 node dist/index.js config set auth.profiles.anthropic:main.provider \"anthropic\""
    echo "    docker exec openclaw-1 node dist/index.js config set auth.profiles.anthropic:main.mode \"api_key\""
    echo "    docker exec openclaw-1 node dist/index.js config set auth.profiles.anthropic:main.apiKey \"sk-ant-xxx\""
    echo "    docker exec openclaw-1 node dist/index.js config set agents.defaults.model \"anthropic/claude-sonnet-4-5\""
    echo ""
    echo "  Telegram 配對:"
    echo "    docker exec openclaw-1 node dist/index.js pairing approve telegram <配對碼>"
    echo ""
    echo "  更新容器:"
    echo "    cd ${BASE_PATH}"
    echo "    docker compose pull                 # 拉取最新映像"
    echo "    docker compose up -d                # 重建容器 (資料不受影響)"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "備份與轉移："
    echo "------------------------------------------------------------------------------"
    echo "  備份: tar -czvf openclaw-backup.tar.gz ${BASE_PATH}"
    echo "  還原: tar -xzvf openclaw-backup.tar.gz -C /"
    echo "  轉移後啟動: cd ${BASE_PATH} && docker compose up -d"
    echo "  (備份包含 docker-compose.yml + 所有設定與資料)"
    echo ""
    echo "=============================================================================="
    echo "參考文檔："
    echo "  • GitHub: https://github.com/openclaw/openclaw"
    echo "  • Docs: https://docs.openclaw.ai/"
    echo "=============================================================================="
    echo ""
    
    # 儲存摘要到檔案
    SUMMARY_FILE="${BASE_PATH}/install-summary.txt"
    {
        echo "OpenClaw 安裝摘要 (Tailscale 模式)"
        echo "建立時間: $(date)"
        echo "Tailscale hostname: ${TAILSCALE_HOSTNAME}"
        echo ""
        for instance in "${INSTANCES[@]}"; do
            NAME=$(echo $instance | cut -d':' -f1)
            PORT=$(echo $instance | cut -d':' -f2)
            TOKEN=${INSTANCE_TOKENS[$NAME]}
            echo "[$NAME]"
            echo "Port: ${PORT}"
            echo "Token: ${TOKEN}"
            echo "URL: https://${TAILSCALE_HOSTNAME}:${PORT}/"
            echo "Config: ${BASE_PATH}/${NAME}/config/openclaw.json"
            echo ""
        done
    } > "${SUMMARY_FILE}"
    chmod 600 "${SUMMARY_FILE}"
    
    log_success "摘要已儲存到: ${SUMMARY_FILE}"
}

# ==============================================================================
# 主函數
# ==============================================================================
main() {
    echo ""
    echo "=============================================================================="
    echo "                    OpenClaw 自動安裝腳本"
    echo "                    Ubuntu 24.04 Server (Tailscale 模式)"
    echo "=============================================================================="
    echo ""
    
    if [ "$SKIP_TO_STEP" -gt 0 ]; then
        log_warning "跳過至 Step ${SKIP_TO_STEP}..."
    fi
    
    [ "$SKIP_TO_STEP" -le 0 ]  && preflight_checks         # Step 0
    [ "$SKIP_TO_STEP" -le 1 ]  && setup_swap               # Step 1
    [ "$SKIP_TO_STEP" -le 2 ]  && install_docker           # Step 2
    [ "$SKIP_TO_STEP" -le 3 ]  && install_tailscale        # Step 3
    [ "$SKIP_TO_STEP" -le 4 ]  && create_directories       # Step 4
    [ "$SKIP_TO_STEP" -le 5 ]  && generate_configs         # Step 5
    [ "$SKIP_TO_STEP" -le 6 ]  && setup_firewall           # Step 6
    [ "$SKIP_TO_STEP" -le 7 ]  && run_containers           # Step 7
    [ "$SKIP_TO_STEP" -le 8 ]  && health_check             # Step 8
    [ "$SKIP_TO_STEP" -le 9 ]  && setup_tailscale_serve    # Step 9
    [ "$SKIP_TO_STEP" -le 10 ] && security_hardening       # Step 10
    show_summary             # Step 11 (永遠顯示摘要)
}

# 執行主函數
main "$@"
