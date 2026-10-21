# C 槽容量稽核計畫檢視（2026-10-15）

| 優先度 | 原計畫項目 | 驗證結論與調整 |
|---|---|---|
| 高 | `Safe` 可直接清理多個系統快取 | 不宜一概歸為安全。Windows Update、WER、CBS、Prefetch、元件庫及軟體快取可能與更新、故障調查或應用程式狀態相關。工具只允許 7 天以上暫存檔進入可執行的 `Safe`；其餘列 Review/Manual。 |
| 高 | 「可回收空間估計」以規則命中大小加總 | 不可靠。規則路徑可能重疊、硬連結重複計數、候選資料夾內可能有正在使用的檔案。報表只顯示命中容量並要求逐項評估。 |
| 高 | 掃描資料夾大小約等於磁碟已用 | 不成立。硬連結、陰影複製、檔案系統中繼資料與系統保留空間未被一般遞迴統計。WinSxS 需用 DISM 分析。 |
| 中 | `GetCompressedFileSize` 代表精確磁碟佔用 | 只能作逐檔壓縮/稀疏差異參考；一般檔案的回傳值未必計入配置單位尾端，硬連結加總仍高估。報表標為估計。 |
| 中 | 管理員可看到所有系統檔 | 管理員權限通常增加可見性，但 ACL、使用中的檔案、系統保護及路徑問題仍可能造成漏算。用 `scan-errors.csv` 呈現。 |
| 中 | SHA-256 相同檔案可直接視為可刪 | 同內容可能被不同應用程式各自需要，也可能是硬連結。重複群組僅供人工檢視。 |
| 中 | `LastAccessTime` 可判斷久未使用 | NTFS 的存取時間更新可能停用或延遲；採最後修改時間，仍不能推論檔案無人使用。 |
| 中 | `-Execute` 可套用所有清理層級 | 本版只支援已掃描的暫存檔位置、7 天門檻且執行時重新確認；Review/Manual 只提供建議。 |
| 低 | 全碟掃描固定數分鐘 | 檔案數、權限失敗、磁碟速度、雜湊候選數量均影響時間；應以實測為準。 |

## 驗證方法與界限

1. 用兩份已知相同的 11 MB 檔案及一份 5 B 檔案測試遞迴大小、門檻與重複檔群組。
2. 由 Windows PowerShell 5.1 啟動，確認不依賴 PowerShell 7。
3. 對清理腳本執行預設預覽，核對沒有刪檔及前後可用空間相同。
4. 非管理員 C 槽掃描作為實際環境壓力測試；完整系統區域仍需管理員再跑一次，且應檢視錯誤列表。

來源：[WinSxS 真實大小](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/determine-the-actual-size-of-the-winsxs-folder)、[GetCompressedFileSize](https://learn.microsoft.com/en-us/windows/win32/fileio/obtaining-the-size-of-a-compressed-file)、[Storage Sense](https://learn.microsoft.com/en-us/windows/configuration/storage/storage-sense)、[NTFS last-access 設定](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-behavior)。
