---
name: parallel-large-download
description: Download very large files (multi-GB) over slow, per-connection-throttled or unstable links with parallel HTTP range chunks, resume, connection refresh, remote sample verification and checksum-guided repair. Use when a download from Zenodo/CERN or any slow host crawls, stalls, drops, or must be verified and repaired; also for 加速下载, 并行下载, 断点续传, 大文件校验/修复.
metadata:
  version: "1.0.0"
---

# Parallel large-file download

A 20–100 GB file over a throttled or flaky route cannot be fetched with one connection and cannot be trusted just because its size matches. This skill is the workflow that worked end to end on a 72 GiB public dataset from Zenodo (about 6 hours) plus the failure modes that cost hours.

## When to use

- A single-connection download is in the KB/s range, or per-connection throttling makes multi-connection far faster.
- The file is large enough that a restart is unacceptable (multi-GB).
- The publisher exposes a checksum (Zenodo: `md5:<hex>` in the record API).
- You must verify or repair an already-downloaded large file.

Not for: small files (use `curl -L -O`), hosts without HTTP `Range` support (check with `curl -I -r 0-0`), or cases where a proper downloader already works (aria2 is fine but caps at 16 connections per server).

## Step 0 — Measure before downloading

Run `scripts/probe.ps1` (resolve it against this skill's base directory). It measures single-connection and N-connection throughput, through a proxy and without one. Decide from its output:

- direct vs `-Proxy http://127.0.0.1:<port>` — pick whichever is faster; for hosts in Europe reached from a distant region, a local proxy is often 10–20× faster than a direct connection.
- `-Parts` ≈ 48 is the sweet spot seen in practice (8 ≈ 1.6 MB/s, 24 ≈ 4.3, 48 ≈ 4.8–5.4, 64–96 ≈ 5 MB/s plateau). More than the plateau wastes sockets.

## Step 1 — Collect facts from the API

For Zenodo, `GET https://zenodo.org/api/records/<id>` gives:

- `files[0].size` (int64), `files[0].checksum` (`md5:...`), `files[0].key`
- direct content URL: `https://zenodo.org/api/records/<id>/files/<key>/content` (returns 206 for `Range`, no redirect)

Do not download the HTML page link; use the `/content` URL.

## Step 2 — Download

```powershell
pwsh -File scripts/download.ps1 -Url <content-url> -TotalSize <bytes> `
  -Dest 'E:\data\thing' -OutName 'thing.zip' -Parts 48 `
  -Proxy 'http://127.0.0.1:<port>' -Md5 <expected-md5>
```

What it does: splits into `Parts` byte ranges, keeps one `part_NNN.bin` per range, runs one `curl --range` per part through a supervisor loop, appends each finished transfer to its part file, refreshes every connection after `-MaxTimeSeconds` (10 min) so long-lived throttling cannot set in, and finally concatenates the parts in order and verifies size/MD5.

Run it detached when it must outlive the session: register a one-shot scheduled task running `pwsh -File ...` and `Start-ScheduledTask`; a task with `-LogonType Interactive` survives the agent, stops at logoff, and resumes with the same command (parts are the resume state).

Watch progress with `<OutName>.progress.txt`; the `.download.log` records START/part completions/assembly/MD5.

## Step 3 — Verify

Size equality is not integrity. Run `scripts/verify.ps1`:

- compares evenly spaced 64 KiB windows of every part (default 6 interior points plus both part ends) against the remote file at the same absolute offsets; probes run sequentially with retries, because bursty parallel probes make some hosts answer with tiny error bodies,
- writes the bad part indices to `<OutName>.badparts.txt`.

A part with duplicated or shifted bytes keeps its exact expected size, so only content comparison finds it. This sampling catches the real failure mode — an inserted or repeated region shifts everything after it. An isolated few-byte substitution smaller than a sample window can slip through, so the publisher's checksum remains the final authority: always run the MD5 after assembly.

## Step 4 — Repair, do not re-download

For each bad index, `scripts/repair.ps1 -Index <n>` re-downloads only that range in `-SubParts` parallel sub-chunks, re-verifies samples, and either replaces the part file (`-Splice none`) or writes it straight into the finished output at `Index * ChunkSize` (`-Splice <path-to-output>`). Then re-check MD5.

## Hard-won rules

- **Never pass `--retry` together with `-o <file>` when you append partial results.** curl truncates the output on each internal retry, silently discarding already-written bytes and making the progress number go backwards. Let the supervisor restart instead: `--max-time`, exit, append, re-range.
- **One supervisor per part directory.** Two processes appending to the same part files duplicate bytes; the part size still ends up exact because the loop stops at the expected size, so the corruption is invisible until the checksum.
- **Refresh connections.** Many proxies throttle a single TCP flow to ~1 Mbps and degrade long flows further; 48 fresh connections every 10 minutes held ~5 MB/s where 48 hour-old connections fell to 1.3 MB/s.
- **A watchdog that reads part growth must ignore the assembly and hashing phase** — parts stop growing at 100%, so it will "detect a stall" and kill the MD5. Skip when the progress file starts with `DONE` or every part is complete, or disable it before assembly.
- **Measurements from Explorer/`Get-ChildItem` lie for files a process holds open** (they report 0 bytes). Use `Get-Item <file>.Length` per file; the progress file must do the same.
- **Reserve 2× disk**: the finished file plus the part files coexist during assembly.
- **Don't wrap curl in `cmd` with non-ASCII paths** — the .cmd file is read in the OEM code page. `Start-Process`/scheduled tasks pass UTF-8 arguments correctly; `curl` itself handles Chinese paths in argv.
- **Do not create processes through `Win32_Process.Create` for the `WindowsApps` `pwsh.exe` alias** (returns 8, "unknown failure"); use a scheduled task.
- **Semantics of the checksum**: Zenodo's `checksum` is over the published object. If MD5 mismatches after a size-identical assembly, suspect duplicate-prefix corruption from a supervisor race, not a wrong file.

## Windows extras

- Reading the archive without extracting: `gdalinfo "/vsizip/E:\path\file.zip/inside/file.tif"` works, including non-ASCII paths, when GDAL is installed (`conda create -p <dir> -c conda-forge gdal`).
- A zip with a valid central directory (`[System.IO.Compression.ZipFile]::OpenRead`) but a wrong MD5 means payload bytes are wrong; the entry list alone proves nothing.

## Reporting

Always report: file size vs expected, MD5 vs publisher checksum, bad parts found and how they were repaired, and where the parts/log files live. Delete part files only after the checksum passes.
