# Cross-Platform Network Sync

> **Status:** Implemented.
> Network sync (`serve`, `push`, `pull`) now works on both macOS and Linux using POSIX sockets and system zlib. The original Apple-only `Network.framework` and `Compression.framework` dependencies have been replaced. This document describes the design decisions and implementation details.

## 1. Goal

Replace two Apple-only frameworks used in Diffa's network sync:

- **Network.framework** (`NWListener`, `NWConnection`) — TCP server and client
- **Compression.framework** (`compression_encode_buffer` / `compression_decode_buffer`) — zlib compression

Both will be replaced with cross-platform alternatives so that network sync compiles and runs on macOS and Linux from a single codebase.

## 2. Security Assumptions

The current sync protocol is **unauthenticated plaintext TCP**. There is no TLS, peer authentication, or authorization layer. This is unchanged by this plan — the transport is swapped, but the protocol remains the same.

Enabling `diffa serve` on Linux increases the likelihood of deployment on internet-facing hosts. Users should be aware of the following constraints:

- **Trusted networks only.** `diffa serve` should only be run on private/trusted networks or behind a VPN. It should not be exposed to the public internet.
- **No access control.** Any client that can reach the server port can push or pull the entire served directory.
- **No encryption.** File contents and metadata are transmitted in cleartext.

Adding TLS and authentication is out of scope for this plan but is recommended as follow-up work before any production deployment on shared infrastructure.

## 3. Technology Decisions

### 3.1 Networking: POSIX Sockets (recommended over SwiftNIO)

**Recommendation: POSIX sockets.**

Rationale:

- **Minimal dependency footprint.** Diffa currently has only two dependencies (`swift-argument-parser`, `swift-crypto`). Adding SwiftNIO would bring in a large transitive dependency tree (swift-nio, swift-nio-extras, swift-system, swift-atomics, swift-collections, etc.). POSIX sockets add zero dependencies.
- **Simple protocol.** The sync protocol is sequential and request-response: connect, exchange HELLO/OK, exchange metadata, transfer files one at a time, send DONE. There is no multiplexing, no pipelining, no concurrent streams. SwiftNIO's event-loop architecture is overkill.
- **Current code is already synchronous.** Both `SyncServer` and `SyncClient` use `DispatchSemaphore` to block and wait for results. The callback-based Network.framework API is forced into synchronous behavior. POSIX sockets are naturally synchronous, so the replacement code will actually be simpler.
- **The current buffered-read pattern maps directly to POSIX.** The `tryParseMessage` / `receiveMoreData` pattern (read bytes into a buffer, scan for header newline, check if enough payload bytes exist, read more if not) is the textbook POSIX socket read loop.
- **Available everywhere.** `import Glibc` on Linux, `import Darwin` on macOS. Both provide identical `socket()`, `bind()`, `listen()`, `accept()`, `connect()`, `send()`, `recv()`, `close()`.

### 3.2 Compression: System zlib via C shim module

**Recommendation: Call zlib directly through a system library target.**

Rationale:

- zlib is available on every Linux distribution and on macOS (as `/usr/lib/libz.dylib`).
- zlib is the most likely compatible replacement for Apple's `COMPRESSION_ZLIB`, but the exact wire format should be validated empirically before finalizing the migration (see Step 2).
- A `CZlib` system library target in Package.swift is the cleanest approach — it declares `pkgConfig: "zlib"` for Linux and links `-lz` on macOS.

## 4. Detailed Implementation Plan

### Step 1: Add CZlib System Library Target

**Files to create:**

- `Sources/CZlib/module.modulemap`
- `Sources/CZlib/shim.h`

**`Sources/CZlib/module.modulemap`** contents:
```
module CZlib [system] {
    header "shim.h"
    link "z"
    export *
}
```

**`Sources/CZlib/shim.h`** contents:
```c
#include <zlib.h>
```

**Changes to `Package.swift`:**

Add a system library target and wire it as a dependency of `Diffa`:

```swift
.systemLibrary(
    name: "CZlib",
    path: "Sources/CZlib",
    pkgConfig: "zlib",
    providers: [
        .apt(["zlib1g-dev"]),
        .brew(["zlib"])
    ]
),
```

Add `"CZlib"` to the Diffa target's dependencies.

### Step 2: Rewrite Compression.swift

**File:** `Sources/Diffa/EfficientSync/Network/Compression.swift`

Remove the `#if canImport(Compression)` guard entirely. The new implementation will:

1. `import CZlib` instead of `import Compression`
2. Replace `compression_encode_buffer(..., COMPRESSION_ZLIB)` with zlib's `deflateInit2` / `deflate` / `deflateEnd`
3. Replace `compression_decode_buffer(..., COMPRESSION_ZLIB)` with `inflateInit2` / `inflate` / `inflateEnd`

**Compression format note:** Apple's `COMPRESSION_ZLIB` is believed to use raw deflate (no zlib header, no gzip header). The equivalent in zlib would be `deflateInit2` with `windowBits = -15` (negative value = raw deflate). This assumption must be verified empirically with cross-implementation interoperability tests before the migration is complete. However, since this is a full replacement and we control both endpoints, backward compatibility with pre-change macOS builds is not required — both sides will upgrade together. If the raw deflate assumption proves wrong, the format can be adjusted before release without protocol impact.

Key mapping:
- `compression_encode_buffer` → `deflateInit2(strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY)` then `deflate(strm, Z_FINISH)` then `deflateEnd(strm)`
- `compression_decode_buffer` → `inflateInit2(strm, -15)` then `inflate(strm, Z_FINISH)` then `inflateEnd(strm)`

The public API surface of `SyncCompression` (`shouldCompress`, `compress`, `decompress`) and `FilePayload` remains identical. No callers need to change.

### Step 3: Rewrite SyncServer.swift with POSIX Sockets

**File:** `Sources/Diffa/EfficientSync/Network/SyncServer.swift`

Remove the `#if canImport(Network)` wrapper. Replace `NWListener` / `NWConnection` with POSIX sockets.

The new server will:

1. **Platform imports:** Use `#if canImport(Darwin) / import Darwin / #else / import Glibc / #endif` at the top. Define a small compatibility shim for `sa_len` (exists on macOS, not on Linux).
2. **`start()` method:** Create a socket with `socket(AF_INET, SOCK_STREAM, 0)`, set `SO_REUSEADDR`, `bind()` to the port, `listen()`, then loop on `accept()`.
3. **Connection handling:** Each accepted connection runs `handleConnection()` on a `DispatchQueue.global()` thread. The connection is a file descriptor (`Int32`). Read/write use `recv()` / `send()`.
4. **Buffered reading:** The existing `tryParseMessage(from: &buffer)` logic is reusable almost verbatim. Replace `connection.receive(minimumIncompleteLength:maximumLength:)` with `recv(fd, buffer, 65536, 0)`.
5. **`stop()` method:** See shutdown design below.
6. **`getLocalIPAddresses()`:** Already uses `getifaddrs` which is cross-platform, but uses `sa_len` which does not exist on Linux. On Linux, use `MemoryLayout<sockaddr_in>.size` instead. Also check for `"lo"` (Linux loopback name) in addition to `"lo0"` (macOS).

**Public API preserved exactly:**
- `SyncServer(path: URL, port: UInt16)`
- `server.start()` (blocking)
- `server.startAsync()` (non-blocking, for testing)
- `server.stop()`
- `server.onLog`

#### Shutdown design for `startAsync()` / `stop()`

The current Network.framework implementation supports non-blocking startup (for tests) via `NWListener` which runs on a dispatch queue and can be cancelled. With blocking POSIX sockets, `accept()` blocks the calling thread indefinitely. This requires an explicit unblocking strategy:

**Approach: self-pipe trick + `select()`/`poll()`**

1. At `startAsync()` time, create a pipe (`pipe(fds)`). Store the write end in an instance variable (`shutdownPipe`).
2. The accept loop uses `poll()` (or `select()`) to wait on both the listener socket and the read end of the shutdown pipe simultaneously.
3. When `stop()` is called, write a byte to `shutdownPipe`. This wakes `poll()`, the loop checks the `isRunning` flag, and exits cleanly.
4. For active client connections: track all accepted file descriptors in a synchronized set. When `stop()` is called, close each tracked fd. This causes any in-progress `recv()` or `send()` to return immediately with an error, and the handler exits. This avoids changing the timeout model during normal transfers — server-side handlers keep the same `SO_RCVTIMEO` as the client (e.g. 30 seconds), and shutdown is immediate rather than polling-based.
5. `stop()` writes to the shutdown pipe, closes all tracked client fds, closes the listener socket, then waits for active client handlers to finish (via a `DispatchGroup` or similar).

This preserves the current test pattern where `startAsync()` returns immediately and `stop()` in `tearDown()` is non-blocking and deterministic.

### Step 4: Rewrite SyncClient.swift with POSIX Sockets

**File:** `Sources/Diffa/EfficientSync/Network/SyncClient.swift`

Remove the `#if canImport(Network)` wrapper. Replace `NWConnection` with POSIX socket.

The new client will:

1. **`sync()` method:** Create a socket with `socket(AF_INET, SOCK_STREAM, 0)`, resolve host with `getaddrinfo()`, connect with timeout (see below).
2. **`sendMessageSync()`:** Replace `connection.send(content:completion:)` with `send(fd, data, length, flags)` in a loop (handle partial sends and `EINTR`). Use `MSG_NOSIGNAL` on Linux to avoid `SIGPIPE`; set `SO_NOSIGPIPE` on macOS.
3. **`receiveMessageSync()`:** Replace `connection.receive(minimumIncompleteLength:maximumLength:)` with `recv(fd, buffer, 65536, 0)`. The existing `tryParseMessageFromBuffer()` logic is reusable.
4. **Timeouts:** See timeout design below.

**Public API preserved exactly:**
- `SyncClient()`
- `client.push(localPath:to:port:)`
- `client.pull(localPath:from:port:)`
- `client.onLog`
- `client.onProgress`

#### Timeout design

The current implementation has an explicit 10-second connection timeout and 30-second receive timeout. A plain blocking `connect()` can stall for far longer (system default is often 75-120 seconds). The POSIX replacement must preserve these timeouts:

**Connection timeout (10 seconds):**
1. Set the socket to non-blocking mode (`fcntl(fd, F_SETFL, O_NONBLOCK)`).
2. Call `connect()` — it will return immediately with `EINPROGRESS`.
3. Use `poll(fd, POLLOUT, timeout_ms)` to wait for the connection to complete or timeout.
4. Check `SO_ERROR` via `getsockopt()` to confirm success.
5. Set the socket back to blocking mode.

**Receive timeout (30 seconds):**
- Use `setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, ...)`.

**Send timeout:**
- Use `setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, ...)` with a reasonable timeout (e.g. 30 seconds) to prevent indefinite blocking on large writes if the remote stops reading.

### Step 5: Update SyncProtocol.swift

**File:** `Sources/Diffa/EfficientSync/Network/SyncProtocol.swift`

- Remove the `#if canImport(Compression)` guard around `FilePayload`. It will work unconditionally once `SyncCompression` uses `CZlib`.
- Everything else in this file is already cross-platform. No changes needed.

### Step 6: Update CLI Commands

**Files:**
- `Sources/DiffaCLI/ServeCommand.swift`
- `Sources/DiffaCLI/PushCommand.swift`
- `Sources/DiffaCLI/PullCommand.swift`
- `Sources/DiffaCLI/DiffaTool.swift`

Changes:
- Remove `#if canImport(Network) ... #endif` wrappers entirely.
- Remove `@available(macOS 10.14, *)` / `@available(macOS 13.0, *)` annotations (POSIX sockets have no minimum OS version).
- Always register serve/push/pull subcommands in `DiffaTool.swift`.

### Step 7: Update Tests

**File:** `Tests/DiffaTests/NetworkSyncTests.swift`
- Remove `#if canImport(Network) ... #endif` wrapper.
- Remove `import Network` and `@available` annotations.
- Test logic remains unchanged since the public API is preserved.

**File:** `Tests/DiffaTests/CompressionTests.swift`
- Remove `#if canImport(Compression) ... #endif` wrapper.
- Test logic remains unchanged.

## 5. Platform Compatibility Shim

A small internal helper for POSIX socket differences between macOS and Linux:

```swift
#if canImport(Darwin)
import Darwin
private let systemClose = Darwin.close
private let systemSend = Darwin.send
private let systemRecv = Darwin.recv
#else
import Glibc
private let systemClose = Glibc.close
private let systemSend = Glibc.send
private let systemRecv = Glibc.recv
#endif
```

Key platform differences to handle:
- **`sa_len`:** Does not exist on Linux. Use `MemoryLayout<sockaddr_in>.size` directly.
- **`SO_NOSIGPIPE` / `MSG_NOSIGNAL`:** macOS uses the `SO_NOSIGPIPE` socket option; Linux uses the `MSG_NOSIGNAL` flag on each `send()` call. Must handle both or the process will crash on remote disconnect.
- **Loopback interface name:** `"lo0"` on macOS, `"lo"` on Linux.

## 6. Public API Changes

**None.** The public API is preserved exactly:

| Type | Public Members | Change |
|------|---------------|--------|
| `SyncServer` | `init(path:port:)`, `start()`, `startAsync()`, `stop()`, `onLog` | Remove `@available` annotation only |
| `SyncClient` | `init()`, `push(localPath:to:port:)`, `pull(localPath:from:port:)`, `onLog`, `onProgress` | Remove `@available` annotation only |
| `SyncCompression` | `shouldCompress(path:size:)`, `compress(_:)`, `decompress(_:originalSize:)` | No change |
| `FilePayload` | `init(...)`, `encode()`, `decode(_:)`, `create(path:data:)`, `decompressedData()` | No change |
| `SyncMessage` | All members | No change |
| `SyncProtocolError` | All cases | No change |

## 7. Testing Strategy

### 7.1 Existing Tests

Existing tests in `NetworkSyncTests.swift` and `CompressionTests.swift` use the same public API and test logic. Once the guards are removed, they should be validated on both macOS and Linux. Note that the project has known pre-existing Linux test issues in other areas (see `docs/` or commit history); if any network/compression tests fail on Linux, those failures should be investigated individually rather than assumed to pass.

### 7.2 Shutdown Tests

The `startAsync()` / `stop()` pattern used in test setUp/tearDown is a critical correctness requirement. The POSIX socket shutdown design (Section 4, Step 3) must be validated with the existing test suite — any intermittent hang in tearDown indicates a shutdown bug.

### 7.3 Cross-Platform LAN Tests (Verified)

**Mac ↔ Linux** tested over LAN (2026-04-10). Four scenarios verified:

1. **Linux pushes to Mac** — 4 files transferred correctly, binary hash matched
2. **Linux pulls from Mac** — 6 files downloaded including Mac-added files, hash matched
3. **Mirror push (Linux → Mac)** — Mac-only files deleted on remote, unchanged files not re-transferred
4. **Reverse push (Mac → Linux)** — Linux-originated files deleted, Mac file delivered correctly

**Mac ↔ Windows** tested over LAN (2026-04-10). Four scenarios verified:

1. **Windows pushes to Mac** — 4 files transferred, compression worked (100KB → 115 bytes), hash matched
2. **Windows pulls from Mac** — 6 files downloaded including Mac-added files, decompression verified, hash matched
3. **Mirror push (Windows → Mac)** — 2 Mac-only files deleted on remote, unchanged files not re-transferred
4. **Reverse push (Mac → Windows)** — File delivered to Windows server correctly

**Windows ↔ Linux** tested over LAN (2026-04-10). Four scenarios verified:

1. **Windows pushes to Linux** — 4 files transferred, compression worked (100KB → 115 bytes), hash matched
2. **Windows pulls from Linux** — 6 files downloaded including Linux-added files, decompression verified, hash matched
3. **Mirror push (Windows → Linux)** — 2 Linux-only files deleted on remote, unchanged files not re-transferred
4. **Reverse push (Linux → Windows)** — File delivered to Windows server correctly

All 12 cross-platform tests passed (4 per platform pair). File contents, SHA-256 hashes, nested directories, compression/decompression, and mirror delete behavior verified across all three platforms.

### 7.4 CI Strategy
- Run `swift test` on both macOS and Linux (e.g., Ubuntu 22.04 with Swift 5.9+).
- Ensure `zlib1g-dev` and `libsqlite3-dev` are installed on Linux CI runners (not needed if using bundled C sources).

## 8. Risk Assessment

### Low Risk
- **Compression replacement:** Both sides upgrade together, so wire compatibility with pre-change builds is not required. The format assumption (raw deflate with `windowBits = -15`) must be validated with round-trip and cross-implementation tests, but the blast radius is contained.
- **Protocol compatibility:** No wire protocol changes. The message format (`TYPE LENGTH\n<payload>`) and file payload format are pure byte sequences, independent of the transport layer.
- **No public API changes:** All callers (CLI commands, tests) use the same interface.
- **No new external dependencies:** CZlib is a system library (zlib). It is universally available.

### Medium Risk
- **Server shutdown.** The `startAsync()` / `stop()` contract requires that blocking `accept()` and `recv()` calls can be interrupted cleanly. The self-pipe + `poll()` approach is well-established but must be implemented carefully to avoid deadlocks or leaked file descriptors. This is the highest-risk part of the implementation.
- **POSIX socket edge cases:** Partial `send()` / `recv()` returns need careful loop handling. Network.framework abstracted this away. Must handle `EINTR` (interrupted system calls) and `EAGAIN`.
- **Connection timeout.** A plain blocking `connect()` does not support custom timeouts. The non-blocking connect + `poll()` pattern adds complexity but is necessary to preserve the current 10-second timeout behavior.
- **`SO_NOSIGPIPE` vs `MSG_NOSIGNAL`:** If the remote disconnects mid-transfer, writing to the socket sends `SIGPIPE`. macOS uses `SO_NOSIGPIPE` socket option; Linux uses `MSG_NOSIGNAL` flag on each `send()` call. Must handle both or the process will crash.
- **`getLocalIPAddresses()` on Linux:** The `sa_len` field does not exist on Linux `sockaddr`. Must use `MemoryLayout<sockaddr_in>.size` and check `sa_family` via different struct layout.

## 9. Implementation Order

The recommended order, where each step is independently testable:

1. **Step 1 + Step 2:** Add CZlib target and rewrite Compression.swift. Run `CompressionTests` to validate. Fully independent of networking changes.
2. **Step 3 + Step 4:** Rewrite SyncServer.swift and SyncClient.swift with POSIX sockets. These must be done together since server and client talk to each other.
3. **Step 5:** Remove `#if canImport(Compression)` from SyncProtocol.swift (trivial, depends on Step 2).
4. **Step 6:** Remove `#if canImport(Network)` from CLI commands and DiffaTool.swift.
5. **Step 7:** Remove guards from test files. Run full test suite on macOS and Linux.

Note: Steps 5-7 are mostly guard-removal and integration work. The real implementation effort is in Steps 1-4, especially Steps 3 and 4.

## 10. Files Changed Summary

| File | Nature of Change |
|------|-----------------|
| `Package.swift` | Add CZlib system library target and dependency |
| `Sources/CZlib/module.modulemap` | **New file** — system module for zlib |
| `Sources/CZlib/shim.h` | **New file** — includes `<zlib.h>` |
| `Sources/Diffa/EfficientSync/Network/Compression.swift` | Full rewrite: Apple Compression → CZlib |
| `Sources/Diffa/EfficientSync/Network/SyncServer.swift` | Full rewrite: Network.framework → POSIX sockets |
| `Sources/Diffa/EfficientSync/Network/SyncClient.swift` | Full rewrite: Network.framework → POSIX sockets |
| `Sources/Diffa/EfficientSync/Network/SyncProtocol.swift` | Remove `#if canImport(Compression)` around FilePayload |
| `Sources/DiffaCLI/ServeCommand.swift` | Remove `#if canImport(Network)` and `@available` |
| `Sources/DiffaCLI/PushCommand.swift` | Remove `#if canImport(Network)` and `@available` |
| `Sources/DiffaCLI/PullCommand.swift` | Remove `#if canImport(Network)` and `@available` |
| `Sources/DiffaCLI/DiffaTool.swift` | Remove `#if canImport(Network)` conditional |
| `Tests/DiffaTests/NetworkSyncTests.swift` | Remove `#if canImport(Network)` and `@available` |
| `Tests/DiffaTests/CompressionTests.swift` | Remove `#if canImport(Compression)` |

## 11. Windows Support (Implemented)

Windows support has been implemented. Key decisions and details:

- **Networking:** A platform abstraction layer (`PlatformSocket.swift`) wraps Winsock2 vs POSIX differences. Uses `WSAPoll()` instead of `poll()`, `closesocket()` instead of `close()`, `ioctlsocket()` instead of `fcntl()`, and `GetAdaptersAddresses()` instead of `getifaddrs()`. Shutdown signaling uses a loopback socket pair instead of a pipe (Windows `_pipe()` fds don't work with `WSAPoll`). `SO_EXCLUSIVEADDRUSE` is used instead of `SO_REUSEADDR` to prevent port hijacking.
- **System libraries:** `CSQLite` and `CZlib` were converted from `.systemLibrary` targets to regular `.target` with bundled source (SQLite3 amalgamation, zlib 1.3.1). This eliminates external dependencies on all platforms — `swift build` works out of the box.
- **Compression:** zlib produces identical wire format on all platforms. No compatibility concerns.
- **Path handling:** `FileSystemItem` uses case-insensitive path comparison on Windows and recognizes drive roots (e.g. `C:/`) alongside Unix `/`.
- **POSIX permissions:** Not available on Windows; defaults to 0o644.
- **Symlinks:** Require admin privileges on Windows; symlink-dependent tests are skipped.
- **WSAStartup:** Called once per process via lazy initialization; aborts on failure.

## 12. Follow-Up Work (Out of Scope)

These are not addressed by this plan but should be considered for future work:

- **TLS support:** Add optional TLS encryption for network sync to protect data in transit.
- **Authentication:** Add a shared-secret or token-based authentication mechanism so that only authorized clients can connect.
- **Access control:** Restrict which directories can be served and which operations (push/pull) are allowed per client.
- **Bidirectional network sync:** The local sync layer already supports bidirectional sync with conflict resolution (`SyncMode`, `ConflictResolver`), but this is not yet exposed over the network transport. Currently only unidirectional mirror modes (push/pull) are available over the network.
- **Windows CLI integration tests:** The CLI test harness looks for `diffa` without `.exe` extension. Needs a platform-aware path lookup.
