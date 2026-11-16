# parallel-large-download

A DeepSeek Harness skill for pulling multi-gigabyte files over slow, throttled or unstable links — parallel HTTP range chunks, resume, periodic connection refresh, remote sample verification and checksum-guided repair.

This is the workflow that completed a 72 GiB Zenodo object in about 6 hours over a per-connection-throttled route, packaged with the failure modes that cost the most time.

## What it solves

- Single-connection downloads in the KB/s range while many connections reach several MB/s.
- Downloads that die partway and must resume without re-downloading everything.
- Files that finish with the right size but the wrong checksum (duplicated or shifted byte ranges).
- Downloads that must outlive the agent session.

## Requirements

- Windows 10/11 with PowerShell 7 (`pwsh`)
- `curl.exe` (ships with Windows) — or pass `-Curl` to another build
- Enough free disk for the file plus its part files (about 2×)

## Install

Copy this directory into a scanned skill root:

```powershell
# per-user skills
Copy-Item -Recurse . "$env:USERPROFILE\.agents\skills\parallel-large-download"
# or: $env:USERPROFILE\.dsh\skills\parallel-large-download
# or a project root: <repo>\.dsh\skills\parallel-large-download
```

The skill provider discovers `<root>/<name>/SKILL.md` and watches the directory, so no restart is needed.

## Usage

Measure first — direct versus proxy, and how many connections the route rewards:

```powershell
pwsh -File scripts/probe.ps1 -Url <file-url> -Proxy 'http://127.0.0.1:<port>' -Connections 1,8,24,48
```

Download with resume and a publisher checksum:

```powershell
pwsh -File scripts/download.ps1 -Url <file-url> -TotalSize <bytes> `
  -Dest 'D:\data\thing' -OutName 'thing.zip' -Parts 48 `
  -Proxy 'http://127.0.0.1:<port>' -Md5 <expected-md5>
```

Verify every part against the remote object, repair only the bad ranges, then re-check:

```powershell
pwsh -File scripts/verify.ps1 -Url <file-url> -TotalSize <bytes> -Dest 'D:\data\thing' -OutName 'thing.zip'
pwsh -File scripts/repair.ps1 -Url <file-url> -TotalSize <bytes> -Index <n> -Dest 'D:\data\thing' -OutName 'thing.zip'
```

Keep a long download alive across agent restarts with a scheduled task, and optionally a watchdog:

```powershell
$action = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -File C:\path\scripts\download.ps1 ...'
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
Register-ScheduledTask -TaskName 'MyDownload' -Action $action -Principal $principal -Force
Start-ScheduledTask -TaskName 'MyDownload'
```

## Scripts

| Script | Purpose |
|---|---|
| `scripts/probe.ps1` | Throughput probe: direct vs proxy, 1..N connections |
| `scripts/download.ps1` | Parallel ranged download with resume, connection refresh, assembly, MD5 |
| `scripts/verify.ps1` | Sample-compare every part with the remote object; list bad parts |
| `scripts/repair.ps1` | Re-download one range in parallel and replace the part or splice the output |
| `scripts/watchdog.ps1` | Restart a dead or stalled download task; never touches assembly/hashing |

## Notes and caveats

- Security software may flag the pattern "hidden process spawns many network clients plus a scheduled task" as suspicious. Prefer `-NoNewWindow`, keep the scripts in a folder you exclude from real-time scanning, and review the code — it is plain PowerShell.
- Progress reported by Explorer or `Get-ChildItem` is unreliable for files a process holds open; the scripts read sizes with `Get-Item`.
- A size match is not integrity. Always compare the publisher checksum.
- No license is declared in this repository; add one if you intend to redistribute.

See `SKILL.md` for the full workflow and the hard-won rules.
