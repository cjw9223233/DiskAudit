<#
.SYNOPSIS
    DiskAudit 自動化測試（不依賴 Pester）。在可丟棄的 fixture 上驗證掃描正確性、重複檔、規則、唯讀性、清理安全性。
.EXAMPLE
    .\tests\Run-Tests.ps1                 # fixture 建在 tests\_work
    .\tests\Run-Tests.ps1 -WorkDir E:\tmp
#>
[CmdletBinding()]
param(
    [string]$WorkDir,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot '_work' }
$audit = Join-Path $root 'Invoke-DiskAudit.ps1'
$cleanup = Join-Path $root 'Invoke-DiskCleanup.ps1'
. (Join-Path $root 'DiskAudit.Common.ps1')

$script:results = New-Object System.Collections.Generic.List[object]
function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:results.Add([pscustomobject]@{ Name = $Name; Pass = $Condition; Detail = $Detail })
    if ($Condition) { Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green }
    else { Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
}
function Get-TreeSnapshot {
    param([string]$Path, [string[]]$ExcludeDirs = @())
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $p = $_.FullName; -not ($ExcludeDirs | Where-Object { $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) } |
        Sort-Object FullName | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }
}
function Remove-Fixture {
    param([string]$Work)
    $fx = Join-Path $Work 'fx'
    if (-not (Test-Path -LiteralPath $fx)) { return }
    & icacls.exe "$fx\denied" /remove:d "$env:USERDOMAIN\$env:USERNAME" 2>&1 | Out-Null
    foreach ($l in 'junc', 'sym') {
        $lp = Join-Path $fx "links\$l"
        if (Test-Path -LiteralPath $lp) { cmd /c rmdir "`"$lp`"" | Out-Null }
    }
    cmd /c rd /s /q "\\?\$fx" 2>&1 | Out-Null
}

Write-Host '== 準備 fixture ==' -ForegroundColor Cyan
Remove-Fixture $WorkDir
if (Test-Path $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$m = & (Join-Path $PSScriptRoot 'New-Fixture.ps1') -Path $WorkDir
$fx = $m.Fixture
$deniedDir = Join-Path $fx 'denied'
Write-Host ("fixture: {0}  (denied ACL: {1}, symlink: {2})" -f $fx, $m.DeniedApplied, $m.SymlinkCreated)

try {
    # ------------------------------------------------------------------ 稽核前快照
    $snapBefore = Get-TreeSnapshot $fx @($deniedDir)

    Write-Host "`n== T-Audit：掃描與報表 ==" -ForegroundColor Cyan
    $reports = Join-Path $WorkDir 'reports'
    $res = & $audit -Root $fx -OutDir $reports -Depth 4 -Top 50 -MinFileMB 10 -DupMinMB 10 -RulesPath $m.RulesPath -NoOpen -Threads 4 6>$null
    $res = @($res)[-1]
    $rd = $res.ReportDir

    Assert-That '報表資料夾與 summary.html 產生' (Test-Path (Join-Path $rd 'summary.html')) $rd
    foreach ($f in 'top-folders.csv', 'top-files.csv', 'extensions.csv', 'candidates.csv', 'dupes.csv', 'empty-folders.csv', 'zero-byte-files.csv', 'scan-errors.csv', 'old-large-files.csv', 'installers-archives.csv', 'installed-programs.csv', 'summary.json', 'snapshot.json') {
        Assert-That "輸出 $f" (Test-Path (Join-Path $rd $f))
    }
    Assert-That '總邏輯大小 = 預期（junction 不重複、硬連結計兩次、denied 不計）' ($res.TotalLogicalBytes -eq $m.ExpectedLogical) ("got {0} expected {1}" -f $res.TotalLogicalBytes, $m.ExpectedLogical)

    $folders = Import-Csv (Join-Path $rd 'top-folders.csv') -Encoding UTF8
    $treeRow = $folders | Where-Object { $_.Path -eq (Join-Path $fx 'tree') }
    Assert-That 'tree 資料夾邏輯大小精確' ($treeRow -and [int64]$treeRow.LogicalBytes -eq $m.ExpectedTreeLogical) ("got {0}" -f $treeRow.LogicalBytes)
    Assert-That 'tree 資料夾磁碟佔用精確' ($treeRow -and [int64]$treeRow.DiskBytes -eq $m.ExpectedTreeDisk) ("got {0} expected {1}" -f $treeRow.DiskBytes, $m.ExpectedTreeDisk)
    $l3 = $folders | Where-Object { $_.Path -eq (Join-Path $fx 'tree\L1\L2\L3') }
    Assert-That '深層資料夾 (L3) 大小 = 20MB' ($l3 -and [int64]$l3.LogicalBytes -eq 20MB)
    Assert-That 'junction 不被遞迴（links 資料夾大小 0）' ($null -eq ($folders | Where-Object { $_.Path -like '*\links\junc*' }))

    $topFiles = Import-Csv (Join-Path $rd 'top-files.csv') -Encoding UTF8
    Assert-That '大檔排行第一名為 20MB 檔' ($topFiles[0].Path -like '*f_20m.bin')

    # 重複檔
    $dupes = Import-Csv (Join-Path $rd 'dupes.csv') -Encoding UTF8
    $gids = @($dupes | Select-Object -ExpandProperty GroupId -Unique)
    Assert-That '重複檔群組數 = 2' ($gids.Count -eq $m.DupGroups) ("got {0}" -f $gids.Count)
    Assert-That '陷阱檔(前64KB相同)不被判為重複' (-not ($dupes | Where-Object { $_.Path -like '*\trap\*' }))
    Assert-That '同大小不同內容不被判為重複' (-not ($dupes | Where-Object { $_.Path -like '*\diff\*' }))
    Assert-That '重複檔包含 orig1/copy1/copy1b' ((@($dupes | Where-Object { $_.Path -match 'orig1|copy1' })).Count -eq 3)
    $dupReclaim = [int64](($dupes | Group-Object GroupId | ForEach-Object { [int64]$_.Group[0].GroupReclaimBytes } | Measure-Object -Sum).Sum)
    Assert-That '重複檔可省空間 = 預期' ($dupReclaim -eq $m.DupReclaim) ("got {0} expected {1}" -f $dupReclaim, $m.DupReclaim)

    # 規則與使用者資料候選
    $cand = Import-Csv (Join-Path $rd 'candidates.csv') -Encoding UTF8
    $tTemp = $cand | Where-Object { $_.Id -eq 't-temp' }
    Assert-That 'Safe 規則 t-temp 命中且可回收 = 4MB（只算 7 天以上）' ($tTemp -and [int64]$tTemp.ReclaimBytes -eq $m.SafeReclaim) ("got {0}" -f $tTemp.ReclaimBytes)
    $tDmp = $cand | Where-Object { $_.Id -eq 't-dmp' }
    Assert-That 'Review 規則 t-dmp 命中 = 5MB' ($tDmp -and [int64]$tDmp.ReclaimBytes -eq $m.ReviewReclaim)
    Assert-That '安裝包 setup.zip 被列為候選' ([bool]($cand | Where-Object { $_.Id -eq 'installer-archive' -and $_.Path -like '*setup.zip' }))
    Assert-That '久未使用大檔 ancient.bin 被列為候選' ([bool]($cand | Where-Object { $_.Id -eq 'old-large' -and $_.Path -like '*ancient.bin' }))

    # 空 / 0 byte / 無權限
    $empty = @(Import-Csv (Join-Path $rd 'empty-folders.csv') -Encoding UTF8) + @(Import-Csv (Join-Path $rd 'zero-byte-files.csv') -Encoding UTF8)
    Assert-That '偵測到空資料夾' ([bool]($empty | Where-Object { $_.Path -like '*\emptydir' }))
    Assert-That '偵測到 0 byte 檔' ([bool]($empty | Where-Object { $_.Path -like '*zero.bin' }))
    if ($m.DeniedApplied) {
        Assert-That '存取被拒被計數並出現在 scan-errors.csv' ($res.Denied -ge 1 -and [bool](Import-Csv (Join-Path $rd 'scan-errors.csv') | Where-Object { $_.Path -like '*\denied*' }))
    }

    # 長路徑
    Assert-That '長路徑 (>260) 檔案被計入（已含在總大小內）' ($m.LongPathLength -gt 260 -and $res.TotalLogicalBytes -eq $m.ExpectedLogical)

    # HTML 自含
    $html = Get-Content -LiteralPath (Join-Path $rd 'summary.html') -Raw -Encoding UTF8
    Assert-That 'summary.html 無外部資源參照' (-not ($html -match '(src|href)\s*=\s*"?https?:'))
    Assert-That 'summary.html 含候選容量估計與規則命中' ($html -match '候選容量估計' -and $html -match 't-temp|fixture temp')

    # ------------------------------------------------------------------ 唯讀性
    Write-Host "`n== T-Safety：唯讀與靜態檢查 ==" -ForegroundColor Cyan
    $snapAfter = Get-TreeSnapshot $fx @($deniedDir)
    Assert-That '稽核前後 fixture 完全一致（唯讀）' (($snapBefore -join "`n") -eq ($snapAfter -join "`n"))
    foreach ($script in $audit, (Join-Path $root 'DiskAudit.Common.ps1')) {
        $src = Get-Content -LiteralPath $script -Raw -Encoding UTF8
        $bad = foreach ($w in 'Remove-Item', 'Move-Item', 'Rename-Item', 'Stop-Service', 'Set-ItemProperty', 'Clear-Item', 'Format-Volume', 'Invoke-Expression', 'Checkpoint-Computer') {
            if ($src -match [regex]::Escape($w)) { $w }
        }
        Assert-That ("靜態檢查 {0} 不含破壞性指令" -f (Split-Path -Leaf $script)) (-not $bad) ($bad -join ', ')
    }

    # ------------------------------------------------------------------ 規則庫驗證
    Write-Host "`n== T-Rules：規則庫驗證 ==" -ForegroundColor Cyan
    $okRules = $null
    try { $okRules = Import-DiskAuditRules -Path (Join-Path $root 'known-targets.json') } catch { }
    Assert-That '正式規則庫可載入且通過驗證' ($null -ne $okRules -and $okRules.Rules.Count -gt 10) ''
    $badFile = Join-Path $WorkDir 'bad-blacklist.json'
    @{ rules = @(@{ id = 'x'; risk = 'Safe'; path = "$env:SystemRoot\System32"; action = 'n/a'; clean = @{ type = 'DeleteContents'; olderThanDays = 0 } }) } | ConvertTo-Json -Depth 5 | Out-File $badFile -Encoding UTF8
    $threw = $false; try { Import-DiskAuditRules -Path $badFile | Out-Null } catch { $threw = $true }
    Assert-That '規則含黑名單路徑(System32) 載入即拒絕' $threw
    $badFile2 = Join-Path $WorkDir 'bad-risk.json'
    @{ rules = @(@{ id = 'y'; risk = 'Whatever'; path = 'C:\x'; action = 'n/a'; clean = @{ type = 'None' } }) } | ConvertTo-Json -Depth 5 | Out-File $badFile2 -Encoding UTF8
    $threw = $false; try { Import-DiskAuditRules -Path $badFile2 | Out-Null } catch { $threw = $true }
    Assert-That '規則 risk 值無效載入即拒絕' $threw
    foreach ($p in "$env:SystemRoot\WinSxS", "$env:SystemRoot\System32\drivers", 'C:\Program Files\App', "C:\Users\$env:USERNAME\NTUSER.DAT", 'D:\repo\.git\objects', "$env:SystemRoot\SoftwareDistribution\DataStore") {
        Assert-That ("黑名單命中: $p") ($null -ne (Test-PathBlacklisted $p))
    }
    Assert-That '黑名單不誤擋 SoftwareDistribution\Download' ($null -eq (Test-PathBlacklisted "$env:SystemRoot\SoftwareDistribution\Download"))
    Assert-That '黑名單不誤擋使用者 Temp' ($null -eq (Test-PathBlacklisted "C:\Users\$env:USERNAME\AppData\Local\Temp"))

    $safeIds = @($okRules.Rules | Where-Object { $_.risk -eq 'Safe' } | ForEach-Object { $_.id } | Sort-Object)
    Assert-That 'Safe 規則僅限 7 天以上暫存檔（user-temp / windows-temp）' (($safeIds -join ',') -eq 'user-temp,windows-temp') ($safeIds -join ',')
    foreach ($id in 'sw-distribution-download', 'wer-programdata', 'cbs-logs', 'delivery-optimization', 'thumbcache', 'component-store-cleanup') {
        $rr = $okRules.Rules | Where-Object { $_.id -eq $id }
        Assert-That ("規則 $id 不屬於 Safe（保守分級）") ($rr -and $rr.risk -ne 'Safe')
    }

    # ------------------------------------------------------------------ 參數邊界
    Write-Host "`n== T-Params：參數邊界 ==" -ForegroundColor Cyan
    $threw = $false; try { & $audit -Root (Join-Path $WorkDir 'no-such-dir') -OutDir $reports -NoOpen 6>$null | Out-Null } catch { $threw = $true }
    Assert-That '-Root 不存在 → 明確錯誤' $threw
    $threw = $false; try { & $audit -Root $fx -OutDir (Join-Path $fx 'out-inside') -NoOpen 6>$null | Out-Null } catch { $threw = $true }
    Assert-That '-OutDir 位於掃描根目錄內 → 拒絕' $threw
    $threw = $false; try { & $audit -Root $fx, (Join-Path $fx 'tree') -OutDir $reports -NoOpen 6>$null | Out-Null } catch { $threw = $true }
    Assert-That '-Root 互相包含 → 拒絕' $threw

    # ------------------------------------------------------------------ 前後比較
    Write-Host "`n== T-Compare：與上次比較 ==" -ForegroundColor Cyan
    $buf = New-Object byte[] (30MB); [IO.File]::WriteAllBytes((Join-Path $fx 'grow_big.bin'), $buf)
    $res2 = @(& $audit -Root $fx -OutDir $reports -Depth 4 -Top 50 -MinFileMB 10 -RulesPath $m.RulesPath -NoOpen -SkipDupes -Threads 4 6>$null)[-1]
    $html2 = Get-Content -LiteralPath (Join-Path $res2.ReportDir 'summary.html') -Raw -Encoding UTF8
    Assert-That '第二次報表出現「與上次比較」' ($html2 -match '與上次比較')
    Remove-Item (Join-Path $fx 'grow_big.bin') -Force

    # ------------------------------------------------------------------ 清理腳本
    Write-Host "`n== T-Cleanup：清理腳本 ==" -ForegroundColor Cyan
    $logDir = Join-Path $WorkDir 'cleanup-logs'
    $snap0 = Get-TreeSnapshot $fx @($deniedDir)
    & $cleanup -Mode Rules -Tier Safe -RulesPath $m.RulesPath -LogDir $logDir 6>$null | Out-Null
    $snap1 = Get-TreeSnapshot $fx @($deniedDir)
    Assert-That '清理預覽（無 -Execute）不變動任何檔案' (($snap0 -join "`n") -eq ($snap1 -join "`n"))
    $planCsv = Get-ChildItem $logDir -Recurse -Filter cleanup-plan.csv | Select-Object -First 1
    $plan = if ($planCsv) { Import-Csv $planCsv.FullName -Encoding UTF8 } else { @() }
    Assert-That '預覽計畫列出 t-temp 且預估 4MB' ([bool]($plan | Where-Object { $_.RuleId -eq 't-temp' -and [int64]$_.Bytes -eq 4MB }))

    & $cleanup -Mode Rules -Tier Safe -RulesPath $m.RulesPath -LogDir $logDir -WhatIf 6>$null | Out-Null
    $snapW = Get-TreeSnapshot $fx @($deniedDir)
    Assert-That '-WhatIf 不變動任何檔案' (($snap0 -join "`n") -eq ($snapW -join "`n"))

    & $cleanup -Mode Rules -Tier Review -RulesPath $m.RulesPath -LogDir $logDir -Execute -AllowReview -SkipRestorePoint -ConfirmTimeoutSeconds 1 6>$null | Out-Null
    Assert-That 'Review 層在無互動確認時不刪除（Minidump 仍在）' (Test-Path (Join-Path $fx 'fake\Minidump\a.dmp'))

    & $cleanup -Mode Rules -Tier Review -RulesPath $m.RulesPath -LogDir $logDir -Execute -Force -SkipRestorePoint 6>$null | Out-Null
    Assert-That 'Review 層未加 -AllowReview 時不執行（即使 -Execute -Force）' (Test-Path (Join-Path $fx 'fake\Minidump\a.dmp'))

    & $cleanup -Mode Rules -Tier Safe -RulesPath $m.RulesPath -LogDir $logDir -Execute -Force -SkipRestorePoint 6>$null | Out-Null
    Assert-That 'Safe 執行：7 天以上舊檔已刪除' (-not (Test-Path (Join-Path $fx 'fake\Temp\old1.tmp')) -and -not (Test-Path (Join-Path $fx 'fake\Temp\sub\old2.tmp')))
    Assert-That 'Safe 執行：新檔 new.tmp 保留' (Test-Path (Join-Path $fx 'fake\Temp\new.tmp'))
    Assert-That 'Safe 執行：不在規則內的 dupes 未被動到' (Test-Path (Join-Path $fx 'dupes\orig1.bin'))
    $log = Join-Path $logDir 'cleanup-log.csv'
    $logRows = if (Test-Path $log) { Import-Csv $log -Encoding UTF8 } else { @() }
    Assert-That 'cleanup-log.csv 有逐筆記錄' ([bool]($logRows | Where-Object { $_.RuleId -eq 't-temp' -and $_.Result -eq 'Done' }))

    $threw = $false; try { & $cleanup -Mode Rules -Tier Safe -RulesPath $badFile -LogDir $logDir 6>$null | Out-Null } catch { $threw = $true }
    Assert-That '清理腳本載入含黑名單路徑的規則庫 → 拒絕' $threw

    # 重複檔模式：無互動時不刪除
    $dupSnap0 = Get-TreeSnapshot (Join-Path $fx 'dupes')
    & $cleanup -Mode Dupes -DupesCsv (Join-Path $rd 'dupes.csv') -LogDir $logDir -Execute -ConfirmTimeoutSeconds 1 6>$null | Out-Null
    $dupSnap1 = Get-TreeSnapshot (Join-Path $fx 'dupes')
    Assert-That 'Dupes 模式無互動確認時不刪除任何檔案' ((($dupSnap1) -join "`n") -eq (($dupSnap0) -join "`n"))
}
finally {
    if (-not $KeepWork) { Remove-Fixture $WorkDir; if (Test-Path $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue } }
}

$pass = @($script:results | Where-Object Pass).Count
$fail = @($script:results | Where-Object { -not $_.Pass }).Count
Write-Host ''
Write-Host ("結果：{0} 通過 / {1} 失敗 / 共 {2}" -f $pass, $fail, $script:results.Count) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { $script:results | Where-Object { -not $_.Pass } | ForEach-Object { Write-Host (" - {0}: {1}" -f $_.Name, $_.Detail) -ForegroundColor Red } }
exit $(if ($fail -eq 0) { 0 } else { 1 })
