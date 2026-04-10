import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Prepared statement wrapper with automatic cleanup (RAII pattern)
public final class SQLiteStatement {
    private var statement: OpaquePointer?
    private let sql: String

    init(database: OpaquePointer, sql: String) throws {
        self.sql = sql

        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(database))
            throw SQLiteError.prepareFailed(message: message, sql: sql)
        }
    }

    deinit {
        sqlite3_finalize(statement)
    }

    /// Bind parameters (1-based indexing like SQLite)
    public func bind(_ values: [SQLiteValue]) throws {
        for (index, value) in values.enumerated() {
            try value.bind(to: statement!, at: Int32(index + 1))
        }
    }

    /// Bind parameters using named placeholders
    public func bind(_ values: [String: SQLiteValue]) throws {
        for (name, value) in values {
            let paramName = name.hasPrefix(":") ? name : ":\(name)"
            let index = sqlite3_bind_parameter_index(statement, paramName)
            guard index > 0 else {
                throw SQLiteError.bindFailed(message: "Parameter '\(name)' not found in SQL")
            }
            try value.bind(to: statement!, at: index)
        }
    }

    /// Execute and return rows
    public func query() throws -> [SQLiteRow] {
        var rows: [SQLiteRow] = []

        while true {
            let result = sqlite3_step(statement)

            if result == SQLITE_ROW {
                rows.append(SQLiteRow(statement: statement!))
            } else if result == SQLITE_DONE {
                break
            } else {
                let message = String(cString: sqlite3_errstr(result))
                throw SQLiteError.stepFailed(message: message)
            }
        }

        sqlite3_reset(statement)
        return rows
    }

    /// Execute without returning rows (INSERT, UPDATE, DELETE)
    public func execute() throws {
        let result = sqlite3_step(statement)

        guard result == SQLITE_DONE else {
            let message = String(cString: sqlite3_errstr(result))
            throw SQLiteError.stepFailed(message: message)
        }

        sqlite3_reset(statement)
    }

    /// Reset the statement for reuse
    public func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }
}
