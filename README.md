# parallel-large-download

A DeepSeek Harness skill for pulling multi-gigabyte files over slow, throttled or unstable links — work-stealing HTTP range chunks, resume, periodic connection refresh, remote sample verification and checksum-guided repair.

Same mechanism as NDM/IDM/aria2 (many `Range` connections), with two differences that matter at this scale: a free worker immediately takes the next queued chunk so one slow connection cannot strand the tail of the file, and the finished bytes are verified and repaired instead of trusted.

## What it solves

- Single-connection downloads in the KB/s range while many connections reach several MB/s.
- Downloads that die partway and must resume without re-downloading everything.
- Files that finish with the right size but the wrong checksum (duplicated or shifted byte ranges).
- Downloads that must outlive the agent session.

## Requirements

- Windows 10/11 with PowerShell 7 (`pwsh`)
- `curl.exe` (ships with Windows) — or pass `-Curl` to another build
- Enough free disk for the file plus its chunk files (about 2×)

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

Tune the connection count against the real URL (sweeps 1..96 by default, recommends a `-Workers` value):

```powershell
pwsh -File scripts/tune.ps1 -Url <file-url> -Proxy 'http://127.0.0.1:<port>' -Connections 1,8,16,32,48,64,96
```

Download with resume and a publisher checksum:

```powershell
pwsh -File scripts/download.ps1 -Url <file-url> -TotalSize <bytes> `
  -Dest 'D:\data\thing' -OutName 'thing.zip' `
  -ChunkMB 128 -Workers 48 `
  -Proxy 'http://127.0.0.1:<port>' -Md5 <expected-md5>
```

Verify every chunk against the remote object, repair only the bad ranges, then re-check:

```powershell
pwsh -File scripts/verify.ps1 -Url <file-url> -TotalSize <bytes> -Dest 'D:\data\thing' -OutName 'thing.zip' -ChunkMB 128
pwsh -File scripts/repair.ps1 -Url <file-url> -TotalSize <bytes> -Index <n> -Dest 'D:\data\thing' -OutName 'thing.zip' -ChunkMB 128
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
| `scripts/tune.ps1` | Sweep connection counts and recommend a worker count |
| `scripts/download.ps1` | Work-stealing parallel ranged download with resume, connection refresh, assembly, MD5 |
| `scripts/verify.ps1` | Sample-compare every chunk with the remote object; list bad chunks |
| `scripts/repair.ps1` | Re-download one chunk in parallel and replace it or splice the output |
| `scripts/watchdog.ps1` | Restart a dead or stalled download task; never touches assembly/hashing |

## Notes and caveats

- Security software may flag the pattern "long-running process spawns many network clients plus a scheduled task" as suspicious. Prefer `-NoNewWindow`, keep the scripts in a folder you exclude from real-time scanning, and review the code — it is plain PowerShell.
- Progress reported by Explorer or `Get-ChildItem` is unreliable for files a process holds open; the scripts read sizes with `Get-Item`.
- A size match is not integrity. Always compare the publisher checksum.

## License

MIT — see [LICENSE](LICENSE).

See `SKILL.md` for the full workflow and the hard-won rules.
