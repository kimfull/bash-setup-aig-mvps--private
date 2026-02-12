#!/bin/bash
# OMR 快速部署脚本
# 用途：在现有的 OpenClaw 环境中部署 Meeting Room 功能

set -e

echo "========================================="
echo "  OMR (Meeting Room) Deployment Script"
echo "========================================="
echo ""

# 1. 生成 Token
echo "[1/5] Generating Tokens..."
ADMIN_TOKEN=$(openssl rand -hex 16)
AGENT_TOKEN_ROSE=$(openssl rand -hex 16)
AGENT_TOKEN_LISA=$(openssl rand -hex 16)

echo "✅ Tokens generated:"
echo "  ADMIN_TOKEN=$ADMIN_TOKEN"
echo "  AGENT_TOKEN_ROSE=$AGENT_TOKEN_ROSE"
echo "  AGENT_TOKEN_LISA=$AGENT_TOKEN_LISA"
echo ""

# 2. 创建数据目录
echo "[2/5] Creating data directory..."
mkdir -p /opt/openclaw/admin-panel-data
chmod 777 /opt/openclaw/admin-panel-data
echo "✅ Data directory created: /opt/openclaw/admin-panel-data"
echo ""

# 3. 更新 docker-compose.yml (备份原文件)
echo "[3/5] Updating docker-compose.yml..."
cd /opt/openclaw

if [ ! -f "docker-compose.yml.backup" ]; then
    cp docker-compose.yml docker-compose.yml.backup
    echo "✅ Backup created: docker-compose.yml.backup"
fi

# 检查 openclaw-admin 服务是否已配置 volumes 和 environment
if ! grep -q "admin-panel-data:/app/data" docker-compose.yml; then
    echo "⚠️  需要手动更新 docker-compose.yml"
    echo ""
    echo "请在 openclaw-admin 服务中添加："
    echo ""
    echo "  openclaw-admin:"
    echo "    volumes:"
    echo "      - /var/run/docker.sock:/var/run/docker.sock:ro"
    echo "      - ./admin-panel-data:/app/data          # ← 添加这行"
    echo "    environment:"
    echo "      - ADMIN_TOKEN=$ADMIN_TOKEN              # ← 添加这行"
    echo "      - AGENT_TOKEN_ROSE=$AGENT_TOKEN_ROSE    # ← 添加这行"
    echo "      - AGENT_TOKEN_LISA=$AGENT_TOKEN_LISA    # ← 添加这行"
    echo ""
else
    echo "✅ docker-compose.yml already configured"
fi
echo ""

# 4. 重新构建 Admin Panel
echo "[4/5] Rebuilding Admin Panel..."
docker compose build openclaw-admin --no-cache || echo "⚠️  Build failed, please check manually"
echo ""

# 5. 重启服务
echo "[5/5] Restarting Admin Panel..."
docker compose down openclaw-admin
docker compose up -d openclaw-admin
echo "✅ Admin Panel restarted"
echo ""

# 检查容器状态
echo "Checking container status..."
sleep 3
docker ps | grep openclaw-admin || echo "⚠️  Container not running!"
echo ""

# 显示访问信息
echo "========================================="
echo "  OMR Deployment Complete!"
echo "========================================="
echo ""
echo "📝 保存以下 Token (重要!)："
echo ""
echo "export ADMIN_TOKEN='$ADMIN_TOKEN'"
echo "export AGENT_TOKEN_ROSE='$AGENT_TOKEN_ROSE'"
echo "export AGENT_TOKEN_LISA='$AGENT_TOKEN_LISA'"
echo ""
echo "🌐 访问 Meeting Room:"
echo "  https://YOUR_TAILSCALE_HOSTNAME:18999/?token=$ADMIN_TOKEN"
echo "  然后点击顶部的 '🌹 Meeting Room' 按钮"
echo ""
echo "🧪 测试 API (从 openclaw-2 容器内):"
echo "  docker exec openclaw-2 curl -X POST http://openclaw-admin:18999/api/omr/send \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -H 'Authorization: Bearer $AGENT_TOKEN_ROSE' \\"
echo "    -d '{\"content\":\"Hello from Rose!\"}'"
echo ""
echo "📋 查看日志:"
echo "  docker logs -f openclaw-admin"
echo ""
