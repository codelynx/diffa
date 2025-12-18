# Cloud Sync Brainstorm

Exploring options for push/pull/sync over the internet, beyond local TCP.

## Current State

- TCP-based sync works on local network (NWListener/NWConnection)
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

## Next Steps

**Phase 1: Documentation (Now)** - For power users / CLI
- [ ] Write Tailscale setup guide for diffa
- [ ] Write ZeroTier setup guide for diffa
- [ ] Document SSH tunnel approach

**Phase 2: App Store App (Future)**
- [ ] Design WebSocket protocol (wrap TCP in WS)
- [ ] Build relay server (Node.js/Go/Swift)
- [ ] User account system (Sign in with Apple)
- [ ] Device pairing flow
- [ ] macOS/iOS GUI app
