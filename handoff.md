# Handoff — DiskAudit 維護（PR #1–#4 已合併、Docker 清理完成；更新：2026-11-13）

▶ 回來第一個動作：先請使用者用**瀏覽器（最好手機／無痕視窗）**確認 `https://cjw9223233.github.io/DiskAudit/` 打得開（Claude 這台機器連不到 github.io，無法代驗），並確認登出狀態也看得到。（CI 已確認全綠，不必再問。）之後依 `BACKLOG.md` 的 P2 做：先「CLAUDE.md 瘦身」，再「以 `-OutDir C:\DiskAuditReports` 實掃 `D:\`」。若要再啟動 Docker，先照 §6 在 WSL 內刪三個殘留 socket。規則見 `CLAUDE.md`。

## 1. 目標
維護 DiskAudit（Windows 磁碟容量稽核＋分級清理工具）：先驗證 CI／Pages 在 GitHub 上實際可用，再做 BACKLOG 的瘦身與實掃項目。

## 2. 已完成
- DiskAudit v1.0.0 合併版；本機測試 75/75；`CLAUDE.md`；README；`docs/` 內教學文件（本專案版、通用 HTML、文件分層指南）；`handoff.md`／`BACKLOG.md`。
- GitHub（private `cjw9223233/DiskAudit`）：**PR #1**（CLAUDE.md＋CI `test.yml`）、**#2**（Pages `pages.yml`）、**#3**（`-OutDir` 衝突時錯誤訊息附可複製的建議指令）、**#4**（handoff／BACKLOG／指南）全部 squash 合併。遠端與本機都只剩 `master`。
- **CI 全綠**：GitHub Actions 的 10 次執行（`test` 在 windows-latest 含 PR #3、#4 與 master 推送，`pages` 2 次）全部成功；單次 `test` 約 20–30 秒（比本機快，BACKLOG 有一條要抽看日誌確認 75 項真的執行）。
- **Pages 部署成功**：`pages.yml` 在 #4 合併後執行，log 顯示 `Reported success!`，網址 `https://cjw9223233.github.io/DiskAudit/`（首頁為 `claude-dev-workflow-guide.html`）。**尚未實際驗證可見**：從 Claude 的機器連 github.io 的 443 失敗（`github.com` 正常，推測網路擋了 Pages IP）。
- **C 槽 Docker vhdx 清理完成（11/13）**：`docker_data.vhdx` 21.73 GB → 8.60 GB，C: 可用 84.3 → 97.4 GB；Docker 29.4.0 驗證可啟動、7 個 volume 全在。做法與決定見 §5、§6。
- Actions 警告：`checkout@v4`、`configure-pages@v5`、`deploy-pages@v4`、`upload-artifact@v4` 被強制改用 Node 24（Node 20 棄用），目前沒有失敗。

## 3. 下一步
1. 使用者回報：網站在瀏覽器／手機打不打得開、登出狀態是否也看得到（私有 repo 的 Pages 通常公開）。
2. `BACKLOG.md` P2：CLAUDE.md 瘦身 → 實掃 `D:\`（`-OutDir C:\DiskAuditReports`）→ 管理員重掃 `C:\`（加 `-WinSxS`）。
3. 使用者決定：孤兒 Docker volume `8d16b1c8…`（約 1.47 GB）、`D:\Backup\docker` 備份與 `settings-store.json.bak-20261113`、舊資料夾 `D:\Tools\DiskAudit-v2`／`D:\Tools\DiskAudit-orig-backup` 何時清掉（不要自動刪）。

## 4. 位置與分支
- 專案 repo：`D:\Tools\DiskAudit`；分支只有 `master`（含 #1–#4）；本次更新在 `docs/handoff-refresh`（未 commit）。
- 其他資料夾：`D:\Tools\DiskAudit-v2`（開發期資料夾，另含首次 C 槽報表）、`D:\Tools\DiskAudit-orig-backup`（整合前備份）、`D:\Backup\docker\`（Docker vhdx 備份 `docker_data.vhdx.bak-20261112`，SHA256 開頭 `263C73E4`；另有 `compact-docker.txt`）。

## 5. 已做的決定
- Docker：K8s／kind 殘留、自己的映像、兩個使用者容器全部刪除；volumes 不動；`UseContainerdSnapshotter` 維持 `false`（設定檔備份 `settings-store.json.bak-20261113`）。
- `-OutDir` 與掃描範圍衝突：維持現狀，只讓錯誤訊息附建議指令（已合併）。
- 流程：commit／push 由使用者核准；新工作開新分支；PR 用 squash 合併，**程式碼 PR 先、文件 PR 後**（handoff 反映最終狀態）。

## 6. 試過但行不通／重要發現
- **每次 Docker 停止後，三個 0 byte 的 AF_UNIX 殘留檔都會留下**，下次啟動報 `Inference manager`／`Secrets Engine … The file cannot be accessed by the system`。PowerShell／`del`／fsutil 刪不掉（error 1920），**在 WSL 內刪除有效**：
  `wsl -d Ubuntu-22.04 -- rm -v /mnt/c/Users/cjw/AppData/Local/docker-secrets-engine/engine.sock /mnt/c/Users/cjw/AppData/Local/Docker/run/dockerInference /mnt/c/Users/cjw/AppData/Local/Docker/run/userAnalyticsOtlpHttp.sock`
  （刪前確認 Docker 沒在跑；只刪這三個 0 byte 檔；用 `docker desktop start/stop` 啟停。）
- 「Windows 更新待重開機」的推測已被推翻。
- `docker system df` 顯示 0 映像不代表空：`UseContainerdSnapshotter` 切換會藏起另一個映像庫；盤點前看 `docker info` 的 Storage Driver 與資料碟實際使用量（`wsl -d docker-desktop -- df -h /mnt/docker-desktop-disk`）。
- `diskpart compact vdisk` 有效；`Optimize-VHD` 不可用（無 Hyper-V 模組）；`wsl --manage --set-sparse` 不採用。
- PowerShell 管線傳腳本給 `wsl … sh -s` 會帶 BOM 失敗；改寫成無 BOM 檔後用 `cmd /c "wsl … sh -s < 檔案"`。
- 這台機器連不到 `*.github.io`（`github.com` 正常），驗證 Pages 要靠使用者的瀏覽器。

## 7. 注意事項
- Claude 不能提權：需要系統管理員的步驟（如 diskpart）由使用者執行。
- Docker 錯誤視窗的 **Reset to factory defaults 會清掉全部 Docker 資料**，勿點。
- 已刪的 `sps-worklog` 容器資料在主機 `D:\Downloads\SPS重置案\deploy\{app,data,public}`（未受影響）；原為 compose 建立、`php:8.1-apache`、埠 8090→80，要用時重新 pull 並重建。
- 此檔含本機路徑；`handoff.md` 已隨 PR 進入 private repo，若要推到其他遠端，先依 `docs/文件分層使用指南.md` §3 檢視敏感度。
