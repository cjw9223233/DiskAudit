# 用 Claude 協作開發 DiskAudit：流程、Skill 與 PR 教學（PM 版）

> 對象：專案負責人與維護者（含新手）。
> 目的：說明**怎麼請 Claude 協助、有哪些 skill 可用、PR / Code Review 怎麼走、哪些事一定要人工核准**。
> 配套文件：[README.md](../README.md)（使用與維護）、[PLAN_REVIEW.md](../PLAN_REVIEW.md)（保守分級依據）。

---

## 0. 一頁總結

| 原則 | 做法 |
|---|---|
| Claude 是「有權限的資深同事」 | 寫得快，但**驗收與核准是你的責任** |
| 動手前先有乾淨的 git 狀態 | 先 commit，再請 Claude 改；改完看 `git diff` |
| 重要規則寫進 `CLAUDE.md` | 讓每次對話都自動遵守（BOM、C# 5、唯讀承諾…） |
| 大改動先 Plan 再做 | 先看計畫、你核准才動手 |
| 審查三件套 | `/code-review` → `/simplify` → `/security-review`（清理腳本必跑） |
| 危險動作維持人工核准 | 刪檔、`push`、`merge`、發版 |
| 如實回報 | 要求 Claude 說明「沒驗證到的部分」 |

> **實際教訓**：本專案早期，Claude 把一個已有內容的資料夾當成新資料夾，覆寫了兩個檔案（事後已從來源還原）。
> 有 git、先 commit、改完看 diff，這類問題就能在幾秒內發現並還原。**這是本文件最重要的一條。**

---

## 1. 首次 commit 前的檢查（避免把私有資料放進版控）

稽核報表（`reports/`）含有本機完整路徑、使用者名稱、VM 名稱、已安裝程式與 Avast 沙箱 SID，`snapshot.json` 可達數 MB。
**報表是執行結果，不是原始碼，不要進版控。**

```bash
cd /d/Tools/DiskAudit
printf 'reports/\ntests/_work/\n' > .gitignore
git rm -r --cached reports        # 若已被 stage / commit 過
git add .gitignore
git status
```

- `reports\` 不必留空資料夾，腳本執行時會自行建立。
- `.ps1` 必須保持 **UTF-8 with BOM**；會去掉 BOM 的編輯器會讓中文變亂碼。clone 後先跑 `tests\Run-Tests.ps1` 確認。
- 若推到 GitHub，請建成 **private** repo。
- Commit 訊息建議用慣例前綴：`feat:` 新功能、`fix:` 修 bug、`docs:` 文件、`test:` 測試、`refactor:` 重構、`chore:` 雜項。

---

## 2. 整體流程（從想法到上線）

```
 立規矩 → 想清楚(Plan) → 開分支 → 實作+測試 → 審查 → commit/PR → 合併 → 維運
 /init     Plan 模式      一需求一分支  Run-Tests   /code-review   gh + app     人工    /schedule
                                                    /simplify
                                                    /security-review
```

| 階段 | 你做什麼 | 請 Claude 做什麼 |
|---|---|---|
| 1. 立規矩（一次性） | 執行 `/init` | 產生 `CLAUDE.md`，記錄專案規則。本專案建議寫入：`.ps1` 須 UTF-8 BOM；C# 限 C# 5 語法；稽核腳本不得出現刪除/移動指令；Safe 只限 7 天以上暫存檔；改完須跑 `tests\Run-Tests.ps1` |
| 2. 想清楚再做 | 用 Plan 模式描述需求 | 先讀程式碼、提出計畫與風險，**你核准才動手**。適合新功能、改規則分級、改清理行為 |
| 3. 開分支 | 一個需求一條分支 | 動手前會提議分支名（如 `feat/scheduled-audit`）。同時做兩件事就開並行 session 或 worktree，避免互相覆蓋 |
| 4. 實作 + 測試 | 看 diff、看測試結果 | 改程式、補測試、跑 `Run-Tests.ps1`；要求它列出「沒驗證到的地方」 |
| 5. 審查 | 跑審查指令（見第 3 節） | 找 bug、簡化、查安全問題，可選擇直接修 |
| 6. 提交 / PR | 核准 commit 與 push | 寫 commit 訊息與 PR 說明、開 PR（見第 4 節） |
| 7. 維運 | 決定頻率 | 排程唯讀稽核、整理報表 |

---

## 3. 可用的 Skill 與指令

在對話中輸入 `/名稱` 即可。以下為目前環境中可用且與本專案相關者：

### 3.1 開發與審查

| 指令 | 用途 | 本專案怎麼用 |
|---|---|---|
| `/init` | 建立 `CLAUDE.md`（專案規則與常用指令） | 第一次就做，效益最高 |
| `/code-review` | 審查目前改動並找出正確性問題。可加等級 `low` `medium` `high` `xhigh` `max`（越高抓越多，但不確定項也越多）；`--fix` 套用修正；`--comment` 把發現貼成 PR 行內留言；`--max-findings <n>` 限制數量；也可指定 PR 編號、分支或路徑 | 每個 PR 前跑 `/code-review high` |
| `/code-review ultra` | 雲端多代理深度審查（可指定 PR 編號） | **只有你能觸發，且會計費**，Claude 無法代你啟動。適合大改動前使用一次。需要是 git repo（不需要 GitHub remote） |
| `/simplify` | 找重複、可簡化、效率問題，並直接修 | 功能完成後收尾；只做品質，不抓 bug |
| `/security-review` | 針對待提交變更做安全審查 | **只要動到 `Invoke-DiskCleanup.ps1`、黑名單、`Command` 白名單，就必跑**——它是會刪檔的腳本 |
| `/run` | 啟動並實際操作專案，確認改動有效 | 驗證稽核/清理真的跑得起來，而不只是測試通過 |

### 3.2 自動化與設定

| 指令 | 用途 | 本專案怎麼用 |
|---|---|---|
| `/schedule` | 建立定期執行的雲端任務（也可一次性） | 例如每月自動做唯讀稽核 |
| `/loop` | 依間隔重複執行某個提示或指令 | 短期內重複檢查某狀態 |
| `/update-config` | 設定 hooks、權限、環境變數（`settings.json`） | 「每次改完 `.ps1` 自動檢查 BOM」這種**必須每次都發生**的行為，要用 hook，口頭交代不保證 |
| `/fewer-permission-prompts` | 掃描歷史，建議哪些唯讀指令可預先允許 | 減少反覆按「允許」的干擾 |

### 3.3 文件與報告

| Skill | 用途 |
|---|---|
| `docs` | 可共享、可留言的文件（提案、報告、SOP） |
| `docx` / `pdf` / `pptx` / `xlsx` | 需要 Word / PDF / 簡報 / 試算表檔案時使用（例如把稽核結果整理成給主管的簡報） |
| `skill-creator` | 把重複的流程做成自己的 skill（例如「發版檢查」） |

> 你的環境另有 SPS 站台維運相關的 skill（`sps-readonly-ssh`、`sps-station-review`），與本 repo 無關。

---

## 4. PR 與 CI 流程

### 4.1 前置條件
1. **遠端 repo**：`git remote add origin <GitHub private repo URL>` 並 `git push -u origin master`（建議把預設分支改名為 `main`）。沒有遠端就無法開 PR。
2. **GitHub CLI 登入**：`gh auth login`（PR、issue 操作靠它）。

### 4.2 一個需求的標準走法

```
git switch -c feat/xxx            # 或請 Claude 在動手前提議分支
  …請 Claude 實作 + 跑測試…
/code-review high                 # 審查
/simplify                         # 收尾
/security-review                  # 動到清理/黑名單時必跑
git diff                          # 你自己看一遍
commit → push → 開 PR → 等 CI → 你核准 → merge
```

- 在 Claude 桌面 app 中，一個需求完成後，下一步區塊會出現**建立 PR**按鈕；Claude 會寫標題與說明並開 PR。
- PR 開出後會綁定該 PR，可開啟 **Auto-fix**：CI 失敗、合併衝突、審查留言時，自動交給 Claude 處理。Claude 不會自己輪詢 CI。
- **不會自動 merge**，除非你明確要求。
- `/code-review --comment` 可把審查發現貼成 PR 行內留言，方便記錄與追蹤。

### 4.3 好的 PR 長什麼樣

| 項目 | 要求 |
|---|---|
| 大小 | 一個 PR 只做一件事；超過約 400 行變更就拆 |
| 標題 | 慣例前綴 + 一句話，例如 `fix: 重複檔比對忽略 ProgramData` |
| 說明 | 為什麼改、改了什麼、**怎麼測**、**沒測到什麼**、風險與還原方式 |
| 檢查 | `Run-Tests.ps1` 全過；動到清理則附 `/security-review` 結論 |
| 還原 | 說明回滾方法（通常 `git revert <commit>`） |

### 4.4 CI（建議）
在 `windows-latest` 上跑 `tests\Run-Tests.ps1`（GitHub Actions）。有 CI，Auto-fix 與 PR 檢查才有依據。
注意：測試會建立約 200MB 暫存 fixture、使用 junction 與 ACL；目前只在本機（Windows PowerShell 5.1）驗證過，CI 上首次執行需觀察結果。

---

## 5. 怎麼下指令（範本）

| 情境 | 建議說法 |
|---|---|
| 新功能 | 「用 Plan 模式：新增 XX。先列影響的檔案與風險，等我核准。」 |
| 修 bug | 「先重現問題 → 寫會失敗的測試 → 修 → 全部測試通過。」 |
| 動刪檔邏輯 | 「這次只改預覽輸出，不得動 `-Execute` 路徑；改完跑 `/security-review`。」 |
| 提交前 | 「看 `git diff`，逐檔說明變更，並列出沒驗證到的地方。」 |
| 不確定時 | 「先別動手，告訴我你打算改哪些檔、為什麼。」 |
| 接手陌生程式 | 「讀 README 與 `Invoke-DiskAudit.ps1`，用 5 句話說明資料流，並指出最容易壞的 3 個地方。」 |
| 寫文件 | 「依目前程式碼更新 README 的參數表，不要改其他段落。」 |

**好的需求包含**：目標、範圍（改哪些/不改哪些）、驗收方式、限制（如不得放寬黑名單）。

---

## 6. 護欄清單（PM 必讀）

- **先 commit 再讓它改**；改完看 `git diff` 再 commit。
- 要求**如實回報**：測試沒涵蓋的、沒驗證的、做了哪些假設。README 的「測試未涵蓋」清單延續此做法。
- **危險動作維持人工核准**：刪檔、`push`、`merge`、發版；清理腳本的預設預覽與確認閘門不得為了方便而放寬。
- **不要貼密碼、金鑰、客戶資料**進對話或 commit。
- 對 Claude 的輸出保持懷疑：命令與路徑先看過再執行（尤其帶 `-Execute` 的）。
- 高強度審查（`ultra`、`max`）花費較多，大改動才用，平常 `high` 即可。
- Claude 看不到你的螢幕與機器狀態，除非它實際執行過；「應該可以」不等於「驗證過」。

---

## 7. 發版檢查清單

- [ ] `.\tests\Run-Tests.ps1` 全數通過
- [ ] 對真實環境跑一次稽核（`-NoOpen`），報表正常、無未處理例外
- [ ] `/code-review`、`/security-review`（動到清理時）已完成，發現已處理或記錄
- [ ] 稽核腳本沒有新增任何寫入被掃描路徑的指令
- [ ] 新增/修改的規則預設為 Review 或 Manual，並有說明與建議指令
- [ ] 所有 `.ps1` 為 UTF-8 BOM、無語法錯誤
- [ ] 版本號（`DiskAudit.Common.ps1` 的 `$script:DiskAuditVersion`、`known-targets.json` 的 `version`）與 README 已更新
- [ ] 打 tag：`git tag v1.0.1 && git push --tags`

---

## 8. 常見問題

| 問題 | 回答 |
|---|---|
| Claude 改壞了怎麼辦？ | `git diff` 檢視；`git restore <檔案>` 或 `git revert <commit>` 還原。這就是要先 commit 的原因 |
| 我可以直接叫它「全部處理好」嗎？ | 小事可以；大事先 Plan。越模糊的需求，越需要你驗收 |
| 審查指令抓到很多項目，都要修嗎？ | 不必。依嚴重度排序，高信心的正確性問題先修，其餘記錄成 issue |
| 它說「測試通過」我就能放心嗎？ | 看測試涵蓋範圍：本專案測試**未涵蓋**符號連結、互動式選保留檔案、還原點、服務暫停恢復、實際 DISM 指令，改到這些要手動驗證 |
| 能讓它自動 merge 嗎？ | 不建議；預設不會，需你明確要求 |
| 怎麼讓團隊都遵守同樣規則？ | 把規則寫進 `CLAUDE.md` 並 commit；必須每次發生的檢查用 hook |

---

## 9. 後續待辦（建議順序）

1. ~~補 `.gitignore`~~（已完成：`reports/`、`tests/_work/` 已排除）。
2. ~~用 `/init` 產生並審閱 `CLAUDE.md`~~（已完成：見根目錄 `CLAUDE.md`）。
3. 建立 GitHub private repo 並推送。
4. ~~新增 GitHub Actions 跑測試~~（已完成：`.github/workflows/test.yml`，首次在 CI 執行需觀察結果）。
5. 第一個 PR 走完整流程（含 `/code-review`、`/security-review`）。
