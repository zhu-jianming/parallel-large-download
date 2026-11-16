param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int64]$TotalSize,
    [string]$Dest = '.',
    [string]$OutName = 'download.bin',
    [int]$ChunkMB = 128,
    [string]$Proxy = '',
    [int]$SampleBytes = 65536,
    [int]$Samples = 2,
    [int]$Retries = 4,
    [string]$Curl = 'C:\Windows\System32\curl.exe'
)

# Compare sampled windows of every chunk with the remote object at the same absolute
# offset. A chunk with duplicated or shifted bytes keeps its exact size, so only
# content comparison finds it. Probes are sequential: bursty parallel probes make
# some hosts answer with tiny error bodies.

$ErrorActionPreference = 'Stop'
$PartsDir = Join-Path $Dest '_parts'
$Report   = Join-Path $Dest ($OutName + '.verify.log')
$BadFile  = Join-Path $Dest ($OutName + '.badchunks.txt')

if (-not (Test-Path -LiteralPath $PartsDir)) { throw "no chunks directory: $PartsDir" }
Set-Content -LiteralPath $Report -Value ('[{0:yyyy-MM-dd HH:mm:ss}] verify start' -f (Get-Date)) -Encoding utf8

$chunkBytes = [int64]$ChunkMB * 1MB
$count = [int]([math]::Ceiling([double]$TotalSize / $chunkBytes))
$points = [System.Collections.Generic.List[double]]::new()
$points.Add(0.001)
$points.Add(0.999)
for ($s = 0; $s -lt $Samples; $s++) { $points.Add(($s + 0.5) / $Samples) }
$fractions = $points.ToArray()

$bad = @()
for ($i = 0; $i -lt $count; $i++) {
    $start = [int64]$i * $chunkBytes
    $end = [math]::Min($start + $chunkBytes - 1, $TotalSize - 1)
    $size = [int64]($end - $start + 1)
    $file = Join-Path $PartsDir ('chunk_{0:D5}.bin' -f $i)
    if (-not (Test-Path -LiteralPath $file)) { $bad += $i; Add-Content -LiteralPath $Report -Value ("chunk {0}: missing" -f $i) -Encoding utf8; continue }
    if ((Get-Item -LiteralPath $file).Length -ne $size) { $bad += $i; Add-Content -LiteralPath $Report -Value ("chunk {0}: wrong size" -f $i) -Encoding utf8; continue }

    $fs = [System.IO.File]::OpenRead($file)
    $problems = @()
    try {
        foreach ($fraction in $fractions) {
            $offset = [int64]([math]::Floor($size * $fraction))
            if ($offset + $SampleBytes -gt $size) { continue }
            $absolute = $start + $offset
            $absoluteEnd = $absolute + $SampleBytes - 1
            $tmp = Join-Path $env:TEMP ("verify_{0}_{1}.bin" -f $i, [int]($fraction * 100))
            $fetched = $false
            for ($attempt = 1; $attempt -le $Retries; $attempt++) {
                $args = @('-sS', '-L', '--max-time', '60', '--range', "$absolute-$absoluteEnd", '-o', $tmp)
                if ($Proxy) { $args += @('-x', $Proxy) }
                $args += $Url
                & $Curl @args 2>$null
                if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -eq $SampleBytes)) { $fetched = $true; break }
                Start-Sleep -Seconds 2
            }
            if (-not $fetched) { $problems += ("offset {0}: fetch failed" -f $offset); continue }
            $remote = [System.IO.File]::ReadAllBytes($tmp)
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            $null = $fs.Seek($offset, 'Begin')
            $buffer = New-Object byte[] $SampleBytes
            $read = 0
            while ($read -lt $SampleBytes) { $got = $fs.Read($buffer, $read, $SampleBytes - $read); if ($got -le 0) { break }; $read += $got }
            $diff = 0
            for ($k = 0; $k -lt $SampleBytes; $k++) { if ($buffer[$k] -ne $remote[$k]) { $diff++ } }
            if ($diff -gt 0) { $problems += ("offset {0}: {1} bytes differ" -f $offset, $diff) }
        }
    } finally { $fs.Dispose() }

    if ($problems.Count -gt 0) {
        $bad += $i
        Add-Content -LiteralPath $Report -Value ("chunk {0}: {1}" -f $i, ($problems -join '; ')) -Encoding utf8
    } else {
        Add-Content -LiteralPath $Report -Value ("chunk {0}: ok" -f $i) -Encoding utf8
    }
}

Set-Content -LiteralPath $BadFile -Value ($bad -join ',') -Encoding utf8
Add-Content -LiteralPath $Report -Value ('[{0:yyyy-MM-dd HH:mm:ss}] verify done; bad chunks = {1}' -f (Get-Date), $(if ($bad.Count) { $bad -join ',' } else { 'none' })) -Encoding utf8
"bad chunks: " + $(if ($bad.Count) { $bad -join ',' } else { 'none' })
if ($bad.Count -gt 0) { exit 2 }
