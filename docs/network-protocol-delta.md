# Diffa Network Protocol Delta — Phase 1 (LAN read-only diff)

**Status:** design, reviewed, no code yet. Two external reviews folded
in (both grounded in the source). This is the implementation contract
for the phase-1 protocol change; Synca's
[`network-sync-design.md`](../../Synca/docs/network-sync-design.md) §5 is
the app-level plan this refines.

**Scope:** add a **read-only network `diff`** over the LAN, gated by a
sound **auth handshake**, on a **trustworthy wire framing**. No file
writes (that's phase 2), no internet tier (overlay/Tailscale, phase 4),
no filename-compatibility layer (phase 3).

---

## 1. Verified starting point (do not re-derive)

Confirmed in `Sources/Diffa/EfficientSync/Network/SyncProtocol.swift`:

- **Message envelope is already length-prefixed:** `<TYPE> <LENGTH>\n` +
  body (`:16-17,:55`). Framing v2 is about the *inner record encoding*,
  not the envelope.
- **Inner metadata is CSV** — `path,size,hash,mtime\n` header + rows,
  comma-delimited, escaping `,`→`\,` and `\n`→`\n` (`:131-141`). Three
  real defects:
  - `decodeCSV` does `String(data:encoding:.utf8)` on the **whole
    payload** (`:146`) → one invalid byte anywhere returns `[]`, i.e.
    the remote side reads as *entirely empty*.
  - it `split(separator: ",")` **then** unescapes (`:153,:157`), so an
    escaped comma still splits — the path truncates and the row is
    dropped.
  - payload read is a single `stream.read` with an `== length` guard
    (`:86-92`) → throws `incompletePayload` on any short read, which
    large listings hit on real sockets.
- **`NetworkFileItem = (path: String, size: Int64, hash: String,
  mtime: Int64)`**; `snapshot.allFiles()` is **files-only**
  (`SyncServer.swift:266`). Hash is SHA-256 (`FileHasher`); the snapshot
  `sha256` column is **nullable**.
- **Modes today:** `push`, `pull`. No `diff`, no auth, no encryption.

Why the naive "network diff = build an in-memory `Snapshot` and call
`Difference.compare`" **does not work:** `ComparisonEngine`
`ATTACH DATABASE '<destination.databaseURL.path>'` (`ComparisonEngine.swift:20,47`)
needs an **on-disk** SQLite file, and its modified-query compares
`is_folder, permissions, owner, group_name, modification_date, sha256` —
fields the network record lacks. Fabricating them flags every file
modified and drops every directory. Hence the dedicated comparator (§4).

---

## 2. Accepted threat model (phase 1, read-only)

Explicit and documented, per both reviews:

- **Transport crypto is out of scope** (settled: overlay VPN owns the
  internet tier). On plain LAN, **metadata crosses in plaintext** — full
  path listings, sizes, hashes are readable by any passive listener, and
  an **active on-path attacker can tamper with post-auth messages**.
- The auth handshake provides **replay-resistant connection admission
  and mutual peer proof — not** message integrity or confidentiality.
- Acceptable **only** if "trusted LAN" explicitly means no malicious or
  compromised on-path participant, and path/size/hash/mtime are treated
  as non-sensitive.
- **Phase 2 (writes) will force revisiting** — tampered metadata driving
  an *execute* is far worse than a wrong diff. The handshake is therefore
  shaped so a channel-crypto layer (Noise or TLS-PSK, riding the same
  pinned secret) can slot in behind it **without another wire break**.

---

## 3. Wire framing v2

A typed, bounded, versioned record format replacing the inner CSV.

- **Version gate first.** A fixed **magic value + protocol-major
  version** precedes mode/auth on the wire. Server rejects unknown
  versions with `ERROR incompatible protocol version` **before parsing
  anything else** (and before the auth challenge, so a mismatched peer
  gets a clean error, not an auth failure). This is version *detection*,
  a hard v1↔v2 break — **not** negotiation. Magic bytes also shed random
  port-scan traffic.
- **Records are length-prefixed, typed, counted.** Fixed-width `u32`
  (network byte order) length per field; a record **count** up front so
  truncation is detectable; each path carried as **counted opaque
  components** (not a delimiter-joined byte path).
- **Hard resource limits on the pre-auth parser** (it faces
  unauthenticated input for the framing-first commit window): max
  frame size, max listing size, max record count, max path length,
  read timeout; reject declared lengths over the cap **without
  allocating** (no 4 GB buffer from a hostile header); reject malformed
  or trailing data. Fuzz the decoder.
- **Path validation even read-only:** reject empty, `.`, `..`,
  NUL-containing, and absolute paths.
- Carry **raw hash bytes**, not hex (halves the field).
- **Record shape is frozen here** (see interlock, §6): reserve
  `is_folder` and `permissions` fields in the v2 encoding **now** —
  producers/consumers keep current semantics and the comparator ignores
  them in phase 1, but the fields exist so phase 2 doesn't break the wire
  a second time. Path is a length-prefixed **byte** field for
  future-proofing; phase-1 producers/consumers keep `String` semantics
  (the `String` lossiness is end-to-end via the schema's `path TEXT`, so
  wire-only raw bytes buy nothing yet).

---

## 4. Network-diff comparator (dedicated, not the SQL engine)

A pure function over two `path → (size, hash)` maps — files-only,
**content semantics only** (hash primary, size as a cheap pre-check).
No SQLite, no temp file, no `ComparisonEngine`.

- **Deliberately coarser than a local diff, and that is correct for
  phase 1:** permissions, ownership, timestamps, and empty directories
  are *not* compared. They only matter on execute (phase 2). mtime
  especially must **not** be compared — cross-machine mtimes legitimately
  differ (clock skew, non-preserving copies, FAT/exFAT 2-second
  granularity), so an mtime clause would manufacture false "modified".
- **The coarseness is surfaced in the diff *output*, not just docs:** the
  result carries a machine-readable note — *"compared by content
  (size + hash); permissions, timestamps, and empty directories not
  compared"* — so a user reading "no differences" knows exactly what that
  claim covers.
- Trivially unit-testable as a pure map→map function; no lifecycle.
- Phase 2 extends the record (the reserved fields) and can add a
  richer comparator then — the door stays open without a wire break.

---

## 5. Auth handshake

Challenge-response, **mutual**, before any metadata.

- **Pairing bootstraps a high-entropy secret — the short code is never
  the secret.** A short numeric code sniffed once would be offline-
  brute-forceable from a single captured `(nonce, response)`. Use a
  **PAKE (SPAKE2-style)** so the short displayed code authenticates a
  one-time exchange that yields a pinned **≥128-bit** per-peer secret;
  all future connects HMAC with that secret. The short-code UX survives;
  the derivation chain must not be "short code → long-term key."
- **Mutual:** the server proves itself too — otherwise the client hands
  its full listing to an unverified peer.
- Server-side: **constant-time** comparison, failed-attempt **tarpit**,
  nonce per connection (replay resistance).
- **Pinned peer identity** needs a concrete model: a symmetric secret
  identifies a *pair*, not a device/role — record that as the phase-1
  identity semantics.

---

## 6. Build order (three Diffa commits) + the interlock

1. **Framing v2** — magic/version gate, typed bounded records, parser
   limits, partial-read loop fix, decoder fuzz. Lands first as the
   foundation.
2. **Auth** — PAKE pairing + mutual challenge-response gate.
3. **`diff` mode** — new `NetworkSyncMode`: metadata exchange then close;
   the §4 comparator runs client-side.

**Interlock (hard):** the **final record shape must be decided before
commit 1** — including the reserved `is_folder`/`permissions` fields and
the byte-vs-String path decision — or the wire breaks twice in three
commits. **Do not ship the network feature** (even framing alone) until
auth and the §2 threat-model decision are complete; framing-first is fine
as an internal commit, but shipping it standalone leaves unauthenticated
metadata exchange intact with a new parser attack surface.

---

## 7. Acceptance criteria

- Filename with comma / tab / newline / invalid-UTF-8 byte survives the
  round trip (framing v2) — no dropped or truncated rows, no empty-remote
  false read.
- Oversized/short/malformed frames are rejected without over-allocation
  or crash (fuzzed).
- Version mismatch → clean `ERROR incompatible protocol version`, both
  directions.
- Auth: wrong/absent proof rejected before metadata; replayed proof
  rejected (nonce); server proves itself; brute force is rate-limited.
- `diff` output equals a content-level (size+hash) truth set on a fixture
  pair, and carries the coarseness note.

---

## 8. References

- Synca app-level plan: `../../Synca/docs/network-sync-design.md`
- Current code: `Sources/Diffa/EfficientSync/Network/{SyncProtocol,
  SyncServer,SyncClient}.swift`, `Sources/Diffa/Comparison/
  ComparisonEngine.swift`, `Sources/Diffa/Snapshots/SnapshotSchema.swift`
- Internet tier (later): `docs/cloud-sync-brainstorm.md`
- Two design reviews (2026-07): pairing-entropy and diff-adapter blocks,
  framing/versioning/sequencing amendments — folded into §2–§6.
