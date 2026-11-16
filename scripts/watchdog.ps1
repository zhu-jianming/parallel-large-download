param(
    [Parameter(Mandatory = $true)][string]$TaskName,
    [Parameter(Mandatory = $true)][string]$Dest,
    [Parameter(Mandatory = $true)][int64]$TotalSize,
    [string]$OutName = 'download.bin',
    [int]$Parts = 48,
    [int]$StallMinutes = 15,
    [int]$CooldownMinutes = 30
)

# Restart a download whose supervisor died or stopped making progress.
# Skips the assembly/hashing phase on purpose: parts stop growing there, and a
# "stall" judgment would kill the checksum.

$ErrorActionPreference = 'SilentlyContinue'
$PartsDir = Join-Path $Dest '_parts'
$Progress = Join-Path $Dest ($OutName + '.progress.txt')
$LogFile  = Join-Path $Dest ($OutName + '.watchdog.log')
$State    = Join-Path $Dest ($OutName + '.watchdog_state.json')

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message) -Encoding utf8
}

$progressText = Get-Content -LiteralPath $Progress -ErrorAction SilentlyContinue
if ($progressText -match '^DONE|^FAIL') { exit 0 }

$chunk = [int64]([math]::Floor([double]$TotalSize / $Parts) + 1)
$complete = 0
$total = 0
for ($i = 0; $i -lt $Parts; $i++) {
    $start = [int64]$i * $chunk
    if ($start -ge $TotalSize) { break }
    $total++
    $file = Join-Path $PartsDir ('part_{0:D3}.bin' -f $i)
    $expected = [math]::Min($chunk, $TotalSize - $start)
    if ((Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).Length -ge $expected)) { $complete++ }
}
if ($total -gt 0 -and $complete -eq $total) { exit 0 }

$bytes = [int64]0
foreach ($file in Get-ChildItem -LiteralPath $PartsDir -File -ErrorAction SilentlyContinue) {
    $bytes += (Get-Item -LiteralPath $file.FullName).Length
}

$now = Get-Date
$state = $null
if (Test-Path -LiteralPath $State) { try { $state = Get-Content -LiteralPath $State -Raw | ConvertFrom-Json } catch { $state = $null } }
$previous = if ($state) { [int64]$state.bytes } else { $bytes }
$lastGrowth = if ($state) { [datetime]$state.lastGrowth } else { $now }
$lastRestart = if ($state -and $state.lastRestart) { [datetime]$state.lastRestart } else { [datetime]::MinValue }

if ($bytes -gt $previous + 20MB) { $lastGrowth = $now }

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$running = $task -and ($task.State -eq 'Running')
$restarted = $false

if (-not $running) {
    Write-Log ('task not running (state=' + $(if ($task) { $task.State } else { 'missing' }) + '); starting')
    Start-ScheduledTask -TaskName $TaskName
    $restarted = $true
}
elseif ((($now - $lastGrowth).TotalMinutes -ge $StallMinutes) -and ((($now - $lastRestart).TotalMinutes -ge $CooldownMinutes))) {
    Write-Log ('no progress for {0:N0} min; restarting task and its curl children' -f ($now - $lastGrowth).TotalMinutes)
    Stop-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2
    Get-CimInstance Win32_Process -Filter "Name='curl.exe'" |
        Where-Object { $_.CommandLine -like ('*' + $Dest + '*') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-ScheduledTask -TaskName $TaskName
    $restarted = $true
    $lastRestart = $now
}
if ($restarted) { $lastGrowth = $now }

(@{
    bytes       = $bytes
    lastGrowth  = $lastGrowth.ToString('o')
    lastRestart = $lastRestart.ToString('o')
    complete    = $complete
    total       = $total
} | ConvertTo-Json -Compress) | Set-Content -LiteralPath $State -Encoding utf8
