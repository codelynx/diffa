import XCTest
@testable import Diffa

final class SQLiteDatabaseTests: XCTestCase {
    var tempURL: URL!
    var db: SQLiteDatabase!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("diffa")
        db = try! SQLiteDatabase(path: tempURL.path)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: - Basic Operations

    func testDatabaseCreation() throws {
        // Database should be created and opened
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testCreateTable() throws {
        try db.execute("""
            CREATE TABLE test (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL
            )
        """)

        // Verify table exists
        XCTAssertTrue(try db.tableExists("test"))
    }

    func testTableExists() throws {
        XCTAssertFalse(try db.tableExists("nonexistent"))

        try db.execute("CREATE TABLE test (id INTEGER)")
        XCTAssertTrue(try db.tableExists("test"))
    }

    // MARK: - Insert and Query

    func testInsertAndQuery() throws {
        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")

        // Insert with positional parameters
        try db.run(
            "INSERT INTO users (name, age) VALUES (?, ?)",
            [.text("Alice"), .integer(30)]
        )

        XCTAssertEqual(db.lastInsertRowID, 1)
        XCTAssertEqual(db.changes, 1)

        // Query
        let rows = try db.query("SELECT name, age FROM users WHERE id = ?", [.integer(1)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].string(at: 0), "Alice")
        XCTAssertEqual(try rows[0].int64(at: 1), 30)
    }

    func testNamedParameters() throws {
        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")

        // Insert with named parameters
        try db.run(
            "INSERT INTO users (name, age) VALUES (:name, :age)",
            ["name": .text("Bob"), "age": .integer(25)]
        )

        // Query with named parameters
        let rows = try db.query(
            "SELECT name, age FROM users WHERE name = :name",
            ["name": .text("Bob")]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try rows[0].string(at: 0), "Bob")
        XCTAssertEqual(try rows[0].int64(at: 1), 25)
    }

    // MARK: - Data Types

    func testIntegerType() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)")
        try db.run("INSERT INTO test (value) VALUES (?)", [.integer(42)])

        let rows = try db.query("SELECT value FROM test")
        XCTAssertEqual(try rows[0].int64(at: 0), 42)
        XCTAssertEqual(try rows[0].int(at: 0), 42)
    }

    func testRealType() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value REAL)")
        try db.run("INSERT INTO test (value) VALUES (?)", [.real(3.14)])

        let rows = try db.query("SELECT value FROM test")
        XCTAssertEqual(try rows[0].double(at: 0), 3.14, accuracy: 0.001)
    }

    func testTextType() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")
        try db.run("INSERT INTO test (value) VALUES (?)", [.text("Hello, World!")])

        let rows = try db.query("SELECT value FROM test")
        XCTAssertEqual(try rows[0].string(at: 0), "Hello, World!")
    }

    func testBlobType() throws {
        try db.execute("CREATE TABLE files (id INTEGER PRIMARY KEY, content BLOB)")

        let testData = "Hello, World!".data(using: .utf8)!
        try db.run("INSERT INTO files (content) VALUES (?)", [.blob(testData)])

        let rows = try db.query("SELECT content FROM files WHERE id = 1")
        let retrieved = try rows[0].data(at: 0)
        XCTAssertEqual(retrieved, testData)
    }

    func testNullValues() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, nullable TEXT)")
        try db.run("INSERT INTO test (nullable) VALUES (?)", [.null])

        let rows = try db.query("SELECT nullable FROM test")
        let value = try rows[0].value(at: 0)

        if case .null = value {
            // Success
        } else {
            XCTFail("Expected null value, got: \(value)")
        }

        // String accessor should return nil for NULL
        XCTAssertNil(try rows[0].string(at: 0))
    }

    func testBooleanValues() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, flag INTEGER)")
        try db.run("INSERT INTO test (flag) VALUES (?)", [SQLiteValue(true)])
        try db.run("INSERT INTO test (flag) VALUES (?)", [SQLiteValue(false)])

        let rows = try db.query("SELECT flag FROM test ORDER BY id")
        XCTAssertTrue(try rows[0].bool(at: 0))
        XCTAssertFalse(try rows[1].bool(at: 0))
    }

    // MARK: - Transactions

    func testSuccessfulTransaction() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")

        try db.transaction {
            try db.run("INSERT INTO test (value) VALUES (?)", [.text("A")])
            try db.run("INSERT INTO test (value) VALUES (?)", [.text("B")])
        }

        let rows = try db.query("SELECT COUNT(*) FROM test")
        XCTAssertEqual(try rows[0].int64(at: 0), 2)
    }

    func testFailedTransaction() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")

        do {
            try db.transaction {
                try db.run("INSERT INTO test (value) VALUES (?)", [.text("A")])
                throw NSError(domain: "test", code: 1)
            }
            XCTFail("Transaction should have thrown")
        } catch {
            // Expected
        }

        // Transaction should have rolled back
        let rows = try db.query("SELECT COUNT(*) FROM test")
        XCTAssertEqual(try rows[0].int64(at: 0), 0)
    }

    // MARK: - Column Access

    func testColumnByName() throws {
        try db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
        try db.run("INSERT INTO users (name, age) VALUES (?, ?)", [.text("Alice"), .integer(30)])

        let rows = try db.query("SELECT * FROM users")
        XCTAssertEqual(try rows[0].string(for: "name"), "Alice")
        XCTAssertEqual(try rows[0].int64(for: "age"), 30)
    }

    func testColumnNames() throws {
        try db.execute("CREATE TABLE users (id INTEGER, name TEXT, age INTEGER)")
        try db.run("INSERT INTO users VALUES (1, 'Alice', 30)")

        let rows = try db.query("SELECT * FROM users")
        let columnNames = rows[0].columnNames
        XCTAssertEqual(columnNames, ["id", "name", "age"])
    }

    // MARK: - Prepared Statements

    func testPreparedStatementReuse() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")

        let stmt = try db.prepare("INSERT INTO test (value) VALUES (?)")

        // Insert multiple values using same statement
        try stmt.bind([.text("A")])
        try stmt.execute()

        stmt.reset()

        try stmt.bind([.text("B")])
        try stmt.execute()

        let rows = try db.query("SELECT COUNT(*) FROM test")
        XCTAssertEqual(try rows[0].int64(at: 0), 2)
    }

    // MARK: - Error Handling

    func testInvalidSQL() {
        XCTAssertThrowsError(try db.execute("INVALID SQL")) { error in
            guard case SQLiteError.executeFailed = error else {
                XCTFail("Expected executeFailed error")
                return
            }
        }
    }

    func testInvalidColumnIndex() throws {
        try db.execute("CREATE TABLE test (id INTEGER)")
        try db.run("INSERT INTO test VALUES (1)")

        let rows = try db.query("SELECT * FROM test")

        XCTAssertThrowsError(try rows[0].value(at: 10)) { error in
            guard case SQLiteError.invalidColumnIndex = error else {
                XCTFail("Expected invalidColumnIndex error")
                return
            }
        }
    }

    func testInvalidColumnType() throws {
        try db.execute("CREATE TABLE test (id INTEGER, name TEXT)")
        try db.run("INSERT INTO test VALUES (1, 'Alice')")

        let rows = try db.query("SELECT * FROM test")

        // Try to get TEXT column as INTEGER
        XCTAssertThrowsError(try rows[0].int64(at: 1)) { error in
            guard case SQLiteError.invalidColumnType = error else {
                XCTFail("Expected invalidColumnType error")
                return
            }
        }
    }

    func testMissingColumn() throws {
        try db.execute("CREATE TABLE test (id INTEGER, name TEXT)")
        try db.run("INSERT INTO test VALUES (1, 'Alice')")

        let rows = try db.query("SELECT * FROM test")

        // Try to access a column that doesn't exist
        XCTAssertThrowsError(try rows[0].string(for: "nonexistent")) { error in
            guard case SQLiteError.missingColumn(let column) = error else {
                XCTFail("Expected missingColumn error, got: \(error)")
                return
            }
            XCTAssertEqual(column, "nonexistent")
        }
    }

    // MARK: - Multiple Rows

    func testMultipleRows() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")
        try db.run("INSERT INTO test (value) VALUES ('A'), ('B'), ('C')")

        let rows = try db.query("SELECT value FROM test ORDER BY id")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(try rows[0].string(at: 0), "A")
        XCTAssertEqual(try rows[1].string(at: 0), "B")
        XCTAssertEqual(try rows[2].string(at: 0), "C")
    }

    // MARK: - Version Info

    func testSQLiteVersion() {
        let version = SQLiteDatabase.version
        XCTAssertFalse(version.isEmpty)

        let versionNumber = SQLiteDatabase.versionNumber
        XCTAssertGreaterThan(versionNumber, 0)
    }

    // MARK: - Foreign Keys

    func testForeignKeys() throws {
        try db.execute("""
            CREATE TABLE parent (
                id INTEGER PRIMARY KEY,
                name TEXT
            )
        """)

        try db.execute("""
            CREATE TABLE child (
                id INTEGER PRIMARY KEY,
                parent_id INTEGER NOT NULL,
                FOREIGN KEY (parent_id) REFERENCES parent(id)
            )
        """)

        try db.run("INSERT INTO parent (id, name) VALUES (1, 'Parent')")
        try db.run("INSERT INTO child (parent_id) VALUES (1)")

        // This should fail due to foreign key constraint
        XCTAssertThrowsError(try db.run("INSERT INTO child (parent_id) VALUES (999)"))
    }

    // MARK: - Unicode Support

    func testUnicodeText() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")

        let unicodeStrings = [
            "Hello 🌍",
            "日本語",
            "Émojis: 🎉🎊",
            "Emoji: 👨‍👩‍👧‍👦"
        ]

        for str in unicodeStrings {
            try db.run("INSERT INTO test (value) VALUES (?)", [.text(str)])
        }

        let rows = try db.query("SELECT value FROM test ORDER BY id")
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(try row.string(at: 0), unicodeStrings[index])
        }
    }

    func testTextBindingWithExplicitLength() throws {
        // Our binding uses explicit length (not relying on C string termination)
        // This test verifies the binding code works correctly
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")

        // Test various strings
        let testStrings = [
            "Normal string",
            "String with emoji 🎉",
            "日本語テキスト",
            "" // empty string
        ]

        for str in testStrings {
            try db.run("INSERT INTO test (value) VALUES (?)", [.text(str)])
        }

        let rows = try db.query("SELECT value FROM test ORDER BY id")
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(try row.string(at: 0), testStrings[index])
        }
    }

    func testTextWithEmbeddedNull() throws {
        // Full round-trip with embedded null byte
        try db.execute("CREATE TABLE t(value TEXT)")
        let expected = "Before\0After"
        try db.run("INSERT INTO t(value) VALUES (?)", [.text(expected)])
        let rows = try db.query("SELECT value FROM t")
        XCTAssertEqual(try rows[0].string(at: 0), expected)
        XCTAssertEqual(try rows[0].string(at: 0)?.count, 12)  // 6 + 1 + 5
    }

    func testBlobForBinaryData() throws {
        // BLOB can also be used for binary data (alternative to TEXT)
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value BLOB)")

        let stringWithNull = "Before\0After"
        let data = stringWithNull.data(using: .utf8)!
        try db.run("INSERT INTO test (value) VALUES (?)", [.blob(data)])

        let rows = try db.query("SELECT value FROM test")
        let retrieved = try rows[0].data(at: 0)

        // BLOB also preserves all bytes including embedded nulls
        XCTAssertEqual(retrieved, data)
        XCTAssertEqual(String(data: retrieved!, encoding: .utf8), stringWithNull)
    }

    // MARK: - Large Data

    func testLargeBlob() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, data BLOB)")

        // Create 1MB of data
        let largeData = Data(count: 1_000_000)
        try db.run("INSERT INTO test (data) VALUES (?)", [.blob(largeData)])

        let rows = try db.query("SELECT data FROM test")
        let retrieved = try rows[0].data(at: 0)
        XCTAssertEqual(retrieved?.count, 1_000_000)
    }
}
