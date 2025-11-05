import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif os(Linux)
import CSQLite
#endif

/// SQLite database connection with type-safe API
public final class SQLiteDatabase {
    private var db: OpaquePointer?
    public let path: String

    /// Open or create a database at the given path
    public init(path: String) throws {
        self.path = path

        let result = sqlite3_open(path, &db)
        guard result == SQLITE_OK else {
            let message = db != nil ? String(cString: sqlite3_errmsg(db)) : "Unknown error"
            sqlite3_close(db)
            throw SQLiteError.openFailed(message: message)
        }

        // Enable foreign keys
        try execute("PRAGMA foreign_keys = ON")

        // Set busy timeout (5 seconds) - prevents "database is locked" errors
        sqlite3_busy_timeout(db, 5000)

        // Enable Write-Ahead Logging for better concurrency
        try? execute("PRAGMA journal_mode = WAL")
    }

    deinit {
        // Use sqlite3_close_v2 which handles SQLITE_BUSY gracefully
        // by deferring close until all statements are finalized
        if db != nil {
            sqlite3_close_v2(db)
        }
    }

    /// Execute SQL without parameters (DDL, simple DML)
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)

        guard result == SQLITE_OK else {
            let message = errorMessage != nil ? String(cString: errorMessage!) : "Unknown error"
            sqlite3_free(errorMessage)
            throw SQLiteError.executeFailed(message: message, sql: sql)
        }
    }

    /// Prepare a statement for parameterized queries
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        return try SQLiteStatement(database: db!, sql: sql)
    }

    /// Query with positional parameters (?)
    public func query(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        return try statement.query()
    }

    /// Query with named parameters (:name)
    public func query(_ sql: String, _ parameters: [String: SQLiteValue]) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        return try statement.query()
    }

    /// Execute with positional parameters (INSERT, UPDATE, DELETE)
    public func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        try statement.execute()
    }

    /// Execute with named parameters
    public func run(_ sql: String, _ parameters: [String: SQLiteValue]) throws {
        let statement = try prepare(sql)
        try statement.bind(parameters)
        try statement.execute()
    }

    /// Transaction support
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try execute("BEGIN TRANSACTION")

        do {
            let result = try block()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Last inserted row ID
    public var lastInsertRowID: Int64 {
        return sqlite3_last_insert_rowid(db)
    }

    /// Number of rows changed by last statement
    public var changes: Int {
        return Int(sqlite3_changes(db))
    }

    /// Close the database connection
    /// Note: Normally called automatically in deinit using sqlite3_close_v2
    /// This method uses sqlite3_close which fails if statements are still active
    public func close() throws {
        guard let dbHandle = db else { return }

        let result = sqlite3_close(dbHandle)
        guard result == SQLITE_OK else {
            if result == SQLITE_BUSY {
                throw SQLiteError.closeFailed(
                    message: "Database is busy. Ensure all statements are finalized before closing."
                )
            } else {
                throw SQLiteError.closeFailed(message: String(cString: sqlite3_errstr(result)))
            }
        }

        db = nil
    }
}

// MARK: - Utility Methods

extension SQLiteDatabase {
    /// Check if a table exists
    public func tableExists(_ tableName: String) throws -> Bool {
        let rows = try query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
            [.text(tableName)]
        )
        return !rows.isEmpty
    }

    /// Get the SQLite library version
    public static var version: String {
        return String(cString: sqlite3_libversion())
    }

    /// Get the SQLite library version number
    public static var versionNumber: Int {
        return Int(sqlite3_libversion_number())
    }
}
