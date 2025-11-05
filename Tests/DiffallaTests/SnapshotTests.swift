import XCTest
@testable import Diffalla
import Foundation

final class SnapshotTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        // Create unique temp directory for each test
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffallaSnapshotTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temp directory
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Snapshot Creation Tests

    func testCreateEmptySnapshot() throws {
        let snapshotURL = tempDir.appendingPathComponent("test.snapshot")
        let rootPath = "/test/path"

        // Create snapshot
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: rootPath)

        // Verify snapshot properties
        XCTAssertEqual(snapshot.databaseURL, snapshotURL)
        XCTAssertEqual(snapshot.rootPath, rootPath)
        XCTAssertEqual(snapshot.metadata.totalFiles, 0)
        XCTAssertEqual(snapshot.metadata.totalFolders, 0)
        XCTAssertEqual(snapshot.metadata.totalSize, 0)
        XCTAssertEqual(snapshot.metadata.version, 1)

        // Verify database file exists
        XCTAssertTrue(fileManager.fileExists(atPath: snapshotURL.path))

        // Verify tables exist
        let db = snapshot.database
        XCTAssertTrue(try db.tableExists("schema_version"))
        XCTAssertTrue(try db.tableExists("metadata"))
        XCTAssertTrue(try db.tableExists("items"))
    }

    func testOpenExistingSnapshot() throws {
        let snapshotURL = tempDir.appendingPathComponent("existing.snapshot")
        let rootPath = "/existing/path"

        // Create snapshot
        let created = try Snapshot.create(at: snapshotURL, rootPath: rootPath)
        let createdDate = created.createdDate

        // Open existing snapshot
        let opened = try Snapshot.open(at: snapshotURL)

        // Verify metadata matches
        XCTAssertEqual(opened.databaseURL, snapshotURL)
        XCTAssertEqual(opened.rootPath, rootPath)
        XCTAssertEqual(opened.metadata.totalFiles, 0)
        XCTAssertEqual(opened.metadata.totalFolders, 0)
        XCTAssertEqual(opened.metadata.totalSize, 0)
        XCTAssertEqual(opened.metadata.version, 1)

        // Dates should match (within 1 second due to ISO8601 formatting)
        let timeDiff = abs(opened.createdDate.timeIntervalSince(createdDate))
        XCTAssertLessThan(timeDiff, 1.0)
    }

    func testOpenNonexistentSnapshot() {
        let snapshotURL = tempDir.appendingPathComponent("nonexistent.snapshot")

        // Should throw error when opening nonexistent file
        XCTAssertThrowsError(try Snapshot.open(at: snapshotURL)) { error in
            // Verify it's the right error type
            XCTAssertTrue(error is SnapshotError)
        }

        // IMPORTANT: Verify no file was created
        XCTAssertFalse(fileManager.fileExists(atPath: snapshotURL.path),
                      "Opening nonexistent snapshot should not create a file")
    }

    // MARK: - Schema Version Tests

    func testSchemaVersion() throws {
        let snapshotURL = tempDir.appendingPathComponent("version.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: "/test")

        // Verify schema version
        XCTAssertEqual(snapshot.metadata.version, 1)

        // Verify version in database
        let db = snapshot.database
        let rows = try db.query("SELECT version FROM schema_version")
        XCTAssertFalse(rows.isEmpty)
        let version = try rows[0].int64(at: 0)
        XCTAssertEqual(version, 1)
    }

    func testSchemaVersionVerification() throws {
        let snapshotURL = tempDir.appendingPathComponent("verify.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: "/test")

        // Verify version check returns true
        let isValid = try SnapshotSchema.verifyVersion(in: snapshot.database)
        XCTAssertTrue(isValid)
    }

    // MARK: - Metadata Tests

    func testMetadataStructure() throws {
        let snapshotURL = tempDir.appendingPathComponent("metadata.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: "/test/metadata")

        // Query metadata directly from database
        let db = snapshot.database
        let rows = try db.query("SELECT root_path, created_date, total_files, total_folders, total_size FROM metadata")
        XCTAssertFalse(rows.isEmpty)
        let row = rows[0]

        let rootPath = try row.string(at: 0)!
        let createdDate = try row.string(at: 1)!
        let totalFiles = try row.int64(at: 2)
        let totalFolders = try row.int64(at: 3)
        let totalSize = try row.int64(at: 4)

        XCTAssertEqual(rootPath, "/test/metadata")
        XCTAssertFalse(createdDate.isEmpty)
        XCTAssertEqual(totalFiles, 0)
        XCTAssertEqual(totalFolders, 0)
        XCTAssertEqual(totalSize, 0)
    }

    // MARK: - Table Structure Tests

    func testItemsTableStructure() throws {
        let snapshotURL = tempDir.appendingPathComponent("items.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: "/test")

        let db = snapshot.database

        // Verify items table has correct columns
        let rows = try db.query("PRAGMA table_info(items)")

        var columnNames: [String] = []
        for row in rows {
            if let name = try row.string(at: 1) { // Column 1 is the name
                columnNames.append(name)
            }
        }

        // Verify expected columns exist
        XCTAssertTrue(columnNames.contains("id"))
        XCTAssertTrue(columnNames.contains("parent_id"))
        XCTAssertTrue(columnNames.contains("path"))
        XCTAssertTrue(columnNames.contains("name"))
        XCTAssertTrue(columnNames.contains("is_folder"))
        XCTAssertTrue(columnNames.contains("size"))
        XCTAssertTrue(columnNames.contains("modification_date"))
        XCTAssertTrue(columnNames.contains("permissions"))
        XCTAssertTrue(columnNames.contains("owner"))
        XCTAssertTrue(columnNames.contains("group_name"))
        XCTAssertTrue(columnNames.contains("sha256"))
    }

    func testIndexesExist() throws {
        let snapshotURL = tempDir.appendingPathComponent("indexes.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: "/test")

        let db = snapshot.database

        // Query for indexes
        let rows = try db.query("SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'")

        var indexNames: [String] = []
        for row in rows {
            if let name = try row.string(at: 0) {
                indexNames.append(name)
            }
        }

        // Verify expected indexes exist
        XCTAssertTrue(indexNames.contains("idx_items_path"))
        XCTAssertTrue(indexNames.contains("idx_items_parent"))
        XCTAssertTrue(indexNames.contains("idx_items_sha256"))
    }

    // MARK: - Date Format Tests

    func testDateFormatISO8601() throws {
        let snapshotURL = tempDir.appendingPathComponent("date.snapshot")
        let snapshot = try Snapshot.create(at: snapshotURL, rootPath: "/test")

        // Verify created date can be parsed back
        let createdDate = snapshot.createdDate

        // Re-open and verify date matches
        let reopened = try Snapshot.open(at: snapshotURL)
        let timeDiff = abs(reopened.createdDate.timeIntervalSince(createdDate))
        XCTAssertLessThan(timeDiff, 1.0) // ISO8601 should be within 1 second
    }

    // MARK: - SnapshotMetadata Codable Tests

    func testSnapshotMetadataCodable() throws {
        let metadata = SnapshotMetadata(
            totalFiles: 100,
            totalFolders: 10,
            totalSize: 1024000,
            version: 1
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SnapshotMetadata.self, from: data)

        // Verify
        XCTAssertEqual(decoded.totalFiles, 100)
        XCTAssertEqual(decoded.totalFolders, 10)
        XCTAssertEqual(decoded.totalSize, 1024000)
        XCTAssertEqual(decoded.version, 1)
    }
}
