import Foundation

/// Errors that can occur during SQLite operations
public enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(message: String)
    case executeFailed(message: String, sql: String)
    case prepareFailed(message: String, sql: String)
    case bindFailed(message: String)
    case stepFailed(message: String)
    case invalidColumnIndex(index: Int)
    case invalidColumnType(column: String, expected: String)
    case missingColumn(column: String)
    case closeFailed(message: String)

    public var description: String {
        switch self {
        case .openFailed(let message):
            return "Failed to open database: \(message)"
        case .executeFailed(let message, let sql):
            return "Failed to execute SQL: \(message)\nSQL: \(sql)"
        case .prepareFailed(let message, let sql):
            return "Failed to prepare statement: \(message)\nSQL: \(sql)"
        case .bindFailed(let message):
            return "Failed to bind parameter: \(message)"
        case .stepFailed(let message):
            return "Failed to step statement: \(message)"
        case .invalidColumnIndex(let index):
            return "Invalid column index: \(index)"
        case .invalidColumnType(let column, let expected):
            return "Invalid column type for '\(column)', expected: \(expected)"
        case .missingColumn(let column):
            return "Column '\(column)' not found in result set"
        case .closeFailed(let message):
            return "Failed to close database: \(message)"
        }
    }
}
