import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Type-safe SQLite value for parameter binding and result retrieval
public enum SQLiteValue: Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null

    /// Bind this value to a statement at the given index (1-based)
    func bind(to statement: OpaquePointer, at index: Int32) throws {
        let result: Int32

        // SQLITE_TRANSIENT tells SQLite to make its own copy
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        switch self {
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .real(let value):
            result = sqlite3_bind_double(statement, index, value)
        case .text(let value):
            // Use UTF-8 data to preserve embedded null bytes
            result = value.utf8CString.withUnsafeBytes { buffer in
                // utf8CString includes null terminator, so subtract 1 from count
                let length = buffer.count > 0 ? buffer.count - 1 : 0
                return sqlite3_bind_text(statement, index, buffer.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(length), SQLITE_TRANSIENT)
            }
        case .blob(let data):
            if data.isEmpty {
                result = sqlite3_bind_blob(statement, index, nil, 0, SQLITE_TRANSIENT)
            } else {
                result = data.withUnsafeBytes { bytes in
                    guard let baseAddress = bytes.baseAddress else {
                        return SQLITE_ERROR
                    }
                    return sqlite3_bind_blob(statement, index, baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            }
        case .null:
            result = sqlite3_bind_null(statement, index)
        }

        guard result == SQLITE_OK else {
            throw SQLiteError.bindFailed(message: String(cString: sqlite3_errstr(result)))
        }
    }
}

// MARK: - Convenience Initializers

extension SQLiteValue {
    /// Create from Int
    public init(_ value: Int) {
        self = .integer(Int64(value))
    }

    /// Create from Bool (stored as 0/1)
    public init(_ value: Bool) {
        self = .integer(value ? 1 : 0)
    }

    /// Create from optional String
    public init(_ value: String?) {
        if let value = value {
            self = .text(value)
        } else {
            self = .null
        }
    }

    /// Create from optional Data
    public init(_ value: Data?) {
        if let value = value {
            self = .blob(value)
        } else {
            self = .null
        }
    }
}
