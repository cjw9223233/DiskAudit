# Handoff — DiskAudit 維護（Docker vhdx 清理已完成；更新：2026-11-13）

▶ 回來第一個動作：先請使用者 commit 並推送本分支 `docs/handoff-backlog`（handoff／BACKLOG／指南），再處理 `BACKLOG.md` 的 P2：合併或關閉 `ci/github-pages`、推送並開 PR `fix/outdir-error-hint`。**Docker 啟動前若報 `Inference manager`／`Secrets Engine` 錯誤，先照 §6 在 WSL 內刪三個殘留 socket。**規則見 `CLAUDE.md`。

## 1. 目標
維護 DiskAudit（Windows 磁碟容量稽核＋分級清理工具）：先把還沒合併的分支與 CI／Pages 收尾，再做 BACKLOG 的實掃與瘦身項目。

## 2. 已完成
- DiskAudit v1.0.0 合併版；測試 75/75；`CLAUDE.md`；CI `test.yml` 隨 PR #1 已合併；教學文件三份在 `docs/`。
- **C 槽 Docker vhdx 清理完成（2026-11-13）**：`docker_data.vhdx` **21.73 GB → 8.60 GB**，C: 可用 **84.3 GB → 97.4 GB**（+13.1 GB）。做法：先備份 → 修正 containerd 映像庫旗標讓舊庫可見 → 依使用者決定刪除全部容器（含 K8s／kind、`sps-worklog`、`priceless_saha`）、全部映像、build cache（內部使用量 15.1 → 5.6 GB）→ Quit Docker + `wsl --shutdown` → 使用者以系統管理員執行 `diskpart compact vdisk`。
- **驗證通過**：Docker 29.4.0 可啟動、`overlay2`、7 個 volume 全在（2.246 GB）、`docker run --rm hello-world` 成功（測試映像已刪）。目前 Docker Desktop **正在執行**。

## 3. 下一步
1. 使用者 commit 並推送 `docs/handoff-backlog`。
2. 依 `BACKLOG.md` 的 P2 順序處理（分支／PR、Pages 設定、CI 首次結果、CLAUDE.md 瘦身、實掃 `D:\` 與管理員重掃 `C:\`）。
3. 使用者決定：孤兒 volume `8d16b1c8…`（約 1.47 GB）、`D:\Backup\docker` 備份與 `settings-store.json.bak-20261113` 何時刪（不要自動刪）。

## 4. 位置與分支
- 專案 repo：`D:\Tools\DiskAudit`（GitHub `cjw9223233/DiskAudit`，private）。
- 分支：`master` 含 PR #1；`ci/github-pages` 已推送（PR／合併狀態未確認）；`fix/outdir-error-hint` 本機已 commit（`9e7b8e5`）、**未推送**；`docs/handoff-backlog`（本次文件，未 commit）。
- 其他資料夾：`D:\Tools\DiskAudit-v2`（開發期資料夾，另含首次 C 槽報表）、`D:\Tools\DiskAudit-orig-backup`（整合前備份）、`D:\Backup\docker\`（vhdx 備份 `docker_data.vhdx.bak-20261112`，23,335,010,304 bytes，SHA256 開頭 `263C73E4`；另有 `compact-docker.txt` diskpart 腳本）。

## 5. 已做的決定
- Docker：K8s／kind 殘留、自己的映像、兩個使用者容器全部刪除（使用者確認沒再用）；volumes 不動；`UseContainerdSnapshotter` 維持 `false`。
- `-OutDir` 與掃描範圍衝突：維持現狀，只把錯誤訊息改成附建議指令（在 `fix/outdir-error-hint`）。
- commit／push 一律由使用者核准；新工作開新分支。

## 6. 試過但行不通／重要發現
- **每次 Docker 停止後，三個 0 byte 的 AF_UNIX 殘留檔都會留下**，下次啟動報 `initializing Inference manager` 或 `Secrets Engine … remove … The file cannot be accessed by the system`。PowerShell／`del`／fsutil 刪不掉（error 1920），**在 WSL 內刪除有效（已驗證 3 次）**：
  `wsl -d Ubuntu-22.04 -- rm -v /mnt/c/Users/cjw/AppData/Local/docker-secrets-engine/engine.sock /mnt/c/Users/cjw/AppData/Local/Docker/run/dockerInference /mnt/c/Users/cjw/AppData/Local/Docker/run/userAnalyticsOtlpHttp.sock`
  （刪前確認 Docker 沒在跑；只刪這三個 0 byte 檔。）
- 「Windows 更新待重開機」的推測**已被推翻**（重開機後同樣失敗）。
- `docker system df` 顯示 0 映像不代表空：`UseContainerdSnapshotter` 切換會把另一個映像庫藏起來（舊庫 overlay2 約 9.5 GB），盤點前要先看 `docker info` 的 Storage Driver 與資料碟實際使用量（`wsl -d docker-desktop -- df -h /mnt/docker-desktop-disk`）。
- `Optimize-VHD` 不可用（無 Hyper-V 模組）；`diskpart compact vdisk` 有效；`wsl --manage --set-sparse` 不採用。以 `docker desktop start/stop`（CLI）啟停最穩。
- PowerShell 管線傳腳本給 `wsl … sh -s` 會帶 BOM 失敗；改寫成無 BOM 檔後用 `cmd /c "wsl … sh -s < 檔案"`。

## 7. 注意事項
- Claude 不能提權：需要系統管理員的步驟（如 diskpart）由使用者執行。
- Docker 錯誤視窗的 **Reset to factory defaults 會清掉全部 Docker 資料**，勿點。
- 已刪的 `sps-worklog` 容器：資料在主機 `D:\Downloads\SPS重置案\deploy\{app,data,public}`（未受影響）；原本是 compose 建立、`php:8.1-apache`、埠 8090→80；要用時重新 pull 並重建。
- 還原 Docker 到清理前：Quit Docker → `wsl --shutdown` → 把備份複製回 `C:\Users\cjw\AppData\Local\Docker\wsl\disk\docker_data.vhdx` → 刪三個殘留 socket → 啟動（會回到 21.73 GB 與舊映像庫狀態，但 `UseContainerdSnapshotter=false` 需維持才看得到舊庫）。
- 此檔含本機路徑；推遠端前依 `docs/文件分層使用指南.md` §3 檢視敏感度，只推私有倉庫。
