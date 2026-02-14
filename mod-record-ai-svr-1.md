# VPS 資源修改記錄

## 2026-02-10 08:30 (Asia/Taipei)

### Docker 容器資源調整

透過 `docker update` 即時修改，未變更 bashhh 腳本。

| 容器 | CPU 保留 (shares) | CPU 上限 (cpus) | RAM 保留 | RAM 上限 |
|------|-------------------|-----------------|----------|----------|
| **realvco-oc-1** Lisa   | 0.5 core (512) | 1.5 cores | 1 GB | 3 GB |
| **realvco-oc-2** Rose   | 2 cores (2048) | 3.5 cores | 4 GB | 6 GB |
| **realvco-oc-3** Jennie | 0.5 core (512) | 1.5 cores | 1 GB | 3 GB |

**系統資源：** 4 cores / 8 GB RAM + 8 GB Swap = 16 GB

**合計上限：** CPU 6.5 cores (共享 4 cores) / RAM 12 GB (8 RAM + 4 Swap)

**指令：**
```bash
docker update --cpus=1.5 --cpu-shares=512 --memory=3g --memory-reservation=1g realvco-oc-1
docker update --cpus=3.5 --cpu-shares=2048 --memory=6g --memory-reservation=4g realvco-oc-2
docker update --cpus=1.5 --cpu-shares=512 --memory=3g --memory-reservation=1g realvco-oc-3
```

**備註：**
- CPU shares 為競爭時的比例分配 (512:2048:512 = 1:4:1)
- `docker update` 即時生效，容器重啟後仍保留設定
- NODE_OPTIONS=--max-old-space-size=1536 維持不變（防 OOM）
