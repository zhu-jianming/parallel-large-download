---
name: parallel-large-download
description: Download very large files (multi-GB) over slow, per-connection-throttled or unstable links with work-stealing HTTP range chunks, resume, connection refresh, remote sample verification and checksum-guided repair. Use when a download from Zenodo/CERN or any slow host crawls, stalls, drops, or must be verified and repaired; also for 加速下载, 并行下载, 断点续传, 大文件校验/修复.
metadata:
  version: "1.1.0"
  license: MIT
---

# Parallel large-file download

A 20–100 GB file over a throttled or flaky route cannot be fetched with one connection and cannot be trusted just because its size matches. This skill is the workflow that worked end to end on a 72 GiB public dataset from Zenodo (about 6 hours), packaged with the failure modes that cost hours.

The mechanism is the same one NDM/IDM/aria2 use — HTTP `Range` requests over many connections — with two differences that matter at this scale: the chunks are handed out to a work-stealing pool (so a slow connection never strands the tail), and the result is verified and repaired rather than trusted.

## When to use

- A single-connection download is in the KB/s range, or per-connection throttling makes multi-connection far faster.
- The file is large enough that a restart is unacceptable (multi-GB).
- The publisher exposes a checksum (Zenodo: `md5:<hex>` in the record API).
- You must verify or repair an already-downloaded large file.

Not for: small files (use `curl -L -O`), hosts without HTTP `Range` support (check with `curl -I -r 0-0`), or cases where a proper download manager already works.

## Step 0 — Tune the connection count

Run `scripts/tune.ps1` (resolve it against this skill's base directory). It sweeps connection counts against the real URL, through a proxy and without one, and prints a table plus a recommended `-Workers`:

```powershell
pwsh -File scripts/tune.ps1 -Url <file-url> -Proxy 'http://127.0.0.1:<port>' -Connections 1,8,16,32,48,64,96
```

Pick direct or proxy from the table — for hosts in Europe reached from a distant region, a local proxy is often 10–20× faster. Take the recommendation (first count reaching 95% of peak); in practice 48 is enough on a ~40 Mbps node, and 64–96 adds sockets without throughput.

## Step 1 — Collect facts from the API

For Zenodo, `GET https://zenodo.org/api/records/<id>` gives:

- `files[0].size` (int64), `files[0].checksum` (`md5:...`), `files[0].key`
- direct content URL: `https://zenodo.org/api/records/<id>/files/<key>/content` (returns 206 for `Range`, no redirect)

Do not download the HTML page link; use the `/content` URL.

## Step 2 — Download

```powershell
pwsh -File scripts/download.ps1 -Url <content-url> -TotalSize <bytes> `
  -Dest 'D:\data\thing' -OutName 'thing.zip' `
  -ChunkMB 128 -Workers 48 `
  -Proxy 'http://127.0.0.1:<port>' -Md5 <expected-md5>
```

How it works: the object is cut into fixed-size chunks (`-ChunkMB`, default 128 MB, last one shorter). A single supervisor keeps up to `-Workers` curls in flight; whenever one finishes, the next queued chunk starts on that free slot, so fast connections take more work and the tail does not crawl behind one slow connection. Each `_parts/chunk_NNNNN.bin` is both the output range and the resume point: a restart re-ranges from that chunk's current byte length, after merging any leftover `.tmp`. Connections are recycled every `-MaxTimeSeconds` (10 min) because long-lived flows get throttled; a chunk with no growth for `-StallKillSeconds` is killed and requeued. Finally the chunks are concatenated in order and checked for size and MD5.

Run it detached when it must outlive the session: register a one-shot scheduled task running `pwsh -File ...` and `Start-ScheduledTask`; a task with `-LogonType Interactive` survives the agent, stops at logoff, and resumes with the same command (the chunk files are the resume state).

Watch progress with `<OutName>.progress.txt`; the `.download.log` records START/chunk completions/assembly/MD5.

## Step 3 — Verify

Size equality is not integrity. Run `scripts/verify.ps1`:

```powershell
pwsh -File scripts/verify.ps1 -Url <content-url> -TotalSize <bytes> `
  -Dest 'D:\data\thing' -OutName 'thing.zip' -ChunkMB 128
```

- compares evenly spaced 64 KiB windows of every chunk (both chunk ends plus `-Samples` interior points) against the remote file at the same absolute offsets; probes run sequentially with retries, because bursty parallel probes make some hosts answer with tiny error bodies,
- writes the bad chunk indices to `<OutName>.badchunks.txt`.

A chunk with duplicated or shifted bytes keeps its exact expected size, so only content comparison finds it. Sampling catches the real failure mode — an inserted or repeated region shifts everything after it. An isolated few-byte substitution smaller than a sample window can slip through, so the publisher's checksum remains the final authority: always run the MD5 after assembly.

## Step 4 — Repair, do not re-download

```powershell
pwsh -File scripts/repair.ps1 -Url <content-url> -TotalSize <bytes> -Index <n> `
  -Dest 'D:\data\thing' -OutName 'thing.zip' -ChunkMB 128 -Sink chunks
```

`repair.ps1` re-downloads only that chunk range in `-SubParts` parallel sub-ranges, re-verifies samples, and either replaces `_parts/chunk_<n>.bin` (`-Sink chunks`) or writes the bytes straight into the finished output at `Index * ChunkBytes` (`-Sink output`). Then re-check MD5.

## Hard-won rules

- **Never pass `--retry` together with `-o <file>` when you append partial results.** curl truncates the output on each internal retry, silently discarding already-written bytes and making the progress number go backwards. Let the supervisor restart instead: `--max-time`, exit, append, re-range.
- **One supervisor per chunk directory.** Two processes appending to the same chunk files duplicate bytes; the chunk size still ends up exact because the loop stops at the expected size, so the corruption is invisible until the checksum.
- **Refresh connections.** Many proxies throttle a single TCP flow to ~1 Mbps and degrade long flows further; 48 fresh connections every 10 minutes held ~5 MB/s where 48 hour-old connections fell to 1.3 MB/s.
- **Keep chunks modest.** Fixed 128 MB chunks plus a stealing pool give the tail of the file the same parallelism as the head; one huge chunk per worker (the old fixed-`Parts` layout) leaves the last chunks lagging.
- **A watchdog that reads chunk growth must ignore the assembly and hashing phase** — chunks stop growing at 100%, so it will "detect a stall" and kill the MD5. Skip when the progress file starts with `DONE`/`FAIL` or every chunk is complete.
- **Measurements from Explorer/`Get-ChildItem` lie for files a process holds open** (they report 0 bytes). Use `Get-Item <file>.Length` per file; the progress file must do the same.
- **Reserve 2× disk**: the finished file plus the chunk files coexist during assembly.
- **Don't wrap curl in `cmd` with non-ASCII paths** — the .cmd file is read in the OEM code page. `Start-Process`/scheduled tasks pass UTF-8 arguments correctly; `curl` itself handles non-ASCII paths in argv.
- **Do not create processes through `Win32_Process.Create` for the `WindowsApps` `pwsh.exe` alias** (returns 8, "unknown failure"); use a scheduled task.
- **Semantics of the checksum**: Zenodo's `checksum` is over the published object. If MD5 mismatches after a size-identical assembly, suspect duplicate-prefix corruption from a supervisor race, not a wrong file.

## Windows extras

- Reading the archive without extracting: `gdalinfo "/vsizip/E:\path\file.zip/inside/file.tif"` works, including non-ASCII paths, when GDAL is installed (`conda create -p <dir> -c conda-forge gdal`).
- A zip with a valid central directory (`[System.IO.Compression.ZipFile]::OpenRead`) but a wrong MD5 means payload bytes are wrong; the entry list alone proves nothing.

## Reporting

Always report: file size vs expected, MD5 vs publisher checksum, bad chunks found and how they were repaired, and where the chunk/log files live. Delete chunk files only after the checksum passes.
