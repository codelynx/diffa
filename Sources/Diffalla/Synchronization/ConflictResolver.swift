import Foundation

/// Resolves conflicts using specified strategies
class ConflictResolver {

    /// Resolve a conflict using the given strategy
    ///
    /// - Parameters:
    ///   - conflict: The conflict to resolve
    ///   - strategy: The resolution strategy to use
    ///   - sourceDirectory: Base directory for source files (needed for .newest)
    ///   - destinationDirectory: Base directory for destination files (needed for .newest)
    /// - Returns: ResolvedConflict describing the resolution decision
    /// - Throws: DiffallaError if strategy is .error or resolution fails
    func resolve(
        conflict: Conflict,
        strategy: ConflictResolution,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) throws -> ResolvedConflict {
        switch strategy {
        case .newest:
            return try resolveNewest(
                conflict: conflict,
                sourceDirectory: sourceDirectory,
                destinationDirectory: destinationDirectory
            )

        case .sourceWins:
            return resolveSourceWins(conflict: conflict)

        case .destinationWins:
            return resolveDestinationWins(conflict: conflict)

        case .error:
            throw DiffallaError.comparisonFailed(
                reason: "Conflict detected at '\(conflict.path)': \(conflict.type). Manual resolution required."
            )
        }
    }

    // MARK: - Private Resolution Strategies

    /// Resolve by choosing the file with the newest modification date
    private func resolveNewest(
        conflict: Conflict,
        sourceDirectory: URL,
        destinationDirectory: URL
    ) throws -> ResolvedConflict {
        switch conflict.type {
        case .diverged:
            // Both exist - compare modification dates
            guard let sourceItem = conflict.sourceItem,
                  let destItem = conflict.destinationItem else {
                throw DiffallaError.comparisonFailed(
                    reason: "Diverged conflict missing item data for '\(conflict.path)'"
                )
            }

            if sourceItem.modificationDate > destItem.modificationDate {
                // Source is newer
                return ResolvedConflict(
                    conflict: conflict,
                    resolution: .newest,
                    direction: .copyToDestination,
                    action: "Use source (newer: \(sourceItem.modificationDate) > \(destItem.modificationDate))"
                )
            } else {
                // Destination is newer or same
                return ResolvedConflict(
                    conflict: conflict,
                    resolution: .newest,
                    direction: .copyToSource,
                    action: "Use destination (newer: \(destItem.modificationDate) >= \(sourceItem.modificationDate))"
                )
            }

        case .onlyInSource:
            // Only in source - use source (it's the "newest" since dest doesn't have it)
            return ResolvedConflict(
                conflict: conflict,
                resolution: .newest,
                direction: .copyToDestination,
                action: "Use source (only exists in source)"
            )

        case .onlyInDestination:
            // Only in destination - use destination (it's the "newest" since source doesn't have it)
            return ResolvedConflict(
                conflict: conflict,
                resolution: .newest,
                direction: .copyToSource,
                action: "Use destination (only exists in destination)"
            )
        }
    }

    /// Resolve by always choosing the source version
    private func resolveSourceWins(conflict: Conflict) -> ResolvedConflict {
        switch conflict.type {
        case .diverged:
            // Both exist - use source
            return ResolvedConflict(
                conflict: conflict,
                resolution: .sourceWins,
                direction: .copyToDestination,
                action: "Use source (source wins strategy)"
            )

        case .onlyInSource:
            // Only in source - use source
            return ResolvedConflict(
                conflict: conflict,
                resolution: .sourceWins,
                direction: .copyToDestination,
                action: "Use source (already only in source)"
            )

        case .onlyInDestination:
            // Only in destination - delete from destination (source doesn't have it)
            return ResolvedConflict(
                conflict: conflict,
                resolution: .sourceWins,
                direction: .deleteFromDestination,
                action: "Delete from destination (source doesn't have it)"
            )
        }
    }

    /// Resolve by always choosing the destination version
    private func resolveDestinationWins(conflict: Conflict) -> ResolvedConflict {
        switch conflict.type {
        case .diverged:
            // Both exist - use destination
            return ResolvedConflict(
                conflict: conflict,
                resolution: .destinationWins,
                direction: .copyToSource,
                action: "Use destination (destination wins strategy)"
            )

        case .onlyInSource:
            // Only in source - delete from source (destination doesn't have it)
            return ResolvedConflict(
                conflict: conflict,
                resolution: .destinationWins,
                direction: .deleteFromSource,
                action: "Delete from source (destination doesn't have it)"
            )

        case .onlyInDestination:
            // Only in destination - use destination
            return ResolvedConflict(
                conflict: conflict,
                resolution: .destinationWins,
                direction: .copyToSource,
                action: "Use destination (already only in destination)"
            )
        }
    }
}
