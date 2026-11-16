param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int64]$TotalSize,
    [string]$Dest = '.',
    [string]$OutName = 'download.bin',
    [int]$ChunkMB = 128,
    [int]$Workers = 48,
    [string]$Proxy = '',
    [string]$Md5 = '',
    [string]$Curl = 'C:\Windows\System32\curl.exe',
    [int]$MaxTimeSeconds = 600,
    [int]$StallKillSeconds = 900
)

# Work-stealing parallel HTTP range downloader.
# The file is cut into fixed-size chunks (ChunkMB); a pool of Workers keeps that many
# curls in flight and any finishing worker immediately takes the next queued chunk,
# so one slow connection cannot leave the tail of the file stranded. Each chunk is a
# resume point: a restart picks up at that chunk's current byte length.

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Curl)) { throw "curl not found: $Curl" }
if ($ChunkMB -lt 1) { throw 'ChunkMB must be >= 1' }
if ($Workers -lt 1) { throw 'Workers must be >= 1' }

New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$PartsDir = Join-Path $Dest '_parts'
New-Item -ItemType Directory -Force -Path $PartsDir | Out-Null
$Out      = Join-Path $Dest $OutName
$LogFile  = Join-Path $Dest ($OutName + '.download.log')
$ProgFile = Join-Path $Dest ($OutName + '.progress.txt')

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) -Encoding utf8
}

function Add-Tmp([string]$ChunkFile) {
    $tmp = $ChunkFile + '.tmp'
    if (Test-Path -LiteralPath $tmp) {
        $len = (Get-Item -LiteralPath $tmp).Length
        if ($len -gt 0) {
            $out = [System.IO.File]::Open($ChunkFile, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
            try { $src = [System.IO.File]::OpenRead($tmp); try { $src.CopyTo($out, 1MB) } finally { $src.Dispose() } }
            finally { $out.Dispose() }
        }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

$chunkBytes = [int64]$ChunkMB * 1MB
$count = [int]([math]::Ceiling([double]$TotalSize / $chunkBytes))
$plan = @()
for ($i = 0; $i -lt $count; $i++) {
    $start = [int64]$i * $chunkBytes
    $end = [math]::Min($start + $chunkBytes - 1, $TotalSize - 1)
    $plan += [pscustomobject]@{
        I = $i; Start = $start; End = $end; Size = [int64]($end - $start + 1)
        File = (Join-Path $PartsDir ('chunk_{0:D5}.bin' -f $i))
    }
}

foreach ($p in $plan) { Add-Tmp $p.File }
Write-Log ("START total={0} chunks={1} chunkBytes={2} workers={3} url={4} proxy={5}" -f $TotalSize, $count, $chunkBytes, $Workers, $Url, $(if ($Proxy) { $Proxy } else { '(direct)' }))

$queue = [System.Collections.Generic.Queue[int]]::new()
foreach ($p in $plan) {
    $have = [int64]0
    if (Test-Path -LiteralPath $p.File) { $have = (Get-Item -LiteralPath $p.File).Length }
    if ($have -lt $p.Size) { $queue.Enqueue($p.I) }
}
Write-Log ("resume: {0} of {1} chunks pending" -f $queue.Count, $count)

$active = @{}
$seen = @{}
$moved = @{}
$finished = @{}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$baseBytes = [int64]0
foreach ($p in $plan) { if (Test-Path -LiteralPath $p.File) { $baseBytes += (Get-Item -LiteralPath $p.File).Length } }
$lastReport = [datetime]::MinValue

while ($queue.Count -gt 0 -or $active.Count -gt 0) {
    while ($active.Count -lt $Workers -and $queue.Count -gt 0) {
        $index = $queue.Dequeue()
        $p = $plan[$index]
        $have = [int64]0
        if (Test-Path -LiteralPath $p.File) { $have = (Get-Item -LiteralPath $p.File).Length }
        if ($have -ge $p.Size) { continue }
        $tmp = $p.File + '.tmp'
        $args = @('-sS', '-L', '--connect-timeout', '30', '--max-time', $MaxTimeSeconds,
                  '--range', ("{0}-{1}" -f ($p.Start + $have), $p.End), '-o', $tmp)
        if ($Proxy) { $args += @('-x', $Proxy) }
        $args += $Url
        $active[$index] = Start-Process -FilePath $Curl -ArgumentList $args -PassThru -NoNewWindow
        $seen[$index] = [int64]0
        $moved[$index] = Get-Date
    }

    foreach ($index in @($active.Keys)) {
        $proc = $active[$index]
        $p = $plan[$index]
        $tmp = $p.File + '.tmp'
        $proc.Refresh()
        if (-not $proc.HasExited) {
            $tmpSize = [int64]0
            if (Test-Path -LiteralPath $tmp) { $tmpSize = (Get-Item -LiteralPath $tmp).Length }
            if ($tmpSize -ne $seen[$index]) { $seen[$index] = $tmpSize; $moved[$index] = Get-Date }
            elseif (((Get-Date) - $moved[$index]).TotalSeconds -gt $StallKillSeconds) {
                Write-Log ("chunk {0} stalled, restarting" -f $index)
                try { $proc.Kill() } catch { }
            }
            continue
        }
        Add-Tmp $p.File
        $active.Remove($index)
        $have = [int64]0
        if (Test-Path -LiteralPath $p.File) { $have = (Get-Item -LiteralPath $p.File).Length }
        if ($have -lt $p.Size) { $queue.Enqueue($index) }
        elseif (-not $finished.ContainsKey($index)) { $finished[$index] = $true; Write-Log ("chunk {0} complete" -f $index) }
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
        $line = '{0:N2} / {1:N2} GiB ({2:P1})  run {3:N2} MB/s  active {4}  queued {5}  elapsed {6:hh\:mm\:ss}  eta {7:hh\:mm\:ss}' -f ($bytes/1GB), ($TotalSize/1GB), ($bytes/$TotalSize), $rate, $active.Count, $queue.Count, $sw.Elapsed, $eta
        Set-Content -LiteralPath $ProgFile -Value $line -Encoding utf8
        Write-Log $line
        $lastReport = Get-Date
    }
    Start-Sleep -Milliseconds 1500
}

Write-Log 'all chunks complete; assembling'
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
