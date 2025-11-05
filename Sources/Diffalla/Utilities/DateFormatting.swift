import Foundation

/// Shared date formatting utilities for consistent serialization
enum DateFormatting {
    /// Convert Date to Unix timestamp (seconds since epoch)
    /// This is simpler, more efficient, and timezone-independent
    static func toUnixTimestamp(_ date: Date) -> Int64 {
        return Int64(date.timeIntervalSince1970)
    }

    /// Convert Unix timestamp to Date
    static func fromUnixTimestamp(_ timestamp: Int64) -> Date {
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }
}
