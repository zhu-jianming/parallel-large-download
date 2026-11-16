param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Proxy = '',
    [int[]]$Connections = @(1, 8, 24, 48),
    [int]$Seconds = 12,
    [int64]$RangeSpan = 1048576,
    [string]$Curl = 'C:\Windows\System32\curl.exe'
)

# Measure achievable throughput before choosing a proxy and a part count.
# Each probe downloads short distinct ranges and discards the bytes.

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Curl)) { throw "curl not found: $Curl" }

function Measure-Once([int]$N, [string]$ProxyUrl) {
    $results = 1..$N | ForEach-Object -Parallel {
        $url = $using:Url; $px = $using:ProxyUrl; $curl = $using:Curl
        $span = $using:RangeSpan
        $start = ([int64]($_ - 1)) * $span
        $end = $start + $span - 1
        $args = @('-sS', '-L', '--max-time', $using:Seconds, '--range', "$start-$end", '-o', 'NUL', '-w', '%{size_download}')
        if ($px) { $args += @('-x', $px) }
        $args += $url
        $out = & $curl @args 2>$null
        [int64]$out
    } -ThrottleLimit $N
    $bytes = ([int64]0)
    foreach ($r in $results) { $bytes += $r }
    return [pscustomobject]@{
        Mode          = $(if ($ProxyUrl) { 'proxy' } else { 'direct' })
        Conns         = $N
        MegabytesPerS = [math]::Round($bytes / [math]::Max(1, $Seconds) / 1MB, 2)
        MegabitsPerS  = [math]::Round($bytes * 8 / [math]::Max(1, $Seconds) / 1MB, 1)
    }
}

$rows = @()
foreach ($n in $Connections) { $rows += Measure-Once $n '' }
if ($Proxy) { foreach ($n in $Connections) { $rows += Measure-Once $n $Proxy } }

$rows | Format-Table -AutoSize
$best = $rows | Sort-Object MegabytesPerS -Descending | Select-Object -First 1
"best: {0} x {1} conns = {2} MB/s" -f $best.Mode, $best.Conns, $best.MegabytesPerS
