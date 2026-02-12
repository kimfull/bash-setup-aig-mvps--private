# Cloudflare Tunnel 方案討論總結 (2026-02-12)

狀態：**待討論** — 尚未執行

---

## 背景

目前 `ai-agent.sh` 使用 **Tailscale** 作為遠端存取方案。
討論是否改用 **Cloudflare Tunnel** 以更適合 SaaS/IaaS 大規模交付場景。

## 結論：採用 Cloudflare Tunnel（不啟用 Zero Trust Access）

### 為什麼換？

| 痛點 | Tailscale | Cloudflare Tunnel |
|------|----------|-------------------|
| 客戶需安裝軟體 | ✅ 要裝 Client | ❌ 不用，瀏覽器即可 |
| Auth Key 過期 | 90 天 | Tunnel Token 不過期 |
| DDoS / WAF 防護 | ❌ 無 | ✅ 自帶 |
| 自訂域名 | ❌ 醜（xxx.ts.net）| ✅ 可用自有域名 |
| 客戶 Onboarding | 複雜（教裝 Tailscale）| 簡單（給 URL + Token）|

### 50 人限制的問題

- Cloudflare **Zero Trust Access** 免費版限 50 Seats（$7/user/month 超過後）
- **解法：不啟用 Access**，改用 OpenClaw 自身的 Token Auth 作為認證層
- Cloudflare Tunnel 本身**免費無限制**，WAF/DDoS 防護照樣生效
- 等客戶數量 50+ 且有營收後，再考慮加購 Access 強化安全

### 安全架構

```
客戶瀏覽器
    │
    ▼ (HTTPS, Cloudflare CDN Edge — WAF/DDoS 防護)
Cloudflare Tunnel (加密通道，VPS 無需開放任何入站端口)
    │
    ▼
VPS 內部 127.0.0.1
    ├── :18111 → openclaw-1  (Token Auth)
    ├── :18222 → openclaw-2  (Token Auth)
    ├── :18333 → openclaw-3  (Token Auth)
    └── :18999 → admin-panel (Token Auth)
```

安全層：
1. **Cloudflare WAF**：擋 SQLi / XSS / Bot
2. **Cloudflare DDoS**：L3/L4/L7 防護
3. **無公開端口**：VPS 的 UFW 只開 SSH，所有流量走 Tunnel
4. **OpenClaw Token Auth**：應用層認證

## 對 ai-agent.sh 的改動規劃

### 新增 `--mode` 參數

```bash
bash ai-agent.sh --mode tailscale --tailscale-key tskey-xxx
bash ai-agent.sh --mode cloudflare --tunnel-token ey-xxx
```

### 受影響的 Steps

| Step | Tailscale 模式（保留） | Cloudflare 模式（新增） |
|------|----------------------|----------------------|
| 3 | 安裝 Tailscale + auth key | 安裝 cloudflared + tunnel token |
| 9 | tailscale serve 設定 HTTPS | cloudflared 路由 + DNS CNAME |
| 其餘 | 完全相同 | 完全相同 |

### Cloudflare 模式前置需求

1. 一個**託管在 Cloudflare 的域名**
2. 在 Cloudflare Dashboard 建立 **Tunnel**，取得 **Tunnel Token**
3. 決定子網域命名規則（如 `c001-1.saas-domain.com`）

### 保留 Tailscale 作為 fallback

- 適用於金融/機密客戶，不願流量經第三方解密
- 兩種模式並存，透過 `--mode` 切換

## 分階段規劃

1. **Phase 1（現在）**：穩定 Tailscale 版本，完成當前交付
2. **Phase 2（下次）**：新增 Cloudflare 模式，測試穩定後切為預設
3. **Phase 3（50+ 客戶後）**：評估是否加購 Cloudflare Zero Trust Access
