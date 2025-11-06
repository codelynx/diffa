import XCTest
@testable import Diffalla

/// Integration tests for end-to-end patching workflows
final class PatchingIntegrationTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!
    var engine: SnapshotEngine!

    override func setUp() async throws {
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = SnapshotEngine()
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? fileManager.removeItem(at: tempDir)
        }
    }

    // MARK: - Helper Methods

    func createDirectory(at relativePath: String) throws {
        let fullURL = tempDir.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: fullURL, withIntermediateDirectories: true)
    }

    func createFile(at relativePath: String, content: String) throws {
        let fullURL = tempDir.appendingPathComponent(relativePath)
        try content.write(to: fullURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Integration Tests

    func testFullPatchWorkflow() async throws {
        // Step 1: Create source directory
        let sourceDir = tempDir.appendingPathComponent("source")
        try createDirectory(at: "source")
        try createFile(at: "source/file1.txt", content: "content1")
        try createFile(at: "source/file2.txt", content: "content2")
        try createDirectory(at: "source/subdir")
        try createFile(at: "source/subdir/file3.txt", content: "content3")

        // Step 2: Create destination directory (with changes)
        let destDir = tempDir.appendingPathComponent("dest")
        try createDirectory(at: "dest")
        try createFile(at: "dest/file1.txt", content: "modified1")  // Modified
        // file2.txt removed
        try createDirectory(at: "dest/subdir")
        try createFile(at: "dest/subdir/file3.txt", content: "content3")  // Unchanged
        try createFile(at: "dest/file4.txt", content: "content4")  // Added

        // Step 3: Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Step 4: Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        let added = try difference.added
        let removed = try difference.removed
        let modified = try difference.modified

        XCTAssertEqual(added.count, 1)  // file4.txt
        XCTAssertEqual(removed.count, 1)  // file2.txt
        XCTAssertEqual(modified.count, 1)  // file1.txt

        // Step 5: Create patch with revert data
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir,
            saveTo: patchURL,
            includeRevertData: true
        )

        // Step 6: Apply patch to a copy of source
        let targetDir = tempDir.appendingPathComponent("target")
        try fileManager.copyItem(at: sourceDir, to: targetDir)

        try await patch.apply(to: targetDir)

        // Step 7: Verify target matches destination
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file1.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file2.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("subdir/file3.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file4.txt").path))

        let file1Content = try String(contentsOf: targetDir.appendingPathComponent("file1.txt"), encoding: .utf8)
        XCTAssertEqual(file1Content, "modified1")

        let file4Content = try String(contentsOf: targetDir.appendingPathComponent("file4.txt"), encoding: .utf8)
        XCTAssertEqual(file4Content, "content4")
    }

    func testApplyAndRevertRoundTrip() async throws {
        // Create source directory
        let sourceDir = tempDir.appendingPathComponent("source")
        try createDirectory(at: "source")
        try createFile(at: "source/original.txt", content: "original content")
        try createFile(at: "source/modified.txt", content: "original version")

        // Create destination directory (with changes)
        let destDir = tempDir.appendingPathComponent("dest")
        try createDirectory(at: "dest")
        try createFile(at: "dest/modified.txt", content: "new version")
        try createFile(at: "dest/added.txt", content: "added content")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Create patch with revert data
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir,
            saveTo: patchURL,
            includeRevertData: true
        )

        // Create target as copy of source
        let targetDir = tempDir.appendingPathComponent("target")
        try fileManager.copyItem(at: sourceDir, to: targetDir)

        // Save original state for verification
        let originalExists = fileManager.fileExists(atPath: targetDir.appendingPathComponent("original.txt").path)
        let originalModified = try String(contentsOf: targetDir.appendingPathComponent("modified.txt"), encoding: .utf8)

        // Apply patch
        try await patch.apply(to: targetDir)

        // Verify applied state (should match destination)
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("original.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("modified.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added.txt").path))

        // Revert patch
        try await patch.revert(on: targetDir)

        // Verify reverted state (should match original source)
        XCTAssertEqual(originalExists, fileManager.fileExists(atPath: targetDir.appendingPathComponent("original.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("modified.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added.txt").path))

        let revertedModified = try String(contentsOf: targetDir.appendingPathComponent("modified.txt"), encoding: .utf8)
        XCTAssertEqual(revertedModified, originalModified)
    }

    func testPatchWithLargeFiles() async throws {
        // Create source with many files
        let sourceDir = tempDir.appendingPathComponent("source")
        try createDirectory(at: "source")

        // Create 1,000 files
        for i in 0..<1000 {
            try createFile(at: "source/file\(i).txt", content: "content \(i)")
        }

        // Create destination with changes (remove some, add some, modify some)
        let destDir = tempDir.appendingPathComponent("dest")
        try fileManager.copyItem(at: sourceDir, to: destDir)

        // Modify 100 files (800-899)
        for i in 800..<900 {
            try createFile(at: "dest/file\(i).txt", content: "modified \(i)")
        }

        // Remove 100 files (900-999)
        for i in 900..<1000 {
            let fileURL = destDir.appendingPathComponent("file\(i).txt")
            try fileManager.removeItem(at: fileURL)
        }

        // Add 100 new files (1000-1099)
        for i in 1000..<1100 {
            try createFile(at: "dest/file\(i).txt", content: "new content \(i)")
        }

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let startSnapshot = Date()
        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)
        let snapshotDuration = Date().timeIntervalSince(startSnapshot)

        print("Snapshot creation time for 1,000 files: \(snapshotDuration)s")

        // Compare and create patch
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)
        let patchURL = tempDir.appendingPathComponent("test.patch")

        let startPatch = Date()
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir,
            saveTo: patchURL,
            includeRevertData: true
        )
        let patchDuration = Date().timeIntervalSince(startPatch)

        print("Patch creation time: \(patchDuration)s")

        // Verify patch operations
        let operations = try patch.loadOperations()
        XCTAssertEqual(operations.count, 300)  // 100 removed + 100 modified + 100 added

        // Apply patch
        let targetDir = tempDir.appendingPathComponent("target")
        try fileManager.copyItem(at: sourceDir, to: targetDir)

        let startApply = Date()
        try await patch.apply(to: targetDir)
        let applyDuration = Date().timeIntervalSince(startApply)

        print("Patch apply time: \(applyDuration)s")

        // Performance check: should complete in reasonable time (<10s total)
        let totalDuration = snapshotDuration + patchDuration + applyDuration
        XCTAssertLessThan(totalDuration, 10.0, "Total operation time should be < 10s")

        // Verify a sample of files
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file0.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file800.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file900.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("file1000.txt").path))

        let modified850 = try String(contentsOf: targetDir.appendingPathComponent("file850.txt"), encoding: .utf8)
        XCTAssertEqual(modified850, "modified 850")
    }

    func testPatchSerialization() async throws {
        // Create source and destination
        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try createDirectory(at: "source")
        try createDirectory(at: "dest")

        try createFile(at: "source/file.txt", content: "original")
        try createFile(at: "dest/file.txt", content: "modified")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Create patch and save to disk
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)
        let patchURL = tempDir.appendingPathComponent("saved.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir,
            saveTo: patchURL,
            includeRevertData: true
        )

        // Verify patch file exists on disk
        XCTAssertTrue(fileManager.fileExists(atPath: patchURL.path))

        // Load patch from disk
        let loadedPatch = try Patch.open(at: patchURL)

        // Verify loaded patch metadata matches
        XCTAssertEqual(loadedPatch.metadata.version, patch.metadata.version)
        XCTAssertEqual(loadedPatch.metadata.operationCount, patch.metadata.operationCount)

        // Verify loaded patch can be applied
        let targetDir = tempDir.appendingPathComponent("target")
        try fileManager.copyItem(at: sourceDir, to: targetDir)

        try await loadedPatch.apply(to: targetDir)

        let fileContent = try String(contentsOf: targetDir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(fileContent, "modified")

        // Verify export functions work on loaded patch
        let text = try loadedPatch.exportAsText()
        XCTAssertTrue(text.contains("M file.txt"))

        let json = try loadedPatch.exportAsJSON()
        XCTAssertTrue(json.contains("\"type\": \"modify\""))
    }

    func testMultiplePatchesSequentially() async throws {
        // Create three separate directories representing three version states
        let options = ScanOptions()

        // State 1: Original
        let v1Dir = tempDir.appendingPathComponent("v1")
        try createDirectory(at: "v1")
        try createFile(at: "v1/file.txt", content: "version 1")

        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot1 = try await engine.createSnapshot(from: v1Dir, saveTo: snapshot1URL, options: options)

        // State 2: First modification
        let v2Dir = tempDir.appendingPathComponent("v2")
        try createDirectory(at: "v2")
        try createFile(at: "v2/file.txt", content: "version 2")
        try createFile(at: "v2/added1.txt", content: "added in v2")

        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let snapshot2 = try await engine.createSnapshot(from: v2Dir, saveTo: snapshot2URL, options: options)

        // State 3: Second modification
        let v3Dir = tempDir.appendingPathComponent("v3")
        try createDirectory(at: "v3")
        try createFile(at: "v3/file.txt", content: "version 3")
        try createFile(at: "v3/added2.txt", content: "added in v3")
        // Note: added1.txt not present (removed)

        let snapshot3URL = tempDir.appendingPathComponent("snapshot3.snapshot")
        let snapshot3 = try await engine.createSnapshot(from: v3Dir, saveTo: snapshot3URL, options: options)

        // Create patch 1->2
        let diff1to2 = try Difference.compare(source: snapshot1, destination: snapshot2)
        let patch1to2URL = tempDir.appendingPathComponent("patch1to2.patch")
        let patch1to2 = try Patch.create(
            from: diff1to2,
            sourceDirectory: v1Dir,
            destinationDirectory: v2Dir,
            saveTo: patch1to2URL,
            includeRevertData: true
        )

        // Create patch 2->3
        let diff2to3 = try Difference.compare(source: snapshot2, destination: snapshot3)
        let patch2to3URL = tempDir.appendingPathComponent("patch2to3.patch")
        let patch2to3 = try Patch.create(
            from: diff2to3,
            sourceDirectory: v2Dir,
            destinationDirectory: v3Dir,
            saveTo: patch2to3URL,
            includeRevertData: true
        )

        // Apply patches sequentially to a clean target starting from v1
        let targetDir = tempDir.appendingPathComponent("target")
        try fileManager.copyItem(at: v1Dir, to: targetDir)

        // Verify initial state (v1)
        var content = try String(contentsOf: targetDir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(content, "version 1")
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added1.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added2.txt").path))

        // Apply patch 1->2
        try await patch1to2.apply(to: targetDir)
        content = try String(contentsOf: targetDir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(content, "version 2")
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added1.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added2.txt").path))

        // Apply patch 2->3
        try await patch2to3.apply(to: targetDir)
        content = try String(contentsOf: targetDir.appendingPathComponent("file.txt"), encoding: .utf8)
        XCTAssertEqual(content, "version 3")
        XCTAssertFalse(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added1.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: targetDir.appendingPathComponent("added2.txt").path))
    }
}
