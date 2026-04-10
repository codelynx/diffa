# Cloud Sync Brainstorm

Exploring options for push/pull/sync over the internet, beyond local TCP.

## Current State (Updated 2026-04-10)

- TCP-based sync works on LAN across macOS, Linux, and Windows (verified 12/12 cross-platform tests)
- Uses cross-platform sockets (POSIX on macOS/Linux, Winsock2 on Windows) via `PlatformSocket.swift`
- Requires direct connection (server IP + port)
- Blocked by NAT/firewalls for internet use
- Protocol is raw TCP, not HTTP

## Problem to Solve

Enable sync between machines that:
1. Are behind NAT/firewalls
2. Don't have static IPs
3. Are on different networks (home ↔ office, laptop ↔ cloud)

## Core Truth

If both machines are behind NAT/firewalls, "P2P with no third party" is NOT reliably achievable.

**You must either:**
- (a) Use a rendezvous/relay component
- (b) Make both ends connect outward to something (VPN, relay)

## Constraints

- **No S3/cloud storage** - want end-to-end or relay communication only
- **Current protocol is raw TCP** - many tunnels (Cloudflare, ngrok) only forward HTTP/HTTPS
- Must work through firewalls (outbound 443 ideal)
- Prefer solutions that don't require data to pass through third-party servers

---

## ~~Option 1: Cloud Storage Backend (S3, GCS, Azure Blob)~~ ❌ EXCLUDED

**Reason:** Not suitable for this project. We want end-to-end or relay communication, not store-and-forward via cloud storage.

---

## Option 2: Mesh VPN (Tailscale / ZeroTier) ⭐ RECOMMENDED

**How it works:**
- Both machines join same mesh network
- Get assigned stable IPs (e.g., 100.x.x.x for Tailscale)
- Direct P2P when possible, relay through DERP/ZeroTier servers when needed
- Our existing TCP protocol works unchanged

**Pros:**
- **Works immediately** with current diffa implementation
- Direct P2P connection when possible (low latency)
- Encrypted end-to-end (WireGuard for Tailscale)
- Works through NAT/firewalls (UDP hole punching)
- Free tiers available (Tailscale: 100 devices, ZeroTier: 25 nodes)
- Cross-platform (macOS, Linux, Windows, iOS, Android)
- No code changes required

**Cons:**
- Requires Tailscale/ZeroTier account and client installed
- Both machines must be online simultaneously
- Adds dependency on third-party service (for coordination only)
- Minor initial setup per machine

**Implementation complexity:** None (just documentation)

```bash
# Setup (one-time per machine)
brew install tailscale
tailscale up

# On server machine (Tailscale IP: 100.64.0.1)
diffa serve --path /data --port 8080

# On client machine (any Tailscale network member)
diffa push /local 100.64.0.1:8080
diffa pull /local 100.64.0.1:8080
```

**Why this is recommended:**
- Zero code changes needed
- True P2P when NAT traversal succeeds
- Fallback relay only for coordination (not data)
- Battle-tested infrastructure (Tailscale uses DERP, ZeroTier uses their roots)

---

## Option 3: Relay Server (WebSocket/HTTP)

**How it works:**
- Both clients connect to relay server
- Server forwards data between clients
- Can use existing cloud (Heroku, Railway, Fly.io)

**Pros:**
- Works through firewalls
- Real-time sync possible
- Control over data path
- Can self-host

**Cons:**
- Need to run/pay for relay server
- Single point of failure
- Bandwidth costs
- Added latency

**Implementation complexity:** Medium-High

```
diffa serve --relay wss://relay.example.com
diffa push /local --via wss://relay.example.com/room-id
```

---

## Option 4: WebRTC (P2P with STUN/TURN)

**How it works:**
- Use STUN to discover public IP
- Attempt direct P2P connection
- Fall back to TURN relay if needed
- Requires complete protocol rewrite (DataChannels API)

**Pros:**
- Direct connection when possible (fast)
- Works through most NATs
- Encrypted by default
- No data on third-party (P2P mode)

**Cons:**
- **Very complex** NAT traversal implementation
- Needs STUN/TURN servers (or use Google's public STUN)
- Not 100% reliable connectivity (some symmetric NATs fail)
- **Limited/no native Swift libraries** (would need C++ WebRTC or WebView hack)
- Requires complete rewrite of network layer
- Signaling server still needed for connection setup

**Implementation complexity:** Very High (weeks of work)

**Reality check:** WebRTC is designed for browsers and real-time media. Using it for file sync is possible but brings enormous complexity for marginal benefit over Mesh VPN solutions.

---

## Option 5: SSH Tunnel (Traditional)

**How it works:**
- Use SSH to tunnel TCP connection
- Connect to remote server via SSH
- Run diffa serve on remote

**Pros:**
- Already works! (just needs SSH)
- Secure, proven
- No code changes needed
- Works with existing infrastructure

**Cons:**
- Requires SSH access to remote
- Not user-friendly setup
- Manual tunnel management

**Implementation complexity:** None (already possible)

```bash
# On local machine
ssh -L 8080:localhost:8080 user@remote.server "diffa serve --path /data --port 8080"
# Then
diffa push /local localhost:8080
```

---

## Option 6: Cloudflare Tunnel (Zero Trust)

**How it works:**
Cloudflare Tunnel is "web-first". For raw TCP, there are two paths:

### 6a: Raw TCP with cloudflared on BOTH ends (works, but requires client tool)
- Server runs `cloudflared` to expose TCP port
- Client ALSO runs `cloudflared` to create local TCP port that forwards through Cloudflare
- Diffa speaks raw TCP to `localhost:<port>` on client side

**Pros:**
- Free tier available
- Works through any firewall
- No code changes to diffa

**Cons:**
- Requires `cloudflared` installed on BOTH server AND client
- More complex setup than Mesh VPN
- Data passes through Cloudflare

### 6b: Raw TCP with NO client helper (public TCP proxy)
- This is NOT the free/simple Tunnel path
- Typically falls into paid Cloudflare products (Spectrum, etc.)
- Cost: $$ to $$$ depending on bandwidth

**Implementation complexity:**
- 6a: Low (just docs + client tool requirement)
- 6b: N/A (paid product, not DIY)

```bash
# Option 6a: Raw TCP with cloudflared on both ends
# On server
cloudflared tunnel --url tcp://localhost:8080

# On client (must also install cloudflared)
cloudflared access tcp --hostname mytunnel.example.com --url localhost:9090
# Then diffa connects to localhost:9090
diffa push /local localhost:9090
```

**Bottom line:** If requiring `cloudflared` on both ends is acceptable, this works. But at that point, Tailscale/ZeroTier offers better UX with less complexity.

---

## Option 7: IPFS / Content-Addressable Network

**How it works:**
- Files stored by content hash
- Distributed across network
- Pull by hash, not location

**Pros:**
- Decentralized
- Content-addressable (dedup built-in)
- Resilient
- Aligns with Diffa's hash-based design

**Cons:**
- Complex setup
- Slow for private data
- Not designed for mutable data
- Overkill for simple sync

**Implementation complexity:** High

---

## Comparison Matrix

| Option | Firewall | Setup | Cost | Latency | Privacy | Code Changes | Works Now |
|--------|----------|-------|------|---------|---------|--------------|-----------|
| ~~S3/Cloud Storage~~ | ❌ EXCLUDED | - | - | - | - | - | - |
| **Mesh VPN** ⭐ | ✅ | Low | Free | Low | ✅ | None | ✅ Yes |
| Relay Server (WSS) | ✅ | High | $$ | Medium | ⚠️ | High | ❌ |
| WebRTC | ✅ | Very High | $ | Low | ✅ | Very High | ❌ |
| SSH Tunnel | ⚠️ | Medium | Free | Low | ✅ | None | ✅ Yes |
| Cloudflare (6a)* | ✅ | Medium | Free | Low | ⚠️ | None | ✅ Yes |
| Cloudflare (6b)** | ✅ | Low | $$$ | Low | ⚠️ | None | N/A |
| IPFS | ✅ | High | Free | High | ⚠️ | Very High | ❌ |

*6a: Requires `cloudflared` on both server AND client
**6b: Paid Cloudflare product (Spectrum) for public TCP proxy

---

## Recommendation

**Immediate (no code changes):**
1. **Mesh VPN (Tailscale/ZeroTier)** ⭐ - Works today, best UX, just add documentation
2. **SSH Tunnel** - Already works, document the setup
3. **Cloudflare (6a)** - Works if users accept `cloudflared` on both ends

**If we build something (future):**
1. **WebSocket relay server** - If we need browser-compatible protocol
2. Avoid WebRTC - complexity not worth it for file sync use case

---

## Key Decision Questions

Before choosing a path, answer these:

1. **Are you okay requiring users to install something (Tailscale or cloudflared) on both ends?**
   - Yes → Mesh VPN or Cloudflare (6a)
   - No → Need paid solutions or build a relay

2. **Does the remote endpoint need to be reachable by "anyone with host:port", or only by paired devices/users?**
   - Paired devices only → Mesh VPN (private network)
   - Public access → SSH with public IP, or paid Cloudflare Spectrum

---

## Questions to Consider

1. **Who is the target user?**
   - Developer syncing code? → Mesh VPN, SSH
   - Team sharing files? → Mesh VPN (easy to share network)
   - Power user? → SSH tunnel

2. **Data sensitivity?**
   - Sensitive → Mesh VPN (E2E encrypted), SSH
   - Less sensitive → WSS Relay (if built)

3. **Real-time needed?**
   - Yes → Mesh VPN, Relay
   - No → Mesh VPN is still simplest

4. **Budget?**
   - Free → Tailscale (100 devices), ZeroTier (25 nodes), SSH
   - Paid → Self-hosted relay server

---

## NAT Traversal: How P2P Works Through Routers

### The Problem

Both users are behind NAT (home routers with private IPs):

```
Dad's house                          Mom's house
┌─────────────────┐                  ┌─────────────────┐
│ Dad: 192.168.1.5│                  │ Mom: 192.168.1.8│
│      (private)  │                  │      (private)  │
└────────┬────────┘                  └────────┬────────┘
         │                                    │
    ┌────▼────┐                          ┌────▼────┐
    │ Router  │                          │ Router  │
    │ NAT     │                          │ NAT     │
    │73.45.1.1│                          │98.22.3.4│
    └────┬────┘                          └────┬────┘
         │                                    │
         └──────────── Internet ──────────────┘

Problem: Routers block incoming connections by default
```

### Solution: UDP Hole Punching

**Step 1:** Both tell relay their public IP:port
```
Dad ──► Relay: "I'm 73.45.1.1:54321"
Mom ──► Relay: "I'm 98.22.3.4:12345"
```

**Step 2:** Relay shares addresses (this is "signaling")
```
Relay ──► Dad: "Mom is at 98.22.3.4:12345"
Relay ──► Mom: "Dad is at 73.45.1.1:54321"
```

**Step 3:** Both send UDP packet simultaneously
```
Dad ──UDP──► 98.22.3.4:12345   (Dad's router creates outbound mapping)
Mom ──UDP──► 73.45.1.1:54321   (Mom's router creates outbound mapping)
```

**Step 4:** NAT "hole" is punched
```
Dad's router: "I sent to 98.22.3.4, incoming from same IP = reply, allow!"
Mom's router: "I sent to 73.45.1.1, incoming from same IP = reply, allow!"

Direct connection established:
Dad ◄────────── 500MB photo ──────────► Mom  (no relay needed!)
```

### Success Rate by NAT Type

| NAT Type | Hole Punch Works? | Common Where |
|----------|-------------------|--------------|
| Full Cone | ✅ Yes | Home routers |
| Restricted Cone | ✅ Yes | Home routers |
| Port Restricted | ✅ Usually | Some routers |
| Symmetric | ❌ No | Corporate, mobile |

**Overall success rate:** ~80-85% of connections go direct

### When Hole Punch Fails → Relay Fallback

```
if hole_punch_timeout(5 seconds):
    use_relay()  # Works 100%, but costs bandwidth
```

This is exactly how Tailscale (DERP), WebRTC (TURN), and ZeroTier work.

---

## Cost Analysis: 10,000 Users

### Assumptions
- 10,000 users ("dad and mom" profile)
- Sync 2x/month each
- 500MB average file size
- Pure relay = data through server twice (upload + download)

### Pure Relay (Naive Approach)

```
10,000 users × 2 syncs × 500MB = 10 TB/month
Relay doubles it: 20 TB/month through server
```

| Provider | Bandwidth Cost | Total/Month |
|----------|---------------|-------------|
| AWS | $0.09/GB × 20TB | **~$1,850** 😱 |
| Fly.io | $0.02/GB × 20TB | **~$420** |
| Hetzner | ~20TB included | **~$50-100** |

### Hybrid P2P + Relay (Smart Approach)

```
85% direct (hole punch works): 0 bandwidth cost
15% relay fallback: 3 TB/month
Signaling for all: ~10 GB/month (negligible)
```

| Provider | Bandwidth Cost | Total/Month |
|----------|---------------|-------------|
| Any provider | 3TB × $0.02-0.09 | **~$60-270** |
| With Hetzner | Included | **~$30-50** |

### Bottom Line

| Approach | 10K Users/Month |
|----------|-----------------|
| Pure relay | $400-2,000 |
| **Hybrid P2P + relay** | **$30-100** |

Hybrid saves 80-95% on bandwidth costs.

---

## App Store App Architecture

For a consumer App Store app targeting non-technical users ("dad and mom"):

**User Profile:**
- Can download app, pick folder, click "Sync"
- Should NOT need to know: VPN, ports, IP addresses, tunnels
- Expect "it just works" like iCloud/Dropbox

**Required Architecture:**

```
┌─────────────────┐         ┌─────────────────┐
│   Dad's Mac     │         │   Mom's Mac     │
│   (Diffa App)   │         │   (Diffa App)   │
└────────┬────────┘         └────────┬────────┘
         │                           │
         │ WebSocket (443)           │ WebSocket (443)
         │                           │
         └───────────┬───────────────┘
                     │
              ┌──────▼──────┐
              │ Your Relay  │
              │   Server    │
              └─────────────┘
```

**App UX Flow:**
1. Sign in with Apple
2. "Create Family Group" or "Join with Code"
3. Pick folder → Click "Sync" → Done

**Components to Build:**
1. **User accounts** - Sign in with Apple/Google
2. **Device pairing** - Invite code or QR code
3. **WebSocket relay server** - Hosted service
4. **HTTP-based protocol** - Wrap current TCP protocol in WebSocket

**Cost Estimate:**
- Relay server: ~$5-20/month (Fly.io, Railway, etc.)
- Scales with active connections, not storage
- Bandwidth is the main variable cost

**Why Relay is the Only Option for App Store:**

| Option | Dad/Mom Friendly? | Reason |
|--------|-------------------|--------|
| Mesh VPN | ❌ No | "Install Tailscale" = lost them |
| SSH | ❌ No | Way too technical |
| Cloudflare | ❌ No | Requires separate tool install |
| **Relay Server** | ✅ Yes | Invisible, handled entirely by app |

---

## Library Hook Design (Credentials Never Exposed)

The library handles sync mechanics, but the App handles authentication. Library never sees user credentials.

### Architecture Layers

```
┌─────────────────────────────────────────────────────────┐
│  App Layer (GUI)                                        │
│  - Sign in with Apple                                   │
│  - User identity, device pairing                        │
│  - Knows credentials                                    │
└────────────────────┬────────────────────────────────────┘
                     │ Hooks (protocols)
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Library Layer (Diffa)                                  │
│  - Sync logic, file transfer                            │
│  - NAT traversal, relay connection                      │
│  - NO credentials, just opaque tokens                   │
└────────────────────┬────────────────────────────────────┘
                     │ Opaque token
                     ▼
┌─────────────────────────────────────────────────────────┐
│  Relay Server                                           │
│  - Validates tokens                                     │
│  - Routes connections                                   │
│  - Never sees file contents (E2E encrypted)             │
└─────────────────────────────────────────────────────────┘
```

### Hook Protocols (Swift)

```swift
/// App implements this - Library calls it for auth
public protocol SyncAuthProvider {
    /// Get auth token for relay connection
    /// App handles login, returns opaque token
    func getAuthToken() async throws -> String

    /// Get room/session ID to connect to peer
    func getRoomID() async throws -> String

    /// Verify peer identity (optional, for E2E)
    func verifyPeer(publicKey: Data) async -> Bool
}

/// App implements this - Library calls for network events
public protocol SyncNetworkDelegate {
    /// Called when NAT type detected
    func didDetectNATType(_ type: NATType)

    /// Called to decide: P2P or relay?
    func shouldUseRelay() -> Bool

    /// Called when connection established
    func didConnect(mode: ConnectionMode)  // .direct or .relay

    /// Called on connection failure
    func didFailToConnect(error: Error)
}

/// Optional: E2E encryption (relay can't read contents)
public protocol SyncEncryptionProvider {
    /// Get this device's public key
    func getPublicKey() -> Data

    /// Encrypt data for peer
    func encrypt(_ data: Data, forPeer peerPublicKey: Data) throws -> Data

    /// Decrypt data from peer
    func decrypt(_ data: Data, fromPeer peerPublicKey: Data) throws -> Data
}
```

### App Implementation Example

```swift
// App implements the auth provider
class MyAppAuthProvider: SyncAuthProvider {
    func getAuthToken() async throws -> String {
        // App calls YOUR backend with Apple Sign-In credential
        // Backend validates and returns a short-lived sync token
        // Library NEVER sees Apple credentials
        return await MyBackend.getSyncToken(user: currentUser)
    }

    func getRoomID() async throws -> String {
        // App creates/joins room via your backend
        return await MyBackend.createSyncRoom(user: currentUser)
    }

    func verifyPeer(publicKey: Data) async -> Bool {
        // Verify this is a known/trusted device
        return await MyBackend.isKnownDevice(publicKey: publicKey)
    }
}

// App uses library with hooks
let syncer = CloudSync(
    authProvider: MyAppAuthProvider(),
    networkDelegate: self,
    encryptionProvider: MyE2EProvider()  // optional
)
try await syncer.connect()
```

### Token Flow Diagram

```
┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐
│  App    │      │ Backend │      │ Library │      │  Relay  │
└────┬────┘      └────┬────┘      └────┬────┘      └────┬────┘
     │                │                │                │
     │ 1. Sign in with Apple           │                │
     ├───────────────►│                │                │
     │                │                │                │
     │ 2. Validate, create user        │                │
     │◄───────────────┤                │                │
     │                │                │                │
     │ 3. Request sync token           │                │
     ├───────────────►│                │                │
     │                │                │                │
     │ 4. Short-lived token (5 min)    │                │
     │◄───────────────┤                │                │
     │                │                │                │
     │ 5. Pass token to library (hook) │                │
     ├───────────────────────────────►│                │
     │                │                │                │
     │                │                │ 6. Connect with token
     │                │                ├───────────────►│
     │                │                │                │
     │                │                │ 7. Relay validates token
     │                │                │◄───────────────┤
     │                │                │                │
     │                │                │ 8. Connected!  │
     │◄────────────────────────────────┤◄───────────────┤
```

### What Each Layer Sees

| Data | App | Library | Relay |
|------|-----|---------|-------|
| Apple ID credentials | ✅ | ❌ | ❌ |
| User email | ✅ | ❌ | ❌ |
| Sync token (opaque) | ✅ | ✅ | ✅ (validates) |
| Room code | ✅ | ✅ | ✅ |
| File contents | ✅ | ✅ | ❌ (E2E encrypted) |
| Peer public keys | ✅ | ✅ | ❌ |

### Security Properties

1. **Library never sees credentials** - Only opaque tokens from App
2. **Tokens are short-lived** - 5 minute expiry, backend controls
3. **E2E encryption optional** - Relay can't read file contents
4. **Backend controls access** - Can revoke tokens, block devices
5. **Device pairing via App** - Library just connects, App decides who

---

## Network Test Tool

A diagnostic tool to test P2P connectivity before syncing.

### User Experience

```bash
diffa network-test

Testing network connectivity...

[1/4] Detecting NAT type.............. Restricted Cone ✅
[2/4] Finding public IP............... 73.45.123.88:54321 ✅
[3/4] Testing hole punch.............. Success ✅
[4/4] Testing relay fallback.......... Available ✅

Results:
┌─────────────────────────────────────────────────┐
│  P2P Direct:  ✅ Should work (85% of peers)     │
│  Relay:       ✅ Available as fallback          │
│  Expected:    Fast direct transfers             │
└─────────────────────────────────────────────────┘
```

When behind corporate firewall:

```bash
diffa network-test

Testing network connectivity...

[1/4] Detecting NAT type.............. Symmetric NAT ⚠️
[2/4] Finding public IP............... 98.22.3.4:??? (port changes)
[3/4] Testing hole punch.............. Failed ❌
[4/4] Testing relay fallback.......... Available ✅

Results:
┌─────────────────────────────────────────────────┐
│  P2P Direct:  ❌ Blocked (corporate firewall?)  │
│  Relay:       ✅ Will use relay automatically   │
│  Expected:    Slower, but works everywhere      │
└─────────────────────────────────────────────────┘

Tip: Ask IT to allow UDP port 41641 for faster sync
```

### How It Works

```
┌──────────────┐         ┌──────────────┐
│  Your Mac    │         │  Test Server │
│              │         │  (STUN-like) │
└──────┬───────┘         └──────┬───────┘
       │                        │
       │ 1. "What's my public IP?"
       ├───────────────────────►│
       │                        │
       │ 2. "You're 73.45.1.1:54321"
       │◄───────────────────────┤
       │                        │
       │ 3. Send UDP to test peer
       ├─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─►│
       │                        │
       │ 4. Did it arrive? Y/N  │
       │◄───────────────────────┤
```

### NAT Type Detection

```swift
enum NATType: String {
    case fullCone = "Full Cone"              // Best - any peer can connect
    case restrictedCone = "Restricted Cone"  // Good - hole punch works
    case portRestricted = "Port Restricted"  // OK - usually works
    case symmetric = "Symmetric"             // Bad - need relay
    case unknown = "Unknown"
}

func detectNATType() -> NATType {
    // 1. Query STUN server A from port X → get public IP:portA
    // 2. Query STUN server B from port X → get public IP:portB
    // 3. If portA == portB → Cone NAT (good)
    // 4. If portA != portB → Symmetric NAT (bad)
}
```

### Components Needed

| Component | Purpose | Build or Use Existing? |
|-----------|---------|------------------------|
| **STUN client** | Detect public IP & NAT type | Build (simple UDP) |
| **Test peer** | Verify hole punch works | Build echo server |
| **Relay check** | Confirm fallback works | Ping our relay |

### Free Public STUN Servers

```
stun.l.google.com:19302
stun.cloudflare.com:3478
stun.stunprotocol.org:3478
```

### Implementation Sketch

```swift
struct NetworkTestCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "network-test",
        abstract: "Test P2P connectivity and fallback options"
    )

    func run() throws {
        print("Testing network connectivity...\n")

        // 1. Detect NAT type using STUN
        let natType = try detectNATType()
        printStep(1, "Detecting NAT type", natType.rawValue, natType != .symmetric)

        // 2. Get public endpoint
        let endpoint = try discoverPublicEndpoint()
        printStep(2, "Finding public IP", endpoint, endpoint != nil)

        // 3. Test hole punch with our test server
        let holePunchWorks = try testHolePunch(endpoint)
        printStep(3, "Testing hole punch", holePunchWorks ? "Success" : "Failed", holePunchWorks)

        // 4. Test relay connectivity
        let relayWorks = try testRelayConnection()
        printStep(4, "Testing relay fallback", relayWorks ? "Available" : "Unavailable", relayWorks)

        // Summary
        printSummary(natType: natType, p2p: holePunchWorks, relay: relayWorks)
    }
}
```

### GUI Version (App Store)

For non-technical users, show simple status:

```
┌─────────────────────────────────────┐
│         Connection Status           │
│                                     │
│    🟢  Direct Connection Ready      │
│                                     │
│    Your transfers will be fast      │
│    and won't use our servers.       │
│                                     │
└─────────────────────────────────────┘
```

Or:

```
┌─────────────────────────────────────┐
│         Connection Status           │
│                                     │
│    🟡  Using Relay Server           │
│                                     │
│    Your network blocks direct       │
│    connections. Sync will work      │
│    but may be slower.               │
│                                     │
└─────────────────────────────────────┘
```

---

## Next Steps

**Phase 1: Documentation (Now)** - For power users / CLI
- [ ] Write Tailscale setup guide for diffa
- [ ] Write ZeroTier setup guide for diffa
- [ ] Document SSH tunnel approach

**Phase 2: Network Test Tool**
- [ ] Implement STUN client (UDP)
- [ ] NAT type detection
- [ ] `diffa network-test` CLI command
- [ ] Test server for hole punch verification

**Phase 3: App Store App (Future)**
- [ ] Design WebSocket protocol (wrap TCP in WS)
- [ ] Build relay server (Node.js/Go/Swift)
- [ ] User account system (Sign in with Apple)
- [ ] Device pairing flow
- [ ] macOS/iOS GUI app

---

## Research Conclusion (2026-04-10)

### Motivation

The driving use case: a non-technical person (e.g. a parent) wants to share a large number of photos or documents with family. Both sides are behind home NAT routers without public IPs. The question was whether Diffa could serve this use case and what infrastructure would be needed.

### The NAT Reality

When both peers are behind NAT, there is no way to establish a direct connection without help from a third party. This is a fundamental networking constraint, not a software limitation.

**What the third party does depends on whether UDP hole punching succeeds:**

| Hole punch result | Third party role | Data flow |
|-------------------|-----------------|-----------|
| Succeeds (~85-90%) | Coordination only — exchanges peer addresses | Direct peer-to-peer, relay sees nothing |
| Fails (symmetric NAT, corporate firewalls) | Full data relay — forwards every byte | All data flows through relay server |

You cannot know in advance which case applies for a given pair of users. The safe assumption for product design is: **the relay must be capable of handling full data transfer.**

### Infrastructure Options Evaluated

**Option A: VPN hub (WireGuard on VPS)**
- Rent a small VPS ($3-5/month on AWS Lightsail, Hetzner, Oracle free tier)
- Install WireGuard, configure as hub — both peers connect outbound
- Diffa works unmodified over the VPN tunnel
- Full control over infrastructure
- Requires manual setup on each peer machine

**Option B: Managed mesh VPN (Tailscale)**
- Sign up at tailscale.com, install client on each machine
- Zero server management — Tailscale handles coordination and relay
- Each machine gets a stable IP (100.x.y.z)
- Direct peer-to-peer when hole punching succeeds, relay through Tailscale's DERP servers when not
- Free for personal use (100 devices)
- Diffa works unmodified

**Both options require zero code changes to Diffa.** The VPN layer is transparent to the application — Diffa just connects to an IP and port as if on LAN.

### The Business Model Problem

If Diffa were to offer cloud sync as a paid service (App Store subscription covering backend costs), the economics are challenging:

**The unpredictable variables:**
- Transfer volume per user (1GB? 100GB? varies wildly with photos)
- Sync frequency (daily? monthly?)
- Hole punch success rate (determines whether relay carries data or just coordinates)
- AWS egress pricing ($0.09/GB after 100GB/month)

**Example at scale (10,000 users):**
- Pure relay: 20TB/month egress → $1,850/month on AWS
- Hybrid (85% P2P): 3TB/month egress → $60-270/month
- A $4.99/month subscription barely covers the hybrid case, and the pure relay case is unsustainable

**Comparison to established services:**
- Tailscale: free personal tier, charges enterprises (relay usage is low)
- Dropbox/iCloud: charge for storage tiers, not transfer (different model)
- Syncthing: fully P2P, no relay cost — but no business model

### Decision

**Ship Diffa as a tool, recommend Tailscale for internet sync, do not take on infrastructure cost.**

Rationale:
1. The networking layer already works across all three platforms
2. Tailscale solves NAT traversal with zero code changes and zero infrastructure
3. Running relay infrastructure introduces unpredictable costs that are hard to cover with subscriptions
4. The real gap for a "mom-friendly" product is UX (GUI app, device pairing, one-click sync) — not networking
5. If traction develops, the relay/subscription model can be revisited with real usage data

### What Diffa Code Does NOT Need

- NAT traversal implementation (VPN handles it)
- STUN/TURN client (VPN handles it)
- WebSocket protocol (TCP over VPN works)
- Relay server (Tailscale DERP or VPS WireGuard handles it)
- User accounts / authentication (out of scope for a CLI/library tool)

### What Could Be Added Later (If Needed)

| Feature | When | Why |
|---------|------|-----|
| mDNS/Bonjour discovery | If users want auto-discovery on Tailscale networks | Convenience — avoids remembering IPs |
| TLS on the wire | If Diffa needs to work without VPN | Currently plaintext TCP; VPN encrypts the tunnel |
| Shared-secret auth | If serving on a shared network | Prevents unauthorized access to `diffa serve` |
| GUI wrapper | If targeting non-technical users | Menu bar / system tray app with folder picker |
| Built-in relay mode | If Diffa must be fully self-contained | Significant effort; only justified if VPN approach is rejected |
