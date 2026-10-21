<#
.SYNOPSIS
    建立 DiskAudit 測試用 fixture（可丟棄的測試資料夾），並回傳預期值（manifest）。
    只會寫入 -Path 之下，不會碰其他位置。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path
)
$ErrorActionPreference = 'Stop'

function New-RandFile {
    param([string]$File, [int]$Bytes, [int]$Seed)
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $buf = New-Object byte[] $Bytes
    (New-Object System.Random $Seed).NextBytes($buf)
    [IO.File]::WriteAllBytes($File, $buf)
}
function New-ZeroFile {
    param([string]$File, [int]$Bytes)
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllBytes($File, (New-Object byte[] $Bytes))
}

$MB = 1MB
$fx = Join-Path ([IO.Path]::GetFullPath($Path)) 'fx'
if (Test-Path -LiteralPath $fx) { throw "fixture 已存在: $fx（請先清除）" }
New-Item -ItemType Directory -Force -Path $fx | Out-Null

# 巢狀資料夾與已知大小
New-ZeroFile "$fx\tree\L1\f_1k.bin" 1024
New-ZeroFile "$fx\tree\L1\L2\f_1m.bin" (1 * $MB)
New-ZeroFile "$fx\tree\L1\L2\L3\f_20m.bin" (20 * $MB)

# 重複檔：group1 x3 (11MB)、group2 x2 (12MB)
New-RandFile "$fx\dupes\orig1.bin" (11 * $MB) 1
Copy-Item "$fx\dupes\orig1.bin" "$fx\dupes\copy1.bin"
New-Item -ItemType Directory -Force "$fx\dupes\sub" | Out-Null
Copy-Item "$fx\dupes\orig1.bin" "$fx\dupes\sub\copy1b.bin"
New-RandFile "$fx\dupes\orig2.bin" (12 * $MB) 2
Copy-Item "$fx\dupes\orig2.bin" "$fx\dupes\copy2.bin"

# 陷阱：同大小、前 64KB 相同、僅最後一個 byte 不同（不得判為重複）
New-RandFile "$fx\trap\t1.bin" (11 * $MB) 3
Copy-Item "$fx\trap\t1.bin" "$fx\trap\t2.bin"
$fs = [IO.File]::Open("$fx\trap\t2.bin", 'Open', 'ReadWrite')
$fs.Seek(-1, 'End') | Out-Null
$last = $fs.ReadByte(); $fs.Seek(-1, 'End') | Out-Null
$fs.WriteByte([byte](($last + 1) % 256)); $fs.Close()
# 同大小、內容完全不同
New-RandFile "$fx\diff\d1.bin" (11 * $MB) 4
New-RandFile "$fx\diff\d2.bin" (11 * $MB) 40

# 硬連結
New-RandFile "$fx\hl\h1.bin" (2 * $MB) 5
New-Item -ItemType HardLink -Path "$fx\hl\h2.bin" -Value "$fx\hl\h1.bin" | Out-Null

# junction（指向 tree\L1，不得重複計算）
New-Item -ItemType Directory -Force "$fx\links" | Out-Null
cmd /c mklink /J "`"$fx\links\junc`"" "`"$fx\tree\L1`"" | Out-Null
$symOk = $false
try { New-Item -ItemType SymbolicLink -Path "$fx\links\sym" -Value $fx -ErrorAction Stop | Out-Null; $symOk = $true } catch { }

# 空資料夾、0 byte
New-Item -ItemType Directory -Force "$fx\emptydir" | Out-Null
New-Item -ItemType Directory -Force "$fx\zero" | Out-Null
[IO.File]::WriteAllBytes("$fx\zero\zero.bin", (New-Object byte[] 0))

# 久未修改的大檔
New-RandFile "$fx\old\ancient.bin" (15 * $MB) 7
(Get-Item "$fx\old\ancient.bin").LastWriteTime = (Get-Date).AddDays(-400)

# 超過 260 字元的長路徑
$seg = 'long_dir_' + ('x' * 40)
$longDir = $fx + ('\' + $seg) * 6
[void][IO.Directory]::CreateDirectory('\\?\' + $longDir)
[IO.File]::WriteAllBytes('\\?\' + $longDir + '\longfile.bin', (New-Object byte[] (1 * $MB)))
$longLen = ($longDir + '\longfile.bin').Length

# Downloads 內的安裝包
New-RandFile "$fx\Downloads\setup.zip" (11 * $MB) 9

# 規則測試用的假 Temp / Minidump
New-ZeroFile "$fx\fake\Temp\old1.tmp" (3 * $MB)
New-ZeroFile "$fx\fake\Temp\sub\old2.tmp" (1 * $MB)
New-ZeroFile "$fx\fake\Temp\new.tmp" (2 * $MB)
foreach ($f in "$fx\fake\Temp\old1.tmp", "$fx\fake\Temp\sub\old2.tmp") { (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-30) }
New-ZeroFile "$fx\fake\Minidump\a.dmp" (5 * $MB)

# 無權限資料夾（拒絕目前使用者 讀取+執行）
$deniedOk = $false
New-ZeroFile "$fx\denied\secret.bin" (1 * $MB)
try {
    $me = "$env:USERDOMAIN\$env:USERNAME"
    & icacls.exe "$fx\denied" /deny "${me}:(OI)(CI)(RX)" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $deniedOk = $true }
} catch { }

# 測試用規則庫（路徑指向 fixture）
$rules = @{
    version = 'test'
    rules   = @(
        @{ id = 't-temp'; risk = 'Safe'; category = '暫存檔'; path = "$fx\fake\Temp"; note = 'fixture temp'; action = 'n/a'; clean = @{ type = 'DeleteContents'; olderThanDays = 7 } },
        @{ id = 't-dmp'; risk = 'Review'; category = '當機傾印'; path = "$fx\fake\Minidump"; note = 'fixture dump'; action = 'n/a'; clean = @{ type = 'DeleteContents'; olderThanDays = 0 } }
    )
}
$rulesPath = Join-Path ([IO.Path]::GetFullPath($Path)) 'rules-test.json'
$rules | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $rulesPath -Encoding UTF8

# 預期值
$tree = 1024 + 1 * $MB + 20 * $MB
$expectedLogical = $tree +
(11 * $MB * 3) + (12 * $MB * 2) +   # dupes
(11 * $MB * 2) +                    # trap
(11 * $MB * 2) +                    # diff
(2 * $MB * 2) +                     # hardlink counted twice
(15 * $MB) + (1 * $MB) +            # old, long
(11 * $MB) +                        # Downloads
(3 + 1 + 2 + 5) * $MB               # fake
$expectedDiskTree = 4096 + 1 * $MB + 20 * $MB

[pscustomobject]@{
    Fixture          = $fx
    RulesPath        = $rulesPath
    ExpectedLogical  = [int64]$expectedLogical
    ExpectedTreeLogical = [int64]$tree
    ExpectedTreeDisk = [int64]$expectedDiskTree
    DupGroups        = 2
    DupReclaim       = [int64](11 * $MB * 2 + 12 * $MB * 1)
    SafeReclaim      = [int64](4 * $MB)      # old1 + old2 (new.tmp excluded)
    ReviewReclaim    = [int64](5 * $MB)
    DeniedApplied    = $deniedOk
    SymlinkCreated   = $symOk
    LongPathLength   = $longLen
}
