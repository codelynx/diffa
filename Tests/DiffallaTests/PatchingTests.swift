import XCTest
@testable import Diffalla
import Foundation

/// Tests for patch operations and metadata
final class PatchingTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!
    var engine: SnapshotEngine!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        engine = SnapshotEngine()

        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffallaPatchingTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helper Methods

    /// Create a test file with content
    private func createFile(at path: String, content: String) throws {
        let url = tempDir.appendingPathComponent(path)
        let parentDir = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Create a test directory
    private func createDirectory(at path: String) throws {
        let url = tempDir.appendingPathComponent(path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - PatchSchema Tests

    func testCreateEmptyPatch() throws {
        // Create a temporary database
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test_patch_\(UUID().uuidString).db")

        // Ensure cleanup
        defer {
            try? FileManager.default.removeItem(at: dbURL)
        }

        // Create database with patch schema
        let db = try SQLiteDatabase(path: dbURL.path)
        try PatchSchema.createTables(in: db)

        // Verify tables exist
        XCTAssertTrue(try db.tableExists("schema_version"))
        XCTAssertTrue(try db.tableExists("metadata"))
        XCTAssertTrue(try db.tableExists("operations"))
        XCTAssertTrue(try db.tableExists("revert_data"))
    }

    func testSchemaVersion() throws {
        // Create a temporary database
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test_patch_\(UUID().uuidString).db")

        // Ensure cleanup
        defer {
            try? FileManager.default.removeItem(at: dbURL)
        }

        // Create database with patch schema
        let db = try SQLiteDatabase(path: dbURL.path)
        try PatchSchema.createTables(in: db)

        // Verify schema version
        XCTAssertTrue(try PatchSchema.verifyVersion(in: db))

        // Verify version number is 1
        let rows = try db.query("SELECT version FROM schema_version LIMIT 1")
        let version = try rows.first?.int64(at: 0)
        XCTAssertEqual(version, 1)
    }

    func testTablesExist() throws {
        // Create a temporary database
        let tempDir = FileManager.default.temporaryDirectory
        let dbURL = tempDir.appendingPathComponent("test_patch_\(UUID().uuidString).db")

        // Ensure cleanup
        defer {
            try? FileManager.default.removeItem(at: dbURL)
        }

        // Create database with patch schema
        let db = try SQLiteDatabase(path: dbURL.path)
        try PatchSchema.createTables(in: db)

        // Verify all required tables exist
        XCTAssertTrue(try db.tableExists("schema_version"))
        XCTAssertTrue(try db.tableExists("metadata"))
        XCTAssertTrue(try db.tableExists("operations"))
        XCTAssertTrue(try db.tableExists("revert_data"))

        // Verify index exists by querying sqlite_master
        let indexRows = try db.query(
            "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_operations_sequence'"
        )
        XCTAssertEqual(indexRows.count, 1, "Index idx_operations_sequence should exist")
    }

    // MARK: - PatchOperation Tests

    func testPatchOperationCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test add operation
        let addOp = PatchOperation.add(path: "test/file.txt", isFolder: false)
        let addData = try encoder.encode(addOp)
        let decodedAdd = try decoder.decode(PatchOperation.self, from: addData)
        XCTAssertEqual(addOp, decodedAdd)

        // Test remove operation
        let removeOp = PatchOperation.remove(path: "old/file.txt", isFolder: false)
        let removeData = try encoder.encode(removeOp)
        let decodedRemove = try decoder.decode(PatchOperation.self, from: removeData)
        XCTAssertEqual(removeOp, decodedRemove)

        // Test modify operation
        let modifyOp = PatchOperation.modify(path: "changed/file.txt", isFolder: false)
        let modifyData = try encoder.encode(modifyOp)
        let decodedModify = try decoder.decode(PatchOperation.self, from: modifyData)
        XCTAssertEqual(modifyOp, decodedModify)

        // Test move operation
        let moveOp = PatchOperation.move(from: "old/path.txt", to: "new/path.txt", isFolder: false)
        let moveData = try encoder.encode(moveOp)
        let decodedMove = try decoder.decode(PatchOperation.self, from: moveData)
        XCTAssertEqual(moveOp, decodedMove)
    }

    func testPatchOperationCodableFolder() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Test add folder
        let addFolder = PatchOperation.add(path: "test/folder", isFolder: true)
        let addData = try encoder.encode(addFolder)
        let decodedAdd = try decoder.decode(PatchOperation.self, from: addData)
        XCTAssertEqual(addFolder, decodedAdd)

        // Test remove folder
        let removeFolder = PatchOperation.remove(path: "old/folder", isFolder: true)
        let removeData = try encoder.encode(removeFolder)
        let decodedRemove = try decoder.decode(PatchOperation.self, from: removeData)
        XCTAssertEqual(removeFolder, decodedRemove)

        // Test move folder
        let moveFolder = PatchOperation.move(from: "old/folder", to: "new/folder", isFolder: true)
        let moveData = try encoder.encode(moveFolder)
        let decodedMove = try decoder.decode(PatchOperation.self, from: moveData)
        XCTAssertEqual(moveFolder, decodedMove)
    }

    func testPatchOperationEquality() throws {
        // Test add equality
        let add1 = PatchOperation.add(path: "file.txt", isFolder: false)
        let add2 = PatchOperation.add(path: "file.txt", isFolder: false)
        let add3 = PatchOperation.add(path: "other.txt", isFolder: false)
        XCTAssertEqual(add1, add2)
        XCTAssertNotEqual(add1, add3)

        // Test remove equality
        let remove1 = PatchOperation.remove(path: "file.txt", isFolder: false)
        let remove2 = PatchOperation.remove(path: "file.txt", isFolder: false)
        let remove3 = PatchOperation.remove(path: "file.txt", isFolder: true)
        XCTAssertEqual(remove1, remove2)
        XCTAssertNotEqual(remove1, remove3)  // Different isFolder

        // Test modify equality
        let modify1 = PatchOperation.modify(path: "file.txt", isFolder: false)
        let modify2 = PatchOperation.modify(path: "file.txt", isFolder: false)
        let modify3 = PatchOperation.modify(path: "other.txt", isFolder: false)
        XCTAssertEqual(modify1, modify2)
        XCTAssertNotEqual(modify1, modify3)

        // Test move equality
        let move1 = PatchOperation.move(from: "a.txt", to: "b.txt", isFolder: false)
        let move2 = PatchOperation.move(from: "a.txt", to: "b.txt", isFolder: false)
        let move3 = PatchOperation.move(from: "a.txt", to: "c.txt", isFolder: false)
        XCTAssertEqual(move1, move2)
        XCTAssertNotEqual(move1, move3)

        // Test different operation types are not equal
        let addOp = PatchOperation.add(path: "file.txt", isFolder: false)
        let removeOp = PatchOperation.remove(path: "file.txt", isFolder: false)
        XCTAssertNotEqual(addOp, removeOp)
    }

    func testPatchOperationPath() throws {
        // Test path property for each operation type
        let addOp = PatchOperation.add(path: "test/file.txt", isFolder: false)
        XCTAssertEqual(addOp.path, "test/file.txt")

        let removeOp = PatchOperation.remove(path: "old/file.txt", isFolder: false)
        XCTAssertEqual(removeOp.path, "old/file.txt")

        let modifyOp = PatchOperation.modify(path: "changed/file.txt", isFolder: false)
        XCTAssertEqual(modifyOp.path, "changed/file.txt")

        // Move operation returns destination path
        let moveOp = PatchOperation.move(from: "old/path.txt", to: "new/path.txt", isFolder: false)
        XCTAssertEqual(moveOp.path, "new/path.txt")
    }

    func testPatchOperationIsFolder() throws {
        // Test isFolder property for each operation type
        let addFile = PatchOperation.add(path: "file.txt", isFolder: false)
        XCTAssertFalse(addFile.isFolder)

        let addFolder = PatchOperation.add(path: "folder", isFolder: true)
        XCTAssertTrue(addFolder.isFolder)

        let removeFile = PatchOperation.remove(path: "file.txt", isFolder: false)
        XCTAssertFalse(removeFile.isFolder)

        let removeFolder = PatchOperation.remove(path: "folder", isFolder: true)
        XCTAssertTrue(removeFolder.isFolder)

        // Test modify with files and folders
        let modifyFile = PatchOperation.modify(path: "file.txt", isFolder: false)
        XCTAssertFalse(modifyFile.isFolder)

        let modifyFolder = PatchOperation.modify(path: "folder", isFolder: true)
        XCTAssertTrue(modifyFolder.isFolder)

        let moveFile = PatchOperation.move(from: "a.txt", to: "b.txt", isFolder: false)
        XCTAssertFalse(moveFile.isFolder)

        let moveFolder = PatchOperation.move(from: "a", to: "b", isFolder: true)
        XCTAssertTrue(moveFolder.isFolder)
    }

    func testPatchOperationType() throws {
        // Test operationType property
        let addOp = PatchOperation.add(path: "file.txt", isFolder: false)
        XCTAssertEqual(addOp.operationType, "add")

        let removeOp = PatchOperation.remove(path: "file.txt", isFolder: false)
        XCTAssertEqual(removeOp.operationType, "remove")

        let modifyOp = PatchOperation.modify(path: "file.txt", isFolder: false)
        XCTAssertEqual(modifyOp.operationType, "modify")

        let moveOp = PatchOperation.move(from: "a.txt", to: "b.txt", isFolder: false)
        XCTAssertEqual(moveOp.operationType, "move")
    }

    // MARK: - PatchMetadata Tests

    func testPatchMetadataCreation() throws {
        let now = Date()
        let metadata = PatchMetadata(
            version: 1,
            createdDate: now,
            sourceChecksum: "abc123",
            targetChecksum: "def456",
            operationCount: 10
        )

        XCTAssertEqual(metadata.version, 1)
        XCTAssertEqual(metadata.createdDate, now)
        XCTAssertEqual(metadata.sourceChecksum, "abc123")
        XCTAssertEqual(metadata.targetChecksum, "def456")
        XCTAssertEqual(metadata.operationCount, 10)
    }

    func testPatchMetadataOptionalChecksums() throws {
        let now = Date()
        let metadata = PatchMetadata(
            version: 1,
            createdDate: now,
            operationCount: 5
        )

        XCTAssertEqual(metadata.version, 1)
        XCTAssertEqual(metadata.createdDate, now)
        XCTAssertNil(metadata.sourceChecksum)
        XCTAssertNil(metadata.targetChecksum)
        XCTAssertEqual(metadata.operationCount, 5)
    }

    func testPatchMetadataCodable() throws {
        let now = Date()
        let metadata = PatchMetadata(
            version: 1,
            createdDate: now,
            sourceChecksum: "abc123",
            targetChecksum: "def456",
            operationCount: 10
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(PatchMetadata.self, from: data)

        XCTAssertEqual(metadata, decoded)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.sourceChecksum, "abc123")
        XCTAssertEqual(decoded.targetChecksum, "def456")
        XCTAssertEqual(decoded.operationCount, 10)
    }

    func testPatchMetadataEquality() throws {
        let now = Date()

        let metadata1 = PatchMetadata(
            version: 1,
            createdDate: now,
            sourceChecksum: "abc",
            targetChecksum: "def",
            operationCount: 5
        )

        let metadata2 = PatchMetadata(
            version: 1,
            createdDate: now,
            sourceChecksum: "abc",
            targetChecksum: "def",
            operationCount: 5
        )

        let metadata3 = PatchMetadata(
            version: 2,  // Different version
            createdDate: now,
            sourceChecksum: "abc",
            targetChecksum: "def",
            operationCount: 5
        )

        XCTAssertEqual(metadata1, metadata2)
        XCTAssertNotEqual(metadata1, metadata3)
    }

    // MARK: - Patch Creation Tests

    func testCreatePatchFromEmptyDiff() async throws {
        // Create identical directories
        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try createDirectory(at: "dir1")
        try createDirectory(at: "dir2")
        try createFile(at: "dir1/file.txt", content: "content")
        try createFile(at: "dir2/file.txt", content: "content")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir2, saveTo: snapshot2URL, options: options)

        // Compare snapshots (should be identical)
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Create patch
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: dir1,
            destinationDirectory: dir2,
            saveTo: patchURL
        )

        // Verify metadata
        XCTAssertEqual(patch.metadata.operationCount, 0)
        XCTAssertEqual(patch.metadata.version, 1)

        // Verify operations
        let operations = try patch.loadOperations()
        XCTAssertEqual(operations.count, 0)
    }

    func testCreatePatchWithAdded() async throws {
        // Create source directory (empty)
        let dir1 = tempDir.appendingPathComponent("dir1")
        try createDirectory(at: "dir1")

        // Create destination directory (with files)
        let dir2 = tempDir.appendingPathComponent("dir2")
        try createDirectory(at: "dir2")
        try createFile(at: "dir2/file1.txt", content: "content1")
        try createFile(at: "dir2/file2.txt", content: "content2")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir2, saveTo: snapshot2URL, options: options)

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Create patch
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: dir1,
            destinationDirectory: dir2,
            saveTo: patchURL
        )

        // Verify metadata
        XCTAssertEqual(patch.metadata.operationCount, 2)

        // Verify operations
        let operations = try patch.loadOperations()
        XCTAssertEqual(operations.count, 2)

        // All operations should be add
        for operation in operations {
            XCTAssertEqual(operation.operationType, "add")
            XCTAssertFalse(operation.isFolder)
        }
    }

    func testCreatePatchWithRemoved() async throws {
        // Create source directory (with files)
        let dir1 = tempDir.appendingPathComponent("dir1")
        try createDirectory(at: "dir1")
        try createFile(at: "dir1/file1.txt", content: "content1")
        try createFile(at: "dir1/file2.txt", content: "content2")

        // Create destination directory (empty)
        let dir2 = tempDir.appendingPathComponent("dir2")
        try createDirectory(at: "dir2")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir2, saveTo: snapshot2URL, options: options)

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Create patch
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: dir1,
            destinationDirectory: dir2,
            saveTo: patchURL
        )

        // Verify metadata
        XCTAssertEqual(patch.metadata.operationCount, 2)

        // Verify operations
        let operations = try patch.loadOperations()
        XCTAssertEqual(operations.count, 2)

        // All operations should be remove
        for operation in operations {
            XCTAssertEqual(operation.operationType, "remove")
            XCTAssertFalse(operation.isFolder)
        }
    }

    func testCreatePatchWithModified() async throws {
        // Create source directory
        let dir1 = tempDir.appendingPathComponent("dir1")
        try createDirectory(at: "dir1")
        try createFile(at: "dir1/file.txt", content: "original")

        // Create destination directory (modified content)
        let dir2 = tempDir.appendingPathComponent("dir2")
        try createDirectory(at: "dir2")
        try createFile(at: "dir2/file.txt", content: "modified")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir2, saveTo: snapshot2URL, options: options)

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Create patch
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: dir1,
            destinationDirectory: dir2,
            saveTo: patchURL
        )

        // Verify metadata
        XCTAssertEqual(patch.metadata.operationCount, 1)

        // Verify operations
        let operations = try patch.loadOperations()
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0].operationType, "modify")
        XCTAssertEqual(operations[0].path, "file.txt")
    }

    func testCreatePatchWithMixed() async throws {
        // Create source directory
        let dir1 = tempDir.appendingPathComponent("dir1")
        try createDirectory(at: "dir1")
        try createFile(at: "dir1/file1.txt", content: "original")
        try createFile(at: "dir1/old.txt", content: "to be removed")

        // Create destination directory
        let dir2 = tempDir.appendingPathComponent("dir2")
        try createDirectory(at: "dir2")
        try createFile(at: "dir2/file1.txt", content: "modified")
        try createFile(at: "dir2/new.txt", content: "new file")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir2, saveTo: snapshot2URL, options: options)

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Create patch
        let patchURL = tempDir.appendingPathComponent("test.patch")
        let patch = try Patch.create(
            from: difference,
            sourceDirectory: dir1,
            destinationDirectory: dir2,
            saveTo: patchURL
        )

        // Verify metadata
        XCTAssertEqual(patch.metadata.operationCount, 3)

        // Verify operations
        let operations = try patch.loadOperations()
        XCTAssertEqual(operations.count, 3)

        // Check operation types (at least one of each)
        let types = operations.map { $0.operationType }
        XCTAssertTrue(types.contains("add"))
        XCTAssertTrue(types.contains("remove"))
        XCTAssertTrue(types.contains("modify"))
    }

    func testLoadOperations() async throws {
        // Create test directories
        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try createDirectory(at: "dir1")
        try createDirectory(at: "dir2")
        try createFile(at: "dir2/file.txt", content: "content")

        // Create snapshots
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.snapshot")
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.snapshot")
        let options = ScanOptions()

        let snapshot1 = try await engine.createSnapshot(from: dir1, saveTo: snapshot1URL, options: options)
        let snapshot2 = try await engine.createSnapshot(from: dir2, saveTo: snapshot2URL, options: options)

        // Compare and create patch
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)
        let patchURL = tempDir.appendingPathComponent("test.patch")
        _ = try Patch.create(
            from: difference,
            sourceDirectory: dir1,
            destinationDirectory: dir2,
            saveTo: patchURL
        )

        // Open patch and load operations
        let loadedPatch = try Patch.open(at: patchURL)
        let operations = try loadedPatch.loadOperations()

        // Verify operations loaded correctly
        XCTAssertEqual(operations.count, 1)
        XCTAssertEqual(operations[0].operationType, "add")
        XCTAssertEqual(operations[0].path, "file.txt")
    }
}
