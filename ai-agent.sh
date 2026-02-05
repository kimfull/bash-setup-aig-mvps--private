#!/bin/bash

# AI Agent 安裝腳本：OpenClaw
# 用途：安裝 Docker、Docker Compose，建置映像檔，並並行設置 3 個完全隔離的 OpenClaw 實例。

set -e # 若發生錯誤則立即退出

# --- 1. 系統更新與 Docker 安裝 ---
echo ">>> [1/4] 正在更新系統並安裝 Docker..."

# 更新套件列表
sudo apt-get update

# 安裝必要套件 (加入 openssl 用於生成 token)
sudo apt-get install -y ca-certificates curl gnupg git openssl

# 安裝 Docker GPG 金鑰
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

# 加入 Docker 倉庫源
echo \
  "deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 安裝 Docker Engine
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 啟動並啟用 Docker 服務
sudo systemctl start docker
sudo systemctl enable docker

echo ">>> Docker 安裝成功。"

# --- 2. 建置 OpenClaw Docker 映像檔 ---
echo ">>> [2/4] 檢查並建置 OpenClaw 映像檔 (openclaw:local)..."

if [[ "$(sudo docker images -q openclaw:local 2> /dev/null)" == "" ]]; then
    echo "    映像檔不存在，開始下載原始碼並建置..."
    
    BUILD_DIR="openclaw-build-temp"
    
    # 清理舊的建置目錄 (如果存在)
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    # 下載原始碼
    git clone https://github.com/openclaw/openclaw "$BUILD_DIR"
    
    cd "$BUILD_DIR"
    
    # 執行 Docker Build
    echo "    正在執行 Docker Build (這可能需要幾分鐘)..."
    sudo docker build -t openclaw:local .
    
    cd ..
    
    # 建置完成後清理暫存目錄
    rm -rf "$BUILD_DIR"
    echo "    映像檔 openclaw:local 建置完成！"
else
    echo "    映像檔 openclaw:local 已存在，跳過建置步驟。"
fi


# --- 3. 部署單個 OpenClaw 實例的函式 ---
deploy_openclaw() {
    local INSTANCE_ID=$1
    local GATEWAY_PORT=$2
    local BRIDGE_PORT=$3
    
    BASE_DIR="openclaw-instance-${INSTANCE_ID}"
    ABS_BASE_DIR=$(pwd)/$BASE_DIR
    
    echo ">>> 正在部署 OpenClaw 實例 ${INSTANCE_ID}..."
    echo "    目錄位置: ${ABS_BASE_DIR}"
    echo "    Gateway (UI) 端口: ${GATEWAY_PORT}"
    echo "    Bridge 端口: ${BRIDGE_PORT}"

    # 建立目錄
    if [ -d "$BASE_DIR" ]; then
        echo "    目錄已存在..."
    else
        mkdir -p "$BASE_DIR"
    fi

    cd "$BASE_DIR"

    # 複製 Repository (我們需要 docker-compose.yml)
    # 雖然我們有全域映像檔，但每個實例仍需要 docker-compose 檔案來啟動
    if [ ! -d "openclaw" ]; then
        git clone https://github.com/openclaw/openclaw openclaw
    fi
    
    cd openclaw

    # 確保代碼是最新的 (主要是為了 docker-compose.yml)
    git checkout .
    git pull origin main

    # --- 配置設定 (使用 .env) ---
    # 生成隨機 Token
    RANDOM_TOKEN=$(openssl rand -hex 16)
    
    # 建立 .env 檔案
    # 這確保了包括數據、配置、端口在內的完全隔離
    cat <<EOF > .env
# OpenClaw Instance ${INSTANCE_ID} Configuration
OPENCLAW_IMAGE=openclaw:local
OPENCLAW_GATEWAY_TOKEN=${RANDOM_TOKEN}
OPENCLAW_GATEWAY_PORT=${GATEWAY_PORT}
OPENCLAW_BRIDGE_PORT=${BRIDGE_PORT}

# 指定數據存儲路徑 (絕對路徑) 以確保隔離
OPENCLAW_CONFIG_DIR=${ABS_BASE_DIR}/config
OPENCLAW_WORKSPACE_DIR=${ABS_BASE_DIR}/workspace

# 綁定位址 (0.0.0.0 允許外部連接)
OPENCLAW_GATEWAY_BIND=0.0.0.0
EOF

    # 建立資料夾結構
    mkdir -p "${ABS_BASE_DIR}/config"
    mkdir -p "${ABS_BASE_DIR}/workspace"
    
    # [重要] 修正權限
    # OpenClaw 容器內使用 'node' (uid:1000) 用戶
    # 我們必須給予這些目錄寫入權限，否則容器會因為 Permission Denied 而崩潰
    chmod 777 "${ABS_BASE_DIR}/config"
    chmod 777 "${ABS_BASE_DIR}/workspace"

    echo "    配置檔 (.env) 已生成。"
    echo "    Token: ${RANDOM_TOKEN}"

    # 執行 Docker Compose
    # 使用 -p (專案名稱) 確保容器名稱與網絡隔離
    sudo docker compose -p openclaw-${INSTANCE_ID} up -d

    echo ">>> 實例 ${INSTANCE_ID} 已啟動。"
    cd ../..
}

# --- 4. 部署 3 個實例 ---
echo ">>> [3/4] 開始部署實例..."

# 實例 1
# Gateway: 18789, Bridge: 18790 (預設)
deploy_openclaw 1 18789 18790

# 實例 2
# Gateway: 18791, Bridge: 18792
deploy_openclaw 2 18791 18792

# 實例 3
# Gateway: 18793, Bridge: 18794
deploy_openclaw 3 18793 18794

echo "=================================================="
echo ">>> [4/4] 安裝全部完成！"
echo "請確保您的防火牆 (UFW/Security Group) 已允許以下端口範圍："
echo "實例 1 UI: http://YOUR_VPS_IP:18789 (Token: 查看 openclaw-instance-1/openclaw/.env)"
echo "實例 2 UI: http://YOUR_VPS_IP:18791 (Token: 查看 openclaw-instance-2/openclaw/.env)"
echo "實例 3 UI: http://YOUR_VPS_IP:18793 (Token: 查看 openclaw-instance-3/openclaw/.env)"
echo "=================================================="

# --- 5. 維護與同步 (Git) ---
# 記錄推送到 GitHub 的指令 (供參考)
# git remote add origin https://github.com/kimfull/bash-setup-ai-agent-mvps.git
# git branch -M main
# git add .
# git commit -m "update: bash setup for ai agent mvps"
# git push -u origin main
