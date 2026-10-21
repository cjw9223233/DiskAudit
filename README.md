# DiskAudit — Windows 磁碟容量稽核與安全清理工具

> **一句話**：幫你找出「C 槽到底被誰吃掉」，列出哪些東西可以清、哪些不能碰，並提供有安全閘門的清理腳本。
> **預設全程唯讀**，不確認就不會刪任何東西。

| 你想做什麼 | 跳到 |
|---|---|
| 5 分鐘先看到結果 | [一、快速上手](#一快速上手5-分鐘) |
| 一步一步學會使用 | [二、Step by Step 教學](#二step-by-step-教學) |
| 看懂報表、知道哪些能刪 | [三、怎麼讀報表與決策](#三怎麼讀報表與決策) |
| 出問題 / 看不懂錯誤 | [五、疑難排解](#五疑難排解) |
| 要維護、修改、擴充專案 | [六、維護者指南](#六維護者指南進入專案維修) |
| 想用 Claude 協助開發、做 PR / Code Review | [docs/CLAUDE-WORKFLOW.md](docs/CLAUDE-WORKFLOW.md)（本專案版）、[通用 HTML 教學](docs/claude-dev-workflow-guide.html) |

---

## 一、快速上手（5 分鐘）

### 你需要
- Windows 10 / 11（已用 Windows PowerShell 5.1 測試；**不需要安裝任何東西**）
- 一個**系統管理員**身分的 PowerShell（不是管理員也能跑，但看不到 `C:\Windows` 內部與其他使用者的資料）

### 三步驟

```powershell
# 1. 進入工具資料夾
cd D:\Tools\DiskAudit

# 2. 掃描 C 槽（唯讀，約數分鐘），完成後會自動用瀏覽器打開報表
.\Invoke-DiskAudit.ps1

# 3. 預覽可以清哪些東西（只預覽，不會刪）
.\Invoke-DiskCleanup.ps1 -Tier Safe
```

> 如果出現「無法載入，因為這個系統上已停用指令碼執行」，改用：
> `powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-DiskAudit.ps1`

### 記住這 4 條就夠了
1. **沒加 `-Execute` 就不會刪任何東西**（預覽模式）。
2. 報表在 `D:\Tools\DiskAudit\reports\<日期時間>\summary.html`。
3. **報表上的容量是「估計」**，不是清理後保證能拿回的空間。
4. 看不懂的項目**不要刪**；Manual 等級的東西本工具也不會幫你刪。

---

## 二、Step by Step 教學

### Step 0：確認環境（只需做一次）

1. 按 `Win` 鍵，輸入 `PowerShell`，**右鍵 → 以系統管理員身分執行**。
2. 確認版本：
   ```powershell
   $PSVersionTable.PSVersion      # Major 5 就可以
   ```
3. 確認工具在：
   ```powershell
   cd D:\Tools\DiskAudit
   dir
   ```
   應該看到 `Invoke-DiskAudit.ps1`、`Invoke-DiskCleanup.ps1`、`known-targets.json`、`DiskScanner.cs` 等檔案。

### Step 1：先看目前磁碟狀況

```powershell
Get-Volume -DriveLetter C | Select-Object DriveLetter,
  @{n='總容量GB';e={[math]::Round($_.Size/1GB,1)}},
  @{n='可用GB';e={[math]::Round($_.SizeRemaining/1GB,1)}}
```
記下「可用 GB」，等一下清理後用來對照。

### Step 2：執行稽核（唯讀）

```powershell
.\Invoke-DiskAudit.ps1
```

執行時你會看到：
- 進度列：已掃幾個檔案 / 資料夾、目前掃到哪個路徑。
- 掃描完成後，會開始「比對規則」與「比對重複檔」（重複檔最久，大檔多時可能數分鐘）。
- 最後在終端機印出摘要與報表位置，並自動開啟 `summary.html`。

常用變化：

| 想要 | 指令 |
|---|---|
| 不要自動開瀏覽器 | `.\Invoke-DiskAudit.ps1 -NoOpen` |
| 跳過最耗時的重複檔比對 | `.\Invoke-DiskAudit.ps1 -SkipDupes` |
| 只掃某個資料夾 | `.\Invoke-DiskAudit.ps1 -Root D:\Downloads` |
| 掃多個位置 | `.\Invoke-DiskAudit.ps1 -Root C:\,D:\Downloads` |
| 限制最多跑 10 分鐘 | `.\Invoke-DiskAudit.ps1 -MaxMinutes 10` |
| 同時分析 WinSxS 真實大小（管理員，約 1–2 分鐘） | `.\Invoke-DiskAudit.ps1 -WinSxS` |

> 提示：`-Root` 的多個路徑**不可互相包含**（例如 `C:\` 與 `C:\Users` 不能一起給）。
> 報表不可輸出到被掃描的範圍內（預設輸出到工具資料夾的 `reports\`，所以掃 `D:\` 時請用 `-OutDir` 指到別處）。

### Step 3：看報表

打開 `reports\<最新日期時間>\summary.html`，由上往下看，詳細解讀見 [第三章](#三怎麼讀報表與決策)。
新手最快的看法：
1. **磁碟總覽**：紅燈 = 可用 < 5%，黃燈 < 15%。
2. **資料夾排行**：點開 ▶ 往下鑽，找最大的那幾個。
3. **規則命中**：看 Risk 欄（Safe / Review / Manual）與「建議指令」。

想用 Excel 排序：直接開同資料夾的 `top-folders.csv`、`top-files.csv`、`candidates.csv`（UTF-8，Excel 可直接開啟）。

### Step 4：預覽清理（仍然不會刪任何東西）

```powershell
.\Invoke-DiskCleanup.ps1 -Tier Safe
```

你會看到類似：
```
清理計畫（Tier=Safe，預覽模式：不會變動任何檔案）
  [user-temp]     1.20 GB   3,456 檔  C:\Users\xxx\AppData\Local\Temp
  [windows-temp]  300 MB      120 檔  C:\WINDOWS\Temp
合計預估釋放約 1.50 GB（估計值；...）
這是預覽。確認清單無誤後，加上 -Execute 才會實際清理。
```
同時會寫出 `reports\cleanup-<時間>\cleanup-plan.csv` 方便檢查。

### Step 5：真的清理 Safe 層（只動「7 天以上的暫存檔」）

先**關閉**瀏覽器、IDE 等常駐程式，然後：

```powershell
.\Invoke-DiskCleanup.ps1 -Tier Safe -Execute
```

它會依序問你：
1. 「確認清理以上 N 項？ [Y/N]」→ 輸入 `Y`。
2. 「是否先建立系統還原點？」→ 建議 `Y`（需管理員；Windows 24 小時內只能建一次）。

完成後會顯示清理前後的可用空間。被程式佔用的檔案會自動略過，並記錄在 `reports\cleanup-log.csv`。

### Step 6：Review 層（需要你自己判斷的項目）

Review 等級包含：Windows Update 下載快取、WER 錯誤報告、CBS 記錄、縮圖快取、當機傾印、瀏覽器與開發工具快取、資源回收筒等。
**預設只給建議**；真的要執行必須額外加 `-AllowReview`，且**每一項都會問你**：

```powershell
.\Invoke-DiskCleanup.ps1 -Tier Review                       # 先看清單
.\Invoke-DiskCleanup.ps1 -Tier Review -Execute -AllowReview # 逐項確認後執行
```

每項可輸入：`Y`=清、`N`=不清、`A`=其餘全部清、`S`=略過、`Q`=中止。
高風險項目（例如清空資源回收筒）需要你**手動輸入指定關鍵字**才會執行。

> 只想處理某一項：`-OnlyIds sw-distribution-download`（規則的 `id` 看 `known-targets.json` 或報表）。

### Step 7：重複檔（逐組由你決定保留哪一份）

稽核報表裡會有 `dupes.csv`。要處理時：

```powershell
# 預覽：列出每一組重複檔
.\Invoke-DiskCleanup.ps1 -Mode Dupes -DupesCsv .\reports\<時間>\dupes.csv

# 執行：每組都會問你「保留哪一份？」，其餘送進資源回收筒（可還原）
.\Invoke-DiskCleanup.ps1 -Mode Dupes -DupesCsv .\reports\<時間>\dupes.csv -Execute
```

安全設計：刪除前會重新比對內容，內容已改變就拒絕；只進資源回收筒，不做永久刪除。

### Step 8：確認成果、之後定期追蹤

1. 再執行一次 Step 1 的指令，對照可用空間。
2. 想看變化：再跑一次 `.\Invoke-DiskAudit.ps1`，報表會多一節「**與上次比較**」，直接告訴你哪個資料夾長最多。
3. **資源回收筒要清空才會真的釋放**（Dupes 模式刪的檔案先進資源回收筒）。
4. 建議每月跑一次稽核。

### Step 9：處理「最大的幾隻」（常常才是重點）

清暫存通常只能拿回幾 GB；真正的大戶多半是下面這些，工具**只會標示、不會代刪**：

| 大戶 | 在哪 | 怎麼處理（先備份！） |
|---|---|---|
| VirtualBox / VMware 虛擬機 | `C:\Users\<你>\VirtualBox VMs`、`Documents\Virtual Machines` | 用管理員介面移動到 D 槽，或刪除不用的 VM；VDI 可關機後 `VBoxManage modifymedium disk "<檔案>.vdi" --compact` |
| WSL 發行版 | `...\LocalState\ext4.vhdx` | `wsl --shutdown` 後 `wsl --manage <發行版> --set-sparse true`；或 `wsl --export` / `--import` 搬到 D 槽 |
| Docker | `...\Docker\wsl\...\*.vhdx` | `docker system df` 檢視，`docker system prune` 清未使用資源（注意會刪未使用的映像/容器） |
| Android SDK / 模擬器 | `.android\avd`、`AppData\Local\Android\Sdk` | Android Studio → SDK Manager / Device Manager 移除不用的映像 |
| 休眠檔 hiberfil.sys | `C:\hiberfil.sys` | 不用休眠/快速啟動才關：`powercfg -h off`（復原：`powercfg -h on`） |
| Windows.old | `C:\Windows.old` | 設定 → 系統 → 儲存空間 → 暫存檔案 → 勾「以前的 Windows 安裝」 |
| 系統還原點 | （不在檔案列舉內） | `vssadmin list shadowstorage` 檢視，必要時調小上限 |
| WinSxS | `C:\Windows\WinSxS` | **不可手動刪**；`DISM /Online /Cleanup-Image /AnalyzeComponentStore` 分析，`/StartComponentCleanup` 清理 |
| Avast 沙箱 | `C:\avast! sandbox` | 由 Avast 介面清除，不要手動刪 |

---

## 三、怎麼讀報表與決策

### 3.1 HTML 報表各區塊

| 區塊 | 意義 |
|---|---|
| 警示橫幅 | 非管理員 / 有路徑讀不到 / 掃描被中止 / 雲端佔位檔 / 重複檔比對受上限限制 |
| 磁碟總覽 | 已用、可用、紅黃綠燈 |
| 候選容量估計 | Safe / Review / Manual / 重複檔四個數字（**估計，不保證可回收**） |
| 與上次比較 | 磁碟用量變化與成長最多的資料夾（第二次起才有） |
| 資料夾排行 | 樹狀，點開往下層；百分比是占該根目錄的比例 |
| 已知可清理位置 | 規則命中清單，附風險等級、說明、建議指令 |
| 大檔排行 / 副檔名 / 使用者 profile | 找出大檔與各類型佔用 |
| 重複檔 / 久未修改的大檔 / 安裝包 | 使用者資料層級，**只列出，由你決定** |

### 3.2 風險等級（最重要）

| 等級 | 意義 | 工具會做什麼 |
|---|---|---|
| **Safe** | **只有**「7 天以上的暫存檔」（`user-temp`、`windows-temp`） | 預覽 → 確認一次 → 執行 |
| **Review** | 多半可清，但要確認用途（更新快取、傾印、瀏覽器/開發工具快取、資源回收筒…） | 預設只給建議；加 `-AllowReview` 後逐項確認 |
| **Manual** | 系統保留檔、虛擬磁碟、使用者資料 | 只列出與建議指令，**不執行** |

### 3.3 為什麼數字對不上？（很正常）

- **「掃描總和」可能比「磁碟已用」大**：硬連結（WinSxS 等）會被重複計算。
- **「可回收」是估計**：規則可能重疊、檔案可能被鎖定。實際以清理後的可用空間為準。
- **「大小」是磁碟佔用估計**：一般檔案以 4KB 簇向上取整；壓縮 / 稀疏檔向系統查詢實際配置。
- **久未使用以「最後修改時間」判斷**：Windows 常關閉最後存取時間的記錄。
- **非管理員時數字是下限**：看 `scan-errors.csv` 就知道哪些路徑沒讀到。
- 大檔排行、重複檔、安裝包清單只涵蓋 ≥ `min(-MinFileMB, -DupMinMB)`（預設 10MB）的檔案，小檔不在其中；「久未修改」清單另以 `-MinFileMB`（預設 200MB）為門檻。

---

## 四、檔案與輸出說明

### 4.1 專案檔案

```
D:\Tools\DiskAudit\
├─ Invoke-DiskAudit.ps1     主程式：掃描 → 排行 → 規則比對 → 重複檔 → 報表（唯讀）
├─ Invoke-DiskCleanup.ps1   清理：Rules（暫存/快取）或 Dupes（重複檔），預設預覽
├─ DiskAudit.Common.ps1     共用函式：黑名單、規則驗證、路徑展開、逾時輸入、格式化
├─ DiskScanner.cs           C# 掃描引擎（多執行緒、跳過連結、長路徑、重複檔 hash）
├─ known-targets.json       規則庫（Safe / Review / Manual），可自行增修
├─ PLAN_REVIEW.md           保守分級的依據（原版對計畫的檢視結論）
├─ README.md                本文件
├─ CLAUDE.md                給 Claude 的專案規則（硬性規則、編碼約束、指令；每次對話自動載入）
├─ .github\workflows\test.yml   CI：每個 PR / push 自動跑靜態檢查與測試（windows-latest）
├─ docs\
│   ├─ CLAUDE-WORKFLOW.md   用 Claude 協作開發：流程、skill、PR / Code Review、護欄（本專案版）
│   └─ claude-dev-workflow-guide.html   同主題的「通用版」互動教學（可複製到任何專案，雙擊開啟）
├─ tests\
│   ├─ Check-Static.ps1     快速靜態檢查（BOM／語法／C# 編譯／規則庫），本機與 CI 共用
│   ├─ Run-Tests.ps1        自動化測試（不需 Pester）
│   └─ New-Fixture.ps1      建立可丟棄的測試資料夾與預期值
└─ reports\                 每次稽核一個資料夾；cleanup-log.csv 也在這
```

備份：整合前的原內容在 `D:\Tools\DiskAudit-orig-backup`；原始來源專案在 `D:\Downloads\SPSMMI_Log_Analysis_Project\DiskAudit`（未被修改）。

### 4.2 報表輸出（`reports\<時間>\`）

| 檔案 | 內容 |
|---|---|
| `summary.html` | 主報表（單檔、離線可開、無外部資源） |
| `summary.json` | 摘要：根目錄、耗時、檔案數、磁碟狀態、前次報表位置 |
| `top-folders.csv` | 展開層數內的資料夾（磁碟佔用、邏輯大小、檔案數），最多 500 筆 |
| `top-files.csv` | 大檔前 50 |
| `extensions.csv` | 副檔名彙總前 25 |
| `candidates.csv` | 規則命中 + 使用者資料候選（含風險、建議指令） |
| `dupes.csv` | 重複檔群組（`GroupId`、`SizeBytes`、`Path`、建議保留） |
| `old-large-files.csv` | 大且久未修改 |
| `installers-archives.csv` | Downloads / Desktop 內的安裝包與封存檔 |
| `installed-programs.csv` | 已安裝程式（登錄檔預估大小前 25） |
| `profiles.csv` | 使用者 profile 拆解 |
| `zero-byte-files.csv` / `empty-folders.csv` | 0 byte 檔與空資料夾（樣本，最多 200） |
| `scan-errors.csv` | 存取被拒 / 讀取錯誤的路徑（樣本，最多 200） |
| `snapshot.json` | 「與上次比較」用的快照 |

清理相關：`reports\cleanup-log.csv`（所有清理動作的逐筆記錄）、`reports\cleanup-<時間>\cleanup-plan.csv`（該次計畫）。

### 4.3 參數速查

**Invoke-DiskAudit.ps1**

| 參數 | 預設 | 說明 |
|---|---|---|
| `-Root` | `C:\` | 要掃描的磁碟/資料夾，可多個、不可互相包含 |
| `-OutDir` | `.\reports` | 報表位置；不可在掃描範圍內 |
| `-Depth` | 3 | HTML 樹狀展開層數 |
| `-Top` | 30 | 每層顯示前幾名 |
| `-MinFileMB` | 200 | 「大且久未修改」的大小門檻 |
| `-OldDays` | 180 | 幾天沒修改算久未使用 |
| `-DupMinMB` | 10 | 重複檔最小大小 |
| `-HashMaxGB` | 50 | 重複檔全檔雜湊的資料量上限 |
| `-Threads` | 核心數（最多 8） | 掃描執行緒 |
| `-MaxMinutes` | 0（不限） | 超時就停止並輸出部分結果 |
| `-SkipDupes` | 否 | 略過重複檔比對 |
| `-WinSxS` | 否 | 用 DISM 分析 WinSxS 真實大小（管理員） |
| `-NoOpen` | 否 | 不自動開瀏覽器 |
| `-RulesPath` | 腳本旁 JSON | 自訂規則庫 |

**Invoke-DiskCleanup.ps1**

| 參數 | 預設 | 說明 |
|---|---|---|
| `-Mode` | `Rules` | `Rules`（規則清理）或 `Dupes`（重複檔） |
| `-Tier` | `Safe` | `Safe` 或 `Review` |
| `-Execute` | 否 | 沒加就只預覽 |
| `-AllowReview` | 否 | Review 層要執行必須加 |
| `-Force` | 否 | Safe 層略過「確認一次」（Review 與關鍵字確認不受影響） |
| `-SkipRestorePoint` | 否 | 不詢問建立還原點 |
| `-OnlyIds` | 全部 | 只處理指定規則 id |
| `-DupesCsv` | — | Dupes 模式必填 |
| `-RulesPath` / `-LogDir` | 預設位置 | 自訂規則庫 / 記錄與計畫位置 |
| `-ConfirmTimeoutSeconds` | 120 | 互動確認逾時（逾時視為「否」） |
| `-WhatIf` | — | 等同預覽 |

---

## 五、疑難排解

| 狀況 | 原因 / 處理 |
|---|---|
| 「已停用指令碼執行」 | 用 `powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-DiskAudit.ps1` |
| 報表上很多項目「無法讀取」 | 沒用系統管理員執行；改用管理員 PowerShell 重跑 |
| 中文亂碼 | 腳本必須是 **UTF-8 with BOM**（見維護者指南）；CSV 用 Excel 開即可 |
| 掃描很久 | SSD 數分鐘、HDD 可 20 分鐘以上；加 `-SkipDupes` 或 `-MaxMinutes 10` |
| 「報表位置不可位於掃描根目錄內」 | `-OutDir` 指到被掃描範圍外（例如掃 `D:\` 就輸出到 `C:` 或 `E:`） |
| 「掃描根目錄不可互相包含」 | `-Root` 只給最上層，或分開跑 |
| 清理後可用空間沒變 | 資源回收筒沒清空；或估計值本來就偏高；或檔案被鎖定而略過（看 `cleanup-log.csv`） |
| Review 層按了 `-Execute` 什麼都沒做 | 需再加 `-AllowReview`；且非互動視窗/逾時一律視為「否」 |
| 清理腳本拒絕某條規則 | 路徑落在黑名單（系統核心路徑），是設計如此，不可繞過 |
| 想還原誤刪 | Dupes 與使用者檔案在資源回收筒；暫存檔無法還原（可用還原點回復系統設定，但不含個人檔案） |
| 腳本啟動就報 Add-Type 錯誤 | 檢查 `DiskScanner.cs` 是否被改壞（C# 5 語法）；跑 `tests\Run-Tests.ps1` 定位 |

---

## 六、維護者指南（進入專案維修）

### 6.1 一分鐘認識架構

```
Invoke-DiskAudit.ps1 ──dot-source──► DiskAudit.Common.ps1 ──Add-Type──► DiskScanner.cs
        │                                  ▲  (黑名單 / 規則驗證 / 路徑展開)
        ├─ 讀 known-targets.json ──────────┘
        └─ 寫 reports\<時間>\*.csv|json|html

Invoke-DiskCleanup.ps1 ──dot-source──► DiskAudit.Common.ps1
        ├─ 讀 known-targets.json（自己重新評估，不信任舊報表）
        ├─ Mode=Dupes 另讀 dupes.csv
        └─ 寫 reports\cleanup-log.csv、reports\cleanup-<時間>\cleanup-plan.csv
```

設計原則（改動前請先理解，它們是專案的「承諾」）：
1. **稽核腳本 100% 唯讀**——不得出現 `Remove-Item`、`Move-Item`、`Stop-Service` 等（測試會靜態檢查）。
2. **清理預設預覽**——必須 `-Execute` 才動手。
3. **Safe 只限 7 天以上暫存檔**——其他一律 Review / Manual（見 `PLAN_REVIEW.md`）。
4. **黑名單不可由參數覆蓋**——規則載入時與每次刪檔前各檢查一次。
5. **使用者資料只進資源回收筒**，且由使用者指定保留哪一份。
6. **容量是估計**——UI 與文件都不得把它寫成「可回收保證」。

### 6.2 各檔案職責與關鍵位置

| 檔案 | 職責 | 想改這個時看這裡 |
|---|---|---|
| `DiskScanner.cs` | 掃描引擎 | `ScanDir`：遞迴與大小計算（連結、雲端佔位檔、壓縮檔判斷）；`FindDuplicates`：三階段重複檔（大小→前 64KB→全檔 SHA-256）；`Measure`：量測單一規則路徑；`GetDirs`：取指定深度的資料夾 |
| `DiskAudit.Common.ps1` | 共用 | `Get-BlacklistPatterns`（黑名單）、`Test-PathBlacklisted`、`Import-DiskAuditRules`（規則驗證）、`Expand-RulePath`（環境變數與萬用字元展開並去重）、`Read-LineTimeout`（逾時輸入）、`Format-Size` |
| `Invoke-DiskAudit.ps1` | 稽核主流程 | 依序為：參數檢查 → 掃描（背景 Task + 進度列）→ 磁碟總覽 → 資料夾排行 → 大檔/副檔名/profile → 規則比對 → 使用者資料候選 → 重複檔 → 已安裝程式 → 與上次比較 → 彙總 → 輸出 CSV/JSON → HTML → 終端摘要 |
| `Invoke-DiskCleanup.ps1` | 清理 | 規劃（`Get-CleanupFiles`）→ 預覽 → 閘門（`-AllowReview`、確認）→ 執行；`$allowedCommands`（Command 型規則的固定指令白名單）；`Write-CleanupLog` |
| `known-targets.json` | 規則 | 見 6.3 |
| `tests\Run-Tests.ps1` | 測試 | 見 6.5 |

### 6.3 如何新增 / 修改規則

編輯 `known-targets.json`，在 `rules` 陣列加一筆：

```json
{
  "id": "my-app-cache",
  "risk": "Review",
  "category": "應用程式快取",
  "path": ["%LOCALAPPDATA%\\MyApp\\Cache", "%APPDATA%\\MyApp\\Cache"],
  "note": "MyApp 快取，會自動重建；請先關閉 MyApp。",
  "action": "關閉 MyApp 後清除",
  "clean": { "type": "DeleteContents", "olderThanDays": 0 }
}
```

| 欄位 | 說明 |
|---|---|
| `id` | 唯一識別（重複會載入失敗） |
| `risk` | `Safe` / `Review` / `Manual`。**新增請預設 Review 或 Manual**；Safe 需有充分理由並同步更新測試中的 Safe 白名單 |
| `path` | 字串或陣列；支援環境變數（`%LOCALAPPDATA%`…）與 `*` `?` 萬用字元；不存在的路徑自動略過 |
| `note` / `action` | 報表顯示的說明與建議指令 |
| `clean.type` | `DeleteContents`（刪內容）/ `Command`（固定指令）/ `None`（只報告） |
| `clean.olderThanDays` | 只處理 N 天以上；0 = 全部 |
| `clean.nameRegex` | 只處理檔名符合的檔案 |
| `clean.services` | 清理期間暫停的服務（結束時恢復） |
| `clean.manualOnly` | `true` = 即使有 type 也不由腳本執行 |
| `clean.confirmKeyword` | Command 型：須手動輸入的確認字串 |
| `measure: "none"` | 不計入可回收估計（如 WinSxS） |

新增規則後務必：
1. `.\tests\Run-Tests.ps1`（規則庫驗證會檢查 schema 與黑名單）。
2. 對真實環境跑一次稽核，確認命中與大小合理。
3. 若是 `Command` 型：還要把指令加進 `Invoke-DiskCleanup.ps1` 的 `$allowedCommands`（正規表示式白名單），否則會被略過。

### 6.4 修改黑名單 / 掃描行為

- **黑名單**：`Get-BlacklistPatterns`（`DiskAudit.Common.ps1`）。每條是正規表示式，比對完整路徑。新增後到 `Run-Tests.ps1` 的 `T-Rules` 區塊補一條 `黑名單命中: <路徑>` 測試。**請勿為了讓某規則能通過而移除既有條目。**
- **掃描行為**（大小計算、連結處理）：改 `DiskScanner.cs`。
  - 必須維持 **C# 5 語法**（Windows PowerShell 5.1 的 `Add-Type` 限制）：不可用 `$""` 字串插值、`?.`、`nameof`、`out var`、expression-bodied 成員。
  - 改完用 `Run-Tests.ps1` 驗證；若修改大小計算，需同步更新 `New-Fixture.ps1` 的預期值。

### 6.5 測試

```powershell
.\tests\Check-Static.ps1                  # 數秒：BOM、語法、C# 編譯、規則庫驗證（提交前先跑）
.\tests\Run-Tests.ps1                     # 約 1–2 分鐘，結果 N 通過 / M 失敗
.\tests\Run-Tests.ps1 -KeepWork           # 失敗時保留 fixture 以便檢查
.\tests\Run-Tests.ps1 -WorkDir E:\tmp     # 改測試暫存位置（需約 200MB）
```

測試做的事：建立 fixture（`tests\_work\fx`，含巢狀資料夾、重複檔與陷阱檔、junction、硬連結、無權限資料夾、長路徑、舊檔、假 Temp…）
→ 執行稽核 → 驗證大小/重複檔/規則/報表檔案 → 驗證稽核前後 fixture 完全一致（唯讀）→ 靜態檢查禁用指令 → 規則庫與黑名單 → 參數邊界 → 與上次比較 → 清理預覽/執行/閘門 → 自動清除 fixture。

新增測試：在 `Run-Tests.ps1` 對應區塊加 `Assert-That '名稱' ($條件) '失敗時的說明'`；需要新的檔案情境就改 `New-Fixture.ps1` 並回傳預期值。

**測試未涵蓋**（修改相關程式時要手動驗證）：符號連結（需特權才能建立）、互動式逐組選保留檔案、`Checkpoint-Computer`、服務暫停/恢復、實際 `Command` 型指令（DISM 等）。

### 6.6 開發注意事項（常踩的坑）

| 項目 | 說明 |
|---|---|
| **檔案編碼** | `.ps1` 必須存成 **UTF-8 with BOM**，否則 Windows PowerShell 5.1 會把中文讀成亂碼。編輯器若存成無 BOM，用下面指令補回 |
| PowerShell 版本 | 以 5.1 為準：沒有 `&&` / `||`、三元運算子、`?.`；測試過的只有 5.1 |
| StrictMode | `DiskAudit.Common.ps1` 啟用 `Set-StrictMode -Version 2.0`（dot-source 後影響呼叫者）；存取不存在的屬性會直接報錯，物件屬性請先確認 |
| `Write-Host` | 在 5.1 寫入資訊串流（6）；測試用 `6>$null` 抑制，且函式回傳值要小心被雜訊污染 |
| 路徑 | 掃描用 `\\?\` 前綴處理長路徑，輸出一律去前綴；比對路徑一律不分大小寫 |
| 報表命名 | `yyyyMMdd-HHmm`；同分鐘重跑會自動加秒 |
| 版本號 | 程式 `$script:DiskAuditVersion`（`DiskAudit.Common.ps1`）、規則庫 `version`（`known-targets.json`），改行為時一併更新 |

補回 BOM（在工具資料夾執行）：

```powershell
Get-ChildItem -Recurse -Include *.ps1 | Where-Object { $_.FullName -notmatch '\\_work\\' } | ForEach-Object {
  $t = [IO.File]::ReadAllText($_.FullName, (New-Object Text.UTF8Encoding($false)))
  [IO.File]::WriteAllText($_.FullName, $t, (New-Object Text.UTF8Encoding($true)))
}
```

### 6.7 發版前檢查清單

- [ ] `.\tests\Check-Static.ps1` 與 `.\tests\Run-Tests.ps1` 全數通過（CI 也會自動跑）
- [ ] 對真實 C 槽跑一次稽核（`-NoOpen`），報表正常、無未處理例外
- [ ] 稽核腳本沒有新增任何寫入被掃描路徑的指令
- [ ] 新增/修改的規則：預設 Review 或 Manual，並已有說明與建議指令
- [ ] 所有 `.ps1` 為 UTF-8 BOM、無語法錯誤
- [ ] 更新版本號與本 README（若參數或輸出有變）

### 6.8 已知限制與可改進方向

- Ctrl+C 會直接中止且不輸出報表（要部分結果請用 `-MaxMinutes`）。
- 重複檔比對在檔案數很多時較慢；`-HashMaxGB` 是資料量上限，不是時間上限。
- 硬連結會重複計算（WinSxS 等），尚未做 file ID 去重。
- 還原點（VSS）容量只做「盡力解析」，輸出語系不同時可能解析失敗，原文會附在說明內。
- 規則庫對「其他使用者」只涵蓋 `user-temp`；其他快取規則僅對目前使用者展開。
- 沒有排程/自動化執行；如需定期稽核，可用工作排程器呼叫 `Invoke-DiskAudit.ps1 -NoOpen`（唯讀）。

---

## 七、安全承諾（一覽）

- 稽核腳本不含任何刪除 / 移動 / 修改指令。
- 黑名單（`System32`、`WinSxS`、`servicing`、`Program Files*`、`NTUSER.DAT`、`System Volume Information`、`.git`、`pagefile/hiberfil/swapfile`、使用者 profile 根與 AppData/Documents 根…）一律拒絕，無法由參數覆蓋。
- `Command` 型規則只允許固定的三種指令（DISM StartComponentCleanup、Delete-DeliveryOptimizationCache、Clear-RecycleBin）。
- 互動確認 120 秒無回應 = 否；非互動環境一律視為否。
- 暫停的服務（`wuauserv`、`bits`）在 `finally` 中恢復。
- 不聯網、不上傳；報表只存本機。

---

## 八、來源與版本

- 本專案合併了兩個實作：原版（保守、純 PowerShell）與 v2（C# 引擎 + 測試）；風險分級、確認閘門與檔名採原版精神，引擎/測試/清理安全機制採 v2。
- 工具 v1.0.0；規則庫 v1.1.0。
- 備份：`D:\Tools\DiskAudit-orig-backup`（整合前內容）；`D:\Tools\DiskAudit-v2`（整合時的開發資料夾，內容同本資料夾）。
