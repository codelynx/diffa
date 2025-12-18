import Foundation

/// Synchronization mode defining transfer and deletion behavior
///
/// The three sync modes provide different semantics:
///
/// **Push:** Client → Server (mirror)
/// ```
/// Before: Client: [A, B], Server: [B, C]
/// After:  Client: [A, B], Server: [A, B]  (C deleted)
/// ```
///
/// **Pull:** Server → Client (mirror)
/// ```
/// Before: Server: [A, B], Client: [B, C]
/// After:  Server: [A, B], Client: [A, B]  (C deleted)
/// ```
///
/// **Sync:** Merge both sides (no deletions)
/// ```
/// Before: Client: [A, B], Server: [B, C]
/// After:  Client: [A, B, C], Server: [A, B, C]
/// Conflicts: Newer wins (by mtime)
/// ```
public enum SyncMode: String, Codable {
    /// Dest mirrors source (dest-only files deleted)
    ///
    /// Use case: Backup to server
    /// - Files on client → uploaded to server
    /// - Files only on server → deleted
    /// - Result: Server becomes exact copy of client
    case push

    /// Source mirrors dest (source-only files deleted)
    ///
    /// Use case: Restore from server
    /// - Files on server → downloaded to client
    /// - Files only on client → deleted
    /// - Result: Client becomes exact copy of server
    case pull

    /// Merge both sides (no deletions, newer wins on conflicts)
    ///
    /// Use case: Keep two directories in sync
    /// - Files unique to either side → copied to both
    /// - Files on both with different content → newer wins
    /// - Result: Both sides have all files
    case sync
}

// MARK: - CustomStringConvertible

extension SyncMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .push:
            return "push (dest mirrors source)"
        case .pull:
            return "pull (source mirrors dest)"
        case .sync:
            return "sync (merge both, newer wins)"
        }
    }
}
