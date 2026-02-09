目標：
我們的目標是完成一個可以在全新的 ubuntu Server 24.04 VPS 上自動安裝openclaw lastest的sh檔。
我們將遠端操作這台VPS，所以要確保openclaw的權限設定能透過遠端操作（webbase/ssh）來完成。
我們將直接用root身份來進行操作，以利~/ai-agent.sh檔的完成。


VPS 規格：
- CPU：4 cores
- RAM：8 GB
- Swap：8 GB (腳本需自動建立，並設定 swappiness=20)

資源限制 (每個實例)：
- CPU：保留 1 core，最多 3 cores
    - Docker 參數：--cpus=3
- RAM：保留 2 GB，最多 4 GB
    - Docker 參數：--memory=4g --memory-reservation=2048m

資源分配總覽：
| 資源 | 每實例保留 | 每實例上限 | 3實例保留 | 系統預留 |
|------|-----------|-----------|----------|---------|
| CPU  | 1 core    | 3 cores   | 3 cores  | 1 core  |
| RAM  | 2 GB      | 4 GB      | 6 GB     | 2 GB    |


sh檔案 的功能及架構等說明：
- 在 Ubuntu 24.04 Server 上自動安裝 Docker 並建置三個完全隔離的openclaw實例。
- 每個實例將使用不同的容器名稱及端口，以確保隔離：
    - ~/openclaw-1   :18111
    - ~/openclaw-2   :18222
    - ~/openclaw-3   :18333
- 每個實例將使用不同的數據存儲路徑，以確保隔離（詳見下方目錄結構規範）。

目錄結構規範：
- 統一基礎路徑：/opt/openclaw (符合 Linux FHS 標準，且方便整機備份)
- 實例結構：
    - /opt/openclaw/openclaw-1/config/openclaw.json (設定檔)
    - /opt/openclaw/openclaw-1/state/             (狀態 sessions)
    - /opt/openclaw/openclaw-1/workspace/         (記憶 memories)
- 備份策略：直接備份 /opt/openclaw 目錄即可包含所有實例資料
- 每個實例將使用不同的 token，以確保隔離。
- 每個實例將使用不同的環境變數，以確保隔離。

- 每個實例需要能從外部存取。相關port需要 ufw allow。


多實例隔離規範 (根據官方文件)：
- 每個實例需要獨立的環境變數：
    - OPENCLAW_CONFIG_PATH：設定檔路徑 (例如 ~/.openclaw-1/openclaw.json)
    - OPENCLAW_STATE_DIR：狀態目錄，存放 sessions/credentials
    - OPENCLAW_GATEWAY_PORT：端口號 (或用 --port 參數)
    - agents.defaults.workspace：memories 存放路徑

端口設定優先順序 (由高到低)：
1. --port 命令行參數
2. OPENCLAW_GATEWAY_PORT 環境變數
3. gateway.port 設定檔

腳本設計建議：
- 使用陣列定義實例配置，預設 3 個實例
- 使用迴圈處理，方便未來擴展
- 範例架構：
    INSTANCES=("openclaw-1:18188" "openclaw-2:18288" "openclaw-3:18388")
    for instance in "${INSTANCES[@]}"; do
        NAME=$(echo $instance | cut -d':' -f1)
        PORT=$(echo $instance | cut -d':' -f2)
        # 建立容器、設定 ufw、設定環境變數等
    done


Docker 容器設定：
- 重啟策略：--restart=unless-stopped (VPS 重開後自動啟動)
- 日誌輪替：--log-opt max-size=30m --log-opt max-file=10
- 時區：-e TZ=Asia/Taipei

Token 生成：
- 自動產生強密碼 Token (例如使用 openssl 或類似工具)
- 將生成的 Token 顯示在腳本執行結束後的摘要報告中，方便使用者複製
- Token 必須寫入 ~/.openclaw-N/openclaw.json 設定檔中，確保容器重啟後驗證機制不變

驗證安裝成功：
- 每個實例建立後，執行健康檢查
- 檢查方式：curl -s -o /dev/null -w "%{http_code}" http://localhost:PORT/
- 預期回傳：200 或相關成功狀態碼
- 若失敗，顯示錯誤訊息並記錄到日誌

錯誤處理：
- 腳本開頭加入：set -e (遇錯即停)
- 每個關鍵步驟加入錯誤檢查和提示訊息
- 錯誤時顯示失敗的步驟和可能原因

前置檢查：
- 確認是 root 使用者 (id -u 應為 0)
- 確認是 Ubuntu 24.04 (lsb_release -rs)
- 確認磁碟空間足夠 (至少 10GB 可用)
- 確認 Docker 未安裝 (避免重複安裝) 或已安裝則跳過

更新機制：
- 未來更新 OpenClaw 時，可執行 docker pull 獲取最新映像
- 然後 docker stop / docker rm / docker run 重建容器
- 數據存儲在主機目錄，不會因重建容器而遺失

安全加固 (可選)：
- fail2ban 防暴力破解
- 定期系統安全更新 (unattended-upgrades)

安裝完成後輸出摘要：
- 顯示每個實例的名稱、端口、Token、以及數據路徑
- 顯示防火牆開放狀態
- 顯示如何查看日誌的指令範例 (例如 docker logs openclaw-1)
- 顯示如何手動停止/重啟的指令範例


你必須不斷地嘗試直到上述任務完成為止。你必須常常更新ai-agent.sh檔。sh檔必須保持最新狀態。


**每次有關於openclaw的操作，請先參考：
https://github.com/openclaw/openclaw
以及
https://docs.openclaw.ai/
**

若收到指示“參考官方”時，請依照這兩個網站。


- 討論模式：「討論討論」= 僅規劃不執行；「goo」= 開始執行。
- Git 指令 (giiit)：
    - 收到 giiit 指令才進行 commit & push。
    - Commit 格式：標題 < 50 字元。內容每一行 < 70 字元，每一行前面加 '- '，每一行都要斷行。
    - 流程：一般的 git add / git commit / git push 或讀取行為請直接執行 (Always Proceed)；Force push 或類似刪除行為才會詢問。



---

## 實作備註 (2026-02-05 更新)

以下是在實作過程中發現的重要技術細節：

### OpenClaw 設定檔必要欄位

根據官方文檔，openclaw.json 必須包含：

```json
{
  "gateway": {
    "mode": "local",        // 必填！否則 Gateway 不會啟動
    "port": 18111,
    "bind": "lan",          // Docker 容器內必須用 "lan" 才能讓外部存取
    "auth": {
      "mode": "token",
      "token": "..."
    }
  },
  "agents": {
    "defaults": {
      "workspace": "/home/node/.openclaw/workspace",
      "userTimezone": "Asia/Taipei"
    }
  }
}
```

### Docker 環境變數

容器需要設定以下環境變數以支援多實例隔離：
- `OPENCLAW_CONFIG_PATH`: 設定檔完整路徑
- `OPENCLAW_STATE_DIR`: 狀態目錄路徑
- `OPENCLAW_GATEWAY_PORT`: 端口號
- `TZ`: 時區

### Volume 掛載

使用單一掛載點簡化配置：
```bash
-v /opt/openclaw/openclaw-1:/home/node/.openclaw
```

這會自動包含 config/, state/, workspace/ 等子目錄。

### 容器內部使用者

OpenClaw 容器以 `node` 使用者 (UID 1000) 運行，因此：
- 主機目錄需 `chown -R 1000:1000`
- 掛載路徑為 `/home/node/.openclaw` (非 /root)

### 健康檢查

- 使用 `127.0.0.1` 而非 `localhost` 避免 IPv6 解析問題
- 預期回應碼：200, 401, 403 都算正常

### 官方文檔參考

- 多實例隔離：https://docs.openclaw.ai/gateway/configuration#multi-instance-isolation
- Gateway 設定：https://docs.openclaw.ai/gateway/configuration#gateway-gateway-server-mode-+-bind

### 外部存取 Control UI

由於 OpenClaw Control UI 需要「安全上下文」(Secure Context)，從外部 HTTP 存取時需要：

1. 設定檔增加：
```json
{
  "gateway": {
    "controlUi": {
      "allowInsecureAuth": true,
      "dangerouslyDisableDeviceAuth": true
    }
  }
}
```

2. 使用帶 token 參數的 URL 存取：
```
http://<VPS-IP>:<PORT>/?token=<TOKEN>
```

Token 會自動儲存在瀏覽器 localStorage，後續存取不需再帶參數。
