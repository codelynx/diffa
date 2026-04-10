import Foundation

#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#else
import Glibc
#endif

// MARK: - Socket Descriptor Type

#if os(Windows)
/// On Windows, SOCKET is UInt64 (UINT_PTR)
typealias SocketDescriptor = SOCKET
let invalidSocket: SocketDescriptor = INVALID_SOCKET
#else
/// On Unix, sockets are file descriptors (Int32)
typealias SocketDescriptor = Int32
let invalidSocket: SocketDescriptor = -1
#endif

// MARK: - Socket Stream Type

/// SOCK_STREAM value — on Darwin it's an enum requiring .rawValue, elsewhere it's a plain Int32
#if canImport(Darwin)
let platformStreamType = Int32(SOCK_STREAM.rawValue)
#else
let platformStreamType = Int32(SOCK_STREAM)
#endif

// MARK: - Initialization / Cleanup

#if os(Windows)
/// Tracks whether Winsock was initialized successfully.
/// Set exactly once by `platformSocketInit()`.
private var winsockInitialized = false
private var winsockInitOnce: Bool = {
    var wsaData = WSADATA()
    let result = WSAStartup(UInt16(0x0202), &wsaData)
    if result != 0 {
        fatalError("WSAStartup failed with error \(result). Winsock2 is required for networking.")
    }
    winsockInitialized = true
    return true
}()
#endif

/// Initialize the platform socket subsystem. Must be called before any socket operations.
/// On Windows, this calls WSAStartup exactly once and aborts on failure.
/// On Unix, this is always a no-op.
func platformSocketInit() {
    #if os(Windows)
    _ = winsockInitOnce
    #endif
}

// MARK: - Socket Operations

/// Close a socket descriptor
func platformClose(_ fd: SocketDescriptor) {
    #if os(Windows)
    closesocket(fd)
    #elseif canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

/// Send data on a socket, handling platform-specific SIGPIPE prevention
func platformSend(_ fd: SocketDescriptor, _ buffer: UnsafeRawPointer, _ length: Int) -> Int {
    #if os(Windows)
    return Int(WinSDK.send(fd, buffer.assumingMemoryBound(to: CChar.self), Int32(length), 0))
    #elseif canImport(Darwin)
    return Darwin.send(fd, buffer, length, 0)
    #else
    return Glibc.send(fd, buffer, length, Int32(MSG_NOSIGNAL))
    #endif
}

/// Receive data from a socket
func platformRecv(_ fd: SocketDescriptor, _ buffer: UnsafeMutableRawPointer, _ length: Int) -> Int {
    #if os(Windows)
    return Int(WinSDK.recv(fd, buffer.assumingMemoryBound(to: CChar.self), Int32(length), 0))
    #elseif canImport(Darwin)
    return Darwin.recv(fd, buffer, length, 0)
    #else
    return Glibc.recv(fd, buffer, length, 0)
    #endif
}

// MARK: - Socket Configuration

/// Set a socket to non-blocking or blocking mode
func platformSetNonBlocking(_ fd: SocketDescriptor, _ nonBlocking: Bool) {
    #if os(Windows)
    var mode: u_long = nonBlocking ? 1 : 0
    ioctlsocket(fd, FIONBIO, &mode)
    #elseif canImport(Darwin)
    var flags = fcntl(fd, F_GETFL, 0)
    if nonBlocking {
        flags |= O_NONBLOCK
    } else {
        flags &= ~O_NONBLOCK
    }
    _ = fcntl(fd, F_SETFL, flags)
    #else
    var flags = Glibc.fcntl(fd, F_GETFL, 0)
    if nonBlocking {
        flags |= O_NONBLOCK
    } else {
        flags &= ~O_NONBLOCK
    }
    _ = Glibc.fcntl(fd, F_SETFL, flags)
    #endif
}

/// Set socket receive and send timeouts
func platformSetSocketTimeouts(_ fd: SocketDescriptor, seconds: Int) {
    #if os(Windows)
    // Windows SO_RCVTIMEO/SO_SNDTIMEO takes DWORD milliseconds
    var timeout = DWORD(seconds * 1000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,
               &timeout, Int32(MemoryLayout<DWORD>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,
               &timeout, Int32(MemoryLayout<DWORD>.size))
    #else
    var timeout = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    #endif
}

/// Prevent SIGPIPE on the socket (macOS only; Linux uses MSG_NOSIGNAL per-send; Windows has no SIGPIPE)
func platformSetNoSigPipe(_ fd: SocketDescriptor) {
    #if canImport(Darwin)
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    #endif
    // Linux: handled via MSG_NOSIGNAL in platformSend
    // Windows: no SIGPIPE exists
}

/// Set socket address reuse option.
/// On Windows, uses SO_EXCLUSIVEADDRUSE to prevent port hijacking
/// (SO_REUSEADDR on Windows allows multiple listeners on the same port,
/// which is materially different from Unix semantics).
/// On Unix, uses SO_REUSEADDR to ease TIME_WAIT reuse.
func platformSetReuseAddr(_ fd: SocketDescriptor) {
    #if os(Windows)
    // SO_EXCLUSIVEADDRUSE = ~SO_REUSEADDR; prevents port hijacking on Windows.
    // Not imported by Swift's WinSDK overlay, so we define the value inline.
    let SO_EXCLUSIVEADDRUSE = Int32(bitPattern: UInt32(~UInt32(bitPattern: SO_REUSEADDR)))
    var exclusive: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
               &exclusive, Int32(MemoryLayout<Int32>.size))
    #else
    var reuseAddr: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
    #endif
}

/// Check SO_ERROR on a socket (for async connect completion)
func platformGetSocketError(_ fd: SocketDescriptor) -> Int32 {
    var connectError: Int32 = 0
    #if os(Windows)
    var errorLen = Int32(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectError, &errorLen)
    #else
    var errorLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectError, &errorLen)
    #endif
    return connectError
}

// MARK: - Poll

/// Platform-independent poll wrapper
func platformPoll(_ fds: inout [pollfd], _ nfds: Int, _ timeoutMs: Int32) -> Int32 {
    #if os(Windows)
    return WSAPoll(&fds, UInt32(nfds), timeoutMs)
    #else
    return poll(&fds, nfds_t(nfds), timeoutMs)
    #endif
}

/// Create a pollfd struct (needed because pollfd layout may differ)
func makePollfd(fd: SocketDescriptor, events: Int16) -> pollfd {
    #if os(Windows)
    return pollfd(fd: fd, events: Int16(events), revents: 0)
    #else
    return pollfd(fd: fd, events: events, revents: 0)
    #endif
}

// MARK: - Shutdown Pipe

/// A pair of connected descriptors for signaling shutdown.
/// On Unix, uses pipe(). On Windows, uses a loopback socket pair
/// (because CRT _pipe fds don't work with WSAPoll).
struct ShutdownPipe {
    var readEnd: SocketDescriptor
    var writeEnd: SocketDescriptor

    static func create() -> ShutdownPipe? {
        #if os(Windows)
        return createLoopbackPair()
        #else
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        return ShutdownPipe(readEnd: fds[0], writeEnd: fds[1])
        #endif
    }

    func close() {
        platformClose(readEnd)
        platformClose(writeEnd)
    }

    /// Signal shutdown by writing a byte to the write end
    func signal() {
        var byte: UInt8 = 1
        #if os(Windows)
        _ = WinSDK.send(writeEnd, &byte, 1, 0)
        #else
        _ = write(writeEnd, &byte, 1)
        #endif
    }

    #if os(Windows)
    /// Create a connected socket pair via loopback for use with WSAPoll
    private static func createLoopbackPair() -> ShutdownPipe? {
        // Create a temporary listener on localhost:0
        let listener = socket(AF_INET, platformStreamType, 0)
        guard listener != invalidSocket else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        addr.sin_port = 0  // Let OS pick a port
        addr.sin_addr.S_un.S_addr = UInt32(0x0100007F)  // 127.0.0.1 in network byte order

        var bindResult: Int32 = 0
        withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bindResult = bind(listener, sockaddrPtr, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { closesocket(listener); return nil }
        guard listen(listener, 1) == 0 else { closesocket(listener); return nil }

        // Get the assigned port
        var boundAddr = sockaddr_in()
        var boundLen = Int32(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                getsockname(listener, sockaddrPtr, &boundLen)
            }
        }

        // Connect to the listener
        let connector = socket(AF_INET, platformStreamType, 0)
        guard connector != invalidSocket else { closesocket(listener); return nil }

        var connectResult: Int32 = 0
        withUnsafePointer(to: &boundAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connectResult = connect(connector, sockaddrPtr, Int32(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            closesocket(connector)
            closesocket(listener)
            return nil
        }

        // Accept the connection
        let acceptor = accept(listener, nil, nil)
        closesocket(listener)  // Don't need listener anymore

        guard acceptor != invalidSocket else {
            closesocket(connector)
            return nil
        }

        return ShutdownPipe(readEnd: acceptor, writeEnd: connector)
    }
    #endif
}

// MARK: - Local IP Addresses

/// Get local non-loopback IPv4 addresses
func platformGetLocalIPs() -> [String] {
    #if os(Windows)
    return getLocalIPsWindows()
    #else
    return getLocalIPsUnix()
    #endif
}

#if os(Windows)
private func getLocalIPsWindows() -> [String] {
    var addresses: [String] = []

    // First call to get required buffer size
    var bufferSize: ULONG = 0
    var result = GetAdaptersAddresses(ULONG(AF_INET), ULONG(0), nil, nil, &bufferSize)
    guard result == ULONG(ERROR_BUFFER_OVERFLOW) else { return ["localhost"] }

    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(bufferSize), alignment: 8)
    defer { buffer.deallocate() }

    let adapters = buffer.bindMemory(to: IP_ADAPTER_ADDRESSES.self, capacity: 1)
    result = GetAdaptersAddresses(ULONG(AF_INET), ULONG(0), nil, adapters, &bufferSize)
    guard result == ULONG(ERROR_SUCCESS) else { return ["localhost"] }

    var current: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES>? = adapters
    while let adapter = current {
        // Skip loopback
        if adapter.pointee.IfType != IF_TYPE_SOFTWARE_LOOPBACK {
            var unicast = adapter.pointee.FirstUnicastAddress
            while let addr = unicast {
                let sockaddr = addr.pointee.Address.lpSockaddr
                if let sockaddr = sockaddr, sockaddr.pointee.sa_family == ADDRESS_FAMILY(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: 46)  // INET_ADDRSTRLEN
                    if getnameinfo(sockaddr, Int32(MemoryLayout<sockaddr_in>.size),
                                   &hostname, DWORD(hostname.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let address = String(cString: hostname)
                        if !address.isEmpty && !addresses.contains(address) {
                            addresses.append(address)
                        }
                    }
                }
                unicast = addr.pointee.Next
            }
        }
        current = UnsafeMutablePointer(adapter.pointee.Next)
    }

    return addresses.isEmpty ? ["localhost"] : addresses
}
#else
private func getLocalIPsUnix() -> [String] {
    var addresses: [String] = []

    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
        return ["localhost"]
    }
    defer { freeifaddrs(ifaddr) }

    var ptr = firstAddr
    while true {
        let interface = ptr.pointee
        let addrFamily = interface.ifa_addr.pointee.sa_family

        if addrFamily == sa_family_t(AF_INET) {
            let name = String(cString: interface.ifa_name)
            // Skip loopback (lo0 on macOS, lo on Linux)
            if name != "lo0" && name != "lo" {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getnameinfo(interface.ifa_addr, addrLen,
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let address = String(cString: hostname)
                    if !address.isEmpty && !addresses.contains(address) {
                        addresses.append(address)
                    }
                }
            }
        }

        guard let next = interface.ifa_next else { break }
        ptr = next
    }

    return addresses.isEmpty ? ["localhost"] : addresses
}
#endif

// MARK: - Socket Creation Helpers

/// Create a TCP socket
func platformCreateTCPSocket() -> SocketDescriptor {
    return socket(AF_INET, platformStreamType, 0)
}

/// Check if a socket descriptor is valid
func platformIsValidSocket(_ fd: SocketDescriptor) -> Bool {
    return fd != invalidSocket
}

/// Get the last socket error code
func platformSocketError() -> Int32 {
    #if os(Windows)
    return WSAGetLastError()
    #else
    return errno
    #endif
}

/// Check if the last error indicates "in progress" (for non-blocking connect)
func platformIsErrorInProgress(_ error: Int32) -> Bool {
    #if os(Windows)
    return error == WSAEWOULDBLOCK
    #else
    return error == EINPROGRESS
    #endif
}

/// Check if the last error indicates "would block" / "try again" / "timed out"
/// On Windows, SO_RCVTIMEO expiry returns WSAETIMEDOUT, not WSAEWOULDBLOCK.
func platformIsErrorWouldBlock(_ error: Int32) -> Bool {
    #if os(Windows)
    return error == WSAEWOULDBLOCK || error == WSAETIMEDOUT
    #else
    return error == EAGAIN || error == EWOULDBLOCK
    #endif
}
