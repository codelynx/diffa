import Foundation

/// Simple helper that limits the number of concurrent hash computations.
/// SnapshotEngine schedules hashing work onto this helper when
/// `ScanOptions.useParallelHashing` is enabled.
public final class ParallelHasher {
    private let queue: OperationQueue

    public init(maxConcurrentHashes: Int) {
        queue = OperationQueue()
        queue.name = "com.diffa.parallelhasher"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentHashes)
    }

    /// Compute the SHA-256 hash for a file. Work is dispatched onto the
    /// internal OperationQueue so multiple calls can run simultaneously,
    /// bounded by `maxConcurrentHashes`.
    public func hashFile(at url: URL) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do {
                    let hash = try FileSystemItem.computeHash(at: url)
                    continuation.resume(returning: hash)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension ParallelHasher: @unchecked Sendable {}
