import XCTest
@testable import Diffa

final class FileHasherTests: XCTestCase {
    var tempDir: URL!
    var hasher: FileHasher!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileHasherTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        hasher = FileHasher()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Basic Hashing

    func testHashKnownContent() throws {
        // SHA-256 of "hello world\n" is a948904f2f0f479b8f8564cbf12daea3c4e99d24a7a89362c1f5a2b5b9c4e8f1
        // (computed via: echo "hello world" | shasum -a 256)
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello world\n".write(to: file, atomically: true, encoding: .utf8)

        let hash = try hasher.hash(fileAt: file)

        XCTAssertEqual(hash.count, 32) // SHA-256 is 32 bytes
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    }

    func testHashHexConvenience() throws {
        let file = tempDir.appendingPathComponent("hello.txt")
        try "hello world\n".write(to: file, atomically: true, encoding: .utf8)

        let hex = try hasher.hashHex(fileAt: file)

        XCTAssertEqual(hex, "a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447")
    }

    func testHashEmptyFile() throws {
        // SHA-256 of empty string is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        let file = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: file)

        let hex = try hasher.hashHex(fileAt: file)

        XCTAssertEqual(hex, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHashBinaryContent() throws {
        let file = tempDir.appendingPathComponent("binary.bin")
        let data = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD])
        try data.write(to: file)

        let hash = try hasher.hash(fileAt: file)

        XCTAssertEqual(hash.count, 32) // SHA-256 is 32 bytes
        // Verify it's deterministic
        let hash2 = try hasher.hash(fileAt: file)
        XCTAssertEqual(hash, hash2)
    }

    // MARK: - Large Files (Streaming)

    func testHashLargeFile() throws {
        // Create a 1MB file to verify streaming works
        let file = tempDir.appendingPathComponent("large.bin")
        let chunkSize = 64 * 1024  // 64KB
        let totalSize = 1024 * 1024  // 1MB

        // Write in chunks to avoid memory issues
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }

        var totalWritten = 0
        while totalWritten < totalSize {
            let chunk = Data(repeating: UInt8(totalWritten % 256), count: chunkSize)
            handle.write(chunk)
            totalWritten += chunkSize
        }

        // Hash should complete without memory issues
        let hash = try hasher.hash(fileAt: file)
        XCTAssertEqual(hash.count, 32) // SHA-256 is 32 bytes

        // Verify deterministic
        let hash2 = try hasher.hash(fileAt: file)
        XCTAssertEqual(hash, hash2)
    }

    // MARK: - Error Handling

    func testHashNonExistentFile() {
        let file = tempDir.appendingPathComponent("nonexistent.txt")

        XCTAssertThrowsError(try hasher.hash(fileAt: file)) { error in
            guard case HasherError.cannotOpenFile = error else {
                XCTFail("Expected cannotOpenFile error")
                return
            }
        }
    }

    func testHashDirectory() {
        // Attempting to hash a directory should fail
        XCTAssertThrowsError(try hasher.hash(fileAt: tempDir)) { error in
            // FileHandle can't open directories for reading
            guard case HasherError.cannotOpenFile = error else {
                XCTFail("Expected cannotOpenFile error")
                return
            }
        }
    }

    // MARK: - Determinism

    func testHashDeterminism() throws {
        let file = tempDir.appendingPathComponent("test.txt")
        try "test content for determinism check".write(to: file, atomically: true, encoding: .utf8)

        // Hash multiple times, should always be the same
        var hashes: [Data] = []
        for _ in 0..<10 {
            hashes.append(try hasher.hash(fileAt: file))
        }

        let first = hashes[0]
        XCTAssertTrue(hashes.allSatisfy { $0 == first }, "All hashes should be identical")
    }

    // MARK: - Different Content Different Hash

    func testDifferentContentDifferentHash() throws {
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        try "content A".write(to: file1, atomically: true, encoding: .utf8)
        try "content B".write(to: file2, atomically: true, encoding: .utf8)

        let hash1 = try hasher.hash(fileAt: file1)
        let hash2 = try hasher.hash(fileAt: file2)

        XCTAssertNotEqual(hash1, hash2)
    }

    func testSameContentSameHash() throws {
        let file1 = tempDir.appendingPathComponent("file1.txt")
        let file2 = tempDir.appendingPathComponent("file2.txt")
        try "identical content".write(to: file1, atomically: true, encoding: .utf8)
        try "identical content".write(to: file2, atomically: true, encoding: .utf8)

        let hash1 = try hasher.hash(fileAt: file1)
        let hash2 = try hasher.hash(fileAt: file2)

        XCTAssertEqual(hash1, hash2)
    }
}
