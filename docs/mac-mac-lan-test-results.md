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
