# DiskAudit.Common.ps1 - shared helpers (dot-sourced by Invoke-DiskAudit.ps1 / Invoke-DiskCleanup.ps1)
# 共用函式：格式化、黑名單、規則庫載入/驗證、路徑展開、逾時輸入。

Set-StrictMode -Version 2.0

$script:DiskAuditVersion = '1.0.0'

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -lt 0) { return 'n/a' }
    $units = 'B', 'KB', 'MB', 'GB', 'TB'
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} B' -f $Bytes) }
    return ('{0:N2} {1}' -f $Bytes, $units[$i])
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-DiskScanner {
    param([string]$SourcePath)
    if (-not ('DiskAudit.DiskScanner' -as [type])) {
        $src = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
        Add-Type -TypeDefinition $src -Language CSharp -ReferencedAssemblies System.Core
    }
}

# ---------------------------------------------------------------------------
# 黑名單：硬性規則，不可由參數覆蓋。清理動作絕不可落在這些路徑。
# ---------------------------------------------------------------------------
function Get-BlacklistPatterns {
    $win = [regex]::Escape($env:SystemRoot)
    @(
        "^$win\\System32(\\|$)",
        "^$win\\SysWOW64(\\|$)",
        "^$win\\WinSxS(\\|$)",
        "^$win\\servicing(\\|$)",
        "^$win\\Boot(\\|$)",
        "^$win\\Fonts(\\|$)",
        "^$win\\Installer(\\|$)",
        "^$win\\SoftwareDistribution\\(?!Download(\\|$))",
        "^$win$",
        '^[A-Za-z]:\\Program Files( \(x86\))?(\\|$)',
        '^[A-Za-z]:\\ProgramData\\Microsoft\\(Windows\\Start Menu|Crypto|Windows Defender)(\\|$)',
        '\\NTUSER\.DAT',
        '\\UsrClass\.dat',
        '\\System Volume Information(\\|$)',
        '\\(pagefile|swapfile|hiberfil)\.sys$',
        '\\\.git(\\|$)',
        '^[A-Za-z]:\\?$',
        '^[A-Za-z]:\\Users\\?$',
        '^[A-Za-z]:\\Users\\[^\\]+\\?$',
        '^[A-Za-z]:\\Users\\[^\\]+\\(AppData|Documents|Desktop|Pictures|Videos|Music)\\?$'
    )
}

function Test-PathBlacklisted {
    # returns the matching pattern, or $null when the path is allowed
    param([string]$Path)
    $p = $Path.TrimEnd('\')
    if ($p -match '^[A-Za-z]:$') { $p += '\' }
    foreach ($pat in (Get-BlacklistPatterns)) {
        if ($p -match $pat) { return $pat }
    }
    return $null
}

# ---------------------------------------------------------------------------
# 規則庫
# ---------------------------------------------------------------------------
function Import-DiskAuditRules {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到規則庫: $Path" }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $json.rules) { throw "規則庫格式錯誤（缺少 rules）: $Path" }

    $validRisk = 'Safe', 'Review', 'Manual'
    $validType = 'DeleteContents', 'Command', 'None'
    $seen = @{}
    foreach ($r in $json.rules) {
        foreach ($f in 'id', 'path', 'risk', 'action', 'clean') {
            if (-not ($r.PSObject.Properties.Name -contains $f)) { throw "規則缺少必要欄位 '$f': $($r.id)" }
        }
        if ($seen.ContainsKey($r.id)) { throw "規則 id 重複: $($r.id)" }
        $seen[$r.id] = $true
        if ($validRisk -notcontains $r.risk) { throw "規則 $($r.id) 的 risk 無效: $($r.risk)" }
        if ($validType -notcontains $r.clean.type) { throw "規則 $($r.id) 的 clean.type 無效: $($r.clean.type)" }

        if ($r.clean.type -eq 'DeleteContents') {
            foreach ($p in @($r.path)) {
                $expanded = [Environment]::ExpandEnvironmentVariables($p)
                $hit = Test-PathBlacklisted $expanded
                if ($hit) { throw "規則 $($r.id) 的清理路徑位於黑名單內（拒絕載入）: $expanded" }
            }
        }
        if ($r.clean.type -eq 'Command' -and -not $r.clean.command) { throw "規則 $($r.id) 為 Command 但缺少 command" }
    }
    return [pscustomobject]@{ Version = $json.version; Rules = @($json.rules) }
}

function Expand-RulePath {
    # returns existing concrete paths (strings) for a rule path spec (env vars + wildcards expanded)
    param([Parameter(Mandatory)]$PathSpec)
    $out = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($spec in @($PathSpec)) {
        $p = [Environment]::ExpandEnvironmentVariables($spec)
        if ($p -match '[\*\?]') {
            $items = Get-Item -Path $p -Force -ErrorAction SilentlyContinue
            foreach ($i in @($items)) { if ($i -and $seen.Add($i.FullName.TrimEnd('\'))) { $out.Add($i.FullName) } }
        }
        elseif (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) {
            if ($seen.Add($p.TrimEnd('\'))) { $out.Add($p) }
        }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# 互動輸入（含逾時；非互動主機一律視為「否」）
# ---------------------------------------------------------------------------
function Read-LineTimeout {
    param([string]$Prompt, [int]$TimeoutSeconds = 120)
    Write-Host -NoNewline $Prompt
    try {
        $null = [Console]::KeyAvailable
    } catch {
        Write-Host ' (非互動環境，視為否)'
        return $null
    }
    $sb = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq 'Enter') { Write-Host ''; return $sb.ToString() }
            elseif ($k.Key -eq 'Backspace') { if ($sb.Length -gt 0) { $sb.Length--; Write-Host -NoNewline "`b `b" } }
            else { [void]$sb.Append($k.KeyChar); Write-Host -NoNewline $k.KeyChar }
        } else {
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ''
    Write-Host "($TimeoutSeconds 秒內無回應，視為否)" -ForegroundColor Yellow
    return $null
}

function Get-FixedVolumeInfo {
    param([string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    try {
        $d = New-Object IO.DriveInfo ($root)
        return [pscustomobject]@{
            Root = $root; Total = [int64]$d.TotalSize; Free = [int64]$d.AvailableFreeSpace
            Used = [int64]($d.TotalSize - $d.AvailableFreeSpace); Type = $d.DriveType.ToString()
        }
    } catch { return $null }
}
