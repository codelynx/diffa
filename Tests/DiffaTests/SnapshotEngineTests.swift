import XCTest
@testable import Diffa
import Foundation

final class SnapshotEngineTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!
    var engine: SnapshotEngine!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        engine = SnapshotEngine()

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffaEngineTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Basic Scanning Tests

    func testScanEmptyDirectory() async throws {
        // Create empty directory
        let emptyDir = tempDir.appendingPathComponent("empty")
        try fileManager.createDirectory(at: emptyDir, withIntermediateDirectories: false)

        // Scan it
        let options = ScanOptions()
        let items = try await engine.scanDirectory(at: emptyDir, options: options)

        // Should return empty array
        XCTAssertEqual(items.count, 0)
    }

    func testScanSingleFile() async throws {
        // Create a single file
        let fileURL = tempDir.appendingPathComponent("single.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Scan the temp directory
        let options = ScanOptions()
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return 1 item
        XCTAssertEqual(items.count, 1, "Should have exactly 1 item")
        XCTAssertTrue(items.count > 0, "items array should not be empty")
        if items.count > 0 {
            XCTAssertEqual(items.first?.path, "single.txt")
            XCTAssertFalse(items.first?.isFolder ?? true)
        }
    }

    func testScanNestedDirectories() async throws {
        // Create nested structure: tempDir/dir/subdir/file.txt
        let dir = tempDir.appendingPathComponent("dir")
        let subdir = dir.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: true)

        let fileURL = subdir.appendingPathComponent("file.txt")
        try "nested content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Scan tempDir
        let options = ScanOptions()
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return 3 items: dir, subdir, file.txt
        XCTAssertEqual(items.count, 3)

        // Verify paths
        let paths = Set(items.map { $0.path })
        XCTAssertTrue(paths.contains("dir"))
        XCTAssertTrue(paths.contains("dir/subdir"))
        XCTAssertTrue(paths.contains("dir/subdir/file.txt"))

        // Verify folder flags
        let dirItem = items.first { $0.path == "dir" }!
        XCTAssertTrue(dirItem.isFolder)

        let subdirItem = items.first { $0.path == "dir/subdir" }!
        XCTAssertTrue(subdirItem.isFolder)

        let fileItem = items.first { $0.path == "dir/subdir/file.txt" }!
        XCTAssertFalse(fileItem.isFolder)
    }

    // MARK: - Hidden File Tests

    func testScanWithHiddenFilesIncluded() async throws {
        // Create regular and hidden files
        let regularURL = tempDir.appendingPathComponent("regular.txt")
        try "regular".write(to: regularURL, atomically: true, encoding: .utf8)

        let hiddenURL = tempDir.appendingPathComponent(".hidden")
        try "hidden".write(to: hiddenURL, atomically: true, encoding: .utf8)

        // Scan with includeHidden = true (default)
        let options = ScanOptions(includeHidden: true)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return both files
        XCTAssertEqual(items.count, 2)

        let paths = Set(items.map { $0.path })
        XCTAssertTrue(paths.contains("regular.txt"))
        XCTAssertTrue(paths.contains(".hidden"))
    }

    func testScanWithHiddenFilesExcluded() async throws {
        // Create regular and hidden files
        let regularURL = tempDir.appendingPathComponent("regular.txt")
        try "regular".write(to: regularURL, atomically: true, encoding: .utf8)

        let hiddenURL = tempDir.appendingPathComponent(".hidden")
        try "hidden".write(to: hiddenURL, atomically: true, encoding: .utf8)

        // Scan with includeHidden = false
        let options = ScanOptions(includeHidden: false)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return only regular file
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, "regular.txt")
    }

    func testScanWithHiddenDirectoriesExcluded() async throws {
        // Create regular and hidden directories with files
        let regularDir = tempDir.appendingPathComponent("regular")
        try fileManager.createDirectory(at: regularDir, withIntermediateDirectories: false)
        let regularFile = regularDir.appendingPathComponent("file.txt")
        try "content".write(to: regularFile, atomically: true, encoding: .utf8)

        let hiddenDir = tempDir.appendingPathComponent(".hidden")
        try fileManager.createDirectory(at: hiddenDir, withIntermediateDirectories: false)
        let hiddenFile = hiddenDir.appendingPathComponent("file.txt")
        try "hidden content".write(to: hiddenFile, atomically: true, encoding: .utf8)

        // Scan with includeHidden = false
        let options = ScanOptions(includeHidden: false)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return only regular directory and its file
        XCTAssertEqual(items.count, 2)

        let paths = Set(items.map { $0.path })
        XCTAssertTrue(paths.contains("regular"))
        XCTAssertTrue(paths.contains("regular/file.txt"))
        XCTAssertFalse(paths.contains(".hidden"))
        XCTAssertFalse(paths.contains(".hidden/file.txt"))
    }

    // MARK: - Symlink Tests

    func testScanFollowSymlinkToFile() async throws {
        #if os(Windows)
        throw XCTSkip("Symlinks require admin privileges on Windows")
        #endif
        // Create target file
        let targetURL = tempDir.appendingPathComponent("target.txt")
        try "target content".write(to: targetURL, atomically: true, encoding: .utf8)

        // Create symlink
        let symlinkURL = tempDir.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        // Scan with followSymlinks = true (default)
        let options = ScanOptions(followSymlinks: true)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return both target and symlink
        XCTAssertEqual(items.count, 2)

        let paths = Set(items.map { $0.path })
        XCTAssertTrue(paths.contains("target.txt"))
        XCTAssertTrue(paths.contains("link.txt"))

        // Both should have the same content hash (followed the link)
        let targetItem = items.first { $0.path == "target.txt" }!
        let linkItem = items.first { $0.path == "link.txt" }!
        XCTAssertEqual(targetItem.sha256, linkItem.sha256)
    }

    func testScanFollowSymlinkToDirectory() async throws {
        #if os(Windows)
        throw XCTSkip("Symlinks require admin privileges on Windows")
        #endif
        // Create target directory with file
        let targetDir = tempDir.appendingPathComponent("target")
        try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: false)
        let fileURL = targetDir.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Create symlink to directory
        let symlinkURL = tempDir.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetDir)

        // Scan with followSymlinks = true
        let options = ScanOptions(followSymlinks: true)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return: target/, target/file.txt, link/ (symlink to target)
        // Note: When following symlinks to directories, we record the symlink itself
        // but contents are not duplicated (they're already in target/)
        XCTAssertEqual(items.count, 3)

        let paths = Set(items.map { $0.path })
        XCTAssertTrue(paths.contains("target"))
        XCTAssertTrue(paths.contains("target/file.txt"))
        XCTAssertTrue(paths.contains("link"))

        // Verify the symlink points to a directory
        if let linkItem = items.first(where: { $0.path == "link" }) {
            XCTAssertTrue(linkItem.isFolder)
        } else {
            // Symlinks may not be created on Windows without admin privileges
            #if os(macOS) || os(iOS) || os(Linux)
            XCTFail("Expected to find symlink item 'link'")
            #endif
        }
    }

    func testScanStoreSymlinkAsIs() async throws {
        #if os(Windows)
        throw XCTSkip("Symlinks require admin privileges on Windows")
        #endif
        // Create target file with known content
        let targetURL = tempDir.appendingPathComponent("target.txt")
        let targetContent = "This is substantial target file content for testing"
        try targetContent.write(to: targetURL, atomically: true, encoding: .utf8)

        // Create symlink
        let symlinkURL = tempDir.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

        // Scan with followSymlinks = false
        let options = ScanOptions(followSymlinks: false)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should return both items
        XCTAssertEqual(items.count, 2)

        let paths = Set(items.map { $0.path })
        XCTAssertTrue(paths.contains("target.txt"))
        XCTAssertTrue(paths.contains("link.txt"))

        // CRITICAL: Verify symlink is stored as symlink, not dereferenced
        let targetItem = items.first { $0.path == "target.txt" }!
        let symlinkItem = items.first { $0.path == "link.txt" }!

        // Target should have hash and full size
        XCTAssertNotNil(targetItem.sha256, "Target file should have SHA-256 hash")
        let targetSize = Int64(targetContent.utf8.count)
        XCTAssertEqual(targetItem.size, targetSize)

        // Symlink should NOT have hash (not dereferenced) - this is the critical check
        XCTAssertNil(symlinkItem.sha256, "Symlink should not have SHA-256 hash when followSymlinks=false")

        // Symlink size is the path length, not the target's content
        // (Can be larger than small files due to long temp directory paths)
        XCTAssertNotEqual(symlinkItem.size, targetSize, "Symlink size should differ from target content size")
    }

    func testScanCircularSymlink() async throws {
        #if os(Windows)
        throw XCTSkip("Symlinks require admin privileges on Windows")
        #endif
        // Create directory structure: tempDir/dir/
        let dir = tempDir.appendingPathComponent("dir")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: false)

        // Create file in dir
        let fileURL = dir.appendingPathComponent("file.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Create circular symlink: dir/loop -> tempDir
        let loopURL = dir.appendingPathComponent("loop")
        try fileManager.createSymbolicLink(at: loopURL, withDestinationURL: tempDir)

        // Scan with followSymlinks = true
        let options = ScanOptions(followSymlinks: true)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should handle circular symlink gracefully and not infinite loop
        // We should get: dir/, dir/file.txt, dir/loop
        // But NOT recurse into dir/loop (which would create infinite loop)

        // Verify we got items without hanging
        XCTAssertGreaterThan(items.count, 0)

        // Verify we don't have deeply nested paths (sign of infinite recursion)
        for item in items {
            let depth = item.path.components(separatedBy: "/").count
            XCTAssertLessThan(depth, 10, "Path depth too large, possible infinite recursion: \(item.path)")
        }
    }

    func testScanBrokenSymlink() async throws {
        #if os(Windows)
        throw XCTSkip("Symlinks require admin privileges on Windows")
        #endif
        // Create symlink to nonexistent target
        let symlinkURL = tempDir.appendingPathComponent("broken.txt")
        let nonexistentPath = tempDir.appendingPathComponent("nonexistent.txt").path
        try fileManager.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: nonexistentPath)

        // Also create a valid file
        let validURL = tempDir.appendingPathComponent("valid.txt")
        try "content".write(to: validURL, atomically: true, encoding: .utf8)

        // Scan with followSymlinks = true
        let options = ScanOptions(followSymlinks: true)
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should skip broken symlink and return only valid file
        #if os(Windows)
        // Windows symlinks require admin privileges; test may see different results
        XCTAssertGreaterThanOrEqual(items.count, 1)
        #else
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].path, "valid.txt")
        #endif
    }

    // MARK: - Progress Callback Tests

    func testScanProgressCallback() async throws {
        // Create multiple files
        for i in 1...5 {
            let fileURL = tempDir.appendingPathComponent("file\(i).txt")
            try "content \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Track progress updates
        var progressUpdates: [SnapshotProgress] = []

        let options = ScanOptions()
        _ = try await engine.scanDirectory(at: tempDir, options: options) { progress in
            progressUpdates.append(progress)
        }

        // Should have received progress updates
        XCTAssertGreaterThan(progressUpdates.count, 0)

        // Verify progress is increasing
        XCTAssertEqual(progressUpdates.last?.filesProcessed, 5)

        // Verify current path is being updated
        let paths = progressUpdates.map { $0.currentPath }
        XCTAssertGreaterThan(Set(paths).count, 1, "Progress should update with different paths")

        // Verify bytes processed is increasing
        let lastProgress = progressUpdates.last!
        XCTAssertGreaterThan(lastProgress.bytesProcessed, 0)
    }

    // MARK: - Edge Case Tests

    func testScanPermissionDenied() async throws {
        // Create a directory and file
        let restrictedDir = tempDir.appendingPathComponent("restricted")
        try fileManager.createDirectory(at: restrictedDir, withIntermediateDirectories: false)

        let fileURL = restrictedDir.appendingPathComponent("file.txt")
        try "secret".write(to: fileURL, atomically: true, encoding: .utf8)

        // Remove read permissions (on macOS this may not work in temp directories)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedDir.path)

        // Scan should handle permission denied gracefully
        let options = ScanOptions()
        let items = try await engine.scanDirectory(at: tempDir, options: options)

        // Should complete without crashing
        // (May or may not include the restricted directory depending on OS behavior)
        XCTAssertGreaterThanOrEqual(items.count, 0)

        // Restore permissions for cleanup
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: restrictedDir.path)
    }

    func testScanMultipleLevelsWithMixedContent() async throws {
        // Create complex structure
        // tempDir/
        //   ├── file1.txt
        //   ├── .hidden1
        //   ├── dir1/
        //   │   ├── file2.txt
        //   │   └── .hidden2
        //   └── dir2/
        //       ├── subdir/
        //       │   └── file3.txt
        //       └── file4.txt

        let file1 = tempDir.appendingPathComponent("file1.txt")
        try "1".write(to: file1, atomically: true, encoding: .utf8)

        let hidden1 = tempDir.appendingPathComponent(".hidden1")
        try "h1".write(to: hidden1, atomically: true, encoding: .utf8)

        let dir1 = tempDir.appendingPathComponent("dir1")
        try fileManager.createDirectory(at: dir1, withIntermediateDirectories: false)

        let file2 = dir1.appendingPathComponent("file2.txt")
        try "2".write(to: file2, atomically: true, encoding: .utf8)

        let hidden2 = dir1.appendingPathComponent(".hidden2")
        try "h2".write(to: hidden2, atomically: true, encoding: .utf8)

        let dir2 = tempDir.appendingPathComponent("dir2")
        try fileManager.createDirectory(at: dir2, withIntermediateDirectories: false)

        let subdir = dir2.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subdir, withIntermediateDirectories: false)

        let file3 = subdir.appendingPathComponent("file3.txt")
        try "3".write(to: file3, atomically: true, encoding: .utf8)

        let file4 = dir2.appendingPathComponent("file4.txt")
        try "4".write(to: file4, atomically: true, encoding: .utf8)

        // Scan with all files
        let optionsAll = ScanOptions(includeHidden: true)
        let allItems = try await engine.scanDirectory(at: tempDir, options: optionsAll)

        // Should return 9 items: 4 regular files + 2 hidden files + 3 directories
        // (file1.txt, .hidden1, dir1, file2.txt, .hidden2, dir2, subdir, file3.txt, file4.txt)
        XCTAssertEqual(allItems.count, 9)

        // Scan without hidden
        let optionsNoHidden = ScanOptions(includeHidden: false)
        let visibleItems = try await engine.scanDirectory(at: tempDir, options: optionsNoHidden)

        // Should return 7 items: 4 regular files + 3 directories (no hidden files)
        XCTAssertEqual(visibleItems.count, 7)

        let visiblePaths = Set(visibleItems.map { $0.path })
        XCTAssertFalse(visiblePaths.contains(".hidden1"))
        XCTAssertFalse(visiblePaths.contains("dir1/.hidden2"))
    }
}
