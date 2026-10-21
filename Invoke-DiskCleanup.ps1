<#
.SYNOPSIS
    依規則庫分級清理（預設只預覽）。使用者資料（重複檔）只能逐組由您指定保留哪一份，並送資源回收筒。
.DESCRIPTION
    -Mode Rules（預設）：依 known-targets.json 的 Safe / Review 規則清理暫存與快取。
                         未加 -Execute 時只輸出預計清單與預估釋放量（cleanup-plan.csv），不會變動任何檔案。
    -Mode Dupes        ：讀取稽核報表的 dupes.csv，逐組詢問保留哪一份，其餘送資源回收筒（需 -Execute）。
    黑名單路徑（System32、WinSxS、Program Files、NTUSER.DAT、.git ...）一律拒絕，無法由參數覆蓋。
.EXAMPLE
    .\Invoke-DiskCleanup.ps1 -Tier Safe                 # 預覽
    .\Invoke-DiskCleanup.ps1 -Tier Safe -Execute        # 確認一次後執行
    .\Invoke-DiskCleanup.ps1 -Tier Review -Execute -AllowReview   # Review 層預設只給建議；加 -AllowReview 才逐項確認執行
    .\Invoke-DiskCleanup.ps1 -Mode Dupes -DupesCsv .\reports\20261015-1200\dupes.csv -Execute
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Rules', 'Dupes')][string]$Mode = 'Rules',
    [ValidateSet('Safe', 'Review')][string]$Tier = 'Safe',
    [string]$RulesPath,
    [string[]]$OnlyIds,
    [string]$DupesCsv,
    [string]$LogDir,
    [switch]$Execute,
    [switch]$AllowReview,
    [switch]$Force,
    [switch]$SkipRestorePoint,
    [int]$ConfirmTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'DiskAudit.Common.ps1')
Initialize-DiskScanner -SourcePath (Join-Path $scriptDir 'DiskScanner.cs')

if (-not $RulesPath) { $RulesPath = Join-Path $scriptDir 'known-targets.json' }
if (-not $LogDir) { $LogDir = Join-Path $scriptDir 'reports' }
if ($WhatIfPreference) { $Execute = $false; $WhatIfPreference = $false }  # -WhatIf = 預覽（仍寫出 cleanup-plan.csv）
$isAdmin = Test-IsAdmin
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $LogDir "cleanup-$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logPath = Join-Path $LogDir 'cleanup-log.csv'

# Command 型規則只允許這些固定指令（不執行規則庫內任意字串）
$allowedCommands = @(
    '^DISM\.exe /Online /Cleanup-Image /StartComponentCleanup$',
    '^Delete-DeliveryOptimizationCache -Force$',
    '^Clear-RecycleBin -DriveLetter [A-Za-z] -Force$'
)

function Write-CleanupLog {
    param($RuleId, $Path, $Action, $Bytes, $Result, $Detail = '', $ConfirmedBy = '')
    $row = [pscustomobject]@{
        Time = (Get-Date).ToString('s'); User = $env:USERNAME; Mode = $Mode; Tier = $Tier; RuleId = $RuleId
        Path = $Path; Action = $Action; Bytes = $Bytes; Result = $Result; Detail = $Detail; ConfirmedBy = $ConfirmedBy
    }
    $row | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding UTF8 -Append
}

function Get-CleanupFiles {
    # 非重解析點遞迴列舉；回傳符合條件的 FileInfo 與可刪除的空資料夾
    param([string]$RootPath, [datetime]$OlderThan, [string]$NameRegex)
    $files = New-Object System.Collections.Generic.List[IO.FileInfo]
    $dirs = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($RootPath)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $di = New-Object IO.DirectoryInfo $d; $entries = @($di.EnumerateFileSystemInfos()) } catch { continue }
        foreach ($e in $entries) {
            $isReparse = ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($e.Attributes -band [IO.FileAttributes]::Directory) {
                if ($isReparse) { continue }
                $dirs.Add($e.FullName); $stack.Push($e.FullName)
            }
            else {
                if ($isReparse) { continue }
                if ($e.LastWriteTime -ge $OlderThan) { continue }
                if ($NameRegex -and $e.Name -notmatch $NameRegex) { continue }
                $files.Add([IO.FileInfo]$e)
            }
        }
    }
    return [pscustomobject]@{ Files = $files; Dirs = $dirs }
}

function Confirm-Choice {
    param([string]$Prompt, [string[]]$Valid)
    $ans = Read-LineTimeout -Prompt $Prompt -TimeoutSeconds $ConfirmTimeoutSeconds
    if ($null -eq $ans) { return 'N' }
    $a = $ans.Trim().ToUpperInvariant()
    if ($Valid -contains $a) { return $a }
    return 'N'
}

# =========================================================================== Dupes
if ($Mode -eq 'Dupes') {
    if (-not $DupesCsv -or -not (Test-Path -LiteralPath $DupesCsv)) { throw '-Mode Dupes 需要 -DupesCsv 指向稽核報表的 dupes.csv。' }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $rows = @(Import-Csv -LiteralPath $DupesCsv -Encoding UTF8)
    $groups = $rows | Group-Object GroupId
    Write-Host ("重複檔群組 {0} 組。" -f @($groups).Count) -ForegroundColor Cyan
    $recycled = 0L; $count = 0
    foreach ($g in $groups) {
        $paths = @($g.Group | ForEach-Object { $_.Path } | Where-Object { Test-Path -LiteralPath $_ })
        if ($paths.Count -lt 2) { continue }
        $size = [int64]$g.Group[0].SizeBytes
        Write-Host ''
        Write-Host ("群組 {0}：每份 {1}，共 {2} 份" -f $g.Name, (Format-Size $size), $paths.Count) -ForegroundColor Yellow
        for ($i = 0; $i -lt $paths.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i + 1), $paths[$i]) }
        if (-not $Execute) { continue }
        $ans = Read-LineTimeout -Prompt '  保留哪一份？(輸入編號，S=略過，Q=中止) > ' -TimeoutSeconds $ConfirmTimeoutSeconds
        if ($null -eq $ans -or $ans.Trim().ToUpperInvariant() -eq 'S' -or $ans.Trim() -eq '') { Write-CleanupLog "dup-$($g.Name)" '' 'Skip' 0 'Skipped' '' 'user'; continue }
        if ($ans.Trim().ToUpperInvariant() -eq 'Q') { break }
        $keep = 0
        if (-not [int]::TryParse($ans.Trim(), [ref]$keep) -or $keep -lt 1 -or $keep -gt $paths.Count) { Write-Host '  無效輸入，略過。' -ForegroundColor Red; continue }
        $keepPath = $paths[$keep - 1]
        $keepHash = (Get-FileHash -LiteralPath $keepPath -Algorithm SHA256).Hash
        for ($i = 0; $i -lt $paths.Count; $i++) {
            if (($i + 1) -eq $keep) { continue }
            $p = $paths[$i]
            $bl = Test-PathBlacklisted $p
            if ($bl) { Write-CleanupLog "dup-$($g.Name)" $p 'Recycle' $size 'Refused' "blacklist: $bl" 'rule'; Write-Host "  拒絕（黑名單）: $p" -ForegroundColor Red; continue }
            $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
            if ($h -ne $keepHash) { Write-CleanupLog "dup-$($g.Name)" $p 'Recycle' $size 'Refused' 'hash changed' 'rule'; Write-Host "  內容已改變，略過: $p" -ForegroundColor Red; continue }
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
                Write-CleanupLog "dup-$($g.Name)" $p 'Recycle' $size 'Done' "kept: $keepPath" 'user'
                $recycled += $size; $count++
                Write-Host "  已送資源回收筒: $p" -ForegroundColor Green
            }
            catch { Write-CleanupLog "dup-$($g.Name)" $p 'Recycle' $size 'Failed' $_.Exception.Message 'user'; Write-Host "  失敗: $p ($($_.Exception.Message))" -ForegroundColor Red }
        }
    }
    Write-Host ''
    if ($Execute) { Write-Host ("完成：{0} 個檔案送資源回收筒，約 {1}（資源回收筒清空後才會釋放）。記錄: {2}" -f $count, (Format-Size $recycled), $logPath) -ForegroundColor Green }
    else { Write-Host '預覽模式：未變動任何檔案。加上 -Execute 後會逐組詢問保留哪一份。' -ForegroundColor Yellow }
    return
}

# =========================================================================== Rules
$ruleSet = Import-DiskAuditRules -Path $RulesPath
$plan = New-Object System.Collections.Generic.List[object]

foreach ($rule in $ruleSet.Rules) {
    if ($rule.risk -ne $Tier) { continue }
    if ($OnlyIds -and ($OnlyIds -notcontains $rule.id)) { continue }
    $cleanProps = $rule.clean.PSObject.Properties.Name
    if ($rule.clean.type -eq 'None') { continue }
    if (($cleanProps -contains 'manualOnly') -and $rule.clean.manualOnly) { continue }

    if ($rule.clean.type -eq 'Command') {
        $cmd = [string]$rule.clean.command
        $ok = $false
        foreach ($rx in $allowedCommands) { if ($cmd -match $rx) { $ok = $true; break } }
        if (-not $ok) { Write-Warning "規則 $($rule.id) 的指令不在允許清單，已略過: $cmd"; continue }
        $keyword = if ($cleanProps -contains 'confirmKeyword') { [string]$rule.clean.confirmKeyword } else { '' }
        # 指令型規則：預估大小取其路徑現況（僅供參考）
        $est = 0L
        foreach ($p in (Expand-RulePath $rule.path)) {
            try { $m = [DiskAudit.DiskScanner]::Measure($p, 0, $null, 2); $est += [int64]$m[0] } catch { }
        }
        $plan.Add([pscustomobject]@{
                RuleId = $rule.id; Risk = $rule.risk; Type = 'Command'; Path = $cmd; Bytes = $est; Files = 0
                Note = $rule.note; Services = @(); Keyword = $keyword; Items = $null
            })
        continue
    }

    # DeleteContents
    $olderDays = if ($cleanProps -contains 'olderThanDays') { [int]$rule.clean.olderThanDays } else { 0 }
    $nameRx = if ($cleanProps -contains 'nameRegex') { [string]$rule.clean.nameRegex } else { $null }
    $services = if ($cleanProps -contains 'services') { @($rule.clean.services) } else { @() }
    $cutoff = if ($olderDays -gt 0) { (Get-Date).AddDays(-$olderDays) } else { [datetime]::MaxValue }
    foreach ($p in (Expand-RulePath $rule.path)) {
        $bl = Test-PathBlacklisted $p
        if ($bl) { Write-Warning "拒絕（黑名單）: $p"; continue }
        $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        if (-not $item.PSIsContainer) {
            if ($item.LastWriteTime -lt $cutoff) {
                $plan.Add([pscustomobject]@{
                        RuleId = $rule.id; Risk = $rule.risk; Type = 'DeleteFile'; Path = $p; Bytes = [int64]$item.Length; Files = 1
                        Note = $rule.note; Services = @(); Keyword = ''; Items = $null
                    })
            }
            continue
        }
        $found = Get-CleanupFiles -RootPath $p -OlderThan $cutoff -NameRegex $nameRx
        $bytes = [int64](($found.Files | Measure-Object Length -Sum).Sum)
        $plan.Add([pscustomobject]@{
                RuleId = $rule.id; Risk = $rule.risk; Type = 'DeleteContents'; Path = $p; Bytes = $bytes; Files = $found.Files.Count
                Note = $rule.note; Services = $services; Keyword = ''; Items = $found
            })
    }
}

# --- 預覽輸出
$planCsv = Join-Path $runDir 'cleanup-plan.csv'
$plan | Select-Object RuleId, Risk, Type, Path, Bytes, Files, Note | Export-Csv -LiteralPath $planCsv -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host ("清理計畫（Tier={0}，{1}）" -f $Tier, $(if ($Execute) { '執行模式' } else { '預覽模式：不會變動任何檔案' })) -ForegroundColor Cyan
if ($plan.Count -eq 0) { Write-Host '沒有符合的項目。'; return }
$plan | ForEach-Object {
    Write-Host ("  [{0}] {1,12}  {2,6} 檔  {3}" -f $_.RuleId, (Format-Size $_.Bytes), $_.Files, $_.Path)
}
$totalBytes = [int64](($plan | Measure-Object Bytes -Sum).Sum)
Write-Host ("合計預估釋放約 {0}（估計值；實際以清理後可用空間為準）。計畫檔: {1}" -f (Format-Size $totalBytes), $planCsv) -ForegroundColor Yellow

if (-not $Execute) {
    Write-Host ''
    Write-Host '這是預覽。確認清單無誤後，加上 -Execute 才會實際清理。' -ForegroundColor Yellow
    return
}

# Review 層預設僅提供建議（見 PLAN_REVIEW.md）：需明確加 -AllowReview 才允許逐項確認後執行
if ($Tier -eq 'Review' -and -not $AllowReview) {
    Write-Host ''
    Write-Host 'Review 層預設只提供建議，不會執行。確認清單後如要逐項確認並執行，請加上 -AllowReview。' -ForegroundColor Yellow
    return
}

# --- 執行前置檢查
if (-not $isAdmin) { Write-Warning '目前非系統管理員，系統層級項目可能失敗。' }
$firstPath = ($plan | Select-Object -First 1).Path
$volRoot = [IO.Path]::GetPathRoot($env:SystemDrive + '\')
$before = Get-FixedVolumeInfo $volRoot

if ($Tier -eq 'Safe') {
    if (-not $Force) {
        $a = Confirm-Choice -Prompt ("確認清理以上 {0} 項（約 {1}）？ [Y/N] > " -f $plan.Count, (Format-Size $totalBytes)) -Valid @('Y', 'N')
        if ($a -ne 'Y') { Write-Host '已取消。'; return }
    }
}

if (-not $SkipRestorePoint -and $isAdmin) {
    $a = Confirm-Choice -Prompt '是否先建立系統還原點？(建議) [Y/N] > ' -Valid @('Y', 'N')
    if ($a -eq 'Y') {
        try { Checkpoint-Computer -Description "DiskAudit cleanup $stamp" -RestorePointType MODIFY_SETTINGS; Write-Host '已建立還原點。' -ForegroundColor Green }
        catch { Write-Warning "建立還原點失敗（可能 24 小時內已建立）: $($_.Exception.Message)" }
    }
}

# --- 執行
$allYes = $false
$freed = 0L
foreach ($it in $plan) {
    if ($it.Risk -eq 'Review') {
        if ($it.Keyword) {
            $typed = Read-LineTimeout -Prompt ("[{0}] 高風險動作，請輸入「{1}」確認（其他輸入視為取消）> " -f $it.RuleId, $it.Keyword) -TimeoutSeconds $ConfirmTimeoutSeconds
            if ($typed -ne $it.Keyword) { Write-CleanupLog $it.RuleId $it.Path 'Skip' $it.Bytes 'Skipped' 'keyword mismatch' 'user'; Write-Host '  略過。'; continue }
        }
        elseif (-not $allYes) {
            Write-Host ''
            Write-Host ("[{0}] {1}  ({2}, {3} 檔)" -f $it.RuleId, $it.Path, (Format-Size $it.Bytes), $it.Files) -ForegroundColor Yellow
            Write-Host ("  說明: {0}" -f $it.Note)
            $a = Confirm-Choice -Prompt '  清理？ [Y]是 [N]否 [A]其餘全是 [S]略過 [Q]中止 > ' -Valid @('Y', 'N', 'A', 'S', 'Q')
            if ($a -eq 'Q') { break }
            if ($a -eq 'A') { $allYes = $true }
            elseif ($a -ne 'Y') { Write-CleanupLog $it.RuleId $it.Path 'Skip' $it.Bytes 'Skipped' '' 'user'; continue }
        }
    }

    $confirmedBy = if ($Tier -eq 'Safe' -and $Force) { 'force' } else { 'user' }

    if ($it.Type -eq 'Command') {
        try {
            Write-Host ("執行: {0}" -f $it.Path)
            Invoke-Expression $it.Path | Out-Host
            Write-CleanupLog $it.RuleId $it.Path 'Command' $it.Bytes 'Done' '' $confirmedBy
        }
        catch { Write-CleanupLog $it.RuleId $it.Path 'Command' $it.Bytes 'Failed' $_.Exception.Message $confirmedBy; Write-Warning $_.Exception.Message }
        continue
    }

    # 暫停服務（結束時必定恢復為原狀態）
    $svcState = @{}
    foreach ($s in $it.Services) {
        try {
            $svc = Get-Service -Name $s -ErrorAction Stop
            $svcState[$s] = $svc.Status
            if ($svc.Status -eq 'Running') { Stop-Service -Name $s -Force -ErrorAction Stop }
        } catch { Write-Warning "無法停止服務 ${s}: $($_.Exception.Message)" }
    }
    try {
        if ($it.Type -eq 'DeleteFile') {
            $files = @([IO.FileInfo]$it.Path)
            $dirs = @()
        }
        else { $files = @($it.Items.Files); $dirs = @($it.Items.Dirs) }

        $done = 0; $fail = 0; $bytesDone = 0L
        foreach ($f in $files) {
            if (Test-PathBlacklisted $f.FullName) { $fail++; continue }
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $done++; $bytesDone += $f.Length
            } catch { $fail++ }
        }
        # 刪除變空的子資料夾（由深到淺；非空者 Remove-Item 會失敗並略過）
        foreach ($d in ($dirs | Sort-Object { $_.Length } -Descending)) {
            try {
                if (-not (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                    Remove-Item -LiteralPath $d -Force -ErrorAction Stop
                }
            } catch { }
        }
        $freed += $bytesDone
        $res = if ($fail -eq 0) { 'Done' } elseif ($done -gt 0) { 'Partial' } else { 'Failed' }
        Write-CleanupLog $it.RuleId $it.Path $it.Type $bytesDone $res ("deleted=$done failed(locked/denied)=$fail") $confirmedBy
        Write-Host ("  {0}: 刪除 {1} 檔（{2}），略過/失敗 {3}" -f $it.RuleId, $done, (Format-Size $bytesDone), $fail) -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
    }
    finally {
        foreach ($s in $svcState.Keys) {
            if ($svcState[$s] -eq 'Running') {
                try { Start-Service -Name $s -ErrorAction Stop } catch { Write-Warning "服務 $s 恢復失敗: $($_.Exception.Message)" }
            }
        }
    }
}

$after = Get-FixedVolumeInfo $volRoot
Write-Host ''
if ($before -and $after) {
    Write-Host ("完成。{0} 可用空間：{1} → {2}（變化 {3}）；本次刪除檔案合計約 {4}。" -f $volRoot, (Format-Size $before.Free), (Format-Size $after.Free), (Format-Size ($after.Free - $before.Free)), (Format-Size $freed)) -ForegroundColor Green
}
Write-Host ("記錄: {0}" -f $logPath)
