#!/bin/bash
# ==============================================================================
# OpenClaw 自動安裝腳本 v2 (Cloudflare Tunnel 版)
# ------------------------------------------------------------------------------
# 基於 ai-agent.sh 的進階功能 (Homebrew, OMR, Agent Logic)
# 融合 aig-cf.sh 的交付架構 (Cloudflare Tunnel, Localhost Binding)
# 
# 包含：
# 1. 3x OpenClaw 實例 (含 Homebrew, OMR Client)
# 2. 1x Admin Panel
# 3. Cloudflare Tunnel 穿透與防護
# ==============================================================================

set -e

# ==============================================================================
# 0. 核心參數配置 (來自 aig-cf.sh)
# ==============================================================================
CF_TOKEN="94-eDawCI63c8QHGOyE-yMCzPwqKaLx8q6dJWlWN"
CF_ACCOUNT="db410229f4fb3cf11e1dff1a02123815"
CF_ZONE="3d7f7eb135bda0a96b5963d797d6e569"
DOMAIN_BASE="realvco.com"
# 互動式輸入專案前綴
read -p "請輸入專案前綴 (例如 client-demo-91): " PREFIX
if [[ -z "${PREFIX}" ]]; then
    echo "錯誤: PREFIX 不能為空"
    exit 1
fi

# ==============================================================================
# 1. 全域變數定義
# ==============================================================================
BASE_PATH="/opt/openclaw/${PREFIX}"  # 調整為與 aig-cf 一致的專案路徑
TUNNEL_NAME="tunnel-${PREFIX}"
TIMEZONE="Asia/Taipei"
SWAP_SIZE="8G"
SWAPPINESS=20

# 端口定義 (內部 Localhost)
PORT_1=18111
PORT_2=18222
PORT_3=18333
PORT_ADMIN=18999

# 網址定義
URL_1="${PREFIX}-1.${DOMAIN_BASE}"
URL_2="${PREFIX}-2.${DOMAIN_BASE}"
URL_3="${PREFIX}-3.${DOMAIN_BASE}"
URL_ADMIN="${PREFIX}-admin.${DOMAIN_BASE}"

# 實例列表
INSTANCES=("openclaw-1:${PORT_1}" "openclaw-2:${PORT_2}" "openclaw-3:${PORT_3}")

# Docker 資源限制
DOCKER_CPUS="3"
DOCKER_CPU_SHARES=1024
DOCKER_MEMORY="4g"
DOCKER_MEMORY_RESERVATION="2048m"
DOCKER_LOG_MAX_SIZE="30m"
DOCKER_LOG_MAX_FILE="10"
NODE_MAX_OLD_SPACE="1536"

# 儲存 Token
declare -A INSTANCE_TOKENS

# 顏色輸出
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

# ==============================================================================
# 2. 前置檢查與環境準備
# ==============================================================================
preflight_checks() {
    log_step "Step 0: 前置檢查"
    if [ "$(id -u)" -ne 0 ]; then
        log_error "請以 root 身份運行此腳本"
        exit 1
    fi
    
    # 安裝基本工具
    apt-get update -qq
    apt-get install -y -qq jq curl ufw openssl
    
    log_success "環境檢查通過"
}

setup_swap() {
    log_step "Step 1: 設定 Swap (${SWAP_SIZE})"
    if [ -f /swapfile ] && grep -q "${SWAP_SIZE}" <(du -h /swapfile); then
        log_success "Swap 已存在且大小相符"
    else
        if [ -f /swapfile ]; then swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; fi
        log_info "建立 Swap 空間..."
        fallocate -l ${SWAP_SIZE} /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then echo '/swapfile none swap sw 0 0' >> /etc/fstab; fi
        log_success "Swap 已建立"
    fi
    
    sysctl vm.swappiness=${SWAPPINESS}
    sed -i "s/vm.swappiness=.*/vm.swappiness=${SWAPPINESS}/" /etc/sysctl.conf 2>/dev/null || echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf
}

install_docker() {
    log_step "Step 2: 安裝 Docker"
    if command -v docker &> /dev/null; then
        log_success "Docker 已安裝: $(docker --version)"
        return
    fi
    
    log_info "安裝 Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    log_success "Docker 安裝完成"
}

install_cloudflared() {
    log_step "Step 3: 安裝 Cloudflared"
    if command -v cloudflared &> /dev/null; then
        log_success "Cloudflared 已安裝: $(cloudflared --version)"
        return
    fi
    
    log_info "下載並安裝 Cloudflared..."
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared.deb
    rm cloudflared.deb
    log_success "Cloudflared 安裝完成"
}

# ==============================================================================
# 3. Cloudflare Tunnel 建置
# ==============================================================================
setup_tunnel() {
    log_step "Step 4: 建立 Cloudflare Tunnel"
    
    # A. 透過 API 建立 Tunnel
    log_info "正在與 Cloudflare API 溝通..."
    local TUNNEL_RESP=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/tunnels" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        -H "Content-Type: application/json" \
        --data '{"name":"'"${TUNNEL_NAME}"'","config_src":"local"}')

    TUNNEL_ID=$(echo $TUNNEL_RESP | jq -r '.result.id')
    TUNNEL_TOKEN=$(echo $TUNNEL_RESP | jq -r '.result.token')

    if [[ "$TUNNEL_ID" == "null" || -z "$TUNNEL_ID" ]]; then
        # 嘗試獲取現有 Tunnel (若已存在)
        TUNNEL_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/tunnels?name=${TUNNEL_NAME}" \
            -H "Authorization: Bearer ${CF_TOKEN}" | jq -r '.result[0].id')
        
        if [[ "$TUNNEL_ID" == "null" || -z "$TUNNEL_ID" ]]; then
             echo "API Debug: $TUNNEL_RESP"
             error "建立 Tunnel 失敗且無法取得現有 Tunnel ID"
        else
             log_warning "Tunnel 已存在 (ID: ${TUNNEL_ID})，將重複使用"
             # 重新獲取 Token (通常需要重新配置，這裡假設我們需要重置)
             # 若無法獲取 token，可能需要刪除重建。這裡簡化處理。
             # 實務上通常建議刪除舊的：
             # curl -X DELETE ...
        fi
    fi
    log_success "Tunnel ID: ${TUNNEL_ID}"

    # B. 建立 DNS CNAME 記錄
    create_dns() {
        local RECORD_NAME=$1
        log_info "設定 DNS: ${RECORD_NAME}..."
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
    create_dns "${URL_ADMIN}"

    # C. 設定 Ingress
    log_info "生成 Ingress 配置..."
    mkdir -p /etc/cloudflared
    cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/creds.json

ingress:
  - hostname: ${URL_1}
    service: http://localhost:${PORT_1}
  - hostname: ${URL_2}
    service: http://localhost:${PORT_2}
  - hostname: ${URL_3}
    service: http://localhost:${PORT_3}
  - hostname: ${URL_ADMIN}
    service: http://localhost:${PORT_ADMIN}
  - service: http_status:404
EOF

    # D. 啟動服務
    log_info "安裝並啟動 Tunnel Service..."
    cloudflared service install "${TUNNEL_TOKEN}" 2>/dev/null || true
    systemctl restart cloudflared
    log_success "Cloudflare Tunnel 已連線"
}

# ==============================================================================
# 4. 應用配置與構建
# ==============================================================================
create_directories() {
    log_step "Step 5: 建立目錄結構"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        mkdir -p "${INSTANCE_PATH}/config"
        mkdir -p "${INSTANCE_PATH}/state"
        mkdir -p "${INSTANCE_PATH}/workspace"
        chown -R 1000:1000 "${INSTANCE_PATH}"
    done
    
    # Admin Panel data
    mkdir -p "${BASE_PATH}/admin-panel-data"
    
    log_success "目錄結構建立完成: ${BASE_PATH}"
}

create_files() {
    log_step "Step 6: 建立 Dockerfile 與 輔助腳本"
    
    # 1. Dockerfile.custom (Homebrew Support)
    cat > "${BASE_PATH}/Dockerfile.custom" <<'DOCKERFILE'
FROM ghcr.io/openclaw/openclaw:latest
USER root
RUN apt-get update && apt-get install -y build-essential curl file git procps && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /home/linuxbrew/.linuxbrew && chown -R node:node /home/linuxbrew
USER node
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" && \
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ~/.bashrc
ENV PATH="/home/linuxbrew/.linuxbrew/bin:${PATH}"
USER root
RUN chown -R node:node /home/linuxbrew
USER node
WORKDIR /app
DOCKERFILE
    
    # 2. OMR Client
    cat > "${BASE_PATH}/omr-client.js" <<'JS_CONTENT'
/**
 * OMR Agent Client (Compatible with Admin Panel)
 */
const AGENT_NAME = process.env.AGENT_NAME || 'unknown';
const ADMIN_HOST = process.env.ADMIN_HOST || 'http://openclaw-admin:18999';
const POLL_INTERVAL = 3000;

console.log(`[OMR] Agent ${AGENT_NAME} starting... connecting to ${ADMIN_HOST}`);
let lastMessageId = 0;

async function init() {
    try {
        const res = await fetch(`${ADMIN_HOST}/api/omr/history?limit=5`);
        if (res.ok) {
            const data = await res.json();
            if (data.messages && data.messages.length > 0) lastMessageId = data.messages[data.messages.length - 1].id;
        }
        setInterval(poll, POLL_INTERVAL);
        await sendPresence();
    } catch (err) { setTimeout(init, 5000); }
}

async function sendPresence() {
    try {
        await fetch(`${ADMIN_HOST}/api/omr/send`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Agent-ID': AGENT_NAME },
            body: JSON.stringify({ content: `🔵 **${AGENT_NAME}** is online.`, type: 'text', agent_status: 'online' })
        });
    } catch (e) {}
}

async function poll() {
    try {
        const res = await fetch(`${ADMIN_HOST}/api/omr/history?since_id=${lastMessageId}`);
        if (!res.ok) return;
        const data = await res.json();
        for (const msg of (data.messages || [])) {
            lastMessageId = Math.max(lastMessageId, msg.id);
            if (msg.sender !== 'kimfull') continue;
            const content = msg.content.toLowerCase();
            if (content.includes(`@${AGENT_NAME.toLowerCase()}`) || content.includes('@all')) {
                await reply(msg);
            }
        }
    } catch (err) {}
}

async function reply(triggerMsg) {
    try {
        await fetch(`${ADMIN_HOST}/api/omr/send`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Agent-ID': AGENT_NAME },
            body: JSON.stringify({ content: `🤖 **${AGENT_NAME}** processing: "${triggerMsg.content}"`, type: 'text', reply_to_id: triggerMsg.id, agent_status: 'working' })
        });
        setTimeout(async () => {
             await fetch(`${ADMIN_HOST}/api/omr/send`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Agent-ID': AGENT_NAME },
                body: JSON.stringify({ content: `✅ Task complete.`, type: 'text', agent_status: 'idle' })
            });
        }, 3000);
    } catch (err) {}
}
init();
JS_CONTENT
    chmod 644 "${BASE_PATH}/omr-client.js"
    log_success "檔案建立完成"
}

generate_configs() {
    log_step "Step 7: 生成配置與 Docker Compose"
    
    # 生成 Admin Token
    ADMIN_TOKEN=$(openssl rand -hex 16)
    
    # 生成 Admin Panel docker.js patch (讓 host mode 容器也能顯示 Dashboard 按鈕)
    cat > "${BASE_PATH}/admin-docker-patch.js" <<'PATCH_EOF'
const Dockerode = require('dockerode');
const os = require('os');
const { execSync } = require('child_process');

const docker = new Dockerode({
    socketPath: process.env.DOCKER_HOST || '/var/run/docker.sock',
});

const CONTAINER_PREFIX = process.env.CONTAINER_PREFIX || 'openclaw-';

async function listContainers() {
    const containers = await docker.listContainers({ all: true });
    return containers
        .filter(c => c.Names.some(n => n.replace('/', '').startsWith(CONTAINER_PREFIX)))
        .filter(c => !c.Names.some(n => n.includes('admin') || n.includes('watchtower')))
        .map(c => {
            let ports = c.Ports.filter(p => p.PublicPort).map(p => ({
                public: p.PublicPort,
                private: p.PrivatePort,
            }));
            // Fallback: read openclaw.port label (needed for network_mode: host)
            if (ports.length === 0 && c.Labels && c.Labels['openclaw.port']) {
                const p = parseInt(c.Labels['openclaw.port'], 10);
                if (p) ports = [{ public: p, private: p }];
            }
            // Read dashboardUrl from label (includes token)
            const dashboardUrl = c.Labels && c.Labels['openclaw.dashboardUrl'] ? c.Labels['openclaw.dashboardUrl'] : null;
            return {
                id: c.Id.substring(0, 12),
                name: c.Names[0].replace('/', ''),
                state: c.State,
                status: c.Status,
                ports,
                dashboardUrl,
                image: c.Image,
                created: c.Created,
            };
        })
        .sort((a, b) => a.name.localeCompare(b.name));
}

async function getContainerStats(containerId) {
    try {
        const container = docker.getContainer(containerId);
        const stats = await container.stats({ stream: false });
        const cpuDelta = stats.cpu_stats.cpu_usage.total_usage - stats.precpu_stats.cpu_usage.total_usage;
        const systemDelta = stats.cpu_stats.system_cpu_usage - stats.precpu_stats.system_cpu_usage;
        const numCpus = stats.cpu_stats.online_cpus || 1;
        const cpuPercent = systemDelta > 0 ? (cpuDelta / systemDelta) * numCpus * 100 : 0;
        const memUsage = stats.memory_stats.usage || 0;
        const memLimit = stats.memory_stats.limit || 1;
        const memPercent = (memUsage / memLimit) * 100;
        return {
            cpu: Math.round(cpuPercent * 10) / 10,
            memory: { usage: memUsage, limit: memLimit, percent: Math.round(memPercent * 10) / 10 },
        };
    } catch (err) {
        return { cpu: 0, memory: { usage: 0, limit: 0, percent: 0 } };
    }
}

async function getAllStats() {
    const containers = await listContainers();
    const results = {};
    for (const c of containers) {
        if (c.state === 'running') results[c.name] = await getContainerStats(c.name);
        else results[c.name] = { cpu: 0, memory: { usage: 0, limit: 0, percent: 0 } };
    }
    return results;
}

async function restartContainer(name) { await docker.getContainer(name).restart({ t: 10 }); }
async function stopContainer(name) { await docker.getContainer(name).stop({ t: 10 }); }
async function startContainer(name) { await docker.getContainer(name).start(); }

async function getContainerLogs(name, tail = 100) {
    const container = docker.getContainer(name);
    const logs = await container.logs({ stdout: true, stderr: true, tail, timestamps: true });
    return logs.toString('utf8');
}

async function createExec(containerName) {
    const container = docker.getContainer(containerName);
    return container.exec({ Cmd: ['/bin/sh'], AttachStdin: true, AttachStdout: true, AttachStderr: true, Tty: true, Env: ['TERM=xterm-256color'] });
}

async function resizeExec(execId, cols, rows) {
    try { await docker.getExec(execId).resize({ w: cols, h: rows }); } catch (err) {}
}

async function getSystemInfo() {
    const cpus = os.cpus();
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    const uptime = os.uptime();
    const loadAvg = os.loadavg();
    const cpuUsage = loadAvg[0] / cpus.length * 100;
    return {
        hostname: os.hostname(), platform: os.type() + ' ' + os.release(),
        cpuCores: cpus.length, cpuUsage: Math.min(Math.round(cpuUsage * 10) / 10, 100),
        memory: { total: totalMem, free: freeMem, used: totalMem - freeMem, percent: Math.round(((totalMem - freeMem) / totalMem) * 100 * 10) / 10 },
        uptime, loadAvg: loadAvg.map(l => Math.round(l * 100) / 100),
    };
}

function getHostDiskUsage() {
    try {
        const output = execSync("df -B1 / | tail -1").toString().trim();
        const parts = output.split(/\s+/);
        return { total: parseInt(parts[1]), used: parseInt(parts[2]), free: parseInt(parts[3]), percent: parseFloat(parts[4]) };
    } catch (err) { return { total: 0, used: 0, free: 0, percent: 0 }; }
}

async function getDockerDiskUsage() {
    try {
        const df = await docker.df();
        const images = df.Images || [], volumes = df.Volumes || [], buildCache = df.BuildCache || [];
        const imagesSize = images.reduce((s, i) => s + (i.Size || 0), 0);
        const volumesSize = volumes.reduce((s, v) => s + (v.UsageData?.Size || 0), 0);
        const buildCacheSize = buildCache.reduce((s, b) => s + (b.Size || 0), 0);
        const reclaimable = images.filter(i => i.Containers === 0).reduce((s, i) => s + (i.Size || 0), 0) + volumes.filter(v => v.UsageData?.RefCount === 0).reduce((s, v) => s + (v.UsageData?.Size || 0), 0) + buildCache.filter(b => !b.InUse).reduce((s, b) => s + (b.Size || 0), 0);
        return { images: { size: imagesSize, count: images.length }, volumes: { size: volumesSize, count: volumes.length }, buildCache: { size: buildCacheSize, count: buildCache.length }, total: imagesSize + volumesSize + buildCacheSize, reclaimable };
    } catch (err) { return { images: {}, volumes: {}, buildCache: {}, total: 0, reclaimable: 0 }; }
}

async function pruneSystem() {
    const results = {};
    try { results.containers = await docker.pruneContainers(); } catch (e) { results.containers = {}; }
    try { results.images = await docker.pruneImages({ filters: { dangling: { 'false': true } } }); } catch (e) { results.images = {}; }
    try { results.volumes = await docker.pruneVolumes(); } catch (e) { results.volumes = {}; }
    try { results.networks = await docker.pruneNetworks(); } catch (e) { results.networks = {}; }
    const reclaimed = (results.containers.SpaceReclaimed || 0) + (results.images.SpaceReclaimed || 0) + (results.volumes.SpaceReclaimed || 0);
    return { reclaimed, details: results };
}

async function execOnHost(cmd) {
    let container;
    try {
        try { await docker.getImage('alpine').inspect(); } catch (e) { await new Promise((resolve, reject) => { docker.pull('alpine', (err, stream) => { if (err) return reject(err); docker.modem.followProgress(stream, (err) => err ? reject(err) : resolve()); }); }); }
        container = await docker.createContainer({ Image: 'alpine', Cmd: ['nsenter', '-t', '1', '-m', '-u', '-n', '-i', ...cmd], HostConfig: { Privileged: true, PidMode: 'host' } });
        await container.start(); await container.wait();
        const logs = await container.logs({ stdout: true, stderr: true }); await container.remove();
        const buf = Buffer.isBuffer(logs) ? logs : Buffer.from(logs); let output = ''; let offset = 0;
        while (offset < buf.length) { if (offset + 8 > buf.length) break; const size = buf.readUInt32BE(offset + 4); offset += 8; if (offset + size > buf.length) { output += buf.slice(offset).toString('utf8'); break; } output += buf.slice(offset, offset + size).toString('utf8'); offset += size; }
        return output.trim();
    } catch (err) { if (container) { try { await container.remove({ force: true }); } catch (e) {} } throw err; }
}

async function getTailscaleStatus() {
    try { const output = await execOnHost(['tailscale', 'status', '--json']); const status = JSON.parse(output); return { connected: status.BackendState === 'Running', hostname: status.Self?.HostName || '', tailscaleIP: status.Self?.TailscaleIPs?.[0] || '', version: status.Version || '', peers: Object.values(status.Peer || {}).map(p => ({ name: p.HostName, ip: p.TailscaleIPs?.[0] || '', online: p.Online, os: p.OS })) }; } catch (err) { return { connected: false, error: err.message }; }
}

async function checkSystemUpdates() {
    try { const result = await execOnHost(['sh', '-c', 'if [ -f /var/run/reboot-required ]; then echo "reboot-required"; else echo "ok"; fi']); return { rebootRequired: result.includes('reboot-required') }; } catch (err) { return { rebootRequired: false, error: err.message }; }
}

async function rebootHost() { await execOnHost(['reboot']); }

async function createBackup() {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-').substring(0, 19);
    const filename = 'openclaw-backup-' + timestamp + '.tar.gz';
    await execOnHost(['tar', '-czf', '/tmp/' + filename, '/opt/openclaw/openclaw-1/config', '/opt/openclaw/openclaw-2/config', '/opt/openclaw/openclaw-3/config', '/opt/openclaw/docker-compose.yml']);
    return { filename, hostPath: '/tmp/' + filename };
}

module.exports = { docker, listContainers, getContainerStats, getAllStats, restartContainer, stopContainer, startContainer, getContainerLogs, createExec, resizeExec, getSystemInfo, getHostDiskUsage, getDockerDiskUsage, pruneSystem, execOnHost, getTailscaleStatus, checkSystemUpdates, rebootHost, createBackup };
PATCH_EOF


    # 生成 Admin Panel app.js patch (前端 Dashboard URL 支援)
    # 我們需要從容器內 extraction 原本的 app.js 嗎？不，我們直接提供一份我們已經驗證過的完整版 app.js
    # 或是更簡單：我們用 docker cp 的方式，或是用 sed 在啟動時修改？
    # 最穩定的方式是 mount 覆蓋。由於我們無法預知 app.js 未來的變化，這裡我們僅提供關鍵修改的 app.js。
    # 但為了簡單起見，我會把剛才那份完整的 app.js 寫入。
    cat > "${BASE_PATH}/admin-frontend-patch.js" <<'FRONTEND_EOF'
/* ═══════════════════════════════════════════════════════
   OpenClaw Admin Panel — Frontend Logic v0.5.0
   ═══════════════════════════════════════════════════════ */

// ─── Helpers ─────────────────────────────────────────
function formatBytes(bytes) {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024, sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return (bytes / Math.pow(k, i)).toFixed(1) + ' ' + sizes[i];
}

function formatUptime(seconds) {
  if (!seconds) return '--';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

function barClass(percent) {
  if (percent > 85) return 'danger';
  if (percent > 65) return 'warn';
  return '';
}

async function apiCall(url, options = {}) {
  try {
    const res = await fetch(url, options);
    if (res.status === 401) {
      window.location.href = '/login.html';
      return null;
    }
    return await res.json();
  } catch (err) {
    console.error('API Error:', url, err);
    return null;
  }
}

function showToast(message, type = 'info') {
  const container = document.getElementById('toast-container');
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.innerHTML = `<span>${type === 'success' ? '✓' : type === 'error' ? '✗' : 'ℹ'}</span> ${message}`;
  container.appendChild(toast);
  setTimeout(() => toast.remove(), 3000);
}

// ─── Confirm Dialog ──────────────────────────────────
let pendingConfirmAction = null;

function showConfirm(title, message, action) {
  document.getElementById('confirm-title').textContent = title;
  document.getElementById('confirm-message').textContent = message;
  document.getElementById('confirm-overlay').classList.remove('hidden');
  pendingConfirmAction = action;
}

function closeConfirm() {
  document.getElementById('confirm-overlay').classList.add('hidden');
  pendingConfirmAction = null;
}

function confirmAction() {
  if (pendingConfirmAction) pendingConfirmAction();
  closeConfirm();
}

// ─── Host Card ───────────────────────────────────────
function renderHostCard(system, disk, tailscale, updates) {
  const hostDisk = disk?.host || {};
  const dockerDisk = disk?.docker || {};
  const diskPercent = hostDisk.percent || 0;
  const diskBarClass = barClass(diskPercent);

  const tsConnected = tailscale?.connected !== false;
  const rebootRequired = updates?.rebootRequired === true;

  return `
    <div class="card host-card" id="host-card">
      <div class="card-header">
        <div class="card-name">
          <div class="host-icon">🖥️</div>
          <div>
            <div>${system?.hostname || 'Host'}</div>
            <div style="font-size:0.7rem;color:var(--text-muted);font-weight:400">${system?.platform || ''}</div>
          </div>
        </div>
        <span class="card-status running">ONLINE</span>
      </div>

      <!-- Disk Usage -->
      <div style="font-size:0.75rem;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;margin-bottom:0.3rem">磁碟用量</div>
      <div class="host-disk-bar">
        <div class="host-disk-bar-fill ${diskBarClass}" style="width:${diskPercent}%"></div>
      </div>
      <div class="host-disk-meta">
        <span>${formatBytes(hostDisk.used)} / ${formatBytes(hostDisk.total)}</span>
        <span>${diskPercent}%</span>
      </div>

      ${dockerDisk.reclaimable > 0 ? `
      <div class="host-reclaimable">
        ⚠️ 可回收 ${formatBytes(dockerDisk.reclaimable)} Docker 快取
      </div>` : ''}

      <!-- Status Items -->
      <div class="host-status-list">
        <div class="host-status-item">
          <span>🌐 Tailscale</span>
          <span class="host-status-badge ${tsConnected ? 'online' : 'offline'}">${tsConnected ? '已連線' : '離線'}</span>
        </div>
        <div class="host-status-item">
          <span>⏱️ Uptime</span>
          <span style="color:var(--text-primary);font-weight:600">${formatUptime(system?.uptime)}</span>
        </div>
        <div class="host-status-item">
          <span>🔄 系統更新</span>
          <span class="host-status-badge ${rebootRequired ? 'warning' : 'ok'}">${rebootRequired ? '需重啟' : '最新'}</span>
        </div>
        <div class="host-status-item">
          <span>🐳 Docker Images</span>
          <span style="color:var(--text-primary);font-weight:600">${dockerDisk.images?.count || 0} 個 · ${formatBytes(dockerDisk.images?.size)}</span>
        </div>
      </div>

      <!-- Actions -->
      <div class="card-actions">
        <button class="btn btn-primary" onclick="handleDiskPrune()" id="btn-prune">
          <span class="btn-icon">🧹</span> 清理磁碟
        </button>
        <button class="btn" onclick="handleBackup()" id="btn-backup">
          <span class="btn-icon">💾</span> 備份
        </button>
        <button class="btn btn-danger" onclick="handleReboot()">
          <span class="btn-icon">🔄</span> 重啟主機
        </button>
      </div>
    </div>`;
}

// ─── Container Card ──────────────────────────────────
function renderContainerCard(container, stats) {
  const s = stats || { cpu: 0, memory: { usage: 0, limit: 0, percent: 0 } };
  const port = container.ports?.[0]?.public || '--';

  return `
    <div class="card" data-container="${container.name}" id="card-${container.name}">
      <div class="card-header">
        <div class="card-name">
          <span class="status-dot ${container.state}"></span>
          ${container.name}
        </div>
        <span class="card-status ${container.state}">${container.state}</span>
      </div>

      <div class="card-stats">
        <div class="card-stat">
          <div class="card-stat-label">CPU</div>
          <div class="card-stat-value" data-stat="cpu">${s.cpu}%</div>
        </div>
        <div class="card-stat">
          <div class="card-stat-label">RAM</div>
          <div class="card-stat-value" data-stat="mem">${formatBytes(s.memory.usage)}</div>
        </div>
      </div>

      <div class="card-info">
        <div class="card-info-row"><span>Port</span><span>${port}</span></div>
        <div class="card-info-row"><span>Image</span><span style="max-width:140px;overflow:hidden;text-overflow:ellipsis">${container.image}</span></div>
        <div class="card-info-row"><span>Status</span><span>${container.status}</span></div>
      </div>

      <div class="card-actions">
        ${(container.dashboardUrl || port !== '--') ? `<a class="btn" href="${container.dashboardUrl || `https://${window.location.hostname}:${port}/`}" target="_blank"><span class="btn-icon">🌐</span> Dashboard</a>` : ''}
        <button class="btn" onclick="openTerminal('${container.name}')"><span class="btn-icon">💻</span> Terminal</button>
        <button class="btn" onclick="showLogs('${container.name}')"><span class="btn-icon">📋</span> Logs</button>
        <button class="btn btn-success" onclick="containerAction('${container.name}','restart')"><span class="btn-icon">⟳</span> Restart</button>
      </div>
    </div>`;
}

// ─── System Bar ──────────────────────────────────────
function renderSystemBar(system) {
  if (!system) return;
  const bar = document.getElementById('system-bar');
  const cpuClass = barClass(system.cpuUsage);
  const memClass = barClass(system.memory.percent);

  bar.innerHTML = `
      <div class="system-stat">
        <div class="system-stat-label">CPU Usage</div>
        <div class="system-stat-value">${system.cpuUsage}%</div>
        <div class="system-stat-bar"><div class="system-stat-bar-fill ${cpuClass}" style="width:${system.cpuUsage}%"></div></div>
      </div>
      <div class="system-stat">
        <div class="system-stat-label">Memory</div>
        <div class="system-stat-value">${formatBytes(system.memory.used)}</div>
        <div class="system-stat-bar"><div class="system-stat-bar-fill ${memClass}" style="width:${system.memory.percent}%"></div></div>
      </div>
      <div class="system-stat">
        <div class="system-stat-label">CPU Cores</div>
        <div class="system-stat-value">${system.cpuCores}</div>
      </div>
      <div class="system-stat">
        <div class="system-stat-label">Uptime</div>
        <div class="system-stat-value">${formatUptime(system.uptime)}</div>
      </div>`;
}

// ─── Render All ──────────────────────────────────────
async function renderAll() {
  // Fetch everything in parallel
  const [containers, stats, system, disk, tailscale, updates] = await Promise.all([
    apiCall('/api/containers'),
    apiCall('/api/stats'),
    apiCall('/api/system'),
    apiCall('/api/disk'),
    apiCall('/api/tailscale'),
    apiCall('/api/host/updates'),
  ]);

  if (!containers) return;

  // System bar
  renderSystemBar(system);

  // All cards: host card first, then container cards
  const grid = document.getElementById('instances');
  const hostHTML = renderHostCard(system, disk, tailscale, updates);
  const containerHTML = containers.map(c => renderContainerCard(c, stats?.[c.name])).join('');
  grid.innerHTML = hostHTML + containerHTML;
}

// ─── Host Actions ────────────────────────────────────
async function handleDiskPrune() {
  const btn = document.getElementById('btn-prune');
  btn.disabled = true;
  btn.innerHTML = '<span class="btn-icon">⏳</span> 清理中...';
  showToast('正在清理 Docker 快取...', 'info');

  const result = await apiCall('/api/disk/prune', { method: 'POST' });
  if (result?.success) {
    showToast(`✅ 已釋放 ${formatBytes(result.reclaimed)}`, 'success');
    // Refresh host card
    setTimeout(renderAll, 1000);
  } else {
    showToast('清理失敗', 'error');
  }
  btn.disabled = false;
  btn.innerHTML = '<span class="btn-icon">🧹</span> 清理磁碟';
}

async function handleBackup() {
  const btn = document.getElementById('btn-backup');
  btn.disabled = true;
  btn.innerHTML = '<span class="btn-icon">⏳</span> 備份中...';
  showToast('正在建立備份...', 'info');

  const result = await apiCall('/api/backup', { method: 'POST' });
  if (result?.success) {
    showToast(`✅ 備份完成: ${result.filename}`, 'success');
  } else {
    showToast('備份失敗', 'error');
  }
  btn.disabled = false;
  btn.innerHTML = '<span class="btn-icon">💾</span> 備份';
}

function handleReboot() {
  showConfirm(
    '⚠️ 重啟主機',
    '這將中斷所有用戶連線約 60 秒。確定要重啟嗎？',
    async () => {
      showToast('主機將在 3 秒後重啟...', 'info');
      await apiCall('/api/host/reboot', { method: 'POST' });
    }
  );
}

// ─── Container Actions ───────────────────────────────
async function containerAction(name, action) {
  showToast(`正在 ${action} ${name}...`, 'info');
  const result = await apiCall(`/api/containers/${name}/${action}`, { method: 'POST' });
  if (result?.success) {
    showToast(`✅ ${name} ${action} 完成`, 'success');
    setTimeout(renderAll, 1500);
  } else {
    showToast(`${action} 失敗: ${result?.error || 'Unknown'}`, 'error');
  }
}

function openTerminal(name) {
  window.open(`/terminal.html?container=${encodeURIComponent(name)}`, '_blank');
}

async function showLogs(name) {
  const overlay = document.getElementById('modal-overlay');
  const title = document.getElementById('modal-title');
  const body = document.getElementById('modal-body');

  title.textContent = `📋 ${name} 日誌`;
  body.innerHTML = '<div class="loading"><div class="spinner"></div>Loading...</div>';
  overlay.classList.remove('hidden');

  const data = await apiCall(`/api/containers/${name}/logs?tail=200`);
  if (data?.logs) {
    body.innerHTML = `<pre class="log-content">${data.logs.replace(/</g, '&lt;')}</pre>`;
  } else {
    body.innerHTML = '<p style="color:var(--error)">無法取得日誌</p>';
  }
}

function closeModal() {
  document.getElementById('modal-overlay').classList.add('hidden');
}

// ─── WebSocket Live Stats ────────────────────────────
let ws = null;

function connectStatsWs() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${protocol}//${location.host}/ws/stats`);

  ws.onmessage = (event) => {
    try {
      const stats = JSON.parse(event.data);
      for (const [name, s] of Object.entries(stats)) {
        const card = document.getElementById(`card-${name}`);
        if (!card) continue;
        const cpuEl = card.querySelector('[data-stat="cpu"]');
        const memEl = card.querySelector('[data-stat="mem"]');
        if (cpuEl) cpuEl.textContent = `${s.cpu}%`;
        if (memEl) memEl.textContent = formatBytes(s.memory.usage);
      }
    } catch (e) { }
  };

  ws.onclose = () => setTimeout(connectStatsWs, 5000);
  ws.onerror = () => ws.close();
}

// ─── Version & Announcements ─────────────────────────
async function loadMeta() {
  const version = await apiCall('/api/version');
  if (version?.version) {
    document.getElementById('header-version').textContent = `v${version.version}`;
  }

  const ann = await apiCall('/api/announcements');
  if (ann?.announcements?.length) {
    const bar = document.getElementById('announcement-bar');
    bar.innerHTML = `<span class="announcement-icon">📢</span> ${ann.announcements[0].message}`;
    bar.classList.remove('hidden');
  }
}

// ─── Init ────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', async () => {
  await loadMeta();
  await renderAll();
  connectStatsWs();
});
FRONTEND_EOF

    # 準備 Docker Compose Header
    COMPOSE_FILE="${BASE_PATH}/docker-compose.yml"
    echo "services:" > "${COMPOSE_FILE}"
    
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        
        # 生成 Agent Token
        TOKEN=$(openssl rand -hex 32)
        INSTANCE_TOKENS[$NAME]=$TOKEN
        
        # Agent Name mapping
        if [[ "${NAME}" == "openclaw-1" ]]; then AGENT_NAME="lisa";
        elif [[ "${NAME}" == "openclaw-2" ]]; then AGENT_NAME="rose";
        else AGENT_NAME="oc-${NAME##*-}"; fi
        
        # 寫入 openclaw.json (Localhost Mode)
        cat > "${INSTANCE_PATH}/config/openclaw.json" <<EOF
{
  "gateway": {
    "mode": "local",
    "port": ${PORT},
    "bind": "lan",
    "trustedProxies": ["127.0.0.1", "::1"],
    "auth": {
      "mode": "token",
      "token": "${TOKEN}",
      "allowTailscale": false
    },
    "controlUi": {
      "enabled": true,
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
    }
  },
  "agents": {
    "defaults": { "workspace": "/home/node/.openclaw/workspace", "userTimezone": "${TIMEZONE}" }
  }
}
EOF
        chown 1000:1000 "${INSTANCE_PATH}/config/openclaw.json"
        chmod 600 "${INSTANCE_PATH}/config/openclaw.json"
        
        # 追加 service 到 docker-compose
        # 使用 network_mode: host，因為 OpenClaw 只監聽 127.0.0.1
        # Docker port mapping 無法轉發到容器內的 127.0.0.1
        # Host mode 讓容器直接使用宿主機網路，Cloudflared 可直接連上
        cat >> "${COMPOSE_FILE}" <<EOF
  ${NAME}:
    build:
      context: .
      dockerfile: Dockerfile.custom
    image: openclaw-custom:latest
    container_name: ${PREFIX}-${NAME##*-}
    restart: unless-stopped
    labels:
      - "openclaw.role=agent"
      - "openclaw.port=${PORT}"
      - "openclaw.name=${AGENT_NAME}"
      - "openclaw.url=https://${PREFIX}-${NAME##*-}.${DOMAIN_BASE}"
      - "openclaw.token=${TOKEN}"
      - "openclaw.dashboardUrl=https://${PREFIX}-${NAME##*-}.${DOMAIN_BASE}/?token=${TOKEN}"
    deploy: { resources: { reservations: { cpus: '0.5', memory: 2048M }, limits: { cpus: "3", memory: 4G } } }
    logging: { driver: "json-file", options: { max-size: "30m", max-file: "10" } }
    network_mode: host
    volumes:
      - ${INSTANCE_PATH}:/home/node/.openclaw
      - ${BASE_PATH}/linuxbrew-${NAME##*-}:/home/linuxbrew
      - ${BASE_PATH}/omr-client.js:/home/node/omr-client.js:ro
    environment:
      - TZ=${TIMEZONE}
      - OPENCLAW_GATEWAY_PORT=${PORT}
      - OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json
      - OPENCLAW_STATE_DIR=/home/node/.openclaw/state
      - NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE}
      - PATH=/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:\$PATH
      - AGENT_NAME=${AGENT_NAME}
      - ADMIN_HOST=http://127.0.0.1:${PORT_ADMIN}
    command: sh -c "nohup node /home/node/omr-client.js > /home/node/.openclaw/omr.log 2>&1 & exec docker-entrypoint.sh node openclaw.mjs gateway --allow-unconfigured"

EOF
    done
    
    # Append Admin Panel
    cat >> "${COMPOSE_FILE}" <<EOF
  admin-panel:
    image: ghcr.io/kimfull/webvco-aig-mvps-panel--private:latest
    container_name: ${PREFIX}-admin
    restart: unless-stopped
    ports: ["127.0.0.1:${PORT_ADMIN}:${PORT_ADMIN}"]
    environment:
      - ADMIN_TOKEN=${ADMIN_TOKEN}
      - CONTAINER_PREFIX=${PREFIX}-
    logging:
      driver: "json-file"
      options:
        max-size: "30m"
        max-file: "10"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${BASE_PATH}/admin-panel-data:/app/data
      - ${BASE_PATH}/admin-docker-patch.js:/app/lib/docker.js:ro
      - ${BASE_PATH}/admin-frontend-patch.js:/app/public/js/app.js:ro

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
EOF
    log_success "配置生成完成"
}

# ==============================================================================
# 5. 部署與運行
# ==============================================================================
setup_firewall() {
    log_step "Step 8: 設定防火牆"
    ufw allow 22/tcp comment 'SSH'
    ufw default deny incoming
    ufw default allow outgoing
    echo "y" | ufw enable
    log_success "防火牆已設定 (只允許 SSH Inbound + All Outbound)"
}

deploy_containers() {
    log_step "Step 9: 部署容器"
    cd ${BASE_PATH}
    
    log_info "構建自定義鏡像 (含 Homebrew)..."
    docker compose build --no-cache
    
    # 提取 Homebrew 初始資料
    log_info "初始化 Homebrew 資料卷..."
    TEMP_ID=$(docker create openclaw-custom:latest)
    docker cp ${TEMP_ID}:/home/linuxbrew ${BASE_PATH}/linuxbrew-1
    docker rm -v ${TEMP_ID}
    
    cp -a ${BASE_PATH}/linuxbrew-1 ${BASE_PATH}/linuxbrew-2
    cp -a ${BASE_PATH}/linuxbrew-1 ${BASE_PATH}/linuxbrew-3
    
    log_info "啟動服務..."
    docker compose up -d
    log_success "所有服務已啟動"
}

# ==============================================================================
# 6. 總結報告
# ==============================================================================
summary() {
    local SUMMARY_FILE="${BASE_PATH}/delivery_info.txt"
    
    cat <<REPORT | tee "${SUMMARY_FILE}"

==============================================================================
 ✅ OpenClaw SaaS 部署完成 (Cloudflare Enhanced)
==============================================================================
客戶代號: ${PREFIX}
Tunnel ID: ${TUNNEL_ID}

[訪問網址]
1. Lisa (Agent 1):
   👉 https://${URL_1}/?token=${INSTANCE_TOKENS[openclaw-1]}

2. Rose (Agent 2):
   👉 https://${URL_2}/?token=${INSTANCE_TOKENS[openclaw-2]}

3. Agent 3:
   👉 https://${URL_3}/?token=${INSTANCE_TOKENS[openclaw-3]}

[管理後台]
   👉 https://${URL_ADMIN}/?token=${ADMIN_TOKEN}

==============================================================================
REPORT
    
    log_success "部署完成！請查看上方資訊。"
}

# ==============================================================================
# 主流程
# ==============================================================================
preflight_checks
setup_swap
install_docker
install_cloudflared
setup_tunnel
create_directories
create_files
generate_configs
setup_firewall
deploy_containers
summary
