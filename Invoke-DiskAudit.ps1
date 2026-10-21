<#
.SYNOPSIS
    磁碟容量稽核（唯讀）：一次掃描 → 資料夾/大檔/副檔名排行、已知可清理項目、重複檔、久未使用大檔、與上次比較。
.DESCRIPTION
    本腳本不會刪除、移動或修改任何被掃描的檔案；唯一寫入位置是 -OutDir 下的報表資料夾。
    需要清理請使用 Invoke-DiskCleanup.ps1（預設 -WhatIf）。
.PARAMETER Root
    要掃描的磁碟或資料夾，可多個。預設 C:\
.PARAMETER OutDir
    報表輸出資料夾，預設為腳本所在資料夾的 reports\
.EXAMPLE
    .\Invoke-DiskAudit.ps1
.EXAMPLE
    .\Invoke-DiskAudit.ps1 -Root C:\,D:\Downloads -Depth 4 -Top 40 -SkipDupes
#>
[CmdletBinding()]
param(
    [string[]]$Root = @('C:\'),
    [string]$OutDir,
    [int]$Depth = 3,
    [int]$Top = 30,
    [int]$MinFileMB = 200,
    [int]$OldDays = 180,
    [int]$DupMinMB = 10,
    [int]$Threads = 0,
    [int]$HashMaxGB = 50,
    [int]$MaxMinutes = 0,
    [switch]$SkipDupes,
    [switch]$WinSxS,
    [switch]$NoOpen,
    [string]$RulesPath
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'DiskAudit.Common.ps1')
Initialize-DiskScanner -SourcePath (Join-Path $scriptDir 'DiskScanner.cs')

if (-not $RulesPath) { $RulesPath = Join-Path $scriptDir 'known-targets.json' }
if (-not $OutDir) { $OutDir = Join-Path $scriptDir 'reports' }
if ($Threads -le 0) { $Threads = [Math]::Min([Environment]::ProcessorCount, 8) }
if ($Depth -lt 1) { $Depth = 1 }
if ($Top -lt 1) { $Top = 1 }
$isAdmin = Test-IsAdmin

# ---------------------------------------------------------------- 參數檢查
$roots = @()
foreach ($r in $Root) {
    if (-not (Test-Path -LiteralPath $r)) { throw "掃描路徑不存在: $r" }
    $full = (Resolve-Path -LiteralPath $r).ProviderPath
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    $roots += $full
}
$roots = @($roots | Select-Object -Unique)

$hasNetwork = $false
foreach ($r in $roots) {
    if ($r.StartsWith('\\')) { $hasNetwork = $true }
    else {
        $vi = Get-FixedVolumeInfo $r
        if ($vi -and $vi.Type -eq 'Network') { $hasNetwork = $true }
    }
}
if ($hasNetwork -and -not $SkipDupes) {
    Write-Warning '掃描範圍含網路路徑，已自動略過重複檔 hash（避免大量網路流量）。'
    $SkipDupes = $true
}

# 掃描根目錄不可互相包含（否則重複計算）
foreach ($a in $roots) {
    foreach ($b in $roots) {
        if ($a -ine $b -and (($b.TrimEnd('\') + '\').StartsWith($a.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw "掃描根目錄不可互相包含：$a 與 $b"
        }
    }
}
# 報表不可寫在被掃描範圍內（會污染統計，且 C 槽爆滿時更糟）
$outFull = [IO.Path]::GetFullPath($OutDir)
foreach ($r in $roots) {
    if (($outFull.TrimEnd('\') + '\').StartsWith($r.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "報表位置不可位於掃描根目錄內：$outFull（請用 -OutDir 指向範圍外的資料夾）"
    }
}
$vOut = Get-FixedVolumeInfo $outFull
if ($vOut -and $vOut.Free -lt 200MB) { throw "報表輸出磁碟剩餘空間不足 200MB: $($vOut.Root)" }

$ruleSet = Import-DiskAuditRules -Path $RulesPath

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$reportDir = Join-Path $outFull $stamp
if (Test-Path $reportDir) { $reportDir = Join-Path $outFull (Get-Date -Format 'yyyyMMdd-HHmmss') }
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

Write-Host ''
Write-Host "DiskAudit $script:DiskAuditVersion  (唯讀稽核)" -ForegroundColor Cyan
Write-Host ("  範圍      : {0}" -f ($roots -join ', '))
Write-Host ("  管理員    : {0}" -f $(if ($isAdmin) { '是' } else { '否（部分系統資料夾將無法讀取）' }))
Write-Host ("  執行緒    : $Threads    報表: $reportDir")
Write-Host ''

# ---------------------------------------------------------------- 掃描
$collectMin = [Math]::Min($MinFileMB, $DupMinMB) * 1MB
$opt = New-Object DiskAudit.ScanOptions
$opt.Threads = $Threads
$opt.CollectMinBytes = [int64]$collectMin
$scanner = New-Object DiskAudit.DiskScanner ($opt)

$startTime = Get-Date
$proc = Get-Process -Id $PID
$origPriority = $proc.PriorityClass
$task = $null
try {
    try { $proc.PriorityClass = 'BelowNormal' } catch { }
    $task = $scanner.RunAsync([string[]]$roots)
    while (-not $task.IsCompleted) {
        Start-Sleep -Milliseconds 500
        $cur = [string]$scanner.Current
        if ($cur.Length -gt 90) { $cur = '...' + $cur.Substring($cur.Length - 87) }
        if (-not $cur) { $cur = ' ' }
        Write-Progress -Activity '掃描磁碟中' -Status ('{0:N0} 個檔案 / {1:N0} 個資料夾 / 已計 {2}' -f $scanner.Files, $scanner.Dirs, (Format-Size $scanner.TotalDisk)) -CurrentOperation $cur
        if ($MaxMinutes -gt 0 -and ((Get-Date) - $startTime).TotalMinutes -ge $MaxMinutes) {
            Write-Warning "已達 -MaxMinutes $MaxMinutes 分鐘，停止掃描並輸出部分結果。"
            $scanner.Cancel()
            $null = $task.Wait(30000)
            break
        }
    }
    if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
}
finally {
    if ($task -and -not $task.IsCompleted) { $scanner.Cancel(); $null = $task.Wait(15000) }
    try { $proc.PriorityClass = $origPriority } catch { }
    Write-Progress -Activity '掃描磁碟中' -Completed
}
$scanSeconds = [int]((Get-Date) - $startTime).TotalSeconds
$partial = $scanner.Cancelled
Write-Host ("掃描完成：{0:N0} 檔案、{1:N0} 資料夾、{2}，耗時 {3} 秒。無法讀取 {4:N0} 個路徑。" -f `
    $scanner.Files, $scanner.Dirs, (Format-Size $scanner.TotalDisk), $scanSeconds, $scanner.Denied) -ForegroundColor Green

# ---------------------------------------------------------------- 工具函式
function Get-Pct { param($Part, $Whole) if ($Whole -le 0) { 0 } else { [Math]::Round(100.0 * $Part / $Whole, 1) } }
function HtmlEncodeValue { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Test-UnderRoot {
    param([string]$Path, [string[]]$Roots)
    foreach ($r in $Roots) {
        $rp = $r.TrimEnd('\') + '\'
        if (($Path.TrimEnd('\') + '\').StartsWith($rp, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Convert-Ticks {
    param([int64]$Ticks)
    if ($Ticks -le 0) { return '' }
    return [datetime]::new($Ticks, [DateTimeKind]::Utc).ToLocalTime().ToString('yyyy-MM-dd')
}

$cutoffTicks = [int64](Get-Date).AddDays(-$OldDays).ToUniversalTime().Ticks
$collected = $scanner.GetCollected()

# ---------------------------------------------------------------- 磁碟總覽
$volumes = @()
foreach ($d in @($roots | ForEach-Object { [IO.Path]::GetPathRoot($_) } | Select-Object -Unique)) {
    $vi = Get-FixedVolumeInfo $d
    if ($vi) {
        $pctFree = Get-Pct $vi.Free $vi.Total
        $light = if ($pctFree -lt 5) { 'red' } elseif ($pctFree -lt 15) { 'yellow' } else { 'green' }
        $volumes += [pscustomobject]@{ Root = $vi.Root; Total = $vi.Total; Used = $vi.Used; Free = $vi.Free; PctFree = $pctFree; Light = $light }
    }
}

# ---------------------------------------------------------------- 資料夾排行
$allDirs = New-Object System.Collections.Generic.List[object]
$rootRecs = @{}
foreach ($r in $roots) {
    $norm = if ($r.Length -eq 2) { $r + '\' } else { $r }
    foreach ($rec in $scanner.GetDirs($norm, $Depth)) {
        $allDirs.Add($rec)
        if ($rec.Depth -eq 0) { $rootRecs[$rec.Path] = $rec }
    }
}
$folderRows = @($allDirs | Where-Object { $_.Depth -ge 1 } | Sort-Object Disk -Descending | Select-Object -First 500)

# 子節點索引（供 HTML 樹狀圖）
$childIndex = @{}
foreach ($rec in $allDirs) {
    if ($rec.Depth -eq 0) { continue }
    $parent = [IO.Path]::GetDirectoryName($rec.Path)
    if (-not $childIndex.ContainsKey($parent)) { $childIndex[$parent] = New-Object System.Collections.Generic.List[object] }
    $childIndex[$parent].Add($rec)
}

# ---------------------------------------------------------------- 大檔 / 副檔名 / 使用者 profile
$topFiles = @($collected | Sort-Object Disk -Descending | Select-Object -First 50 | ForEach-Object {
        [pscustomobject]@{
            Path = $_.Path; SizeBytes = $_.Disk; Size = (Format-Size $_.Disk); LogicalBytes = $_.Logical
            Extension = $_.Ext
            LastWrite = (Convert-Ticks $_.MTimeTicks)
            LastAccess = (Convert-Ticks $_.ATimeTicks)
        }
    })

$extRows = @($scanner.ExtTotals.GetEnumerator() | Sort-Object { $_.Value[0] } -Descending | Select-Object -First 25 | ForEach-Object {
        [pscustomobject]@{ Extension = $(if ($_.Key) { $_.Key } else { '(無副檔名)' }); SizeBytes = $_.Value[0]; Size = (Format-Size $_.Value[0]); Files = $_.Value[1] }
    })

$profileRows = @()
foreach ($r in $roots) {
    $usersRoot = Join-Path ([IO.Path]::GetPathRoot($r)) 'Users'
    if (-not (Test-UnderRoot $usersRoot $roots)) { continue }
    if (-not (Test-Path -LiteralPath $usersRoot)) { continue }
    foreach ($u in Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue) {
        $uTotal = $scanner.GetDirDisk($u.FullName)
        if ($uTotal -lt 0) { continue }
        foreach ($sub in '.', 'AppData\Local', 'AppData\Roaming', 'Downloads', 'Desktop', 'Documents', 'Videos', 'Pictures', 'Music', 'OneDrive') {
            $p = if ($sub -eq '.') { $u.FullName } else { Join-Path $u.FullName $sub }
            $sz = $scanner.GetDirDisk($p)
            if ($sz -ge 0) {
                $profileRows += [pscustomobject]@{ User = $u.Name; Folder = $(if ($sub -eq '.') { '(整個 profile)' } else { $sub }); SizeBytes = $sz; Size = (Format-Size $sz) }
            }
        }
    }
}
$profileRows = @($profileRows | Sort-Object User, @{ Expression = 'SizeBytes'; Descending = $true })

# ---------------------------------------------------------------- 規則比對
$candidates = New-Object System.Collections.Generic.List[object]
$ruleHits = New-Object System.Collections.Generic.List[object]
foreach ($rule in $ruleSet.Rules) {
    foreach ($p in (Expand-RulePath $rule.path)) {
        if (-not (Test-UnderRoot $p $roots)) { continue }
        $ruleHits.Add([pscustomobject]@{ Rule = $rule; Path = $p })
    }
}
# 去除重疊（子路徑被父路徑涵蓋者）
$accepted = New-Object System.Collections.Generic.List[object]
foreach ($h in ($ruleHits | Sort-Object { $_.Path.Length })) {
    $covered = $false
    foreach ($a in $accepted) {
        if (($h.Path.TrimEnd('\') + '\').StartsWith(($a.Path.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase) -and $h.Path -ne $a.Path) { $covered = $true; break }
    }
    if (-not $covered) { $accepted.Add($h) }
}

Write-Host ("比對 {0} 個已知清理位置..." -f $accepted.Count)
foreach ($h in $accepted) {
    $rule = $h.Rule; $p = $h.Path
    $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if (-not $item) { continue }
    $cleanProps = $rule.clean.PSObject.Properties.Name
    $olderDays = if ($cleanProps -contains 'olderThanDays') { [int]$rule.clean.olderThanDays } else { 0 }
    $nameRx = if ($cleanProps -contains 'nameRegex') { [string]$rule.clean.nameRegex } else { $null }
    $total = 0L; $reclaim = 0L; $files = 0L
    if (-not $item.PSIsContainer) {
        $total = [int64]$item.Length; $reclaim = $total; $files = 1
    }
    elseif ($olderDays -gt 0 -or $nameRx) {
        $cut = if ($olderDays -gt 0) { [int64](Get-Date).AddDays(-$olderDays).ToUniversalTime().Ticks } else { 0 }
        $m = [DiskAudit.DiskScanner]::Measure($p, $cut, $nameRx, 2)
        $total = [int64]$m[0]; $files = [int64]$m[2]
        $reclaim = if ($cut -gt 0) { [int64]$m[3] } else { $total }
    }
    else {
        $sz = $scanner.GetDirDisk($p)
        if ($sz -ge 0) { $total = $sz }
        else { $m = [DiskAudit.DiskScanner]::Measure($p, 0, $null, 2); $total = [int64]$m[0]; $files = [int64]$m[2] }
        $reclaim = $total
    }
    $measureNone = ($rule.PSObject.Properties.Name -contains 'measure') -and $rule.measure -eq 'none'
    if ($measureNone) { $reclaim = 0 }
    $manualOnly = ($cleanProps -contains 'manualOnly') -and $rule.clean.manualOnly
    $candidates.Add([pscustomobject]@{
            Kind = '規則'; Risk = $rule.risk; Category = $rule.category; Id = $rule.id; Path = $p
            SizeBytes = $total; Size = (Format-Size $total)
            ReclaimBytes = $reclaim; Reclaim = (Format-Size $reclaim)
            CanAutoClean = ((-not $manualOnly) -and $rule.clean.type -ne 'None')
            Note = $rule.note; Action = $rule.action
        })
}

# 還原點 / 陰影複製儲存空間（唯讀資訊）
if ($isAdmin) {
    try {
        $vss = & vssadmin.exe list shadowstorage 2>$null
        if ($vss) {
            $usedLine = @($vss | Where-Object { $_ -match '([\d\.,]+)\s*(KB|MB|GB|TB)' }) | Select-Object -First 1
            $sz = 0L
            if ($usedLine -match '([\d\.,]+)\s*(KB|MB|GB|TB)') {
                $num = [double]($Matches[1] -replace ',', '')
                $mult = switch ($Matches[2]) { 'KB' { 1KB } 'MB' { 1MB } 'GB' { 1GB } 'TB' { 1TB } }
                $sz = [int64]($num * $mult)
            }
            $candidates.Add([pscustomobject]@{
                    Kind = '規則'; Risk = 'Review'; Category = '還原點'; Id = 'vss-shadowstorage'; Path = '(Volume Shadow Copy)'
                    SizeBytes = $sz; Size = (Format-Size $sz); ReclaimBytes = 0; Reclaim = (Format-Size 0); CanAutoClean = $false
                    Note = ('系統還原/陰影複製佔用（首列數值：{0}）。縮小上限或刪除舊還原點可釋放，需自行決定。' -f ($usedLine -join ' ').Trim())
                    Action = 'vssadmin list shadowstorage   /   vssadmin Resize ShadowStorage /For=C: /On=C: /MaxSize=10GB'
                })
        }
    } catch { }
}

# WinSxS 真實大小（選用，需管理員，約 1~2 分鐘）
$winsxsInfo = $null
if ($WinSxS) {
    if (-not $isAdmin) { Write-Warning '-WinSxS 需要系統管理員權限，已略過。' }
    else {
        Write-Host '以 DISM 分析元件存放區（唯讀，約 1~2 分鐘）...'
        try {
            $out = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1
            $winsxsInfo = @($out | Where-Object { $_ -match '(?i)Size|大小|Cleanup|清理' } | ForEach-Object { [string]$_ })
        } catch { Write-Warning "DISM 分析失敗: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- 使用者資料層級：安裝包 / 大且久未用
$installerExt = '.iso', '.exe', '.msi', '.zip', '.7z', '.rar', '.cab', '.msu', '.img', '.dmg'
$userDataCandidates = New-Object System.Collections.Generic.List[object]
foreach ($f in $collected) {
    if ($f.Ext -and ($installerExt -contains $f.Ext.ToLowerInvariant()) -and $f.Path -match '\\(Downloads|Desktop)\\') {
        $userDataCandidates.Add([pscustomobject]@{
                Kind = '安裝包/封存檔'; Risk = 'Manual'; Category = '使用者資料'; Id = 'installer-archive'; Path = $f.Path
                SizeBytes = $f.Disk; Size = (Format-Size $f.Disk); ReclaimBytes = $f.Disk; Reclaim = (Format-Size $f.Disk); CanAutoClean = $false
                Note = '位於 Downloads/Desktop 的安裝包或壓縮檔，確認已安裝/已解壓後可刪除。'; Action = '人工檢視後送資源回收筒'
            })
    }
}
$oldLarge = @($collected | Where-Object { $_.Logical -ge ($MinFileMB * 1MB) -and $_.MTimeTicks -gt 0 -and $_.MTimeTicks -lt $cutoffTicks } |
        Sort-Object Disk -Descending | Select-Object -First 200)
foreach ($f in $oldLarge) {
    $userDataCandidates.Add([pscustomobject]@{
            Kind = '大且久未用'; Risk = 'Manual'; Category = '使用者資料'; Id = 'old-large'; Path = $f.Path
            SizeBytes = $f.Disk; Size = (Format-Size $f.Disk); ReclaimBytes = $f.Disk; Reclaim = (Format-Size $f.Disk); CanAutoClean = $false
            Note = ('{0} 以上未修改（最後修改 {1}）。' -f "$OldDays 天", (Convert-Ticks $f.MTimeTicks))
            Action = '人工檢視後搬到其他磁碟或送資源回收筒'
        })
}

# ---------------------------------------------------------------- 重複檔
$dupRows = @()
$dupGroups = @()
$dupReclaim = 0L
if (-not $SkipDupes -and -not $partial) {
    Write-Host ("比對重複檔（>= {0} MB，hash 預算上限 {1} GB）..." -f $DupMinMB, $HashMaxGB)
    # 與原版一致：系統/程式目錄不比對重複檔（重複屬正常現象，且不可處置）
    $dupSkipPrefixes = [string[]]@(
        ($env:SystemRoot.TrimEnd('\') + '\'), ($env:ProgramFiles.TrimEnd('\') + '\'),
        ($(if (${env:ProgramFiles(x86)}) { ${env:ProgramFiles(x86)}.TrimEnd('\') + '\' } else { $env:ProgramFiles.TrimEnd('\') + '\' })),
        ($env:ProgramData.TrimEnd('\') + '\'))
    $dtask = $scanner.FindDuplicatesAsync([int64]($DupMinMB * 1MB), [int64]($HashMaxGB * 1GB), [string[]]('.sys', '.dll', '.mui'), $dupSkipPrefixes)
    while (-not $dtask.IsCompleted) {
        Start-Sleep -Milliseconds 500
        Write-Progress -Activity '比對重複檔' -Status ('已雜湊 {0} / 預計 {1}' -f (Format-Size $scanner.HashedBytes), (Format-Size $scanner.HashPlannedBytes))
    }
    Write-Progress -Activity '比對重複檔' -Completed
    if ($dtask.IsFaulted) { throw $dtask.Exception.GetBaseException() }
    $dupGroups = @($dtask.Result)
    $gid = 0
    foreach ($g in $dupGroups) {
        $gid++
        $sorted = @($g.Paths | Sort-Object { $_.Length })
        $reclaimG = [int64]$g.Size * ($g.Paths.Count - 1)
        $dupReclaim += $reclaimG
        $i = 0
        foreach ($p in $sorted) {
            $dupRows += [pscustomobject]@{
                GroupId = $gid; SizeBytes = $g.Size; Size = (Format-Size $g.Size); Copies = $g.Paths.Count
                GroupReclaimBytes = $reclaimG; GroupReclaim = (Format-Size $reclaimG)
                Path = $p; KeepSuggestion = $(if ($i -eq 0) { '建議保留(路徑最短)' } else { '' }); Hash = $g.Hash
            }
            $i++
        }
    }
}

# ---------------------------------------------------------------- 已安裝程式（依大小）
$programRows = @()
try {
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $programRows = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
            Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' -and $_.DisplayName -and $_.PSObject.Properties.Name -contains 'EstimatedSize' -and $_.EstimatedSize } |
            Sort-Object EstimatedSize -Descending | Select-Object -First 25 | ForEach-Object {
                [pscustomobject]@{ Name = $_.DisplayName; SizeBytes = [int64]$_.EstimatedSize * 1KB; Size = (Format-Size ([int64]$_.EstimatedSize * 1KB)); Publisher = $(if ($_.PSObject.Properties.Name -contains 'Publisher') { $_.Publisher } else { '' }) }
            })
} catch { }

# ---------------------------------------------------------------- 與上次比較
$prevDir = $null
if (Test-Path $outFull) {
    $prevDir = Get-ChildItem -LiteralPath $outFull -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $reportDir -and (Test-Path (Join-Path $_.FullName 'snapshot.json')) } |
        Sort-Object Name -Descending | Select-Object -First 1
}
$compare = $null
$snapDirs = @($allDirs | Where-Object { $_.Depth -ge 1 -and $_.Depth -le $Depth } | ForEach-Object { @{ p = $_.Path; d = $_.Disk } })
if ($prevDir) {
    try {
        $prev = Get-Content -LiteralPath (Join-Path $prevDir.FullName 'snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $prevMap = @{}
        foreach ($d in $prev.dirs) { $prevMap[[string]$d.p] = [int64]$d.d }
        $growth = @()
        foreach ($rec in ($allDirs | Where-Object { $_.Depth -ge 1 })) {
            if ($prevMap.ContainsKey($rec.Path)) {
                $delta = $rec.Disk - $prevMap[$rec.Path]
                if ($delta -ne 0) { $growth += [pscustomobject]@{ Path = $rec.Path; Delta = [int64]$delta; Now = $rec.Disk; Before = $prevMap[$rec.Path] } }
            }
        }
        $volDelta = @()
        foreach ($v in $volumes) {
            $pv = @($prev.volumes | Where-Object { $_.Root -eq $v.Root })
            if ($pv.Count -gt 0) { $volDelta += [pscustomobject]@{ Root = $v.Root; UsedDelta = [int64]($v.Used - [int64]$pv[0].Used); Before = [int64]$pv[0].Used; Now = $v.Used } }
        }
        $compare = [pscustomobject]@{
            PreviousTime = $prev.time; Volumes = $volDelta
            Growth = @($growth | Sort-Object Delta -Descending | Select-Object -First 20)
            Shrink = @($growth | Sort-Object Delta | Select-Object -First 10 | Where-Object { $_.Delta -lt 0 })
        }
    } catch { Write-Warning "讀取上次快照失敗: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- 彙總
$all = $candidates.ToArray() + $userDataCandidates.ToArray()
$sumSafe = [int64]0; $sumReview = [int64]0; $sumManual = [int64]0; $sumUser = [int64]0
foreach ($candidate in $candidates) {
    switch ($candidate.Risk) {
        'Safe' { $sumSafe += [int64]$candidate.ReclaimBytes }
        'Review' { $sumReview += [int64]$candidate.ReclaimBytes }
        'Manual' { $sumManual += [int64]$candidate.SizeBytes }
    }
}
foreach ($candidate in $userDataCandidates) { $sumUser += [int64]$candidate.ReclaimBytes }

# ---------------------------------------------------------------- 輸出 CSV / JSON
$folderCsv = $folderRows | ForEach-Object {
    [pscustomobject]@{
        Path = $_.Path; Depth = $_.Depth; DiskBytes = $_.Disk; DiskSize = (Format-Size $_.Disk)
        LogicalBytes = $_.Logical; Files = $_.Files
    }
}
$folderCsv | Export-Csv -LiteralPath (Join-Path $reportDir 'top-folders.csv') -NoTypeInformation -Encoding UTF8
$topFiles | Export-Csv -LiteralPath (Join-Path $reportDir 'top-files.csv') -NoTypeInformation -Encoding UTF8
$extRows | Export-Csv -LiteralPath (Join-Path $reportDir 'extensions.csv') -NoTypeInformation -Encoding UTF8
$all | Select-Object Kind, Risk, Category, Id, Path, SizeBytes, Size, ReclaimBytes, Reclaim, CanAutoClean, Note, Action |
    Export-Csv -LiteralPath (Join-Path $reportDir 'candidates.csv') -NoTypeInformation -Encoding UTF8
if ($dupRows.Count -gt 0) { $dupRows | Select-Object -First 5000 | Export-Csv -LiteralPath (Join-Path $reportDir 'dupes.csv') -NoTypeInformation -Encoding UTF8 }
else { 'GroupId,SizeBytes,Size,Copies,GroupReclaimBytes,GroupReclaim,Path,KeepSuggestion,Hash' | Out-File -LiteralPath (Join-Path $reportDir 'dupes.csv') -Encoding UTF8 }
# 檔名與原版 DiskAudit 對齊（installed-programs / old-large-files / installers-archives / zero-byte-files / empty-folders / scan-errors）
@($programRows) | Export-Csv -LiteralPath (Join-Path $reportDir 'installed-programs.csv') -NoTypeInformation -Encoding UTF8
@($profileRows) | Export-Csv -LiteralPath (Join-Path $reportDir 'profiles.csv') -NoTypeInformation -Encoding UTF8
@($userDataCandidates | Where-Object Kind -eq '大且久未用') | Select-Object Path, SizeBytes, Size, Note |
    Export-Csv -LiteralPath (Join-Path $reportDir 'old-large-files.csv') -NoTypeInformation -Encoding UTF8
@($userDataCandidates | Where-Object Kind -eq '安裝包/封存檔') | Select-Object Path, SizeBytes, Size |
    Export-Csv -LiteralPath (Join-Path $reportDir 'installers-archives.csv') -NoTypeInformation -Encoding UTF8
@($scanner.ZeroSample() | ForEach-Object { [pscustomobject]@{ Path = $_ } }) |
    Export-Csv -LiteralPath (Join-Path $reportDir 'zero-byte-files.csv') -NoTypeInformation -Encoding UTF8
@($scanner.EmptyDirSample() | ForEach-Object { [pscustomobject]@{ Path = $_ } }) |
    Export-Csv -LiteralPath (Join-Path $reportDir 'empty-folders.csv') -NoTypeInformation -Encoding UTF8
@(@($scanner.DeniedSample() | ForEach-Object { [pscustomobject]@{ Type = '存取被拒'; Path = $_ } }) +
    @($scanner.ErrorSample() | ForEach-Object { [pscustomobject]@{ Type = '讀取錯誤'; Path = $_ } })) |
    Export-Csv -LiteralPath (Join-Path $reportDir 'scan-errors.csv') -NoTypeInformation -Encoding UTF8

# summary.json（欄位同原版，另含 Prev 比較用資訊）
[pscustomobject]@{
    Created = (Get-Date).ToString('s'); Roots = $roots; DurationSeconds = $scanSeconds
    FileCount = $scanner.Files; FolderCount = $scanner.Dirs; ErrorCount = ($scanner.Denied + $scanner.Errors)
    SkippedReparsePoints = $scanner.Reparse; CloudPlaceholders = $scanner.CloudPlaceholders
    Volumes = @($volumes | ForEach-Object { [pscustomobject]@{ Root = $_.Root; TotalBytes = $_.Total; FreeBytes = $_.Free; UsedBytes = $_.Used } })
    ScannedDiskBytes = $scanner.TotalDisk; ScannedLogicalBytes = $scanner.TotalLogical
    PreviousReport = $(if ($prevDir) { $prevDir.FullName } else { '' }); Partial = [bool]$partial; Version = $script:DiskAuditVersion
} | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $reportDir 'summary.json') -Encoding UTF8

$snapshot = @{
    time    = (Get-Date).ToString('s'); version = $script:DiskAuditVersion
    volumes = @($volumes | ForEach-Object { @{ Root = $_.Root; Used = $_.Used; Free = $_.Free; Total = $_.Total } })
    dirs    = $snapDirs
}
$snapshot | ConvertTo-Json -Depth 5 -Compress | Out-File -LiteralPath (Join-Path $reportDir 'snapshot.json') -Encoding UTF8

# ---------------------------------------------------------------- HTML 報表
function Write-TreeNode {
    param($sb, $Rec, [int64]$RootTotal, [int]$Level)
    $children = @()
    if ($childIndex.ContainsKey($Rec.Path)) {
        $children = @($childIndex[$Rec.Path] | Sort-Object Disk -Descending | Select-Object -First $Top)
    }
    $pct = Get-Pct $Rec.Disk $RootTotal
    $name = if ($Level -eq 0) { $Rec.Path } else { [IO.Path]::GetFileName($Rec.Path) }
    $bar = '<span class="bar"><i style="width:{0}%"></i></span>' -f [Math]::Min(100, [Math]::Max(0.5, $pct))
    $line = '<span class="n">{0}</span><span class="s">{1}</span><span class="p">{2}%</span>{3}<span class="f">{4:N0} 檔</span>' -f (HtmlEncodeValue $name), (Format-Size $Rec.Disk), $pct, $bar, $Rec.Files
    if ($children.Count -gt 0) {
        $open = if ($Level -eq 0) { ' open' } else { '' }
        [void]$sb.AppendLine("<details$open><summary>$line</summary><div class=`"kids`">")
        foreach ($c in $children) { Write-TreeNode $sb $c $RootTotal ($Level + 1) }
        [void]$sb.AppendLine('</div></details>')
    } else {
        [void]$sb.AppendLine("<div class=`"leaf`">$line</div>")
    }
}

function New-HtmlTable {
    param($Rows, [string[]]$Props, [string[]]$Headers, [string[]]$NumCols = @(), [string]$CodeCol = '')
    if (-not $Rows -or @($Rows).Count -eq 0) { return '<p class="muted">（無資料）</p>' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tw"><table><thead><tr>')
    foreach ($h in $Headers) { [void]$sb.Append("<th>$(HtmlEncodeValue $h)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($p in $Props) {
            $v = $r.$p
            $cls = if ($NumCols -contains $p) { ' class="num"' } else { '' }
            if ($p -eq $CodeCol -and $v) { [void]$sb.Append("<td$cls><code>$(HtmlEncodeValue $v)</code></td>") }
            else { [void]$sb.Append("<td$cls>$(HtmlEncodeValue $v)</td>") }
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

$h = New-Object System.Text.StringBuilder
$null = $h.AppendLine(@"
<!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>DiskAudit 容量稽核報表</title>
<style>
:root{--bg:#f7f7f5;--fg:#1d1d1b;--mut:#6b6b66;--card:#fff;--bd:#dcdcd5;--acc:#2a6df4;--ok:#1b8a4b;--warn:#b7791f;--bad:#c53030;--bar:#cfe0ff}
@media (prefers-color-scheme:dark){:root{--bg:#161615;--fg:#ecece8;--mut:#9a9a93;--card:#1f1f1d;--bd:#34342f;--acc:#6ea0ff;--ok:#4cc27d;--warn:#e0b050;--bad:#ff7a7a;--bar:#243a66}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.55 "Segoe UI","Microsoft JhengHei",sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:20px 16px 60px}
h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 10px;padding-bottom:6px;border-bottom:1px solid var(--bd)}
.muted{color:var(--mut)}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:10px;margin:12px 0}
.card{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:12px 14px}.card b{display:block;font-size:20px}
.light{display:inline-block;width:12px;height:12px;border-radius:50%;margin-right:6px;vertical-align:-1px}
.green{background:var(--ok)}.yellow{background:var(--warn)}.red{background:var(--bad)}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%;background:var(--card);border:1px solid var(--bd)}
th,td{padding:6px 9px;border-bottom:1px solid var(--bd);text-align:left;vertical-align:top;word-break:break-all}th{background:var(--bg);font-weight:600;white-space:nowrap}
td.num{text-align:right;white-space:nowrap}code{font:12px Consolas,monospace;background:var(--bg);padding:1px 4px;border-radius:3px;word-break:break-all}
details{margin-left:0}.kids{margin-left:18px;border-left:1px dotted var(--bd);padding-left:6px}
summary,.leaf{display:flex;align-items:center;gap:10px;padding:3px 4px;cursor:default}summary{cursor:pointer}
.n{flex:1;min-width:0;word-break:break-all}.s{width:90px;text-align:right;font-variant-numeric:tabular-nums}.p{width:52px;text-align:right;color:var(--mut)}
.f{width:90px;text-align:right;color:var(--mut)}.bar{width:120px;height:8px;background:var(--bd);border-radius:4px;overflow:hidden}.bar i{display:block;height:100%;background:var(--acc)}
.tag{display:inline-block;padding:0 7px;border-radius:9px;font-size:12px;border:1px solid var(--bd)}.Safe{color:var(--ok)}.Review{color:var(--warn)}.Manual{color:var(--mut)}
.note{background:var(--card);border-left:4px solid var(--warn);padding:8px 12px;margin:8px 0;border-radius:4px}
@media (max-width:640px){.bar,.f{display:none}}
</style></head><body><div class="wrap">
"@)

$null = $h.AppendLine("<h1>DiskAudit 容量稽核報表</h1>")
$null = $h.AppendLine(('<div class="muted">{0} · {1} · 範圍 {2} · 掃描 {3} 秒 · {4} · v{5}</div>' -f (HtmlEncodeValue $env:COMPUTERNAME), (Get-Date -Format 'yyyy-MM-dd HH:mm'), (HtmlEncodeValue ($roots -join ', ')), $scanSeconds, $(if ($isAdmin) { '系統管理員' } else { '一般權限' }), $script:DiskAuditVersion))

# 警示
if (-not $isAdmin) { $null = $h.AppendLine('<div class="note">目前非系統管理員身分，部分系統資料夾（C:\Windows 內部、其他使用者、System Volume Information）無法讀取，實際用量可能更高。請以系統管理員重新執行。</div>') }
if ($scanner.Denied -gt 0 -or $scanner.Errors -gt 0) { $null = $h.AppendLine(('<div class="note">有 {0:N0} 個路徑存取被拒、{1:N0} 個讀取錯誤（樣本見 scan-errors.csv）。掃描不完整時，數字是下限。</div>' -f $scanner.Denied, $scanner.Errors)) }
if ($partial) { $null = $h.AppendLine('<div class="note">掃描被中止，以下為部分結果。</div>') }
if ($scanner.CloudPlaceholders -gt 0) { $null = $h.AppendLine(('<div class="note">偵測到 {0:N0} 個雲端佔位檔（OneDrive 等，邏輯大小 {1}），不佔本機空間，未計入。</div>' -f $scanner.CloudPlaceholders, (Format-Size $scanner.CloudLogicalBytes))) }
if ($scanner.HashTruncated) { $null = $h.AppendLine(('<div class="note">重複檔比對受 -HashMaxGB {0} 上限限制，部分大檔群組未比對。</div>' -f $HashMaxGB)) }

# 磁碟總覽
$null = $h.AppendLine('<h2>磁碟總覽</h2><div class="cards">')
foreach ($v in $volumes) {
    $null = $h.AppendLine(('<div class="card"><span class="light {0}"></span><b>{1}</b>已用 {2} / {3}<br><span class="muted">可用 {4}（{5}%）</span></div>' -f $v.Light, (HtmlEncodeValue $v.Root), (Format-Size $v.Used), (Format-Size $v.Total), (Format-Size $v.Free), $v.PctFree))
}
$null = $h.AppendLine('</div>')

# 可回收估計
$null = $h.AppendLine('<h2>候選容量估計（非可回收保證）</h2><p class="muted">此處為「待評估項目」的容量：規則可能互相重疊、硬連結會重複計算、檔案可能被鎖定，不可當作清理後必然釋放的空間；實際以清理後可用空間為準。</p><div class="cards">')
$null = $h.AppendLine(('<div class="card"><span class="tag Safe">Safe</span><b>{0}</b><span class="muted">已知暫存/快取，可一次確認清理</span></div>' -f (Format-Size $sumSafe)))
$null = $h.AppendLine(('<div class="card"><span class="tag Review">Review</span><b>{0}</b><span class="muted">需確認用途後再清</span></div>' -f (Format-Size $sumReview)))
$null = $h.AppendLine(('<div class="card"><span class="tag Manual">Manual</span><b>{0}</b><span class="muted">系統保留/虛擬磁碟/使用者資料，由您決定</span></div>' -f (Format-Size $sumManual)))
$null = $h.AppendLine(('<div class="card"><span class="tag">重複檔</span><b>{0}</b><span class="muted">{1} 組，保留每組 1 份可省</span></div>' -f (Format-Size $dupReclaim), $dupGroups.Count))
$null = $h.AppendLine('</div>')

# 與上次比較
if ($compare) {
    $null = $h.AppendLine(('<h2>與上次比較（{0}）</h2>' -f (HtmlEncodeValue $compare.PreviousTime)))
    $vr = $compare.Volumes | ForEach-Object { [pscustomobject]@{ Root = $_.Root; Before = (Format-Size $_.Before); Now = (Format-Size $_.Now); Delta = ($(if ($_.UsedDelta -ge 0) { '+' } else { '-' }) + (Format-Size ([Math]::Abs($_.UsedDelta)))) } }
    $null = $h.AppendLine((New-HtmlTable $vr @('Root', 'Before', 'Now', 'Delta') @('磁碟', '上次已用', '現在已用', '變化') @('Before', 'Now', 'Delta')))
    $gr = $compare.Growth | Where-Object { $_.Delta -gt 0 } | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Delta = ('+' + (Format-Size $_.Delta)); Now = (Format-Size $_.Now) } }
    $null = $h.AppendLine('<p class="muted">成長最多的資料夾：</p>')
    $null = $h.AppendLine((New-HtmlTable $gr @('Path', 'Delta', 'Now') @('資料夾', '增加', '現在大小') @('Delta', 'Now')))
}

# 資料夾樹
$null = $h.AppendLine(('<h2>資料夾排行（展開至第 {0} 層，每層前 {1} 名）</h2>' -f $Depth, $Top))
$null = $h.AppendLine('<p class="muted">大小為「磁碟佔用」（含 NTFS 壓縮/稀疏檔校正）。硬連結（如 WinSxS）會使總和高估。</p>')
foreach ($r in $roots) {
    $norm = if ($r.Length -eq 2) { $r + '\' } else { $r }
    if ($rootRecs.ContainsKey($norm)) {
        $sb = New-Object System.Text.StringBuilder
        Write-TreeNode $sb $rootRecs[$norm] ([int64]$rootRecs[$norm].Disk) 0
        $null = $h.AppendLine($sb.ToString())
    }
}

# 規則命中
$null = $h.AppendLine('<h2>已知可清理位置（規則命中）</h2>')
$ruleRows = @($candidates | Sort-Object @{ Expression = { switch ($_.Risk) { 'Safe' { 0 } 'Review' { 1 } default { 2 } } } }, @{ Expression = 'SizeBytes'; Descending = $true })
$null = $h.AppendLine((New-HtmlTable $ruleRows @('Risk', 'Category', 'Path', 'Size', 'Reclaim', 'Note', 'Action') @('風險', '類別', '路徑', '大小', '可回收估計', '說明', '建議指令') @('Size', 'Reclaim') 'Action'))

# 大檔
$null = $h.AppendLine('<h2>大檔排行（前 50）</h2>')
$null = $h.AppendLine((New-HtmlTable $topFiles @('Path', 'Size', 'Extension', 'LastWrite', 'LastAccess') @('檔案', '大小', '副檔名', '最後修改', '最後存取') @('Size')))

# 副檔名
$null = $h.AppendLine('<h2>副檔名彙總（前 25）</h2>')
$null = $h.AppendLine((New-HtmlTable $extRows @('Extension', 'Size', 'Files') @('副檔名', '大小', '檔案數') @('Size', 'Files')))

# 使用者 profile
if ($profileRows.Count -gt 0) {
    $null = $h.AppendLine('<h2>使用者 profile 拆解</h2>')
    $null = $h.AppendLine((New-HtmlTable $profileRows @('User', 'Folder', 'Size') @('使用者', '資料夾', '大小') @('Size')))
}

# 重複檔
$null = $h.AppendLine(('<h2>重複檔（>= {0} MB，前 30 組）</h2>' -f $DupMinMB))
if ($SkipDupes) { $null = $h.AppendLine('<p class="muted">已略過重複檔比對。</p>') }
else {
    $dshow = @($dupRows | Where-Object { $_.GroupId -le 30 })
    $null = $h.AppendLine((New-HtmlTable $dshow @('GroupId', 'Size', 'Copies', 'GroupReclaim', 'Path', 'KeepSuggestion') @('群組', '單檔大小', '份數', '可省', '路徑', '建議') @('Size', 'Copies', 'GroupReclaim')))
}

# 久未用
$null = $h.AppendLine(('<h2>大且久未修改（>= {0} MB 且超過 {1} 天，前 30）</h2>' -f $MinFileMB, $OldDays))
$null = $h.AppendLine('<p class="muted">以最後修改時間判斷（NTFS 常停用最後存取時間記錄）。僅列出，不做任何處理。</p>')
$null = $h.AppendLine((New-HtmlTable @($userDataCandidates | Where-Object Kind -eq '大且久未用' | Select-Object -First 30) @('Path', 'Size', 'Note') @('檔案', '大小', '說明') @('Size')))

$null = $h.AppendLine('<h2>Downloads / Desktop 內的安裝包與封存檔</h2>')
$null = $h.AppendLine((New-HtmlTable @($userDataCandidates | Where-Object Kind -eq '安裝包/封存檔' | Sort-Object SizeBytes -Descending | Select-Object -First 30) @('Path', 'Size') @('檔案', '大小') @('Size')))

# 程式
if ($programRows.Count -gt 0) {
    $null = $h.AppendLine('<h2>已安裝程式（依登錄的預估大小，前 25）</h2>')
    $null = $h.AppendLine((New-HtmlTable $programRows @('Name', 'Size', 'Publisher') @('程式', '大小', '發行者') @('Size')))
}

# WinSxS
if ($winsxsInfo) {
    $null = $h.AppendLine('<h2>WinSxS 元件存放區（DISM 分析）</h2><pre>' + (HtmlEncodeValue ($winsxsInfo -join "`n")) + '</pre>')
}

# 空/零
$null = $h.AppendLine(('<h2>空資料夾與 0 byte 檔案</h2><p class="muted">空資料夾 {0:N0} 個、0 byte 檔案 {1:N0} 個（樣本見 empty-folders.csv / zero-byte-files.csv）。</p>' -f $scanner.EmptyDirs, $scanner.ZeroByteFiles))

$null = $h.AppendLine(('<h2>限制說明</h2><ul class="muted"><li>硬連結（WinSxS 等）會被重複計入；hiberfil/pagefile/還原點不在一般列舉內，另列於規則命中。</li><li>報表為掃描當下快照；{0} 之後新增/刪除的檔案不反映。</li><li>最後存取時間在 NTFS 常被關閉，故久未用以最後修改時間為準。</li><li>收集的大檔門檻為 {1} MB，低於此大小的檔案不會出現在大檔/重複檔/安裝包清單。</li></ul>' -f (Get-Date $startTime -Format 'HH:mm:ss'), [int]($collectMin / 1MB)))
$null = $h.AppendLine(('<div class="muted" style="margin-top:30px">DiskAudit v{0} · 規則庫 v{1} · PowerShell {2} · 本報表為唯讀稽核產出，未更動任何檔案。</div></div></body></html>' -f $script:DiskAuditVersion, (HtmlEncodeValue $ruleSet.Version), $PSVersionTable.PSVersion))

$htmlPath = Join-Path $reportDir 'summary.html'
[IO.File]::WriteAllText($htmlPath, $h.ToString(), (New-Object System.Text.UTF8Encoding($true)))

# ---------------------------------------------------------------- 主控台摘要
Write-Host ''
Write-Host '================ 摘要 ================' -ForegroundColor Cyan
foreach ($v in $volumes) {
    $color = switch ($v.Light) { 'red' { 'Red' } 'yellow' { 'Yellow' } default { 'Green' } }
    Write-Host ("{0}  已用 {1} / {2}，可用 {3} ({4}%)" -f $v.Root, (Format-Size $v.Used), (Format-Size $v.Total), (Format-Size $v.Free), $v.PctFree) -ForegroundColor $color
}
Write-Host ''
Write-Host '佔用前 10 名資料夾：'
$folderRows | Select-Object -First 10 | ForEach-Object { Write-Host ("  {0,12}  {1}" -f (Format-Size $_.Disk), $_.Path) }
Write-Host ''
Write-Host ("可回收估計  Safe: {0}   Review: {1}   Manual(可評估): {2}   重複檔: {3}" -f (Format-Size $sumSafe), (Format-Size $sumReview), (Format-Size $sumManual), (Format-Size $dupReclaim)) -ForegroundColor Yellow
Write-Host ("報表: {0}" -f $htmlPath) -ForegroundColor Green
Write-Host ''

[pscustomobject]@{
    ReportDir = $reportDir; Html = $htmlPath; SafeBytes = $sumSafe; ReviewBytes = $sumReview; ManualBytes = $sumManual
    DupReclaimBytes = $dupReclaim; Files = $scanner.Files; Dirs = $scanner.Dirs; Denied = $scanner.Denied; Seconds = $scanSeconds
    TotalDiskBytes = $scanner.TotalDisk; TotalLogicalBytes = $scanner.TotalLogical; ReportDir2 = $reportDir
}
if (-not $NoOpen) { try { Start-Process $htmlPath } catch { } }
