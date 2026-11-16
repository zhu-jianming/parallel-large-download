param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][int64]$TotalSize,
    [Parameter(Mandatory = $true)][int]$Index,
    [string]$Dest = '.',
    [string]$OutName = 'download.bin',
    [int]$ChunkMB = 128,
    [string]$Proxy = '',
    [int]$SubParts = 16,
    [ValidateSet('chunks', 'output')][string]$Sink = 'chunks',
    [int]$SampleBytes = 65536,
    [string]$Curl = 'C:\Windows\System32\curl.exe'
)

# Re-download one chunk in SubParts parallel sub-ranges, verify samples against the
# remote object, then either replace _parts/chunk_<Index>.bin or write those bytes
# straight into the assembled output at Index * chunkBytes.

$ErrorActionPreference = 'Stop'
$chunkBytes = [int64]$ChunkMB * 1MB
$start = [int64]$Index * $chunkBytes
if ($start -ge $TotalSize) { throw "chunk index $Index out of range" }
$end  = [math]::Min($start + $chunkBytes - 1, $TotalSize - 1)
$size = [int64]($end - $start + 1)

$PartsDir = Join-Path $Dest '_parts'
$Log      = Join-Path $Dest ($OutName + '.repair.log')
New-Item -ItemType Directory -Force -Path $PartsDir | Out-Null
$work = Join-Path $env:TEMP ("repair_{0}_{1}" -f $Index, [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $Log -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) -Encoding utf8
}

Write-Log ("repair chunk {0}: start={1} size={2} subs={3} sink={4}" -f $Index, $start, $size, $SubParts, $Sink)

$subSize = [int64]([math]::Floor([double]$size / $SubParts) + 1)
$subs = @()
for ($s = 0; $s -lt $SubParts; $s++) {
    $subStart = $start + [int64]$s * $subSize
    if ($subStart -gt $end) { break }
    $subEnd = [math]::Min($subStart + $subSize - 1, $end)
    $subs += [pscustomobject]@{ S = $subStart; E = $subEnd; Size = [int64]($subEnd - $subStart + 1); File = (Join-Path $work ('sub_{0:D3}.bin' -f $s)) }
}

$subs | ForEach-Object -Parallel {
    $u = $using:Url; $px = $using:Proxy; $curl = $using:Curl
    $sub = $_
    $tmp = $sub.File + '.tmp'
    $attempts = 0
    while ($true) {
        $cur = [int64]0
        if (Test-Path -LiteralPath $sub.File) { $cur = (Get-Item -LiteralPath $sub.File).Length }
        if ($cur -ge $sub.Size) { break }
        $attempts++
        if ($attempts -gt 60) { break }
        $from = $sub.S + $cur
        $args = @('-sS', '-L', '--connect-timeout', '30', '--max-time', '600', '--range', "$from-$($sub.E)", '-o', $tmp)
        if ($px) { $args += @('-x', $px) }
        $args += $u
        & $curl @args 2>$null
        if (Test-Path -LiteralPath $tmp) {
            $len = (Get-Item -LiteralPath $tmp).Length
            if ($len -gt 0) {
                $out = [System.IO.File]::Open($sub.File, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
                try { $src = [System.IO.File]::OpenRead($tmp); try { $src.CopyTo($out, 1MB) } finally { $src.Dispose() } } finally { $out.Dispose() }
            }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        } else { Start-Sleep -Seconds 3 }
    }
} -ThrottleLimit $SubParts

$newChunk = Join-Path $work 'chunk.bin'
$out = [System.IO.File]::Open($newChunk, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
try {
    foreach ($sub in $subs) {
        $in = [System.IO.File]::OpenRead($sub.File)
        try { $in.CopyTo($out, 4MB) } finally { $in.Dispose() }
    }
} finally { $out.Dispose() }

$newSize = (Get-Item -LiteralPath $newChunk).Length
if ($newSize -ne $size) { Write-Log ("FAIL new chunk size {0} != {1}" -f $newSize, $size); exit 2 }

$fs = [System.IO.File]::OpenRead($newChunk)
$badSamples = 0
try {
    foreach ($fraction in @(0.001, 0.2, 0.4, 0.6, 0.8, 0.999)) {
        $offset = [int64]([math]::Floor($size * $fraction))
        if ($offset + $SampleBytes -gt $size) { continue }
        $absolute = $start + $offset
        $tmp = Join-Path $work 'sample.bin'
        $ok = $false
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            $args = @('-sS', '-L', '--max-time', '60', '--range', ("{0}-{1}" -f $absolute, ($absolute + $SampleBytes - 1)), '-o', $tmp)
            if ($Proxy) { $args += @('-x', $Proxy) }
            $args += $Url
            & $Curl @args 2>$null
            if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -eq $SampleBytes)) { $ok = $true; break }
        }
        if (-not $ok) { $badSamples++; continue }
        $remote = [System.IO.File]::ReadAllBytes($tmp)
        $null = $fs.Seek($offset, 'Begin')
        $buffer = New-Object byte[] $SampleBytes
        $null = $fs.Read($buffer, 0, $SampleBytes)
        $diff = 0
        for ($k = 0; $k -lt $SampleBytes; $k++) { if ($buffer[$k] -ne $remote[$k]) { $diff++ } }
        if ($diff -gt 0) { $badSamples++ }
    }
} finally { $fs.Dispose() }

if ($badSamples -gt 0) { Write-Log ("FAIL {0} sample(s) still differ" -f $badSamples); exit 3 }

if ($Sink -eq 'output') {
    $target = Join-Path $Dest $OutName
    if (-not (Test-Path -LiteralPath $target)) { throw "output not found: $target" }
    $dst = [System.IO.File]::Open($target, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write)
    $src = [System.IO.File]::OpenRead($newChunk)
    try { $null = $dst.Seek($start, 'Begin'); $src.CopyTo($dst, 4MB) } finally { $src.Dispose(); $dst.Dispose() }
    Write-Log ("chunk {0} spliced into {1} at {2}" -f $Index, $OutName, $start)
} else {
    Move-Item -LiteralPath $newChunk -Destination (Join-Path $PartsDir ('chunk_{0:D5}.bin' -f $Index)) -Force
    Write-Log ("chunk {0} replaced" -f $Index)
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Log 'repair done'
