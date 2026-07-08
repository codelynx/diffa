# Mac ↔ Mac Network Sync — LAN Test Results

Empirical verification of Diffa network sync (`serve` / `push` / `pull`)
between two macOS machines over a local network, with emphasis on the
hash-based copy optimization. Complements the design in
[`network-copy-optimization.md`](network-copy-optimization.md) and the
cross-platform LAN results in
[`cross-platform-network-sync.md`](cross-platform-network-sync.md) §7.3.

**Date:** 2026-07-09
**Diffa:** `develop` @ `e5e0a32` on both machines, debug builds
**Result:** all four scenarios passed; every file verified by SHA-256 on both ends.

## Environment

| Role | Machine | OS | Swift | Address |
|------|---------|----|-------|---------|
| Server | MacBook Pro 16″ (`MacBookPro18,2`) | macOS 26.5.1 (25F80) | 6.3.3 | `192.168.2.116:8756` |
| Client | Mac mini 2024 | macOS 26.5.2 | 6.3.3 | `192.168.2.109` |

macOS application firewall was disabled on the server; the port was
reachable on both loopback and the LAN interface before testing.

## Server setup

```
diffa serve --path ~/diffa-synctest/served --port 8756
```

Initial served directory (reference state):

| path | size | sha256 |
|------|------|--------|
| `notes.txt` | 32 B | `4d00def1…e19bcb` |
| `docs/guide.md` | 49 B | `3fc2b09e…c9ddd7` |
| `assets/payload.bin` | 104960 B | `739150d6…81443f` |
| `media/photo.dat` | 20480 B | `eb071032…4ffd75` |

`payload.bin` and `photo.dat` are deterministic repeated-block files
sized to exercise zlib compression (≥4 KB).

## Scenarios

Client drives all operations from the Mac mini. Note that both `push`
and `pull` are **mirror** operations — they delete files absent on the
source side.

### 1. Pull into an empty directory — PASS

```
diffa pull pulled 192.168.2.116:8756
→ Local files: 0 · Remote files: 4 · Operations: 4 · Sync complete!
```

- All 4 files downloaded; every SHA-256 matched the reference table.
- zlib compression active on the wire: `payload.bin` 104960 B → **368 B**,
  `photo.dat` 20480 B → **107 B**.
- Server directory unmodified (pull is read-only on the server) — verified.

### 2. Incremental push (add + modify) — PASS

Client added `added-from-mini.txt` (60 B) and modified `notes.txt` (→ 74 B).

```
diffa push pulled 192.168.2.116:8756
→ Local files: 5 · Remote files: 4 · Operations: 2
  Uploading: added-from-mini.txt (60 bytes)
  Uploading: notes.txt (74 bytes)
```

- Exactly 2 operations; the 3 unchanged files were skipped.
- Server end-state (5 files) verified: both changed files matched the
  new expected hashes; the 3 untouched files **retained their original
  hashes** (no needless rewrite, no corruption, nothing wrongly deleted).

### 3. Mirror-delete — PASS

Client `rm pulled/media/photo.dat`, then push.

```
→ Local files: 4 · Remote files: 5 · Operations: 1
  Deleting (remote): media/photo.dat
```

- 1 operation, 0 content bytes transferred.
- Server end-state verified: `media/photo.dat` removed, the now-empty
  `media/` directory cleaned up, other 4 files unchanged.

### 4. Rename → hash-based copy optimization — PASS ⭐

Client `mv assets/payload.bin assets/payload-moved.bin` (content
unchanged, 100 KB), then push.

```
→ Local files: 4 · Remote files: 4 · Operations: 2
  Copying (remote): assets/payload.bin → assets/payload-moved.bin
  Deleting (remote): assets/payload.bin
```

- **No `Uploading:` line** for `payload-moved.bin` → **zero content bytes
  crossed the wire** for the 100 KB file (versus 368 B compressed in
  scenario 1).
- Server end-state verified: `assets/payload-moved.bin` present with the
  original content hash `739150d6…81443f`; `assets/payload.bin` gone;
  other 3 files unchanged.

This matches the "Rename" row of the scenario table in
[`network-copy-optimization.md`](network-copy-optimization.md): 0
transfers, resolved as a destination-side local copy plus a delete of the
old path.

**Proof of the optimization.** Because zero content bytes were transferred
for `payload-moved.bin`, yet the correct 100 KB materialized at the new
path on the server, the content can only have arrived via a **server-side
local copy** from the pre-existing `payload.bin`. The client's wire output
and the server's filesystem end-state together establish this by
necessity.

## Notes / gotchas

- **`diffa serve` stdout is block-buffered when redirected to a
  non-TTY** (e.g. a log file). The buffer is not flushed per request, and
  is lost entirely if the server is terminated by signal (`SIGINT`).
  Consequently, live server-side logs were **not** available during this
  test; server-side verification was done via filesystem state (SHA-256
  before/after each operation), which is stronger evidence than logs.
  A small upstream fix — `setvbuf` to line-buffering, or an explicit
  flush after each request line in `serve` — would make live monitoring
  reliable for future LAN tests.

## Summary

| # | Scenario | Content bytes on wire | Result |
|---|----------|-----------------------|--------|
| 1 | Pull into empty dir | 4 files, zlib compressed | ✅ |
| 2 | Incremental push (add + modify) | 2 files only | ✅ |
| 3 | Mirror-delete | 0 | ✅ |
| 4 | Rename → copy optimization | **0** (server-side local copy) | ✅ |

---

# Role-Flip Run — Mac mini serves, MacBook Pro drives

A second run with the **roles reversed**: the Mac mini is the server, the
MacBook Pro is the client. The point is to exercise the **client-side**
copy-optimization path (destination hash-index build + `COPY` emission) on
the *other* machine — the first run only proved it with the Mac mini as
client. Both machines are now proven as the client side.

Two fixes landed between the runs (see the network-sync history) and were
exercised live here:

- **`5354031`** — `diffa serve` now flushes stdout per log line, so the
  server-side log **streamed live** this run (the buffering gotcha noted
  above is resolved). Every step below was quoted from the live server log.
- **`4b252e6`** — path-validation fix. The Mac mini served from a
  **`/private/tmp`-form root**, so scenario 2's new-file push
  **revalidated the fix end-to-end over the LAN**: pre-fix, the new file
  would have been silently rejected.

## Environment

| Role | Machine | Address |
|------|---------|---------|
| Server | Mac mini 2024 | `192.168.2.109:8756` (served root in `/private/tmp`-form) |
| Client | MacBook Pro 16″ | `192.168.2.116` |

Both on `develop` @ `4b252e6`, debug builds. Server firewall disabled.

## Served reference (4 files)

| path | size | sha256 |
|------|------|--------|
| `notes.txt` | 63 B | `28dbbe42…fcd7c6` |
| `docs/guide.md` | 52 B | `0f8dc5cd…47f0e6` |
| `assets/payload.bin` | 99840 B | `a0badab2…83e04` |
| `media/photo.dat` | 20480 B | `d5d75946…0bf8de` |

`payload.bin` is a repeating pattern (highly compressible); `photo.dat` is
seeded-random (**incompressible** — exercises the no-compress wire path, a
variation from the first run).

## Scenarios (client = MacBook Pro)

### 1. Pull into an empty directory — PASS

All 4 files pulled; every SHA-256 matched the reference. Wire behavior:
`payload.bin` sent `99840 → 349 bytes` (compressed), `photo.dat` sent at
**full 20480 B** (no-compress path confirmed).

### 2. Incremental push (add + modify) — PASS ⭐ (revalidates `4b252e6`)

Client added `added-from-mac.txt` (30 B) and modified `notes.txt` (→ 90 B),
then pushed. 2 operations; 3 unchanged files skipped. Server log showed
**`Received file: added-from-mac.txt`** (not `Path rejected`) — the
new-file push to the `/private/tmp`-form root succeeded, confirming the
validation fix over the wire. End-state hashes verified on the server.

### 3. Mirror-delete — PASS

Client `rm media/photo.dat`, push → 1 remote-delete op, 0 content bytes.
Server pruned the file and the now-empty `media/` directory.

### 4. Rename → copy optimization (MacBook client-driven) — PASS ⭐

Client `mv assets/payload.bin assets/payload-moved.bin`, push:

```
Operations: 2
Copying (remote): assets/payload.bin → assets/payload-moved.bin
Deleting (remote): assets/payload.bin
```

**No `Uploading:` line** — zero content bytes on the wire for the 99840 B
file. The server log independently showed `Copied: … → …` with **no
`Received file:`** for the payload. End-state: `payload-moved.bin` @
`a0badab2…83e04`, `payload.bin` gone, other 3 files unchanged.

This is a stronger proof than the first run: with the flush fix in place,
**both ends** provide direct evidence — the client's zero-transfer output
*and* the server's live `Copied`/no-receive log — and the client-side
optimization logic ran on the MacBook this time.

## Summary

| # | Scenario | Content bytes on wire | Result |
|---|----------|-----------------------|--------|
| 1 | Pull into empty dir | 4 files (payload compressed, photo.dat full) | ✅ |
| 2 | Incremental push — new file on `/private` root | 2 files (revalidates `4b252e6`) | ✅ |
| 3 | Mirror-delete | 0 | ✅ |
| 4 | Rename → copy optimization (client-driven) | **0** (two-sided proof) | ✅ |

**Result:** network sync is symmetric — both machines verified as client
and as server, copy optimization proven client-driven from each — and the
flush (`5354031`) and path-validation (`4b252e6`) fixes held up under live
LAN fire.
