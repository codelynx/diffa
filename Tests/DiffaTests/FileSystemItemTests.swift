import XCTest
@testable import Diffa
import Foundation

final class FileSystemItemTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffaTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Regular File Tests

    func testReadRegularFile() async throws {
        // Create a test file
        let fileURL = tempDir.appendingPathComponent("test.txt")
        let content = "Hello, Diffa!"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Set known permissions
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        // Read with FileSystemItem
        let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Verify
        XCTAssertEqual(item.path, "test.txt")
        XCTAssertFalse(item.isFolder)
        XCTAssertNotNil(item.sha256)
        XCTAssertEqual(item.size, Int64(content.utf8.count))
        XCTAssertEqual(item.metadata.permissions.posix, 0o644)
        XCTAssertNil(item.metadata.owner) // Not captured by default
        XCTAssertNil(item.metadata.group)
    }

    func testReadDirectory() async throws {
        // Create a test directory
        let dirURL = tempDir.appendingPathComponent("testdir")
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: false)

        // Read with FileSystemItem
        let item = try await FileSystemItem(at: dirURL, relativeTo: tempDir)

        // Verify
        XCTAssertEqual(item.path, "testdir")
        XCTAssertTrue(item.isFolder)
        XCTAssertNil(item.sha256) // No hash for directories
        XCTAssertEqual(item.size, 0) // Directories have size 0
    }

    // MARK: - SHA-256 Hash Tests

    func testComputeSHA256() async throws {
        // Create file with known content
        let fileURL = tempDir.appendingPathComponent("hashtest.txt")
        let content = "The quick brown fox jumps over the lazy dog"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Known SHA-256 hash for this content
        let expectedHash = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"

        // Read with FileSystemItem
        let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Verify hash
        XCTAssertEqual(item.sha256, expectedHash)
    }

    func testComputeSHA256ForLargeFile() async throws {
        // Create a larger file (>64KB to test chunked reading)
        let fileURL = tempDir.appendingPathComponent("largefile.bin")
        let data = Data(repeating: 0x42, count: 128 * 1024) // 128 KB
        try data.write(to: fileURL)

        // Read with FileSystemItem
        let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Verify hash exists and has correct format (64 hex chars)
        XCTAssertNotNil(item.sha256)
        XCTAssertEqual(item.sha256?.count, 64)
        XCTAssertTrue(item.sha256?.allSatisfy { $0.isHexDigit } ?? false)
    }

    // MARK: - Symlink Tests

    func testSymlinkFollowing() async throws {
        // Create a target file
        let targetURL = tempDir.appendingPathComponent("target.txt")
        let content = "Target content"
        try content.write(to: targetURL, atomically: true, encoding: .utf8)

        // Create symlink
        let symlinkURL = tempDir.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        // FileSystemItem with followSymlinks=true reads target
        let itemFollowing = try await FileSystemItem(at: symlinkURL, relativeTo: tempDir, followSymlinks: true)

        // Should read the target file's content
        XCTAssertEqual(itemFollowing.path, "link.txt")
        XCTAssertFalse(itemFollowing.isFolder)
        XCTAssertNotNil(itemFollowing.sha256)

        // Hash should match target file
        let targetItem = try await FileSystemItem(at: targetURL, relativeTo: tempDir)
        XCTAssertEqual(itemFollowing.sha256, targetItem.sha256)
    }

    func testSymlinkNotFollowing() async throws {
        // Create a target file with known content
        let targetURL = tempDir.appendingPathComponent("target.txt")
        let targetContent = "This is the target file with substantial content"
        try targetContent.write(to: targetURL, atomically: true, encoding: .utf8)

        // Create symlink
        let symlinkURL = tempDir.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        // FileSystemItem with followSymlinks=false reads symlink itself
        let symlinkItem = try await FileSystemItem(at: symlinkURL, relativeTo: tempDir, followSymlinks: false)

        // Should read the symlink itself, not target
        XCTAssertEqual(symlinkItem.path, "link.txt")
        XCTAssertFalse(symlinkItem.isFolder)

        // CRITICAL: Should NOT have a hash (symlinks are not hashed)
        XCTAssertNil(symlinkItem.sha256, "Symlink should not have SHA-256 hash when followSymlinks=false")

        // Symlink size is the length of the path it points to (can be larger than small files)
        // The key point is it's NOT the target's content size
        let targetSize = Int64(targetContent.utf8.count)
        XCTAssertNotEqual(symlinkItem.size, targetSize, "Symlink size should differ from target content size")

        // For comparison, verify following the symlink gives different results
        let targetItem = try await FileSystemItem(at: targetURL, relativeTo: tempDir)
        XCTAssertNotNil(targetItem.sha256, "Target file should have SHA-256 hash")
        XCTAssertEqual(targetItem.size, targetSize, "Target file should have full content size")
    }

    // MARK: - Hidden File Tests

    func testHiddenFileDetection() async throws {
        // Create a hidden file (starts with '.')
        let hiddenURL = tempDir.appendingPathComponent(".hidden")
        let content = "Hidden content"
        try content.write(to: hiddenURL, atomically: true, encoding: .utf8)

        // FileSystemItem can read hidden files
        // (Filtering will be done by the scanner in Step 4)
        let item = try await FileSystemItem(at: hiddenURL, relativeTo: tempDir)

        // Verify we can read hidden files
        XCTAssertEqual(item.path, ".hidden")
        XCTAssertFalse(item.isFolder)
        XCTAssertNotNil(item.sha256)

        // Verify path starts with "." (this is how scanner will detect hidden files)
        XCTAssertTrue(item.path.hasPrefix("."))
    }

    // MARK: - Ownership Tests

    func testOwnershipCapture() async throws {
        // Create a test file
        let fileURL = tempDir.appendingPathComponent("owned.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Read WITHOUT ownership capture (default)
        let itemNoOwnership = try await FileSystemItem(at: fileURL, relativeTo: tempDir, captureOwnership: false)

        XCTAssertNil(itemNoOwnership.metadata.owner)
        XCTAssertNil(itemNoOwnership.metadata.group)

        // Read WITH ownership capture
        let itemWithOwnership = try await FileSystemItem(at: fileURL, relativeTo: tempDir, captureOwnership: true)

        // Owner and group should be captured (may be nil if not available)
        // On macOS, owner should typically be available for files we create
        XCTAssertNotNil(itemWithOwnership.metadata.owner)
    }

    // MARK: - Relative Path Tests

    func testRelativePathComputation() async throws {
        // Create nested structure: tempDir/subdir/file.txt
        let subdir = tempDir.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: false)

        let fileURL = subdir.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Read relative to tempDir
        let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Should have correct relative path
        XCTAssertEqual(item.path, "subdir/file.txt")
    }

    func testRelativePathWithRootBase() async throws {
        // This tests the critical fix for root snapshots
        // Create a file anywhere in the filesystem
        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Read relative to root "/"
        let rootURL = URL(fileURLWithPath: "/")
        let item = try await FileSystemItem(at: fileURL, relativeTo: rootURL)

        // Should have correct relative path (no leading slash, all separators intact)
        let expectedPath = String(fileURL.path.dropFirst()) // Remove leading "/"
        XCTAssertEqual(item.path, expectedPath)

        // Verify all path separators are intact
        XCTAssertTrue(item.path.contains("/"), "Root-relative paths should preserve directory separators")
        XCTAssertFalse(item.path.hasPrefix("/"), "Root-relative paths should not start with /")
    }

    func testRelativePathWithRepeatedComponents() async throws {
        // Test that repeated path components don't cause issues
        // Create: tempDir/test/test/file.txt
        let test1 = tempDir.appendingPathComponent("test")
        let test2 = test1.appendingPathComponent("test")
        try fileManager.createDirectory(at: test2, withIntermediateDirectories: true)

        let fileURL = test2.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Read relative to tempDir/test
        let item = try await FileSystemItem(at: fileURL, relativeTo: test1)

        // Should only remove the first "test", not all occurrences
        XCTAssertEqual(item.path, "test/file.txt")
    }

    func testRelativePathOutsideBase() async throws {
        // Test that files outside the base path throw an error
        let fileURL = tempDir.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Try to read with a base path that definitely doesn't contain the file
        // Use /usr which is never a parent of temp directories
        let otherBase = URL(fileURLWithPath: "/usr")

        // Should throw an error
        do {
            _ = try await FileSystemItem(at: fileURL, relativeTo: otherBase)
            XCTFail("Should have thrown an error")
        } catch {
            // Expected
        }
    }

    func testRelativePathSiblingDirectory() async throws {
        // CRITICAL TEST: Sibling directories with common prefix should NOT be accepted
        // Example: /tmp/base and /tmp/baseball are siblings, not parent/child

        // Create: tempDir/base/file.txt
        let baseDir = tempDir.appendingPathComponent("base")
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: false)
        let fileInBase = baseDir.appendingPathComponent("file.txt")
        try "in base".write(to: fileInBase, atomically: true, encoding: .utf8)

        // Create: tempDir/baseball/file.txt (sibling directory with common prefix)
        let baseballDir = tempDir.appendingPathComponent("baseball")
        try fileManager.createDirectory(at: baseballDir, withIntermediateDirectories: false)
        let fileInBaseball = baseballDir.appendingPathComponent("file.txt")
        try "in baseball".write(to: fileInBaseball, atomically: true, encoding: .utf8)

        // Reading fileInBase with base=baseDir should work
        let validItem = try await FileSystemItem(at: fileInBase, relativeTo: baseDir)
        XCTAssertEqual(validItem.path, "file.txt")

        // Reading fileInBaseball with base=baseDir should FAIL (sibling, not child)
        // This is the critical test - string prefix check would wrongly accept this
        do {
            _ = try await FileSystemItem(at: fileInBaseball, relativeTo: baseDir)
            XCTFail("File in sibling directory should be rejected")
        } catch {
            // Verify it's the correct error type
            if case FileSystemError.fileNotUnderBasePath = error {
                // Expected
            } else {
                XCTFail("Expected fileNotUnderBasePath error, got \(error)")
            }
        }
    }

    // MARK: - Metadata Tests

    func testMetadataCapture() async throws {
        // Create a file
        let fileURL = tempDir.appendingPathComponent("metadata.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Set specific permissions
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)

        // Read metadata
        let item = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Verify metadata
        XCTAssertEqual(item.metadata.permissions.posix, 0o755)
        XCTAssertEqual(item.metadata.permissions.symbolic, "rwxr-xr-x")
        XCTAssertEqual(item.metadata.size, Int64("content".utf8.count))

        // Modification date should be recent (within last minute)
        let now = Date()
        let timeDiff = abs(item.metadata.modificationDate.timeIntervalSince(now))
        XCTAssertLessThan(timeDiff, 60.0) // Within 60 seconds
    }

    // MARK: - Equality Tests

    func testFileSystemItemEquality() async throws {
        // Create a file
        let fileURL = tempDir.appendingPathComponent("equal.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Read twice
        let item1 = try await FileSystemItem(at: fileURL, relativeTo: tempDir)
        let item2 = try await FileSystemItem(at: fileURL, relativeTo: tempDir)

        // Should be equal
        XCTAssertEqual(item1, item2)
    }
}

// MARK: - Character Extension for Hex Validation

extension Character {
    fileprivate var isHexDigit: Bool {
        return self.isNumber || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
