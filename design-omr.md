# OpenClaw Operatives Meeting Room (OMR) - 最终设计文档

**状态**: 准备实作 (2026-02-12)  
**目标**: 建立一个整合在 Admin Panel 内的即时人机协作会议室

---

## 🎯 核心愿景

让 **Human (KimFull)** 与 **Agents (Rose, Lisa)** 在同一个会议室进行平等的对话与协作。

**核心价值**：
1. **即时性** - WebSocket 推播，Human 可随时介入
2. **持久化** - 所有讨论记录在案，知识不流失
3. **简洁性** - 3 人会议室，不需要复杂的频道/Thread 系统

---

## 🏗️ 技术架构

### 1. 服务整合
- **位置**: 直接整合在 `openclaw-admin` (webvco-panel)
- **新增依赖**: `socket.io`, `better-sqlite3`
- **零新容器**: 复用现有的 Node.js 环境

### 2. 网络拓扑

```
KimFull (Browser)
    │ WebSocket (Socket.io)
    ▼
openclaw-admin:18999 (Admin Panel + OMR)
    ▲ RESTful API (curl)
    │
├── openclaw-1 (Lisa 🚀)
├── openclaw-2 (Rose 🌹)
└── openclaw-3

所有容器共享 Docker Network: openclaw_default
Agent 访问方式: http://openclaw-admin:18999
```

### 3. 数据库设计 (SQLite)

**文件位置**: `/app/data/omr.db` (需挂载 Volume 持久化)

```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT NOT NULL,       -- 'kimfull', 'rose', 'lisa', 'system'
    content TEXT NOT NULL,      -- Markdown 格式
    type TEXT DEFAULT 'text',   -- 'text', 'code', 'error', 'log'
    channel_id TEXT DEFAULT 'general',  -- 预留扩充
    reply_to_id INTEGER,        -- 引用回复
    agent_task_id TEXT,         -- OpenClaw Task ID (如果有)
    agent_status TEXT,          -- 'thinking', 'executing', 'done', 'error'
    metadata TEXT,              -- JSON 格式弹性资料
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT
);

CREATE TABLE read_receipts (
    message_id INTEGER NOT NULL,
    reader TEXT NOT NULL,       -- 'kimfull', 'rose', 'lisa'
    read_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (message_id, reader)
);

CREATE INDEX idx_messages_channel ON messages(channel_id);
CREATE INDEX idx_messages_sender ON messages(sender);
CREATE INDEX idx_messages_created ON messages(created_at);
```

---

## 🔌 API 规格

### 1. 发送消息 (Agent → Server)

**Endpoint**: `POST /api/omr/send`

**Headers**:
```
Authorization: Bearer <AGENT_TOKEN_ROSE or AGENT_TOKEN_LISA>
```

**Body**:
```json
{
  "content": "Dockerfile 更新完成，请 Review。",
  "type": "text",
  "agent_task_id": "task-123",
  "agent_status": "done",
  "metadata": {
    "git_commit": "abc1234",
    "file_path": "/app/Dockerfile"
  }
}
```

**Response**:
```json
{
  "success": true,
  "message_id": 105
}
```

**认证逻辑**:
- `sender` 由服务器根据 Token 决定，Agent 无法自己指定
- 防止冒充攻击

---

### 2. 读取历史 (Agent ← Server)

**Endpoint**: `GET /api/omr/history`

**Query Parameters**:
- `limit`: 数量限制 (默认 20)
- `since_id`: 只读取 ID > since_id 的消息

**Response**:
```json
{
  "messages": [
    {
      "id": 102,
      "sender": "kimfull",
      "content": "Rose，改好了吗？",
      "type": "text",
      "created_at": "2026-02-12T08:00:00Z"
    },
    {
      "id": 103,
      "sender": "rose",
      "content": "改好了，已 push。",
      "type": "text",
      "created_at": "2026-02-12T08:01:30Z"
    }
  ]
}
```

---

### 3. Kill Switch (Human Only)

**Endpoint**: `POST /api/omr/kill`

**Headers**:
```
Authorization: Bearer <ADMIN_TOKEN>
```

**Body**:
```json
{
  "target": "rose"  // or "lisa"
}
```

**执行逻辑**:
1. 尝试通过 OpenClaw API 取消任务 (Graceful)
2. 如果失败 (3s timeout)，重启对应容器 (Force Kill)
3. 在 Chatroom 发送系统消息

**权限**: 仅 `ADMIN_TOKEN` 可触发

---

## 🔐 Token 认证系统

**环境变量**:
```bash
ADMIN_TOKEN=xxx123           # KimFull (Human)
AGENT_TOKEN_ROSE=yyy456      # Rose (Builder)
AGENT_TOKEN_LISA=zzz789      # Lisa (Deployer)
```

**身份验证函数**:
```javascript
function identifySender(token) {
  if (token === process.env.ADMIN_TOKEN) return 'kimfull';
  if (token === process.env.AGENT_TOKEN_ROSE) return 'rose';
  if (token === process.env.AGENT_TOKEN_LISA) return 'lisa';
  return null; // 401 Unauthorized
}
```

---

## 📋 实作优先级

| 优先级 | 功能 | 说明 |
|--------|------|------|
| **P0** | 后端 API (send/history) | 核心通讯 |
| **P0** | SQLite 数据库初始化 | 持久化 |
| **P0** | Socket.io 即时推播 | Human 即时接收 |
| **P0** | 前端聊天 UI | React 组件 |
| **P0** | Token 认证 | 安全基础 |
| **P1** | Markdown 渲染 | 代码区块高亮 |
| **P1** | Kill Switch | 紧急终止按钮 |
| **P1** | Read Receipts | 已读追踪 |
| **P2** | System Log 转发 | Watchtower 等系统事件自动推送 |

---

## 🚫 决定不做的功能

| 功能 | 理由 |
|------|------|
| Redis | SQLite 足够，减少维护负担 |
| 多频道系统 | 3 人不需要分频道 |
| Thread 回复 (嵌套) | MVP 保持简单，reply_to_id 已足够 |
| Thinking 状态心跳 | Agent 执行模型复杂，MVP 不做 |

---

## 📦 交付清单

### Backend (webvco-panel)
- [ ] `package.json` 新增依赖
- [ ] `server.js` 整合 Socket.io
- [ ] `/api/omr/send` 实作
- [ ] `/api/omr/history` 实作
- [ ] `/api/omr/kill` 实作
- [ ] SQLite 数据库初始化逻辑
- [ ] Token 认证中间件

### Frontend (React)
- [ ] `/omr` 页面组件
- [ ] MessageList 组件
- [ ] MessageInput 组件
- [ ] Socket.io 客户端连接
- [ ] Kill Switch UI

### Agent Tool
- [ ] `omr_send.sh` (Rose/Lisa 用的 curl 封装)
- [ ] System Prompt 更新 (告知 OMR 存在)

### Deployment
- [ ] `docker-compose.yml` 挂载 Volume `/app/data`
- [ ] 环境变量配置 (3 组 Token)

---

## 🧪 测试计划

1. **连通性测试**: Agent 容器能否 curl 到 Admin Panel
2. **认证测试**: 错误的 Token 是否被拒绝
3. **即时性测试**: Human 发送消息，Agent 5 秒内能读取到
4. **Kill Switch 测试**: 按下按钮后，Agent 任务是否终止

---

**负责分工**:
- **Rose (Dev)**: 修改 webvco-panel 代码
- **Lisa (Ops)**: 更新 docker-compose.yml 并部署
- **KimFull (Owner)**: 测试与验收

---

*文档版本: v1.0*  
*最后更新: 2026-02-12*
