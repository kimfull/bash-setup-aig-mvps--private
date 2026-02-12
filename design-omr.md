# 🌹 OpenClaw Operatives Meeting Room (OMR) - 最終設計 v3

## 核心體驗：Agent 即時指揮中心

一個整合於 Admin Panel 的協作空間，讓 **KimFull (Human)** 主人可以與 **所有的docker裡的openclaw**對話討論，並接收即時回報。

## 🎯 關鍵設計：Wake-up Console

在輸入框下方提供 Agent 喚醒按鈕，實現精準指揮。

- **[🟢 Rose (ocd-2)]**：點亮時，訊息將透過 API 喚醒 Rose 並開始執行任務。
- **[⚪ Lisa (ocd-1)]**：熄滅時，Lisa 保持休眠，不消耗 Token。
- **多選與廣播**：同時點亮多個 Agent，大家一起開會。

## 🏗️ 技術架構 (Updated)

### 服務組件
- **Host**: `openclaw-admin` (Node.js Express)
- **Realtime**: Socket.io (Human Interface)
- **API**: RESTful API (Agent Interface)
- **Database**: SQLite (`omr.db` persistent in `/app/data`)
- **Network**: Docker Network `openclaw_default` (Internal Trust Zone)

### 身份驗證策略 (Hybrid Auth)
1.  **Human (KimFull)**:
    - **Method**: HttpOnly Cookie (`ocadmin_session`)
    - **Access**: WebSocket + Admin API (`/api/omr/kill`)
    - **Security**: 依賴瀏覽器自动带 Cookie，并在 Server 端验证 Hash。
2.  **Agent (Rose/Lisa)**:
    - **Method**: Header Trust (`X-Agent-ID`)
    - **Access**: Agent API (`/api/omr/send`, `/api/omr/history`)
    - **Security**: 僅允許 Docker 內部網路存取，由 Middleware 豁免驗證。

### API 規格
1.  **Agent Speak**: `POST /api/omr/send`
    - Header: `X-Agent-ID: rose`
    - Body: `{"content": "...", "type": "text"}`
2.  **Agent Listen**: `GET /api/omr/history`
    - Header: `X-Agent-ID: rose`
    - Returns: JSON list of messages
3.  **Agent Wake-up (Internal)**:
    - Admin Panel 收到 Human 指令後，透過 Webhook 呼叫 OpenClaw API 喚醒 Agent。

### 資料庫 Schema
```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT NOT NULL,       -- 'kimfull', 'rose', 'lisa', 'system'
    content TEXT NOT NULL,      -- Markdown
    type TEXT DEFAULT 'text',   -- 'text', 'code', 'error'
    metadata TEXT,              -- JSON { task_id: 123 }
    created_at TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
```

## 🛠️ 實作狀態 & 已知挑戰

### 已完成 (Phase 1)
- [x] Backend API (Send/History) 實作
- [x] 資料庫持久化配置 (`/opt/openclaw/admin-panel-data`)
- [x] 認證邏輯修正 (Header Trust for Agents)

### 待解決挑戰
1.  **前端 Cookie 存取**：HttpOnly Cookie 導致前端 JS 無法讀取 Token，需依賴純 Cookie 驗證。
2.  **Socket.io Auth**：需修改 Server 端邏輯以支援從 Handshake 解析 Cookie。
3.  **穩定性**：自製聊天室維護成本高，考慮轉向成熟開源方案。

## � 未來替代方案建議 (Evaluation)

如果自製 OMR 維護成本過高，建議評估以下開源替代品：

1.  **Gitea (Forgejo)**:
    - **優點**: Issue = Thread，代碼與討論合一，API 完善。
    - **缺點**: 非即時聊天 (需輪詢)。
2.  **VoceChat**:
    - **優點**: 極輕量 (Rust)，專為嵌入式聊天設計，支援 Bot/Webhook。
    - **缺點**: 需額外容器。
3.  **Memos**:
    - **優點**: 筆記流形式，適合非同步回報。
    - **缺點**: 互動性較弱。

---
**Next Step**: 決定繼續修復自製 OMR 的前端 Cookie 問題，或轉向 VoceChat / Gitea 方案。
