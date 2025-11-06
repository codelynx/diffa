import XCTest
@testable import Diffalla

final class SynchronizationTests: XCTestCase {

    // MARK: - Step 1: Sync Core Types Tests

    func testSyncProgressCreation() {
        // Create a SyncProgress instance
        let progress = SyncProgress(
            currentOperation: "Copying file.txt",
            filesProcessed: 10,
            totalFiles: 100,
            bytesTransferred: 1024,
            totalBytes: 10240,
            operationType: .copying
        )

        // Verify all properties
        XCTAssertEqual(progress.currentOperation, "Copying file.txt")
        XCTAssertEqual(progress.filesProcessed, 10)
        XCTAssertEqual(progress.totalFiles, 100)
        XCTAssertEqual(progress.bytesTransferred, 1024)
        XCTAssertEqual(progress.totalBytes, 10240)
        XCTAssertEqual(progress.operationType, .copying)
    }

    func testOperationTypeCodable() throws {
        // Test all operation types can be encoded/decoded
        let types: [OperationType] = [.comparing, .copying, .deleting, .moving]

        for type in types {
            // Encode
            let encoder = JSONEncoder()
            let data = try encoder.encode(type)

            // Decode
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(OperationType.self, from: data)

            // Verify
            XCTAssertEqual(decoded, type, "OperationType \(type) should round-trip correctly")
        }
    }

    func testSyncResultCreation() {
        // Create a SyncResult instance
        let result = SyncResult(
            filesCopied: 5,
            filesDeleted: 3,
            filesMoved: 2,
            bytesTransferred: 5120,
            conflicts: [],
            duration: 1.5,
            errors: []
        )

        // Verify all properties
        XCTAssertEqual(result.filesCopied, 5)
        XCTAssertEqual(result.filesDeleted, 3)
        XCTAssertEqual(result.filesMoved, 2)
        XCTAssertEqual(result.bytesTransferred, 5120)
        XCTAssertEqual(result.conflicts.count, 0)
        XCTAssertEqual(result.duration, 1.5)
        XCTAssertEqual(result.errors.count, 0)
    }

    func testConflictCreation() {
        // Create mock SnapshotItems
        let sourceItem = SnapshotItem(
            id: 1,
            parentId: nil,
            path: "file.txt",
            name: "file.txt",
            isFolder: false,
            size: 100,
            modificationDate: Date(),
            permissions: FilePermissions(posix: 0o644),
            owner: nil,
            group: nil,
            sha256: "source-hash"
        )

        let destItem = SnapshotItem(
            id: 2,
            parentId: nil,
            path: "file.txt",
            name: "file.txt",
            isFolder: false,
            size: 200,
            modificationDate: Date(),
            permissions: FilePermissions(posix: 0o644),
            owner: nil,
            group: nil,
            sha256: "dest-hash"
        )

        // Create a conflict
        let conflict = Conflict(
            path: "file.txt",
            type: .diverged,
            sourceItem: sourceItem,
            destinationItem: destItem
        )

        // Verify properties
        XCTAssertEqual(conflict.path, "file.txt")
        XCTAssertEqual(conflict.type, .diverged)
        XCTAssertNotNil(conflict.sourceItem)
        XCTAssertNotNil(conflict.destinationItem)
        XCTAssertEqual(conflict.sourceItem?.sha256, "source-hash")
        XCTAssertEqual(conflict.destinationItem?.sha256, "dest-hash")
    }

    // MARK: - Step 2: Sync Plan & Operations Tests

    func testPlanUnidirectionalWithAdded() async throws {
        // Items only in destination should be DELETED for unidirectional sync
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file only in destination
        let destFile = destDir.appendingPathComponent("extra.txt")
        try "extra content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should plan to delete the extra file in destination
        XCTAssertEqual(operations.count, 1)
        if case .deleteFile(let path) = operations[0] {
            XCTAssertTrue(path.path.hasSuffix("extra.txt"))
        } else {
            XCTFail("Expected deleteFile operation")
        }
    }

    func testPlanUnidirectionalWithRemoved() async throws {
        // Items only in source should be COPIED to destination for unidirectional sync
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file only in source
        let sourceFile = sourceDir.appendingPathComponent("new.txt")
        try "new content".write(to: sourceFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should plan to copy the new file from source to destination
        XCTAssertEqual(operations.count, 1)
        if case .copyFile(let from, let to, let size) = operations[0] {
            XCTAssertTrue(from.path.hasSuffix("new.txt"))
            XCTAssertTrue(to.path.hasSuffix("new.txt"))
            XCTAssertGreaterThan(size, 0)
        } else {
            XCTFail("Expected copyFile operation")
        }
    }

    func testPlanUnidirectionalWithModified() async throws {
        // Modified items should be COPIED from source to destination
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Create file in both with different content
        let sourceFile = sourceDir.appendingPathComponent("modified.txt")
        try "source content".write(to: sourceFile, atomically: true, encoding: .utf8)

        let destFile = destDir.appendingPathComponent("modified.txt")
        try "dest content".write(to: destFile, atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should plan to copy the modified file from source to destination
        XCTAssertEqual(operations.count, 1)
        if case .copyFile(let from, let to, let size) = operations[0] {
            XCTAssertTrue(from.path.hasSuffix("modified.txt"))
            XCTAssertTrue(to.path.hasSuffix("modified.txt"))
            XCTAssertGreaterThan(size, 0)
        } else {
            XCTFail("Expected copyFile operation")
        }
    }

    func testPlanUnidirectionalWithMixed() async throws {
        // Test all operation types together
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceDir = tempDir.appendingPathComponent("source")
        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Source: new.txt, modified.txt
        try "new".write(to: sourceDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try "source modified".write(to: sourceDir.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)

        // Dest: extra.txt, modified.txt
        try "extra".write(to: destDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try "dest modified".write(to: destDir.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")

        let engine = SnapshotEngine()
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: sourceDir, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: destDir, saveTo: snapshot2URL, options: options)

        // Compare
        let diff = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Plan unidirectional sync
        let planner = SyncPlanner()
        let operations = try planner.planUnidirectional(
            difference: diff,
            sourceDirectory: sourceDir,
            destinationDirectory: destDir
        )

        // Should have:
        // - 1 copyFile for new.txt (from source)
        // - 1 deleteFile for extra.txt (from dest)
        // - 1 copyFile for modified.txt (update from source)
        XCTAssertEqual(operations.count, 3)

        var hasCopyNew = false
        var hasDeleteExtra = false
        var hasCopyModified = false

        for op in operations {
            switch op {
            case .copyFile(let from, _, _):
                if from.path.hasSuffix("new.txt") {
                    hasCopyNew = true
                } else if from.path.hasSuffix("modified.txt") {
                    hasCopyModified = true
                }
            case .deleteFile(let at):
                if at.path.hasSuffix("extra.txt") {
                    hasDeleteExtra = true
                }
            default:
                break
            }
        }

        XCTAssertTrue(hasCopyNew, "Should copy new.txt from source")
        XCTAssertTrue(hasDeleteExtra, "Should delete extra.txt from dest")
        XCTAssertTrue(hasCopyModified, "Should copy modified.txt from source")
    }

    func testCalculateTotalBytes() {
        // Create some operations
        let operations: [SyncOperation] = [
            .copyFile(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/b"), size: 100),
            .deleteFile(at: URL(fileURLWithPath: "/c")),
            .copyFile(from: URL(fileURLWithPath: "/d"), to: URL(fileURLWithPath: "/e"), size: 200),
            .createDirectory(at: URL(fileURLWithPath: "/f")),
            .copyFile(from: URL(fileURLWithPath: "/g"), to: URL(fileURLWithPath: "/h"), size: 50),
        ]

        let planner = SyncPlanner()
        let totalBytes = planner.calculateTotalBytes(operations: operations)

        // Should sum only copyFile sizes: 100 + 200 + 50 = 350
        XCTAssertEqual(totalBytes, 350)
    }
}
