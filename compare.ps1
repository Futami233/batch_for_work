param(
    [Parameter(Mandatory = $true)]
    [string]$OldList,

    [Parameter(Mandatory = $true)]
    [string]$NewList,

    [string]$OutputDir = ".\compare_result"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Normalize-Path {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    return ($Path.Trim() -replace '/', '\').ToLowerInvariant()
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Parse-DirSFile {
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "文件不存在: $FilePath"
    }

    $lines = Get-Content -LiteralPath $FilePath -Encoding Default
    $currentDir = $null
    $map = @{}

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        # 匹配“某某目录”的标题行
        # 示例:
        #  Directory of C:\Test
        #  C:\Test のディレクトリ
        #  驱动器 ... 这种不要
        if ($line -match '^\s*Directory of\s+(.+)$') {
            $currentDir = $matches[1].Trim()
            continue
        }

        if ($line -match '^\s*(.+)\s+のディレクトリ\s*$') {
            $currentDir = $matches[1].Trim()
            continue
        }

        # 跳过汇总/说明类行
        if (
            $trimmed -match '^(Volume in drive|Volume Serial Number is|驱动器|卷的序列号是|ディレクトリ|File\(s\)|ファイル|Dir\(s\)|個のファイル|個のディレクトリ|总共文件数|合計ファイル数)' -or
            $trimmed -match '^(<DIR>)$'
        ) {
            continue
        }

        if (-not $currentDir) {
            continue
        }

        # 尝试匹配标准文件行
        # 常见格式：
        # 2026/04/16  10:20             123 a.txt
        # 2026-04-16  10:20             123 a.txt
        # 2026/04/16  10:20 AM          123 a.txt
        # 2026/04/16  10:20 PM          123 a.txt
        #
        # 过滤掉 <DIR>
        if ($line -match '^\s*(\d{4}[-/]\d{1,2}[-/]\d{1,2})\s+(\d{1,2}:\d{2})(?:\s*([AP]M))?\s+(.+?)\s+(.+)$') {
            $datePart = $matches[1]
            $timePart = $matches[2]
            $ampmPart = $matches[3]
            $sizeOrDir = $matches[4].Trim()
            $namePart = $matches[5].Trim()

            if ($sizeOrDir -eq '<DIR>') {
                continue
            }

            # 去掉千分位逗号
            $sizeText = $sizeOrDir -replace ',', ''

            if ($sizeText -notmatch '^\d+$') {
                continue
            }

            $dateTimeText = "$datePart $timePart"
            if ($ampmPart) {
                $dateTimeText += " $ampmPart"
            }

            try {
                $dt = [datetime]::Parse($dateTimeText)
            } catch {
                continue
            }

            $fullPath = Join-Path $currentDir $namePart
            $key = Normalize-Path $fullPath

            $map[$key] = [PSCustomObject]@{
                FullName      = $fullPath
                LastWriteTime = $dt
                Length        = [int64]$sizeText
            }

            continue
        }
    }

    return $map
}

Write-Host "读取旧列表: $OldList"
$oldMap = Parse-DirSFile -FilePath $OldList

Write-Host "读取新列表: $NewList"
$newMap = Parse-DirSFile -FilePath $NewList

Ensure-Directory -Path $OutputDir

$added = New-Object System.Collections.Generic.List[object]
$removed = New-Object System.Collections.Generic.List[object]
$timestampChanged = New-Object System.Collections.Generic.List[object]
$sizeChanged = New-Object System.Collections.Generic.List[object]

foreach ($key in $newMap.Keys) {
    if (-not $oldMap.ContainsKey($key)) {
        $item = $newMap[$key]
        $added.Add([PSCustomObject]@{
            FullName      = $item.FullName
            LastWriteTime = $item.LastWriteTime
            Length        = $item.Length
        })
    }
    else {
        $oldItem = $oldMap[$key]
        $newItem = $newMap[$key]

        if ($oldItem.LastWriteTime -ne $newItem.LastWriteTime) {
            $timestampChanged.Add([PSCustomObject]@{
                FullName          = $newItem.FullName
                OldLastWriteTime  = $oldItem.LastWriteTime
                NewLastWriteTime  = $newItem.LastWriteTime
                OldLength         = $oldItem.Length
                NewLength         = $newItem.Length
            })
        }

        if ($oldItem.Length -ne $newItem.Length) {
            $sizeChanged.Add([PSCustomObject]@{
                FullName    = $newItem.FullName
                OldLength   = $oldItem.Length
                NewLength   = $newItem.Length
                LastWriteTime = $newItem.LastWriteTime
            })
        }
    }
}

foreach ($key in $oldMap.Keys) {
    if (-not $newMap.ContainsKey($key)) {
        $item = $oldMap[$key]
        $removed.Add([PSCustomObject]@{
            FullName      = $item.FullName
            LastWriteTime = $item.LastWriteTime
            Length        = $item.Length
        })
    }
}

Write-Host ""
Write-Host "==================== 对比结果 ====================" -ForegroundColor Cyan
Write-Host ("新增文件数: {0}" -f $added.Count) -ForegroundColor Green
Write-Host ("删除文件数: {0}" -f $removed.Count) -ForegroundColor Yellow
Write-Host ("时间戳变化文件数: {0}" -f $timestampChanged.Count) -ForegroundColor Magenta
Write-Host ("大小变化文件数: {0}" -f $sizeChanged.Count) -ForegroundColor Blue
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$addedPath = Join-Path $OutputDir "added.csv"
$removedPath = Join-Path $OutputDir "removed.csv"
$timestampChangedPath = Join-Path $OutputDir "timestamp_changed.csv"
$sizeChangedPath = Join-Path $OutputDir "size_changed.csv"
$summaryPath = Join-Path $OutputDir "summary.txt"

$added | Export-Csv -Path $addedPath -NoTypeInformation -Encoding UTF8
$removed | Export-Csv -Path $removedPath -NoTypeInformation -Encoding UTF8
$timestampChanged | Export-Csv -Path $timestampChangedPath -NoTypeInformation -Encoding UTF8
$sizeChanged | Export-Csv -Path $sizeChangedPath -NoTypeInformation -Encoding UTF8

@"
旧列表: $OldList
新列表: $NewList

新增文件数: $($added.Count)
删除文件数: $($removed.Count)
时间戳变化文件数: $($timestampChanged.Count)
大小变化文件数: $($sizeChanged.Count)

输出文件:
$addedPath
$removedPath
$timestampChangedPath
$sizeChangedPath
"@ | Set-Content -Path $summaryPath -Encoding UTF8

Write-Host "结果已输出到: $OutputDir" -ForegroundColor Cyan
