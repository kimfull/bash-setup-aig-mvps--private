#!/bin/bash
# ==============================================================================
# OpenClaw 自動安裝腳本 v2 (Cloudflare Tunnel 版 + Meeting Room)
# ==============================================================================

set -e

# ==============================================================================
# 變數定義
# ==============================================================================
BASE_PATH="/opt/openclaw"
TIMEZONE="Asia/Taipei"
SWAP_SIZE="8G"
SWAPPINESS=20
SSH_PORT=22

# 實例配置
INSTANCES=("openclaw-1:18111" "openclaw-2:18222" "openclaw-3:18333")
# Admin Panel Port
PORT_ADMIN=18999

# Docker 資源限制
DOCKER_CPUS="3"
DOCKER_CPU_SHARES=1024
DOCKER_MEMORY="4g"
DOCKER_MEMORY_RESERVATION="2048m"
DOCKER_LOG_MAX_SIZE="30m"
DOCKER_LOG_MAX_FILE="10"
NODE_MAX_OLD_SPACE="1536"

# Cloudflare 設定
CLOUDFLARE_TOKEN=""
DOMAIN_BASE="realvco.com"
PREFIX=""

# 儲存 Token
declare -A INSTANCE_TOKENS

# ==============================================================================
# 輔助函數
# ==============================================================================
log_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
log_step() { echo -e "\n\033[0;36m▶ $1\033[0m\n"; }

# ==============================================================================
# 參數解析
# ==============================================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        --cloudflare-token) CLOUDFLARE_TOKEN="$2"; shift 2 ;;
        --domain) DOMAIN_BASE="$2"; shift 2 ;;
        --prefix) PREFIX="$2"; shift 2 ;;
        *) echo "未知參數: $1"; exit 1 ;;
    esac
done

if [ -z "$CLOUDFLARE_TOKEN" ]; then
    read -p "請輸入 Cloudflare Token: " CLOUDFLARE_TOKEN
fi

if [ -z "$PREFIX" ]; then
    read -p "請輸入二級域名 Prefix (例如 demo): " PREFIX
fi

if [ -z "$CLOUDFLARE_TOKEN" ] || [ -z "$PREFIX" ]; then
    log_error "必須提供 Cloudflare Token 和 Prefix 才能繼續。"
    exit 1
fi

# ==============================================================================
# Step 1: 系統準備
# ==============================================================================
setup_system() {
    log_step "Step 1: 系統準備 (Swap & Basic Tools)"
    
    # Swap
    if ! grep -q "swap" /proc/swaps; then
        fallocate -l ${SWAP_SIZE} /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_success "Swap created"
    fi
    
    # Packages
    apt-get update
    apt-get install -y curl jq git ufw build-essential
}

# ==============================================================================
# Step 2: 安裝 Docker
# ==============================================================================
install_docker() {
    log_step "Step 2: 安裝 Docker"
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    fi
    log_success "Docker installed"
}

# ==============================================================================
# Step 3: 安裝 Cloudflared
# ==============================================================================
install_cloudflared() {
    log_step "Step 3: 安裝 Cloudflared"
    if ! command -v cloudflared &> /dev/null; then
        curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
        dpkg -i cloudflared.deb
        rm cloudflared.deb
    fi
    log_success "Cloudflared installed"
}

# ==============================================================================
# Step 4: 建立目錄與檔案
# ==============================================================================
create_files() {
    log_step "Step 4: 建立目錄與設定檔"
    
    mkdir -p ${BASE_PATH}
    
    # 4.1 Dockerfile.custom
    cat > "${BASE_PATH}/Dockerfile.custom" <<'EOF'
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
EOF

    # 4.2 OMR Client (Agent Component)
    cat > "${BASE_PATH}/omr-client.js" <<'JS_CONTENT'
const AGENT_NAME = process.env.AGENT_NAME || 'unknown';
const ADMIN_HOST = process.env.ADMIN_HOST || 'http://127.0.0.1:18999'; // Use localhost since network_mode: host
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
            // Basic command handling remains, but Meeting Room uses direct API calls now
            if (content.includes(`@${AGENT_NAME.toLowerCase()}`) || content.includes('@all')) {
                // Legacy poll-based reply (optional)
            }
        }
    } catch (err) {}
}
init();
JS_CONTENT
    chmod 644 "${BASE_PATH}/omr-client.js"

    # 4.3 Meeting Module (Backend)
    cat > "${BASE_PATH}/meeting.js" <<'JS_CONTENT'
const http = require('http');
const path = require('path');
const fs = require('fs');
const WebSocket = require('ws');
const crypto = require('crypto');

// Global Error Handlers (attach once)
if (!global.__MEETING_HANDLERS_ATTACHED) {
    process.on('unhandledRejection', (reason) => {
        console.error('[Meeting] Unhandled Rejection:', reason);
    });
    process.on('uncaughtException', (err) => {
        console.error('[Meeting] Uncaught Exception:', err);
    });
    global.__MEETING_HANDLERS_ATTACHED = true;
}

module.exports = function (app, io, server) {
    // Singleton Guard
    if (global.__MEETING_ROOM_INITIALIZED) {
        console.log('[Meeting] Already initialized. Skipping.');
        return;
    }
    global.__MEETING_ROOM_INITIALIZED = true;
    console.log('[Meeting] Initializing Meeting Room module...');

    if (!io) {
        console.error('[Meeting] Error: Socket.IO instance not available.');
        return;
    }

    // --- State ---
    const clients = new Set();
    const agents = new Map();
    const transcript = [];
    const bufferQueue = [];
    let activeStream = null;
    let messageIdCounter = Date.now();
    let isDiscovering = false;
    const AGENT_COLORS = ['#22c55e', '#3b82f6', '#eab308', '#ec4899', '#8b5cf6'];

    // --- OpenClaw Agent WebSocket Connection Pool ---
    const agentConnections = new Map(); // agentId -> { ws, connected, pending }

    function connectToAgent(agent) {
        if (agentConnections.has(agent.id)) {
            const conn = agentConnections.get(agent.id);
            if (conn.ws && conn.ws.readyState === WebSocket.OPEN) return conn;
        }

        const conn = { ws: null, connected: false, pending: new Map(), rid: 0 };
        agentConnections.set(agent.id, conn);

        try {
            const ws = new WebSocket(`ws://127.0.0.1:${agent.port}`, {
                headers: { Origin: `http://127.0.0.1:${agent.port}` }
            });
            conn.ws = ws;

            ws.on('open', () => {
                console.log(`[Meeting] WS opened to ${agent.name} (port ${agent.port})`);
            });

            ws.on('message', (data, isBinary) => {
                try {
                    if (isBinary) return; // skip binary frames
                    const str = data.toString('utf8');
                    const msg = JSON.parse(str);
                    handleAgentMessage(agent, conn, msg);
                } catch (e) {
                    if (e.code === 'WS_ERR_INVALID_UTF8') return;
                    console.error(`[Meeting] Parse error from ${agent.name}:`, e.message);
                }
            });

            ws.on('close', (code) => {
                console.log(`[Meeting] WS closed to ${agent.name}: ${code}`);
                conn.connected = false;
                agentConnections.delete(agent.id);
                updateAgentStatus(agent.id, 'offline');
                // Auto-reconnect after a delay  
                setTimeout(() => {
                    if (agents.has(agent.id)) {
                        console.log(`[Meeting] Reconnecting to ${agent.name}...`);
                        connectToAgent(agent);
                    }
                }, 5000);
            });

            ws.on('error', (e) => {
                if (e.code === 'WS_ERR_INVALID_UTF8') return; // ignore UTF8 frame errors
                console.error(`[Meeting] WS error to ${agent.name}:`, e.message);
            });
        } catch (e) {
            console.error(`[Meeting] Failed to connect to ${agent.name}:`, e.message);
        }

        return conn;
    }

    function handleAgentMessage(agent, conn, msg) {
        // Handle challenge-response auth
        if (msg.type === 'event' && msg.event === 'connect.challenge') {
            const connectReq = {
                type: 'req',
                id: 'connect-' + (++conn.rid),
                method: 'connect',
                params: {
                    minProtocol: 3,
                    maxProtocol: 3,
                    client: { id: 'openclaw-control-ui', version: 'dev', platform: 'linux', mode: 'webchat' },
                    role: 'operator',
                    scopes: ['operator.admin', 'operator.approvals', 'operator.pairing'],
                    caps: [],
                    auth: { token: agent.token }
                }
            };
            conn.ws.send(JSON.stringify(connectReq));
            console.log(`[Meeting] Sent connect to ${agent.name}`);
            return;
        }

        // Handle responses
        if (msg.type === 'res') {
            const pending = conn.pending.get(msg.id);

            // Connect response (hello-ok)
            if (msg.ok && msg.payload && msg.payload.type === 'hello-ok') {
                conn.connected = true;
                updateAgentStatus(agent.id, 'idle');
                console.log(`[Meeting] Authenticated with ${agent.name}`);
                return;
            }

            if (pending) {
                conn.pending.delete(msg.id);
                if (msg.ok) {
                    pending.resolve(msg.payload);
                } else {
                    pending.reject(new Error(msg.error?.message || 'request failed'));
                }
            } else if (!msg.ok) {
                console.error(`[Meeting] Error from ${agent.name}:`, msg.error);
            }
            return;
        }

        // Handle events from agent
        if (msg.type === 'event') {
            const evt = msg.event;
            const payload = msg.payload || {};

            // OpenClaw uses a single "chat" event with payload.state:
            //   "delta"   -> streaming (message.content is CUMULATIVE, not incremental)
            //   "final"   -> done
            //   "error"   -> error
            //   "aborted" -> cancelled
            if (evt === 'chat') {
                console.log(`[Meeting] CHAT EVT from ${agent.name}: state=${payload.state} runId=${payload.runId} hasMsg=${!!payload.message}`);
                handleChatEvent(agent, payload);
            } else if (evt === 'agent') {
                // Agent event carries streaming data
                handleAgentStreamEvent(agent, payload);
            }
            // Ignore health, tick, heartbeat, presence, etc.
        }
    }

    // --- Agent Stream Event Handling ---
    // "agent" events carry the actual streaming tokens: { runId, stream, data, sessionKey, seq, ts }
    // data contains incremental text chunks (tokens as they arrive)
    function handleAgentStreamEvent(agent, payload) {
        const runId = payload.runId;
        const stream = payload.stream; // e.g. true, "text", etc.
        const data = payload.data;

        // Only process text streaming data
        if (!data) return;

        // Debug: log first few events to see data structure
        if (!agent._agentEvtCount) agent._agentEvtCount = 0;
        if (agent._agentEvtCount++ < 3) {
            console.log(`[Meeting] AGENT_DATA from ${agent.name} stream=${stream} type=${typeof data} data=${JSON.stringify(data).substring(0, 300)}`);
        }
        // Skip non-text streams (lifecycle, tool calls, etc.)
        if (stream === 'lifecycle' || stream === 'tool' || stream === 'system') return;

        // For assistant stream: data = { text: "cumulative", delta: "incremental" }
        let deltaText = '';  // incremental chunk to send to frontend
        let fullText = '';   // cumulative text for transcript
        if (typeof data === 'object') {
            deltaText = data.delta || '';
            fullText = data.text || '';
        } else if (typeof data === 'string') {
            deltaText = data;
            fullText = data;
        }
        if (!deltaText) return;

        // Get or create stream state
        let ss = agentStreamState.get(agent.id);
        if (!ss || ss.runId !== runId) {
            ss = { lastContent: '', runId: runId, msgId: ++messageIdCounter, started: false, accumulate: '' };
            agentStreamState.set(agent.id, ss);
        }

        // Track cumulative text for transcript
        ss.accumulate = fullText || ((ss.accumulate || '') + deltaText);

        // Can we stream to frontend?
        const canStream = (activeStream === null || activeStream === agent.id);
        if (canStream) {
            if (!ss.started) {
                if (activeStream !== null && activeStream !== agent.id) return;
                activeStream = agent.id;
                ss.started = true;
                io.to('meeting').emit('meeting:stream_start', { agentId: agent.id, messageId: ss.msgId });
                console.log(`[Meeting] Agent stream start from ${agent.name}`);
            }
            io.to('meeting').emit('meeting:stream_chunk', { agentId: agent.id, content: deltaText });
        }
    }

    // --- Chat Event Handling ---
    // OpenClaw sends cumulative content in delta events (full text so far, not just the new chars)
    // We track the last known length to compute the incremental chunk
    const agentStreamState = new Map(); // agentId -> { lastContent, runId, msgId, started, accumulate }

    function extractContent(message) {
        // message can be: { role: "assistant", content: "..." }
        // or content can be an array of { type: "text", text: "..." }
        if (!message) return '';
        const c = message.content;
        if (typeof c === 'string') return c;
        if (Array.isArray(c)) {
            return c.filter(p => p.type === 'text' && typeof p.text === 'string').map(p => p.text).join('');
        }
        // Fallback: maybe payload itself has text
        if (typeof message === 'string') return message;
        return '';
    }

    function handleChatEvent(agent, payload) {
        const state = payload.state;
        const runId = payload.runId;
        const fullContent = extractContent(payload.message);

        if (state === 'delta') {
            // Chat delta events carry cumulative content snapshots
            // Agent events already handle streaming to frontend, so just update tracking
            let ss = agentStreamState.get(agent.id);
            if (!ss || ss.runId !== runId) {
                ss = { lastContent: '', runId: runId, msgId: ++messageIdCounter, started: false, accumulate: '' };
                agentStreamState.set(agent.id, ss);
            }
            ss.lastContent = fullContent;
            // Update accumulate if chat event has more complete content
            if (fullContent && fullContent.length > (ss.accumulate || '').length) {
                ss.accumulate = fullContent;
            }
            return;
        }

        if (state === 'final') {
            const ss = agentStreamState.get(agent.id);
            // Prefer accumulated content from agent streaming events, then chat event content, then lastContent
            const content = (ss && ss.accumulate) ? ss.accumulate : (fullContent || (ss ? ss.lastContent : ''));
            agentStreamState.delete(agent.id);

            if (activeStream === agent.id) {
                // We were streaming this agent - finish it
                io.to('meeting').emit('meeting:stream_end', { agentId: agent.id });
                activeStream = null;
                console.log(`[Meeting] Stream end from ${agent.name}: ${content.length} chars`);
                if (content) {
                    transcript.push({
                        id: (ss ? ss.msgId : ++messageIdCounter),
                        sender: 'agent',
                        agentId: agent.id,
                        name: agent.name,
                        content: content,
                        timestamp: Date.now()
                    });
                }
                processNextBuffer();
            } else if (content) {
                // We weren't streaming this agent - buffer the full response
                const msgId = ss ? ss.msgId : ++messageIdCounter;
                bufferQueue.push({
                    agentId: agent.id,
                    messageId: msgId,
                    fullContent: content,
                    agentName: agent.name
                });
                console.log(`[Meeting] Buffered response from ${agent.name}: ${content.length} chars`);
                if (activeStream === null) processNextBuffer();
            }

            updateAgentStatus(agent.id, 'idle');
            return;
        }

        if (state === 'error' || state === 'aborted') {
            const errMsg = payload.errorMessage || payload.error || state;
            agentStreamState.delete(agent.id);
            if (activeStream === agent.id) {
                io.to('meeting').emit('meeting:stream_end', { agentId: agent.id });
                activeStream = null;
                processNextBuffer();
            }
            io.to('meeting').emit('meeting:error', { agentId: agent.id, message: errMsg });
            updateAgentStatus(agent.id, 'idle');
            console.log(`[Meeting] Chat ${state} from ${agent.name}: ${errMsg}`);
            return;
        }
    }

    function sendRequest(agent, method, params) {
        const conn = agentConnections.get(agent.id);
        if (!conn || !conn.ws || conn.ws.readyState !== WebSocket.OPEN || !conn.connected) {
            return Promise.reject(new Error(`Not connected to ${agent.name}`));
        }

        const id = agent.id + '-' + (++conn.rid);
        const reqMsg = { type: 'req', id: id, method: method, params: params };

        return new Promise((resolve, reject) => {
            conn.pending.set(id, { resolve, reject });
            conn.ws.send(JSON.stringify(reqMsg));
            // Timeout
            setTimeout(() => {
                if (conn.pending.has(id)) {
                    conn.pending.delete(id);
                    reject(new Error('Request timeout'));
                }
            }, 120000);
        });
    }

    // --- Discovery ---
    async function discoverAgents() {
        if (isDiscovering) return;
        isDiscovering = true;
        try {
            const socketPath = '/var/run/docker.sock';
            if (!fs.existsSync(socketPath)) {
                console.error('[Meeting] Docker socket not found');
                return;
            }

            const containers = await new Promise((resolve, reject) => {
                const options = {
                    socketPath,
                    path: '/containers/json?filters=' + encodeURIComponent('{"label":["openclaw.role=agent"]}'),
                    method: 'GET'
                };
                const req = http.request(options, (res) => {
                    let data = '';
                    res.on('data', chunk => data += chunk);
                    res.on('end', () => { try { resolve(JSON.parse(data)); } catch (e) { reject(e); } });
                });
                req.on('error', reject);
                req.end();
            });

            const previousAgents = new Set(agents.keys());

            containers.forEach((c, index) => {
                const labels = c.Labels || {};
                let name = labels['openclaw.name'];
                if (!name) {
                    name = c.Names[0].replace('/', '');
                    name = name.replace(/^(client-demo-\d+-|openclaw-|oc-)/, '');
                }
                const token = labels['openclaw.token'];
                const port = labels['openclaw.port'] || '18111';

                if (name && token) {
                    const id = name.toLowerCase().replace(/\s+/g, '_');

                    if (!agents.has(id)) {
                        agents.set(id, {
                            id, name,
                            port: parseInt(port),
                            token: token,
                            color: AGENT_COLORS[index % AGENT_COLORS.length],
                            status: 'connecting'
                        });
                        // Connect WebSocket to this agent
                        connectToAgent(agents.get(id));
                    }
                    previousAgents.delete(id);
                }
            });

            // Remove agents that no longer exist
            previousAgents.forEach(id => {
                agents.delete(id);
                const conn = agentConnections.get(id);
                if (conn && conn.ws) conn.ws.close();
                agentConnections.delete(id);
            });

            io.to('meeting').emit('agents_update', Array.from(agents.values()));
        } catch (err) {
            console.error('[Meeting] Discovery failed:', err.message);
        } finally {
            isDiscovering = false;
        }
    }

    // Initial discovery
    setTimeout(discoverAgents, 2000);
    setInterval(discoverAgents, 30000);

    // --- Routes ---
    app.get('/meeting', (req, res) => {
        res.sendFile(path.join(__dirname, '../public/meeting.html'));
    });
    app.get('/api/meeting/agents', (req, res) => {
        res.json({ agents: Array.from(agents.values()) });
    });

    // --- Socket.IO ---
    io.on('connection', (socket) => {
        socket.on('error', (err) => {
            console.error(`[Meeting] Socket error from ${socket.id}:`, err.message);
        });

        const referer = socket.handshake.headers.referer || '';
        if (!referer.includes('/meeting')) return;

        socket.join('meeting');
        clients.add(socket);

        const agentList = Array.from(agents.values());
        socket.emit('init_state', { agents: agentList, history: transcript.slice(-50) });

        socket.on('meeting:send', async (data) => {
            const { content, targetAgentIds } = data;
            if (!content || !targetAgentIds) return;

            const message = {
                id: ++messageIdCounter,
                sender: 'user',
                name: 'Host',
                content,
                timestamp: Date.now()
            };
            transcript.push(message);
            io.to('meeting').emit('meeting:message', message);

            // Send to each selected agent via WebSocket RPC
            for (const id of targetAgentIds) {
                const agent = agents.get(id);
                if (!agent) continue;
                updateAgentStatus(id, 'working');

                try {
                    const idem = crypto.randomUUID();
                    const result = await sendRequest(agent, 'chat.send', {
                        sessionKey: 'main',
                        idempotencyKey: idem,
                        message: content
                    });
                    console.log(`[Meeting] chat.send to ${agent.name}: ${result.status || 'ok'}`);
                } catch (err) {
                    console.error(`[Meeting] Error sending to ${agent.name}:`, err.message);
                    io.to('meeting').emit('meeting:error', {
                        agentId: id,
                        message: `Error: ${err.message}`
                    });
                    updateAgentStatus(id, 'idle');
                }
            }
        });

        socket.on('meeting:push', async (data) => {
            const { targetAgentId, sourceName, content, originalQuestion } = data;
            const agent = agents.get(targetAgentId);
            if (!agent) return;

            const pushPrompt = `[會議室轉發] ${sourceName} 說：\n「${content}」\n\n原始問題：${originalQuestion}\n\n請根據你的角色回應以上內容。`;

            const sysMsg = {
                id: ++messageIdCounter,
                sender: 'system',
                content: `(轉發給 ${agent.name})`,
                timestamp: Date.now()
            };
            io.to('meeting').emit('meeting:message', sysMsg);

            updateAgentStatus(targetAgentId, 'working');
            try {
                const idem = crypto.randomUUID();
                await sendRequest(agent, 'chat.send', {
                    sessionKey: 'main',
                    idempotencyKey: idem,
                    message: pushPrompt
                });
            } catch (err) {
                console.error(`[Meeting] Push error to ${agent.name}:`, err.message);
                io.to('meeting').emit('meeting:error', {
                    agentId: targetAgentId,
                    message: `Push Error: ${err.message}`
                });
                updateAgentStatus(targetAgentId, 'idle');
            }
        });

        socket.on('disconnect', () => {
            clients.delete(socket);
        });
    });

    // --- Helpers ---
    function processNextBuffer() {
        if (bufferQueue.length === 0 || activeStream !== null) return;
        const next = bufferQueue.shift();
        activeStream = next.agentId;
        io.to('meeting').emit('meeting:stream_start', {
            agentId: next.agentId,
            messageId: next.messageId,
            fromBuffer: true
        });
        io.to('meeting').emit('meeting:stream_chunk', {
            agentId: next.agentId,
            content: next.fullContent
        });
        setTimeout(() => {
            io.to('meeting').emit('meeting:stream_end', { agentId: next.agentId });
            transcript.push({
                id: next.messageId,
                sender: 'agent',
                agentId: next.agentId,
                name: next.agentName,
                content: next.fullContent,
                timestamp: Date.now()
            });
            activeStream = null;
            processNextBuffer();
        }, 500);
    }

    function updateAgentStatus(id, status) {
        const agent = agents.get(id);
        if (agent) {
            agent.status = status;
            io.to('meeting').emit('agents_update', Array.from(agents.values()));
        }
    }
};

JS_CONTENT
    
    # 4.4 Meeting Module (Frontend)
    mkdir -p "${BASE_PATH}/public"
    cat > "${BASE_PATH}/public/meeting.html" <<'HTML_CONTENT'
<!DOCTYPE html>
<html lang="zh-TW">

<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>OpenClaw Meeting Room</title>
    <script src="/socket.io/socket.io.js"></script>
    <style>
        :root {
            --bg-color: #0f172a;
            --panel-bg: #1e293b;
            --text-primary: #e2e8f0;
            --accent-color: #3b82f6;
            --text-secondary: #94a3b8;
            --input-bg: #334155;
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            font-family: 'Inter', system-ui, sans-serif;
            background: var(--bg-color);
            color: var(--text-primary);
            height: 100vh;
            display: flex;
            flex-direction: column;
        }

        header {
            padding: 1rem 1.5rem;
            background: var(--panel-bg);
            border-bottom: 1px solid #334155;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        h1 {
            margin: 0;
            font-size: 1.2rem;
            font-weight: 600;
        }

        #status {
            font-size: 0.85rem;
            color: #22c55e;
            display: flex;
            align-items: center;
            gap: 6px;
        }

        #status::before {
            content: '';
            width: 8px;
            height: 8px;
            background: currentColor;
            border-radius: 50%;
            display: block;
        }

        #debug-area {
            background: #330000;
            color: #ffcccc;
            font-size: 0.75rem;
            padding: 0.5rem;
            display: none;
            max-height: 80px;
            overflow: auto;
        }

        #chat-display {
            flex: 1;
            overflow-y: auto;
            padding: 2rem;
            display: flex;
            flex-direction: column;
            gap: 1rem;
            scroll-behavior: smooth;
        }

        .message {
            max-width: 80%;
            padding: 1rem 1.25rem;
            border-radius: 1rem;
            line-height: 1.6;
            animation: slideIn 0.2s ease-out;
            box-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
        }

        @keyframes slideIn {
            from {
                opacity: 0;
                transform: translateY(10px);
            }

            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        .message.user {
            align-self: flex-end;
            background: var(--accent-color);
            color: white;
            border-bottom-right-radius: 0.25rem;
        }

        .message.agent {
            align-self: flex-start;
            background: var(--panel-bg);
            border: 1px solid #475569;
            border-bottom-left-radius: 0.25rem;
            border-left: 4px solid transparent;
        }

        .message.system {
            align-self: center;
            background: transparent;
            color: var(--text-secondary);
            font-size: 0.85rem;
            font-style: italic;
            box-shadow: none;
            padding: 0.5rem;
        }

        .sender-name {
            display: block;
            font-size: 0.8rem;
            font-weight: 700;
            margin-bottom: 0.4rem;
            opacity: 0.9;
        }

        .content {
            white-space: pre-wrap;
            word-break: break-word;
        }

        .actions {
            margin-top: 0.8rem;
            display: flex;
            gap: 0.5rem;
            flex-wrap: wrap;
            opacity: 0;
            transition: opacity 0.2s;
        }

        .message:hover .actions {
            opacity: 1;
        }

        .btn-push {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255, 255, 255, 0.1);
            color: var(--text-secondary);
            padding: 4px 10px;
            border-radius: 4px;
            font-size: 0.75rem;
            cursor: pointer;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            gap: 4px;
        }

        .btn-push:hover {
            background: rgba(255, 255, 255, 0.15);
            color: white;
            border-color: rgba(255, 255, 255, 0.3);
        }

        #buffer-note {
            align-self: center;
            background: rgba(59, 130, 246, 0.15);
            color: #60a5fa;
            padding: 0.5rem 1rem;
            border-radius: 99px;
            font-size: 0.85rem;
            display: none;
            animation: pulse 2s infinite;
        }

        @keyframes pulse {

            0%,
            100% {
                opacity: 0.7;
            }

            50% {
                opacity: 1;
            }
        }

        #input-area {
            background: var(--panel-bg);
            padding: 1.5rem;
            border-top: 1px solid #334155;
            display: flex;
            flex-direction: column;
            gap: 1rem;
        }

        .input-row {
            display: flex;
            gap: 1rem;
        }

        textarea {
            flex: 1;
            background: var(--input-bg);
            border: 1px solid #475569;
            color: white;
            padding: 1rem;
            border-radius: 0.75rem;
            resize: none;
            height: 60px;
            font-family: inherit;
            font-size: 0.95rem;
            line-height: 1.5;
            transition: border-color 0.2s;
        }

        textarea:focus {
            outline: none;
            border-color: var(--accent-color);
        }

        #send-btn {
            background: var(--accent-color);
            color: white;
            border: none;
            padding: 0 1.5rem;
            border-radius: 0.75rem;
            font-weight: 600;
            cursor: pointer;
            transition: transform 0.1s;
            height: 60px;
        }

        #send-btn:active {
            transform: scale(0.96);
        }

        #agent-selector {
            display: flex;
            gap: 0.8rem;
            overflow-x: auto;
            padding-bottom: 4px;
        }

        .agent-toggle {
            background: var(--input-bg);
            padding: 0.5rem 1rem;
            border-radius: 0.5rem;
            cursor: pointer;
            border: 1px solid transparent;
            display: flex;
            align-items: center;
            gap: 6px;
            user-select: none;
            transition: all 0.2s;
            font-size: 0.9rem;
        }

        .agent-toggle:hover {
            filter: brightness(1.1);
        }

        .agent-toggle.selected {
            background: rgba(34, 197, 94, 0.15);
            border-color: currentColor;
        }

        .dot {
            width: 8px;
            height: 8px;
            border-radius: 50%;
            background: #64748b;
            transition: background 0.3s;
        }

        ::-webkit-scrollbar {
            width: 8px;
        }

        ::-webkit-scrollbar-track {
            background: transparent;
        }

        ::-webkit-scrollbar-thumb {
            background: #475569;
            border-radius: 4px;
        }
    </style>
</head>

<body>
    <header>
        <h1>OpenClaw Meeting Room</h1>
        <div id="status">Connecting...</div>
    </header>
    <div id="debug-area"></div>
    <div id="chat-display"></div>
    <div id="input-area">
        <div class="input-row">
            <textarea id="msg-input" placeholder="輸入訊息... (Enter 發送, Shift+Enter 換行)"></textarea>
            <button id="send-btn">發送</button>
        </div>
        <div id="agent-selector"></div>
    </div>
    <script>
        function logDebug(msg) {
            const d = document.getElementById('debug-area');
            d.style.display = 'block';
            d.innerText += '[' + new Date().toLocaleTimeString() + '] ' + msg + '\n';
            d.scrollTop = d.scrollHeight;
        }

        const urlParams = new URLSearchParams(window.location.search);
        const token = urlParams.get('token');
        const socket = io({ query: token ? { token } : {}, reconnection: true, reconnectionAttempts: Infinity, reconnectionDelay: 1000 });

        const chatEl = document.getElementById('chat-display');
        const agentsEl = document.getElementById('agent-selector');
        const inputEl = document.getElementById('msg-input');
        const btnEl = document.getElementById('send-btn');
        const statusEl = document.getElementById('status');

        let agents = [], selected = new Set(), currStreamEl = null, lastUserMsg = '';

        socket.on('connect', () => { statusEl.innerText = 'Online'; statusEl.style.color = '#22c55e'; logDebug('Socket Connected: ' + socket.id); });
        socket.on('disconnect', r => { statusEl.innerText = 'Offline'; statusEl.style.color = '#ef4444'; logDebug('Disconnected: ' + r); });
        socket.on('connect_error', e => { statusEl.innerText = 'Error'; statusEl.style.color = '#fbbf24'; logDebug('Connect Error: ' + e.message); });

        socket.on('init_state', d => {
            logDebug('init_state: ' + d.agents.length + ' agents');
            if (selected.size === 0 && d.agents.length > 0) {
                d.agents.forEach(a => selected.add(a.id));
            }
            renderAgents(d.agents);
            chatEl.innerHTML = '';
            d.history.forEach(m => appendMsg(m));
            chatEl.scrollTop = chatEl.scrollHeight;
        });

        socket.on('agents_update', renderAgents);

        socket.on('meeting:message', msg => {
            if (msg.sender === 'user' && msg.content === lastUserMsg) return;
            if (msg.sender === 'user') lastUserMsg = msg.content;
            appendMsg(msg);
            chatEl.scrollTop = chatEl.scrollHeight;
        });

        socket.on('meeting:stream_start', d => {
            const a = agents.find(x => x.id === d.agentId);
            if (!a) return;
            const div = document.createElement('div');
            div.className = 'message agent';
            div.style.borderLeftColor = a.color;
            div.innerHTML = '<span class="sender-name" style="color:' + a.color + '">' + a.name + (d.fromBuffer ? ' (buffered)' : '') + '</span><span class="content"></span>';
            chatEl.appendChild(div);
            currStreamEl = div.querySelector('.content');
            chatEl.scrollTop = chatEl.scrollHeight;
        });

        socket.on('meeting:stream_chunk', d => {
            if (currStreamEl) { currStreamEl.textContent += d.content; chatEl.scrollTop = chatEl.scrollHeight; }
        });

        socket.on('meeting:stream_end', d => {
            if (!currStreamEl) return;
            const a = agents.find(x => x.id === d.agentId);
            const content = currStreamEl.textContent;
            const acts = document.createElement('div');
            acts.className = 'actions';
            agents.forEach(t => {
                if (t.id !== d.agentId) {
                    const b = document.createElement('button');
                    b.className = 'btn-push';
                    b.innerHTML = '↪ 推給 ' + t.name;
                    b.onclick = () => {
                        socket.emit('meeting:push', { targetAgentId: t.id, sourceName: a.name, content: content, originalQuestion: lastUserMsg });
                        b.textContent = '已推送 ✓';
                        setTimeout(() => { b.innerHTML = '↪ 推給 ' + t.name; }, 2000);
                    };
                    acts.appendChild(b);
                }
            });
            currStreamEl.parentElement.appendChild(acts);
            currStreamEl = null;
        });

        socket.on('meeting:buffer_ready', d => {
            const a = agents.find(x => x.id === d.agentId);
            if (a) logDebug(a.name + ' 回覆已緩衝，等待顯示...');
        });

        socket.on('meeting:error', d => {
            logDebug('Agent error ' + d.agentId + ': ' + d.message);
            appendMsg({ sender: 'system', content: '⚠️ ' + d.agentId + ': ' + d.message });
        });

        function renderAgents(list) {
            agents = list;
            agentsEl.innerHTML = '';
            agents.forEach(a => {
                const el = document.createElement('div');
                el.className = 'agent-toggle' + (selected.has(a.id) ? ' selected' : '');
                el.style.color = selected.has(a.id) ? a.color : 'inherit';
                el.style.borderColor = selected.has(a.id) ? a.color : 'transparent';
                const dotColor = a.status === 'working' ? '#eab308' : a.status === 'offline' ? '#ef4444' : '#22c55e';
                el.innerHTML = '<div class="dot" style="background:' + dotColor + '"></div> ' + a.name;
                el.onclick = () => { if (selected.has(a.id)) selected.delete(a.id); else selected.add(a.id); renderAgents(agents); };
                agentsEl.appendChild(el);
            });
        }

        function appendMsg(msg) {
            const div = document.createElement('div');
            div.className = 'message ' + msg.sender;
            if (msg.sender === 'agent') {
                const a = agents.find(x => x.id === msg.agentId) || { name: msg.name || '?', color: '#ccc' };
                div.style.borderLeftColor = a.color;
                div.innerHTML = '<span class="sender-name" style="color:' + a.color + '">' + a.name + '</span><span class="content"></span>';
                div.querySelector('.content').textContent = msg.content;
            } else if (msg.sender === 'user') {
                const span = document.createElement('span');
                span.className = 'content';
                span.textContent = msg.content;
                div.appendChild(span);
            } else {
                div.textContent = msg.content;
            }
            chatEl.appendChild(div);
        }

        function send() {
            try {
                const txt = inputEl.value.trim();
                if (!txt) return;
                if (selected.size === 0) { alert('請先點選下方 Agent'); return; }

                lastUserMsg = txt;
                appendMsg({ sender: 'user', content: txt });
                chatEl.scrollTop = chatEl.scrollHeight;

                logDebug('Send → ' + Array.from(selected).join(', '));
                socket.emit('meeting:send', { content: txt, targetAgentIds: Array.from(selected) });
                inputEl.value = '';
                inputEl.focus();
            } catch (e) {
                alert('Send Error: ' + e.message);
            }
        }

        btnEl.onclick = send;
        inputEl.addEventListener('keydown', e => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                send();
            }
        });
        inputEl.focus();
    </script>
</body>

</html>
HTML_CONTENT

}

# ==============================================================================
# Step 5: 生成設定檔 (Cloudflare Mode)
# ==============================================================================
generate_configs() {
    log_step "Step 5: 生成設定檔 (Cloudflare Mode)"
    
    # 5.1 Cloudflared Config
    mkdir -p ${BASE_PATH}/cloudflared
    cat > "${BASE_PATH}/cloudflared/config.yml" <<EOF
tunnel: ${CLOUDFLARE_TOKEN}
credentials-file: /etc/cloudflared/cert.json
ingress:
  - hostname: ${PREFIX}-99.${DOMAIN_BASE}
    service: http://127.0.0.1:${PORT_ADMIN}
EOF

    # 5.2 Instance Configs
        if [ $i -eq 0 ]; then SUFFIX="11"; fi
        if [ $i -eq 1 ]; then SUFFIX="22"; fi
        if [ $i -eq 2 ]; then SUFFIX="33"; fi
        PORT=$(echo ${INSTANCES[$i]} | cut -d':' -f2)
        INSTANCE_PATH="${BASE_PATH}/${NAME}"
        mkdir -p "${INSTANCE_PATH}/config" "${INSTANCE_PATH}/state" "${INSTANCE_PATH}/workspace"
        chown -R 1000:1000 "${INSTANCE_PATH}"
        
        TOKEN=$(openssl rand -hex 32)
        INSTANCE_TOKENS[$NAME]=$TOKEN
        
        # Cloudflared Ingress
        echo "  - hostname: ${PREFIX}-${SUFFIX}.${DOMAIN_BASE}" >> "${BASE_PATH}/cloudflared/config.yml"
        echo "    service: http://127.0.0.1:${PORT}" >> "${BASE_PATH}/cloudflared/config.yml"
        
        # openclaw.json
        cat > "${INSTANCE_PATH}/config/openclaw.json" <<JSON
{
  "gateway": {
    "mode": "local",
    "port": ${PORT},
    "bind": "lan",
    "trustedProxies": ["127.0.0.1"],
    "auth": { "mode": "token", "token": "${TOKEN}", "allowTailscale": false },
    "controlUi": { "enabled": true, "allowInsecureAuth": true }
  },
  "agents": { "defaults": { "workspace": "/home/node/.openclaw/workspace" } }
}
JSON
        chown 1000:1000 "${INSTANCE_PATH}/config/openclaw.json"
    done
    
    echo "  - service: http_status:404" >> "${BASE_PATH}/cloudflared/config.yml"

    # 5.3 Docker Compose
    ADMIN_TOKEN=$(openssl rand -hex 16)
    COMPOSE_FILE="${BASE_PATH}/docker-compose.yml"
    
    cat > "${COMPOSE_FILE}" <<EOF
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: ${PREFIX}-cloudflared
    restart: unless-stopped
    command: tunnel run --token ${CLOUDFLARE_TOKEN}
    network_mode: host

  admin-panel:
    image: ghcr.io/kimfull/webvco-aig-mvps-panel--private:latest
    container_name: ${PREFIX}-admin
    restart: unless-stopped
    network_mode: host
    environment:
      - ADMIN_TOKEN=${ADMIN_TOKEN}
      - CONTAINER_PREFIX=${PREFIX}-
      - PORT=${PORT_ADMIN}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ${BASE_PATH}/admin-panel-data:/app/data
      - ${BASE_PATH}/meeting.js:/app/lib/meeting.js:ro
      - ${BASE_PATH}/public/meeting.html:/app/public/meeting.html:ro
    command: >
      sh -c "if ! grep -q 'meeting' /app/server.js; then sed -i '/server.listen/i require(\"./lib/meeting\")(app, io, server);' /app/server.js; fi && node /app/server.js"

EOF

    for i in 0 1 2; do
        NAME="openclaw-$((i+1))"
        PORT=$(echo ${INSTANCES[$i]} | cut -d':' -f2)
        AGENT_NAME="agent-$((i+1))"
        if [ $i -eq 0 ]; then AGENT_NAME="lisa"; fi
        if [ $i -eq 1 ]; then AGENT_NAME="rose"; fi
        
        cat >> "${COMPOSE_FILE}" <<EOF
  ${NAME}:
    build: { context: ., dockerfile: Dockerfile.custom }
    image: openclaw-custom:latest
    container_name: ${PREFIX}-${NAME##*-}
    restart: unless-stopped
    network_mode: host
    environment:
      - AGENT_NAME=${AGENT_NAME}
      - ADMIN_HOST=http://127.0.0.1:${PORT_ADMIN}
      - OPENCLAW_GATEWAY_PORT=${PORT}
      - OPENCLAW_CONFIG_PATH=/home/node/.openclaw/config/openclaw.json
      - OPENCLAW_STATE_DIR=/home/node/.openclaw/state
      - NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE}
      - PATH=/home/linuxbrew/.linuxbrew/bin:\$PATH
    labels:
      - "openclaw.role=agent"
      - "openclaw.name=${AGENT_NAME}"
      - "openclaw.port=${PORT}"
      - "openclaw.token=${INSTANCE_TOKENS[$NAME]}"
    volumes:
      - ${BASE_PATH}/${NAME}:/home/node/.openclaw
      - ${BASE_PATH}/linuxbrew-$((i+1)):/home/linuxbrew
      - ${BASE_PATH}/omr-client.js:/home/node/omr-client.js:ro
    command: sh -c "nohup node /home/node/omr-client.js > /home/node/.openclaw/omr.log 2>&1 & exec docker-entrypoint.sh node openclaw.mjs gateway --allow-unconfigured"

EOF
    done
}

# ==============================================================================
# Main
# ==============================================================================
setup_system
install_docker
install_cloudflared
create_files
generate_configs

# Firewall
ufw allow ${SSH_PORT}/tcp
echo "y" | ufw enable

# Run
cd ${BASE_PATH}
docker compose build
docker compose up -d

log_success "Deployment Complete!"
echo "Admin Panel: https://${PREFIX}-admin.${DOMAIN_BASE}/?token=${ADMIN_TOKEN}"
EOF
