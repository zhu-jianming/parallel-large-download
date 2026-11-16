param(
    [Parameter(Mandatory = $true)][string]$Url,
    [string]$Proxy = '',
    [string]$Connections = '1,8,16,32,48,64,96',
    [int]$Seconds = 8,
    [int64]$RangeSpan = 1048576,
    [string]$Curl = 'C:\Windows\System32\curl.exe'
)

# Sweep connection counts against a real URL and recommend a worker count.
# Each probe downloads short distinct ranges and discards the bytes, so total traffic
# is roughly Connections * RangeSpan * Seconds worth of throughput, not the file.

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Curl)) { throw "curl not found: $Curl" }

$rows = @()
$totalBytes = [int64]0

# A comma list arrives as one string when the script runs via `pwsh -File`, where the
# culture parser can fold "1,4" into the number 14; split it explicitly instead.
$counts = @($Connections -split '[,;\s]+' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })

foreach ($connCount in $counts) {
    $probeUrl = $Url
    $probeProxy = $Proxy
    $probeSpan = $RangeSpan
    $probeSeconds = $Seconds
    $probeCurl = $Curl

    $results = 1..$connCount | ForEach-Object -Parallel {
        $u = $using:probeUrl; $px = $using:probeProxy; $span = $using:probeSpan
        $limit = $using:probeSeconds; $curl = $using:probeCurl
        $start = ([int64]($_ - 1)) * $span
        $end = $start + $span - 1
        $args = @('-sS', '-L', '--max-time', $limit, '--range', "$start-$end", '-o', 'NUL', '-w', '%{size_download}')
        if ($px) { $args += @('-x', $px) }
        $args += $u
        $value = & $curl @args 2>$null
        [int64]$value
    } -ThrottleLimit $connCount

    $bytes = [int64]0
    foreach ($value in $results) { $bytes += $value }
    $totalBytes += $bytes

    $rows += [pscustomobject]@{
        Connections = $connCount
        MBps        = [math]::Round($bytes / [math]::Max(1, $Seconds) / 1MB, 2)
        MbitPerSec  = [math]::Round($bytes * 8 / [math]::Max(1, $Seconds) / 1MB, 1)
    }
}

$rows | Format-Table -AutoSize

$max = ($rows | Measure-Object MBps -Maximum).Maximum
$threshold = $max * 0.95
$recommended = ($rows | Where-Object { $_.MBps -ge $threshold } | Sort-Object Connections | Select-Object -First 1)

"peak: {0} MB/s ({1} Mbps)" -f $max, [math]::Round($max * 8, 1)
"recommended: -Workers {0}  ({1} MB/s, >=95% of peak)" -f $recommended.Connections, $recommended.MBps
"probe traffic used: {0:N1} MB" -f ($totalBytes / 1MB)
