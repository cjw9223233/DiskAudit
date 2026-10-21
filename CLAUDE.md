# DiskAudit — 給 Claude 的專案規則

Windows 磁碟容量稽核（唯讀）＋ 分級清理（預設只預覽）。Windows PowerShell 5.1 + 內嵌 C#（C# 5）。
使用者文件與訊息一律使用**繁體中文**。完整說明見 [README.md](README.md)，協作流程見 [docs/CLAUDE-WORKFLOW.md](docs/CLAUDE-WORKFLOW.md)。

## 常用指令（在專案根目錄、Windows PowerShell 5.1）

```powershell
# 全部測試（約 1–2 分鐘；會在 tests\_work 建約 200MB fixture，結束自動清除）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# 稽核（唯讀；真實 C 槽需數分鐘；非管理員會有讀不到的路徑）
.\Invoke-DiskAudit.ps1 -NoOpen
.\Invoke-DiskAudit.ps1 -Root <測試資料夾> -OutDir <範圍外的資料夾> -NoOpen

# 清理（預設預覽，不會變動任何檔案）
.\Invoke-DiskCleanup.ps1 -Tier Safe
```

**改完任何 `.ps1` / `.cs` / `known-targets.json` 都要跑全部測試**，結束時回報「改了什麼、測試結果、沒驗證到的部分」。

## 檔案地圖

| 檔案 | 職責 |
|---|---|
| `Invoke-DiskAudit.ps1` | 稽核主流程與報表（唯讀） |
| `Invoke-DiskCleanup.ps1` | 清理：`-Mode Rules` / `-Mode Dupes`，預設預覽 |
| `DiskAudit.Common.ps1` | 黑名單、規則驗證、路徑展開、逾時輸入、格式化 |
| `DiskScanner.cs` | 掃描引擎、重複檔 hash（透過 `Add-Type` 載入） |
| `known-targets.json` | 規則庫（Safe / Review / Manual） |
| `tests\Run-Tests.ps1`、`tests\New-Fixture.ps1` | 自動化測試與測試資料（不依賴 Pester） |
| `reports\` | 執行產物（已被 `.gitignore` 排除，**不可提交**） |

## 不可違反的規則（硬性）

1. **稽核腳本 100% 唯讀**：`Invoke-DiskAudit.ps1`、`DiskAudit.Common.ps1` 不得出現
   `Remove-Item`、`Move-Item`、`Rename-Item`、`Stop-Service`、`Set-ItemProperty`、`Clear-Item`、`Format-Volume`、`Invoke-Expression`、`Checkpoint-Computer`（測試會靜態檢查）。唯一允許的寫入是 `-OutDir` 下的報表。
2. **清理預設預覽**：必須 `-Execute` 才動手；Review 層另需 `-AllowReview`，且逐項確認。
3. **Safe 只限「7 天以上的暫存檔」**（`user-temp`、`windows-temp`）。新增規則預設 `Review` 或 `Manual`；要新增 Safe 須有充分理由，並同步更新測試中的 Safe 白名單。
4. **黑名單不可由參數覆蓋、不可為了讓規則通過而移除條目**（`Get-BlacklistPatterns`）。新增條目要在 `Run-Tests.ps1` 的 T-Rules 補測試。
5. **`Command` 型規則只允許固定指令**：新增需同時加入 `Invoke-DiskCleanup.ps1` 的 `$allowedCommands` 白名單與測試。
6. **使用者檔案只進資源回收筒**；刪除前重新比對 SHA-256；不做永久刪除；不自動選「保留哪一份」。
7. **容量是估計值**：介面與文件用「候選容量估計（非可回收保證）」，不要寫成可回收保證。
8. 不聯網、不上傳；報表與記錄只存本機。
9. 破壞性操作（真實機器上的 `-Execute`、刪檔、`git push --force`、改黑名單）**必須先停下來問使用者**。

## 程式與編碼約束

- **`.ps1` 必須是 UTF-8 with BOM**（否則 Windows PowerShell 5.1 讀中文會亂碼）。編輯後若 BOM 掉了，用 README 6.6 的指令補回。
- **C# 限 C# 5**（`Add-Type` 限制）：不可用 `$""`、`?.`、`nameof`、`out var`、expression-bodied 成員。
- **PowerShell 5.1**：沒有 `&&` / `||`、三元運算子、`?.`。
- `DiskAudit.Common.ps1` 啟用 `Set-StrictMode -Version 2.0`（dot-source 後影響呼叫者）：存取不存在的屬性會報錯。
- `Write-Host` 在 5.1 寫入資訊串流（6）；測試以 `6>$null` 抑制，注意函式回傳值不要被雜訊污染。
- 路徑：掃描用 `\\?\` 處理長路徑，輸出一律去前綴；路徑比對不分大小寫。
- 改大小計算（`DiskScanner.cs`）要同步更新 `New-Fixture.ps1` 的預期值。
- 改版時同步更新版本號：`DiskAudit.Common.ps1` 的 `$script:DiskAuditVersion`、`known-targets.json` 的 `version`。

## 工作方式

- 新功能、重構、任何動到刪除/確認邏輯的改動：**先用 Plan 模式提出計畫，等使用者核准**。
- 修 bug：先寫會失敗的測試，再修到通過。
- 一個 PR 只做一件事；commit 訊息用 `feat:` `fix:` `docs:` `test:` `refactor:` `chore:` 前綴。
- **commit 與 push 由使用者核准**；不要自行 commit、push 或 merge。
- 動到清理腳本、黑名單、`$allowedCommands` 後，建議執行 `/security-review`；PR 前執行 `/code-review high`。
- 不要提交 `reports/`、`tests/_work/`、任何含本機完整路徑或使用者名稱的產物。

## 已知限制與測試未涵蓋（改到相關程式時要手動驗證）

- 符號連結（建立需特權）、互動式逐組選保留檔案、`Checkpoint-Computer`、服務暫停/恢復、實際 `Command` 型指令（DISM 等）。
- Ctrl+C 會直接中止且不輸出報表（要部分結果用 `-MaxMinutes`）。
- 硬連結會重複計入（WinSxS 等），掃描總和可能高於磁碟已用。
- 測試會建立 junction 與 ACL 拒絕資料夾；目前只在本機驗證，CI 環境首次執行需觀察。

## 地雷（過去踩過）

- 不要把「已有內容的資料夾」當成新資料夾直接寫入——寫入前先 `git status` / 列目錄確認，並先 commit。
- 報表檔名與原版對齊：`installed-programs.csv`、`old-large-files.csv`、`installers-archives.csv`、`zero-byte-files.csv`、`empty-folders.csv`、`scan-errors.csv`、`summary.json`；改名要同步改測試與 README。
