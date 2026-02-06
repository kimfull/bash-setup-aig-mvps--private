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
SSH_PORT=28182

# 自動偵測 VPS 公開 IP
VPS_IP=$(hostname -I | awk '{print $1}')

# 實例配置 (名稱:端口)
INSTANCES=("openclaw-1:18111" "openclaw-2:18222" "openclaw-3:18333")

# Docker 資源限制
DOCKER_CPUS="3"
DOCKER_MEMORY="4g"
DOCKER_MEMORY_RESERVATION="2048m"
DOCKER_LOG_MAX_SIZE="30m"
DOCKER_LOG_MAX_FILE="10"

# 儲存生成的 Token (用於摘要報告)
declare -A INSTANCE_TOKENS

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
    
    # 檢查 Ubuntu 版本
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            log_error "此腳本僅支援 Ubuntu 系統，當前系統: $ID"
            exit 1
        fi
        if [[ "$VERSION_ID" != "24.04" ]]; then
            log_warning "建議使用 Ubuntu 24.04，當前版本: $VERSION_ID"
        else
            log_success "已確認 Ubuntu 24.04"
        fi
    else
        log_error "無法確認作業系統版本"
        exit 1
    fi
    
    # 檢查磁碟空間 (至少 10GB)
    AVAILABLE_SPACE=$(df / --output=avail -BG | tail -1 | tr -d ' G')
    if [ "$AVAILABLE_SPACE" -lt 10 ]; then
        log_error "磁碟空間不足，需要至少 10GB，目前可用: ${AVAILABLE_SPACE}GB"
        exit 1
    fi
    log_success "磁碟空間足夠: ${AVAILABLE_SPACE}GB 可用"
    
    log_success "前置檢查完成"
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
# Step 3: 建立目錄結構
# ==============================================================================
create_directories() {
    log_step "Step 3: 建立目錄結構 (${BASE_PATH})"
    
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
# Step 4: 生成 Token 並建立設定檔
# ==============================================================================
generate_configs() {
    log_step "Step 4: 生成 Token 並建立設定檔"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        # 生成 Token
        TOKEN=$(openssl rand -hex 32)
        INSTANCE_TOKENS[$NAME]=$TOKEN
        
        log_info "生成 ${NAME} 的設定檔..."
        
        # 建立 openclaw.json 設定檔
        cat > "${INSTANCE_PATH}/config/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${PORT},
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${TOKEN}"
    },
    "controlUi": {
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
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
    
    log_success "所有設定檔已建立"
}

# ==============================================================================
# Step 5: 設定防火牆 (UFW)
# ==============================================================================
setup_firewall() {
    log_step "Step 5: 設定防火牆 (UFW)"
    
    # 確保 UFW 已安裝
    if ! command -v ufw &> /dev/null; then
        log_info "安裝 UFW..."
        apt-get install -y ufw
    fi
    
    # 允許自訂 SSH 端口 (非預設 22)
    log_info "允許 SSH 端口 ${SSH_PORT}..."
    ufw allow ${SSH_PORT}/tcp comment 'SSH custom port'
    
    # 開放各實例的端口
    for instance in "${INSTANCES[@]}"; do
        PORT=$(echo $instance | cut -d':' -f2)
        log_info "開放端口 ${PORT}..."
        ufw allow ${PORT}/tcp
    done
    
    # 啟用 UFW
    log_info "啟用 UFW..."
    echo "y" | ufw enable
    
    log_success "防火牆設定完成"
    ufw status
}

# ==============================================================================
# Step 6: 拉取並運行 OpenClaw 容器
# ==============================================================================
run_containers() {
    log_step "Step 6: 拉取並運行 OpenClaw 容器"
    
    # 拉取最新映像檔
    log_info "拉取 OpenClaw 最新映像檔..."
    docker pull ghcr.io/openclaw/openclaw:latest
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        log_info "建立容器 ${NAME} (Port: ${PORT})..."
        
        # 檢查容器是否已存在
        if docker ps -a --format '{{.Names}}' | grep -q "^${NAME}$"; then
            log_warning "容器 ${NAME} 已存在，正在停止並移除..."
            docker stop ${NAME} 2>/dev/null || true
            docker rm ${NAME} 2>/dev/null || true
        fi
        
        # 運行容器
        docker run -d \
            --name ${NAME} \
            --restart=unless-stopped \
            --cpus=${DOCKER_CPUS} \
            --memory=${DOCKER_MEMORY} \
            --memory-reservation=${DOCKER_MEMORY_RESERVATION} \
            --log-opt max-size=${DOCKER_LOG_MAX_SIZE} \
            --log-opt max-file=${DOCKER_LOG_MAX_FILE} \
            -p ${PORT}:${PORT} \
            -v ${INSTANCE_PATH}:/home/node/.openclaw \
            -e TZ=${TIMEZONE} \
            -e OPENCLAW_GATEWAY_PORT=${PORT} \
            -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json \
            -e OPENCLAW_STATE_DIR=/home/node/.openclaw/state \
            ghcr.io/openclaw/openclaw:latest
        
        log_success "容器 ${NAME} 已啟動"
    done
    
    log_success "所有容器已啟動"
}

# ==============================================================================
# Step 7: 健康檢查
# ==============================================================================
health_check() {
    log_step "Step 7: 健康檢查"
    
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
            
            # 嘗試 HTTP 健康檢查 (最多重試 12 次，共 60 秒)
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
# Step 8: 安全加固 (可選)
# ==============================================================================
security_hardening() {
    log_step "Step 8: 安全加固"
    
    # 修改 SSH 端口
    log_info "修改 SSH 端口為 ${SSH_PORT}..."
    sed -i 's/^#Port 22/Port '${SSH_PORT}'/' /etc/ssh/sshd_config
    sed -i 's/^Port 22/Port '${SSH_PORT}'/' /etc/ssh/sshd_config
    
    # Ubuntu 24.04 使用 systemd socket activation，需要額外設定
    mkdir -p /etc/systemd/system/ssh.socket.d
    cat > /etc/systemd/system/ssh.socket.d/override.conf << EOF
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
    systemctl restart ssh
    log_success "SSH 端口已修改為 ${SSH_PORT}"
    
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
# Step 9: 顯示安裝摘要
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
    echo "實例資訊："
    echo "------------------------------------------------------------------------------"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        TOKEN=${INSTANCE_TOKENS[$NAME]}
        
        echo ""
        echo -e "  ${CYAN}${NAME}${NC}"
        echo "  ├── 端口: ${PORT}"
        echo "  ├── Token: ${TOKEN}"
        echo "  ├── 存取網址: http://${VPS_IP}:${PORT}/?token=${TOKEN}"
        echo "  ├── 設定檔: ${BASE_PATH}/${NAME}/config/openclaw.json"
        echo "  ├── 狀態目錄: ${BASE_PATH}/${NAME}/state/"
        echo "  └── 工作區: ${BASE_PATH}/${NAME}/workspace/"
    done
    
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "防火牆狀態："
    echo "------------------------------------------------------------------------------"
    ufw status | grep -E "^[0-9]|Status"
    
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "常用指令："
    echo "------------------------------------------------------------------------------"
    echo "  查看容器狀態:    docker ps"
    echo "  查看日誌:        docker logs openclaw-1"
    echo "  停止容器:        docker stop openclaw-1"
    echo "  重啟容器:        docker restart openclaw-1"
    echo "  進入容器:        docker exec -it openclaw-1 /bin/sh"
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
    echo "    docker pull ghcr.io/openclaw/openclaw:latest"
    echo "    docker stop openclaw-1 && docker rm openclaw-1"
    echo "    # 然後重新運行 docker run 指令"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo "備份路徑："
    echo "------------------------------------------------------------------------------"
    echo "  備份整個 ${BASE_PATH} 目錄即可包含所有實例資料"
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
        echo "OpenClaw 安裝摘要"
        echo "建立時間: $(date)"
        echo ""
        for instance in "${INSTANCES[@]}"; do
            NAME=$(echo $instance | cut -d':' -f1)
            PORT=$(echo $instance | cut -d':' -f2)
            TOKEN=${INSTANCE_TOKENS[$NAME]}
            echo "[$NAME]"
            echo "Port: ${PORT}"
            echo "Token: ${TOKEN}"
            echo "URL: http://${VPS_IP}:${PORT}/?token=${TOKEN}"
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
    echo "                    Ubuntu 24.04 Server"
    echo "=============================================================================="
    echo ""
    
    preflight_checks
    setup_swap
    install_docker
    create_directories
    generate_configs
    setup_firewall
    run_containers
    health_check
    security_hardening
    show_summary
}

# 執行主函數
main "$@"
