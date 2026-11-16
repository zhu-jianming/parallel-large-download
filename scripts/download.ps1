param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int64]$TotalSize,
    [string]$Dest = '.',
    [string]$OutName = 'download.bin',
    [int]$Parts = 48,
    [string]$Proxy = '',
    [string]$Md5 = '',
    [string]$Curl = 'C:\Windows\System32\curl.exe',
    [int]$MaxTimeSeconds = 600,
    [int]$StallKillSeconds = 900
)

# Parallel HTTP range downloader: one part file per range, curl per part through a
# supervisor loop, append-on-exit (never curl --retry with -o), keep-alive refresh
# via MaxTimeSeconds, assemble in order, verify size and optional MD5.

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Curl)) { throw "curl not found: $Curl" }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$PartsDir = Join-Path $Dest '_parts'
New-Item -ItemType Directory -Force -Path $PartsDir | Out-Null
$Out      = Join-Path $Dest $OutName
$LogFile  = Join-Path $Dest ($OutName + '.download.log')
$ProgFile = Join-Path $Dest ($OutName + '.progress.txt')

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) -Encoding utf8
}

function Add-Tmp([string]$PartFile) {
    $tmp = $PartFile + '.tmp'
    if (Test-Path -LiteralPath $tmp) {
        $len = (Get-Item -LiteralPath $tmp).Length
        if ($len -gt 0) {
            $out = [System.IO.File]::Open($PartFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
            try { $src = [System.IO.File]::OpenRead($tmp); try { $src.CopyTo($out, 1MB) } finally { $src.Dispose() } }
            finally { $out.Dispose() }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

$chunk = [int64]([math]::Floor([double]$TotalSize / $Parts) + 1)
$plan = @()
for ($i = 0; $i -lt $Parts; $i++) {
    $start = [int64]$i * $chunk
    if ($start -ge $TotalSize) { break }
    $end = [math]::Min($start + $chunk - 1, $TotalSize - 1)
    $plan += [pscustomobject]@{
        I = $i; Start = $start; End = $end; Size = [int64]($end - $start + 1)
        File = (Join-Path $PartsDir ('part_{0:D3}.bin' -f $i))
    }
}

# merge leftovers from an interrupted run so nothing is re-downloaded
foreach ($p in $plan) { Add-Tmp $p.File }
Write-Log ("START total={0} parts={1} chunk={2} url={3} proxy={4}" -f $TotalSize, $plan.Count, $chunk, $Url, $(if ($Proxy) { $Proxy } else { '(direct)' }))

$procs = @{}; $seen = @{}; $moved = @{}; $starts = @{}; $done = @{}
foreach ($p in $plan) { $seen[$p.I] = [int64]0; $moved[$p.I] = Get-Date; $starts[$p.I] = 0 }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$baseBytes = [int64]0
foreach ($p in $plan) { if (Test-Path -LiteralPath $p.File) { $baseBytes += (Get-Item -LiteralPath $p.File).Length } }
$lastReport = [datetime]::MinValue

while ($true) {
    $allDone = $true
    foreach ($p in $plan) {
        $cur = [int64]0
        if (Test-Path -LiteralPath $p.File) { $cur = (Get-Item -LiteralPath $p.File).Length }
        if ($cur -ge $p.Size) {
            if (-not $done.ContainsKey($p.I)) { $done[$p.I] = $true; Write-Log ("part {0} complete" -f $p.I) }
            continue
        }
        $allDone = $false
        $tmp = $p.File + '.tmp'
        $proc = $procs[$p.I]
        if ($proc) {
            $proc.Refresh()
            if (-not $proc.HasExited) {
                $tmpSize = [int64]0
                if (Test-Path -LiteralPath $tmp) { $tmpSize = (Get-Item -LiteralPath $tmp).Length }
                if ($tmpSize -ne $seen[$p.I]) { $seen[$p.I] = $tmpSize; $moved[$p.I] = Get-Date }
                elseif (((Get-Date) - $moved[$p.I]).TotalSeconds -gt $StallKillSeconds) {
                    Write-Log ("part {0} stalled {1}s, restarting curl" -f $p.I, [int]$StallKillSeconds)
                    try { $proc.Kill() } catch { }
                }
                continue
            }
            Add-Tmp $p.File
            $procs.Remove($p.I)
            $seen[$p.I] = 0; $moved[$p.I] = Get-Date
            if (Test-Path -LiteralPath $p.File) { $cur = (Get-Item -LiteralPath $p.File).Length }
            if ($cur -ge $p.Size -and -not $done.ContainsKey($p.I)) { $done[$p.I] = $true; Write-Log ("part {0} complete" -f $p.I) }
        }
        if ($cur -ge $p.Size) { continue }
        if ($starts[$p.I] -ge 200) { Write-Log ("part {0}: too many restarts, giving up" -f $p.I); continue }
        $from = $p.Start + $cur
        $args = @('-sS', '-L', '--connect-timeout', '30', '--max-time', $MaxTimeSeconds, '--range', ("{0}-{1}" -f $from, $p.End), '-o', $tmp)
        if ($Proxy) { $args += @('-x', $Proxy) }
        $args += $Url
        $procs[$p.I] = Start-Process -FilePath $Curl -ArgumentList $args -PassThru -NoNewWindow
        $starts[$p.I] = $starts[$p.I] + 1
        $moved[$p.I] = Get-Date
    }

    if (((Get-Date) - $lastReport).TotalSeconds -ge 30) {
        $bytes = [int64]0
        foreach ($p in $plan) {
            if (Test-Path -LiteralPath $p.File) { $bytes += (Get-Item -LiteralPath $p.File).Length }
            $t = $p.File + '.tmp'
            if (Test-Path -LiteralPath $t) { $bytes += (Get-Item -LiteralPath $t).Length }
        }
        $elapsed = [math]::Max(1, $sw.Elapsed.TotalSeconds)
        $rate = ($bytes - $baseBytes) / $elapsed / 1MB
        $eta = if ($rate -gt 0) { [TimeSpan]::FromSeconds((($TotalSize - $bytes) / 1MB) / $rate) } else { [TimeSpan]::Zero }
        $line = '{0} / {1} ({2:P1})  this-run {3:N2} MB/s  eta {4:hh\:mm\:ss}' -f ($bytes/1GB), ($TotalSize/1GB), ($bytes/$TotalSize), $rate, $eta
        Set-Content -LiteralPath $ProgFile -Value $line -Encoding utf8
        Write-Log $line
        $lastReport = Get-Date
    }
    if ($allDone) { break }
    Start-Sleep -Seconds 3
}

Write-Log 'all parts complete; assembling'
$outStream = [System.IO.File]::Open($Out, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
    foreach ($p in $plan) {
        $in = [System.IO.File]::OpenRead($p.File)
        try { $in.CopyTo($outStream, 4MB) } finally { $in.Dispose() }
    }
} finally { $outStream.Dispose() }

$finalSize = (Get-Item -LiteralPath $Out).Length
$sizeOk = ($finalSize -eq $TotalSize)
Write-Log ("assembled size={0} expected={1} match={2}" -f $finalSize, $TotalSize, $sizeOk)
if (-not $sizeOk) { Set-Content -LiteralPath $ProgFile -Value ("FAIL size={0} expected={1}" -f $finalSize, $TotalSize) -Encoding utf8; exit 3 }

if ($Md5) {
    Write-Log 'computing MD5'
    $hash = (Get-FileHash -LiteralPath $Out -Algorithm MD5).Hash.ToLower()
    $ok = ($hash -eq $Md5.ToLower())
    Write-Log ("MD5={0} expected={1} match={2}" -f $hash, $Md5, $ok)
    Set-Content -LiteralPath $ProgFile -Value ("DONE size={0} md5={1} match={2}" -f $finalSize, $hash, $ok) -Encoding utf8
    if (-not $ok) { exit 4 }
} else {
    Set-Content -LiteralPath $ProgFile -Value ("DONE size={0} md5=unchecked" -f $finalSize) -Encoding utf8
}
Write-Log 'ALL DONE'

