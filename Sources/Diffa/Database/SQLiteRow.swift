import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A row from a query result
/// Note: Data is copied from the statement to ensure safety
public struct SQLiteRow {
    private let values: [SQLiteValue]
    private let names: [String]

    init(statement: OpaquePointer) {
        let columnCount = sqlite3_column_count(statement)

        // Copy column names
        var names: [String] = []
        for i in 0..<columnCount {
            if let cString = sqlite3_column_name(statement, i) {
                names.append(String(cString: cString))
            } else {
                names.append("")
            }
        }
        self.names = names

        // Copy values
        var values: [SQLiteValue] = []
        for i in 0..<columnCount {
            let columnType = sqlite3_column_type(statement, i)

            switch columnType {
            case SQLITE_INTEGER:
                values.append(.integer(sqlite3_column_int64(statement, i)))
            case SQLITE_FLOAT:
                values.append(.real(sqlite3_column_double(statement, i)))
            case SQLITE_TEXT:
                if let cString = sqlite3_column_text(statement, i) {
                    // Use explicit byte count to preserve embedded nulls
                    let byteCount = Int(sqlite3_column_bytes(statement, i))
                    let data = Data(bytes: cString, count: byteCount)
                    if let string = String(data: data, encoding: .utf8) {
                        values.append(.text(string))
                    } else {
                        // Invalid UTF-8, treat as null
                        values.append(.null)
                    }
                } else {
                    values.append(.null)
                }
            case SQLITE_BLOB:
                if let bytes = sqlite3_column_blob(statement, i) {
                    let count = Int(sqlite3_column_bytes(statement, i))
                    values.append(.blob(Data(bytes: bytes, count: count)))
                } else {
                    values.append(.null)
                }
            case SQLITE_NULL:
                values.append(.null)
            default:
                values.append(.null)
            }
        }
        self.values = values
    }

    /// Get column value by index (0-based)
    public func value(at index: Int) throws -> SQLiteValue {
        guard index >= 0 && index < values.count else {
            throw SQLiteError.invalidColumnIndex(index: index)
        }
        return values[index]
    }

    /// Get column value by name
    public func value(for columnName: String) throws -> SQLiteValue {
        guard let index = columnIndex(for: columnName) else {
            throw SQLiteError.missingColumn(column: columnName)
        }
        return try value(at: index)
    }

    /// Get column name at index
    public func columnName(at index: Int) -> String? {
        guard index >= 0 && index < names.count else { return nil }
        return names[index]
    }

    /// Get all column names
    public var columnNames: [String] {
        return names
    }

    /// Get column index for name
    private func columnIndex(for name: String) -> Int? {
        return names.firstIndex(of: name)
    }

    // MARK: - Convenience Accessors

    /// Get as Int64
    public func int64(at index: Int) throws -> Int64 {
        guard case .integer(let value) = try value(at: index) else {
            throw SQLiteError.invalidColumnType(column: "\(index)", expected: "INTEGER")
        }
        return value
    }

    /// Get as Int
    public func int(at index: Int) throws -> Int {
        return Int(try int64(at: index))
    }

    /// Get as Bool (0 = false, non-zero = true)
    public func bool(at index: Int) throws -> Bool {
        return try int64(at: index) != 0
    }

    /// Get as Double
    public func double(at index: Int) throws -> Double {
        guard case .real(let value) = try value(at: index) else {
            throw SQLiteError.invalidColumnType(column: "\(index)", expected: "REAL")
        }
        return value
    }

    /// Get as String (returns nil if NULL)
    public func string(at index: Int) throws -> String? {
        let value = try value(at: index)
        guard case .text(let str) = value else {
            if case .null = value { return nil }
            throw SQLiteError.invalidColumnType(column: "\(index)", expected: "TEXT")
        }
        return str
    }

    /// Get as Data (returns nil if NULL)
    public func data(at index: Int) throws -> Data? {
        let value = try value(at: index)
        guard case .blob(let data) = value else {
            if case .null = value { return nil }
            throw SQLiteError.invalidColumnType(column: "\(index)", expected: "BLOB")
        }
        return data
    }

    // MARK: - By Name Accessors

    /// Get as Int64 by column name
    public func int64(for columnName: String) throws -> Int64 {
        guard let index = columnIndex(for: columnName) else {
            throw SQLiteError.missingColumn(column: columnName)
        }
        return try int64(at: index)
    }

    /// Get as String by column name
    public func string(for columnName: String) throws -> String? {
        guard let index = columnIndex(for: columnName) else {
            throw SQLiteError.missingColumn(column: columnName)
        }
        return try string(at: index)
    }
}
