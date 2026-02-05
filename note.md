docker exec -it openclaw-1 node dist/index.js onboard
docker exec -it openclaw-2 node dist/index.js onboard
docker exec -it openclaw-3 node dist/index.js onboard





# 進入容器的指令：
bash
docker exec -it openclaw-1 /bin/sh



bash
# 執行 onboard 精靈
docker exec -it openclaw-1 node dist/index.js onboard
# 執行 configure 精靈
docker exec -it openclaw-1 node dist/index.js configure
# 查看設定
docker exec -it openclaw-1 node dist/index.js config get
# 查看狀態
docker exec -it openclaw-1 node dist/index.js gateway status


# 寫入 telegram
docker exec openclaw-1 node dist/index.js pairing approve telegram G8CSUAE4








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