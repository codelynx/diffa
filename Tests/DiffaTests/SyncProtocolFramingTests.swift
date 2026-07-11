import XCTest
@testable import Diffa

/// Framing-v2 acceptance tests (network protocol delta, phase-1 commit 1).
/// Covers the §7 acceptance bar: pathological-filename round-trip,
/// oversized-frame rejection, version-mismatch clean error, path
/// validation, and a decoder fuzz pass.
final class SyncProtocolFramingTests: XCTestCase {

    // MARK: - Metadata round-trip

    func testRoundTripPreservesPathsThatBrokeCSV() throws {
        // Commas, newlines, tabs, backslashes, and unicode — every one of
        // these corrupted or dropped rows under the v1 CSV encoding.
        let items = [
            NetworkFileItem(path: "docs/guide.md", size: 42, hash: "abcd1234", mtime: 100),
            NetworkFileItem(path: "weird/na,me.txt", size: 1, hash: "00", mtime: 2),
            NetworkFileItem(path: "line\nbreak/file", size: 3, hash: "ff", mtime: 4),
            NetworkFileItem(path: "tab\tsep/x", size: 5, hash: "1a2b", mtime: 6),
            NetworkFileItem(path: "back\\slash/y", size: 7, hash: "de", mtime: 8),
            NetworkFileItem(path: "úñïçødé/篁.dat", size: 9, hash: "cafe", mtime: 10),
        ]
        let decoded = try NetworkFileItem.decode(NetworkFileItem.encode(items))
        XCTAssertEqual(decoded.count, items.count)
        for (a, b) in zip(items, decoded) {
            XCTAssertEqual(a.path, b.path, "path must survive verbatim")
            XCTAssertEqual(a.size, b.size)
            XCTAssertEqual(a.hash, b.hash)
            XCTAssertEqual(a.mtime, b.mtime)
        }
    }

    func testEmptyListingRoundTrips() throws {
        XCTAssertEqual(try NetworkFileItem.decode(NetworkFileItem.encode([])).count, 0)
    }

    func testOneBadRecordDoesNotEmptyWholeListing() throws {
        // v1 CSV returned [] if any byte was invalid; v2 throws instead of
        // silently reporting the remote as empty.
        var payload = NetworkFileItem.encode([
            NetworkFileItem(path: "a/b", size: 1, hash: "00", mtime: 1),
        ])
        payload.append(0xFF) // trailing garbage
        XCTAssertThrowsError(try NetworkFileItem.decode(payload))
    }

    // MARK: - Path validation (rejected even read-only)

    func testTraversalAndAbsolutePathsRejected() {
        for bad in ["../escape", "a/../../x", "/etc/passwd"] {
            let payload = NetworkFileItem.encode([
                NetworkFileItem(path: bad, size: 0, hash: "00", mtime: 0),
            ])
            XCTAssertThrowsError(try NetworkFileItem.decode(payload), "must reject \(bad)")
        }
    }

    // MARK: - Bounded parser (reject over-cap without trusting the header)

    func testOverCapRecordCountRejected() {
        var payload = Data()
        appendU32(NetworkProtocolLimits.maxRecordCount + 1, to: &payload)
        XCTAssertThrowsError(try NetworkFileItem.decode(payload))
    }

    func testOverCapComponentLengthRejected() {
        var payload = Data()
        appendU32(1, to: &payload)                                        // 1 record
        appendU32(1, to: &payload)                                        // 1 component
        appendU32(NetworkProtocolLimits.maxComponentLength + 1, to: &payload) // huge declared len
        // No bytes follow — must reject on the cap, not try to read them.
        XCTAssertThrowsError(try NetworkFileItem.decode(payload))
    }

    func testTruncatedRecordRejected() {
        var payload = Data()
        appendU32(1, to: &payload)   // claims 1 record
        appendU32(1, to: &payload)   // 1 component
        appendU32(4, to: &payload)   // component len 4
        payload.append(contentsOf: Array("ab".utf8)) // but only 2 bytes present
        XCTAssertThrowsError(try NetworkFileItem.decode(payload))
    }

    // MARK: - Version gate

    func testHelloRoundTrip() throws {
        XCTAssertEqual(try NetworkProtocol.decodeHello(NetworkProtocol.encodeHello(mode: .push)), .push)
        XCTAssertEqual(try NetworkProtocol.decodeHello(NetworkProtocol.encodeHello(mode: .pull)), .pull)
    }

    func testWrongMagicRejected() {
        var payload = Data([0x00, 0x00, 0x00, 0x00])
        appendU32(NetworkProtocol.major, to: &payload)
        payload.append(Data("PUSH".utf8))
        XCTAssertThrowsError(try NetworkProtocol.decodeHello(payload)) { error in
            guard case SyncProtocolError.incompatibleProtocol = error else {
                return XCTFail("expected incompatibleProtocol, got \(error)")
            }
        }
    }

    func testWrongVersionRejectedCleanly() {
        var payload = Data(NetworkProtocol.magic)
        appendU32(NetworkProtocol.major + 1, to: &payload)
        payload.append(Data("PUSH".utf8))
        XCTAssertThrowsError(try NetworkProtocol.decodeHello(payload)) { error in
            guard case SyncProtocolError.incompatibleProtocol = error else {
                return XCTFail("expected incompatibleProtocol, got \(error)")
            }
        }
    }

    func testV1StyleHelloRejected() {
        // An old client sent the bare mode string "PUSH" as the HELLO body.
        XCTAssertThrowsError(try NetworkProtocol.decodeHello(Data("PUSH".utf8)))
    }

    // MARK: - Envelope length cap

    func testEnvelopeRejectsOverCapDeclaredLength() {
        let huge = NetworkProtocolLimits.maxControlPayload + 1
        let header = "HELLO \(huge)\n"
        let stream = InputStream(data: Data(header.utf8))
        stream.open()
        defer { stream.close() }
        XCTAssertThrowsError(try SyncMessage.decode(from: stream)) { error in
            guard case SyncProtocolError.payloadTooLarge = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
        }
    }

    // MARK: - Fuzz: the decoder must never crash on arbitrary input

    func testDecoderSurvivesArbitraryBytes() {
        // Deterministic pseudo-random byte blobs (no Date/Random in tests):
        // the decoder must throw or return, never trap.
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for iteration in 0..<2000 {
            let len = Int(next()) + (iteration % 64)
            var blob = Data()
            for _ in 0..<len { blob.append(next()) }
            // Must not crash. Result is irrelevant; absence of a trap is the test.
            _ = try? NetworkFileItem.decode(blob)
            _ = try? NetworkProtocol.decodeHello(blob)
        }
    }
}
