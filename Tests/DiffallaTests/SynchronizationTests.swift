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
}
