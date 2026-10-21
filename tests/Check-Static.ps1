<#
.SYNOPSIS
    快速靜態檢查（數秒）：BOM、PowerShell 語法、C# 可編譯、規則庫驗證、報表未被版控。
    本機與 CI 共用；任何一項失敗即以退出碼 1 結束。
.EXAMPLE
    .\tests\Check-Static.ps1
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green }
    else { Write-Host ("  FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red; $failures.Add($Name) }
}

$ps1 = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.ps1 |
        Where-Object { $_.FullName -notmatch '\\(_work|reports|\.git)\\' })
Write-Host ("== 靜態檢查（{0} 個 .ps1）==" -f $ps1.Count) -ForegroundColor Cyan

# 1. 每個 .ps1 必須是 UTF-8 with BOM（否則 Windows PowerShell 5.1 會把中文讀成亂碼）
foreach ($f in $ps1) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    Check ("BOM: {0}" -f $f.FullName.Substring($root.Length + 1)) $hasBom '缺少 UTF-8 BOM（見 README 6.6 補回指令）'
}

# 2. PowerShell 語法
foreach ($f in $ps1) {
    $tok = $null; $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
    $msg = if ($err -and @($err).Count -gt 0) { 'L{0}: {1}' -f @($err)[0].Extent.StartLineNumber, @($err)[0].Message } else { '' }
    Check ("語法: {0}" -f $f.FullName.Substring($root.Length + 1)) (-not ($err -and @($err).Count -gt 0)) $msg
}

# 3. C# 5 可編譯，且規則庫通過驗證（含黑名單檢查）
. (Join-Path $root 'DiskAudit.Common.ps1')
$ok = $true; $detail = ''
try { Initialize-DiskScanner -SourcePath (Join-Path $root 'DiskScanner.cs') } catch { $ok = $false; $detail = $_.Exception.Message }
Check 'DiskScanner.cs 可編譯（C# 5）' $ok $detail

$rules = $null; $detail = ''
try { $rules = Import-DiskAuditRules -Path (Join-Path $root 'known-targets.json') } catch { $detail = $_.Exception.Message }
Check 'known-targets.json 通過 schema 與黑名單驗證' ($null -ne $rules) $detail
if ($rules) {
    $safe = @($rules.Rules | Where-Object { $_.risk -eq 'Safe' } | ForEach-Object { $_.id } | Sort-Object)
    Check 'Safe 規則僅限 user-temp / windows-temp' (($safe -join ',') -eq 'user-temp,windows-temp') ($safe -join ',')
}

# 4. 執行產物不得進版控（含本機路徑、使用者名稱等私有資料）
$tracked = @()
try { $tracked = @(& git -C $root ls-files -- reports tests/_work 2>$null) } catch { }
Check 'reports/ 與 tests/_work/ 未被版控追蹤' ($tracked.Count -eq 0) (($tracked | Select-Object -First 3) -join ', ')

Write-Host ''
if ($failures.Count -eq 0) { Write-Host '靜態檢查全部通過。' -ForegroundColor Green; exit 0 }
Write-Host ("靜態檢查失敗 {0} 項。" -f $failures.Count) -ForegroundColor Red
exit 1
