import XCTest
@testable import Diffa

/// Tests for SyncSyncSnapshotSchema - SQLite schema creation and queries
final class SyncSyncSnapshotSchemaTests: XCTestCase {

    private var tempDir: URL!
    private var dbPath: String!
    private var db: SQLiteDatabase!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncSnapshotSchemaTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        dbPath = tempDir.appendingPathComponent("test.db").path
    }

    override func tearDown() {
        // Explicitly close database before cleanup to avoid file locks on Linux
        try? db?.close()
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func makeHash(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 16)
    }

    // MARK: - Tests

    func testCreateSchema() throws {
        db = try SQLiteDatabase(path: dbPath)
        try SyncSnapshotSchema.createTables(in: db)

        // Verify files table exists
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='files'")
        XCTAssertEqual(tables.count, 1, "files table should exist")

        // Verify metadata table exists
        let metadataTables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='metadata'")
        XCTAssertEqual(metadataTables.count, 1, "metadata table should exist")

        // Verify schema version is set
        let versionRows = try db.query("SELECT value FROM metadata WHERE key = 'schema_version'")
        XCTAssertEqual(versionRows.count, 1)
        let version = try versionRows[0].string(at: 0)
        XCTAssertEqual(version, "1")
    }

    func testHashIndexExists() throws {
        db = try SQLiteDatabase(path: dbPath)
        try SyncSnapshotSchema.createTables(in: db)

        // Verify idx_hash index exists
        let indexes = try db.query("SELECT name FROM sqlite_master WHERE type='index' AND name='idx_hash'")
        XCTAssertEqual(indexes.count, 1, "idx_hash index should exist")

        // Verify index is on hash column
        let indexInfo = try db.query("PRAGMA index_info(idx_hash)")
        XCTAssertEqual(indexInfo.count, 1, "Index should have one column")

        let columnName = try indexInfo[0].string(at: 2)
        XCTAssertEqual(columnName, "hash", "Index should be on hash column")
    }

    func testInsertAndQueryByPath() throws {
        db = try SQLiteDatabase(path: dbPath)
        try SyncSnapshotSchema.createTables(in: db)

        // Insert a file
        let hash = makeHash(0xAA)
        try db.run("""
            INSERT INTO files (path, size, hash, mtime, mode)
            VALUES (?, ?, ?, ?, ?)
        """, [
            .text("photos/vacation.jpg"),
            .integer(2048576),
            .blob(hash),
            .integer(1699459200),
            .integer(0o644)
        ])

        // Query by path
        let rows = try db.query("SELECT size, hash, mtime, mode FROM files WHERE path = ?", [
            .text("photos/vacation.jpg")
        ])

        XCTAssertEqual(rows.count, 1)

        let size = try rows[0].int64(at: 0)
        let retrievedHash = try rows[0].data(at: 1)
        let mtime = try rows[0].int64(at: 2)
        let mode = try rows[0].int64(at: 3)

        XCTAssertEqual(size, 2048576)
        XCTAssertEqual(retrievedHash, hash)
        XCTAssertEqual(mtime, 1699459200)
        XCTAssertEqual(mode, 0o644)
    }

    func testInsertAndQueryByHash() throws {
        db = try SQLiteDatabase(path: dbPath)
        try SyncSnapshotSchema.createTables(in: db)

        let hash = makeHash(0xBB)

        // Insert multiple files with same hash
        try db.run("""
            INSERT INTO files (path, size, hash, mtime, mode)
            VALUES (?, ?, ?, ?, ?)
        """, [
            .text("photos/img1.jpg"),
            .integer(1024),
            .blob(hash),
            .integer(1699459200),
            .integer(0o644)
        ])

        try db.run("""
            INSERT INTO files (path, size, hash, mtime, mode)
            VALUES (?, ?, ?, ?, ?)
        """, [
            .text("photos/img2.jpg"),
            .integer(1024),
            .blob(hash),
            .integer(1699459200),
            .integer(0o644)
        ])

        // Query by hash (should return both files)
        let rows = try db.query("SELECT path FROM files WHERE hash = ? ORDER BY path", [
            .blob(hash)
        ])

        XCTAssertEqual(rows.count, 2, "Should find 2 files with same hash")

        let path1 = try rows[0].string(at: 0)
        let path2 = try rows[1].string(at: 0)

        XCTAssertEqual(path1, "photos/img1.jpg")
        XCTAssertEqual(path2, "photos/img2.jpg")
    }

    func testSchemaVersionVerification() throws {
        db = try SQLiteDatabase(path: dbPath)
        try SyncSnapshotSchema.createTables(in: db)

        // Verify current schema version
        let isCompatible = SyncSnapshotSchema.verifyVersion(in: db)
        XCTAssertTrue(isCompatible, "Current schema version should be compatible")

        // Simulate incompatible version
        try db.run("UPDATE metadata SET value = '999' WHERE key = 'schema_version'")
        let isIncompatible = SyncSnapshotSchema.verifyVersion(in: db)
        XCTAssertFalse(isIncompatible, "Incompatible schema version should fail verification")
    }

    func testVerifyVersionGracefullyHandlesLegacySnapshot() throws {
        db = try SQLiteDatabase(path: dbPath)

        // Create database with files table but no metadata table (legacy format)
        try db.execute("""
            CREATE TABLE files (
                path TEXT PRIMARY KEY NOT NULL,
                size INTEGER NOT NULL,
                hash BLOB NOT NULL,
                mtime INTEGER NOT NULL,
                mode INTEGER
            );
        """)

        // Should return false instead of throwing
        let isCompatible = SyncSnapshotSchema.verifyVersion(in: db)
        XCTAssertFalse(isCompatible, "Legacy snapshot without metadata table should return false")
    }

    func testIdempotentSchemaCreation() throws {
        db = try SQLiteDatabase(path: dbPath)

        // Create schema multiple times (should not error)
        try SyncSnapshotSchema.createTables(in: db)
        try SyncSnapshotSchema.createTables(in: db)
        try SyncSnapshotSchema.createTables(in: db)

        // Verify only one files table exists
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='files'")
        XCTAssertEqual(tables.count, 1, "Should only have one files table despite multiple creations")
    }

    func testNullModeHandling() throws {
        db = try SQLiteDatabase(path: dbPath)
        try SyncSnapshotSchema.createTables(in: db)

        let hash = makeHash(0xCC)

        // Insert file with NULL mode (optional on some filesystems)
        try db.run("""
            INSERT INTO files (path, size, hash, mtime, mode)
            VALUES (?, ?, ?, ?, ?)
        """, [
            .text("file_without_mode.txt"),
            .integer(512),
            .blob(hash),
            .integer(1699459200),
            .null
        ])

        // Query and verify NULL mode
        let rows = try db.query("SELECT mode FROM files WHERE path = ?", [
            .text("file_without_mode.txt")
        ])

        XCTAssertEqual(rows.count, 1)

        let value = try rows[0].value(at: 0)
        if case .null = value {
            // Expected: mode is NULL
        } else {
            XCTFail("Mode should be NULL")
        }
    }
}
