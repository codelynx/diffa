import XCTest
@testable import Diffa

final class HashCacheTests: XCTestCase {

    // MARK: - Step 0: Hash Cache Foundation Tests

    func testHashCacheLookup() throws {
        // Create temporary cache database
        let tempDir = FileManager.default.temporaryDirectory
        let cacheURL = tempDir.appendingPathComponent(UUID().uuidString + ".diffa")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = try HashCache(at: cacheURL)

        // Store a hash
        let path = "/test/file.txt"
        let size: Int64 = 1024
        let modDate = Date()
        let hash = "abc123def456"

        try cache.store(path: path, size: size, modificationDate: modDate, hash: hash)

        // Lookup should return the cached hash
        let result = try cache.lookup(path: path, size: size, modificationDate: modDate)
        XCTAssertEqual(result, hash, "Lookup should return cached hash")
    }

    func testHashCacheMiss() throws {
        // Create temporary cache database
        let tempDir = FileManager.default.temporaryDirectory
        let cacheURL = tempDir.appendingPathComponent(UUID().uuidString + ".diffa")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = try HashCache(at: cacheURL)

        // Store a hash
        let path = "/test/file.txt"
        let size: Int64 = 1024
        let modDate = Date()
        let hash = "abc123def456"

        try cache.store(path: path, size: size, modificationDate: modDate, hash: hash)

        // Lookup with different size → cache miss
        let result1 = try cache.lookup(path: path, size: 2048, modificationDate: modDate)
        XCTAssertNil(result1, "Lookup with different size should return nil")

        // Lookup with different modification date → cache miss
        let differentDate = modDate.addingTimeInterval(10.0)
        let result2 = try cache.lookup(path: path, size: size, modificationDate: differentDate)
        XCTAssertNil(result2, "Lookup with different modification date should return nil")

        // Lookup with different path → cache miss
        let result3 = try cache.lookup(path: "/other/file.txt", size: size, modificationDate: modDate)
        XCTAssertNil(result3, "Lookup with different path should return nil")
    }

    func testHashCacheStore() throws {
        // Create temporary cache database
        let tempDir = FileManager.default.temporaryDirectory
        let cacheURL = tempDir.appendingPathComponent(UUID().uuidString + ".diffa")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = try HashCache(at: cacheURL)

        // Store multiple hashes
        let files = [
            ("/file1.txt", Int64(100), "hash1"),
            ("/file2.txt", Int64(200), "hash2"),
            ("/file3.txt", Int64(300), "hash3")
        ]

        let modDate = Date()
        for (path, size, hash) in files {
            try cache.store(path: path, size: size, modificationDate: modDate, hash: hash)
        }

        // Verify all were stored
        for (path, size, hash) in files {
            let result = try cache.lookup(path: path, size: size, modificationDate: modDate)
            XCTAssertEqual(result, hash, "Cached hash for \(path) should match")
        }

        // Update an existing entry (INSERT OR REPLACE)
        let updatedHash = "hash1-updated"
        try cache.store(path: files[0].0, size: files[0].1, modificationDate: modDate, hash: updatedHash)

        let result = try cache.lookup(path: files[0].0, size: files[0].1, modificationDate: modDate)
        XCTAssertEqual(result, updatedHash, "Updated hash should be returned")
    }

    func testHashCachePrune() throws {
        // Create temporary cache database
        let tempDir = FileManager.default.temporaryDirectory
        let cacheURL = tempDir.appendingPathComponent(UUID().uuidString + ".diffa")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = try HashCache(at: cacheURL)

        // Store several hashes
        let modDate = Date()
        try cache.store(path: "/file1.txt", size: 100, modificationDate: modDate, hash: "hash1")
        try cache.store(path: "/file2.txt", size: 200, modificationDate: modDate, hash: "hash2")
        try cache.store(path: "/file3.txt", size: 300, modificationDate: modDate, hash: "hash3")
        try cache.store(path: "/file4.txt", size: 400, modificationDate: modDate, hash: "hash4")

        // Prune: Keep only file1 and file3
        let validPaths: Set<String> = ["/file1.txt", "/file3.txt"]
        try cache.prune(validPaths: validPaths)

        // Verify file1 and file3 still cached
        XCTAssertNotNil(try cache.lookup(path: "/file1.txt", size: 100, modificationDate: modDate))
        XCTAssertNotNil(try cache.lookup(path: "/file3.txt", size: 300, modificationDate: modDate))

        // Verify file2 and file4 removed
        XCTAssertNil(try cache.lookup(path: "/file2.txt", size: 200, modificationDate: modDate))
        XCTAssertNil(try cache.lookup(path: "/file4.txt", size: 400, modificationDate: modDate))
    }

    func testHashCacheClear() throws {
        // Create temporary cache database
        let tempDir = FileManager.default.temporaryDirectory
        let cacheURL = tempDir.appendingPathComponent(UUID().uuidString + ".diffa")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = try HashCache(at: cacheURL)

        // Store several hashes
        let modDate = Date()
        try cache.store(path: "/file1.txt", size: 100, modificationDate: modDate, hash: "hash1")
        try cache.store(path: "/file2.txt", size: 200, modificationDate: modDate, hash: "hash2")
        try cache.store(path: "/file3.txt", size: 300, modificationDate: modDate, hash: "hash3")

        // Verify all are cached
        XCTAssertNotNil(try cache.lookup(path: "/file1.txt", size: 100, modificationDate: modDate))
        XCTAssertNotNil(try cache.lookup(path: "/file2.txt", size: 200, modificationDate: modDate))
        XCTAssertNotNil(try cache.lookup(path: "/file3.txt", size: 300, modificationDate: modDate))

        // Clear cache
        try cache.clear()

        // Verify all entries removed
        XCTAssertNil(try cache.lookup(path: "/file1.txt", size: 100, modificationDate: modDate))
        XCTAssertNil(try cache.lookup(path: "/file2.txt", size: 200, modificationDate: modDate))
        XCTAssertNil(try cache.lookup(path: "/file3.txt", size: 300, modificationDate: modDate))
    }

    func testHashCacheFileExtension() throws {
        // Test that .diffa extension works correctly
        let tempDir = FileManager.default.temporaryDirectory
        let cacheURL = tempDir.appendingPathComponent(UUID().uuidString + ".diffa")
        defer { try? FileManager.default.removeItem(at: cacheURL) }

        let cache = try HashCache(at: cacheURL)

        // Store and retrieve a hash
        let modDate = Date()
        try cache.store(path: "/test.txt", size: 100, modificationDate: modDate, hash: "test-hash")
        let result = try cache.lookup(path: "/test.txt", size: 100, modificationDate: modDate)

        XCTAssertEqual(result, "test-hash", "Hash cache should work with .diffa extension")

        // Verify the file was actually created with .diffa extension
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path),
                     "Cache file should exist at path with .diffa extension")
        XCTAssertTrue(cacheURL.lastPathComponent.hasSuffix(".diffa"),
                     "Cache filename should end with .diffa extension")
    }
}
