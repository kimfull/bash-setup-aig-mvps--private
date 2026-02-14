docker exec -it realvco-oc-1 node dist/index.js onboard
docker exec -it realvco-oc-2 node dist/index.js onboard
docker exec -it realvco-oc-3 node dist/index.js onboard




# 角色對應表
# realvco-oc-1 (Lisa)    :18801
# realvco-oc-2 (Rose)    :18802
# realvco-oc-3 (Jennie)  :18803

# 進入容器的指令：
bash
docker exec -it realvco-oc-1 /bin/sh



bash
# 執行 onboard 精靈
docker exec -it realvco-oc-1 node dist/index.js onboard
# 執行 configure 精靈
docker exec -it realvco-oc-1 node dist/index.js configure
# 查看設定
docker exec -it realvco-oc-1 node dist/index.js config get
# 查看狀態
docker exec -it realvco-oc-1 node dist/index.js gateway status


# 寫入 telegram
docker exec realvco-oc-1 node dist/index.js pairing approve telegram G8CSUAE4





{
  "auth": {
    "profiles": {
      "anthropic:main": {
        "provider": "anthropic",
        "mode": "api_key",
        "apiKey": "sk-ant-api03-xxxx"
      },
      "openai:main": {
        "provider": "openai",
        "mode": "api_key",
        "apiKey": "sk-proj-xxxx"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-5",
        "fallbacks": ["openai/gpt-4o"]
      }
    }
  }
}


---

## 常用指令 (從 ai-agent.sh 摘錄)

### 容器狀態管理

```bash
# 查看容器狀態
docker ps

# 查看日誌
docker logs realvco-oc-1
docker logs realvco-oc-2
docker logs realvco-oc-3

# 停止容器
docker stop realvco-oc-1

# 重啟容器
docker restart realvco-oc-1

# 進入容器
docker exec -it realvco-oc-1 /bin/sh
```

### OpenClaw CLI (在容器內執行)

```bash
# 設定精靈
docker exec -it realvco-oc-1 node dist/index.js onboard

# 進階設定
docker exec -it realvco-oc-1 node dist/index.js configure

# 查看設定
docker exec realvco-oc-1 node dist/index.js config get

# 列出模型
docker exec realvco-oc-1 node dist/index.js models list

# 查看 Gateway 狀態
docker exec realvco-oc-1 node dist/index.js gateway status
```

### 設定 API Key (範例)

```bash
# Anthropic API Key
docker exec realvco-oc-1 node dist/index.js config set auth.profiles.anthropic:main.provider "anthropic"
docker exec realvco-oc-1 node dist/index.js config set auth.profiles.anthropic:main.mode "api_key"
docker exec realvco-oc-1 node dist/index.js config set auth.profiles.anthropic:main.apiKey "sk-ant-xxx"

# 設定預設模型
docker exec realvco-oc-1 node dist/index.js config set agents.defaults.model "anthropic/claude-sonnet-4-5"
```

### Telegram 配對

```bash
docker exec realvco-oc-1 node dist/index.js pairing approve telegram <配對碼>
```

### 更新容器

```bash
# 拉取最新映像
docker pull ghcr.io/openclaw/openclaw:latest

# 停止並移除舊容器
docker stop realvco-oc-1 && docker rm realvco-oc-1

# 重新運行容器 (使用原本的 docker run 指令)
```

### 備份

```bash
# 備份整個 /opt/openclaw 目錄即可包含所有實例資料
tar -czvf openclaw-backup-$(date +%Y%m%d).tar.gz /opt/openclaw
```

---

## 目錄結構

```
/opt/openclaw/
├── realvco-oc-1/
│   ├── config/openclaw.json    # 設定檔
│   ├── state/                  # 狀態 sessions
│   └── workspace/              # 記憶 memories
├── realvco-oc-2/
│   └── ...
├── realvco-oc-3/
│   └── ...
└── install-summary.txt         # 安裝摘要 (含 Token)
```

---

## 存取網址格式

```
http://<VPS-IP>:18801/?token=<TOKEN>
http://<VPS-IP>:18802/?token=<TOKEN>
http://<VPS-IP>:18803/?token=<TOKEN>
```

Token 會自動儲存在瀏覽器 localStorage，後續存取不需再帶參數。