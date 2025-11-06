import Foundation

/// Operations that can be performed to transform a directory
public enum PatchOperation: Codable, Equatable, Sendable {
    /// Add a new file or folder
    /// - path: Relative path from root
    /// - isFolder: True for directories, false for files
    case add(path: String, isFolder: Bool)

    /// Remove an existing file or folder
    /// - path: Relative path from root
    /// - isFolder: True for directories, false for files
    case remove(path: String, isFolder: Bool)

    /// Modify an existing file or folder
    /// - path: Relative path from root
    /// - isFolder: True for directories, false for files
    case modify(path: String, isFolder: Bool)

    /// Move/rename a file or folder
    /// - from: Original relative path
    /// - to: New relative path
    /// - isFolder: True for directories, false for files
    case move(from: String, to: String, isFolder: Bool)

    // MARK: - Codable Implementation

    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case isFolder
        case from
        case to
    }

    private enum OperationType: String, Codable {
        case add
        case remove
        case modify
        case move
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OperationType.self, forKey: .type)

        switch type {
        case .add:
            let path = try container.decode(String.self, forKey: .path)
            let isFolder = try container.decode(Bool.self, forKey: .isFolder)
            self = .add(path: path, isFolder: isFolder)

        case .remove:
            let path = try container.decode(String.self, forKey: .path)
            let isFolder = try container.decode(Bool.self, forKey: .isFolder)
            self = .remove(path: path, isFolder: isFolder)

        case .modify:
            let path = try container.decode(String.self, forKey: .path)
            let isFolder = try container.decode(Bool.self, forKey: .isFolder)
            self = .modify(path: path, isFolder: isFolder)

        case .move:
            let from = try container.decode(String.self, forKey: .from)
            let to = try container.decode(String.self, forKey: .to)
            let isFolder = try container.decode(Bool.self, forKey: .isFolder)
            self = .move(from: from, to: to, isFolder: isFolder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .add(let path, let isFolder):
            try container.encode(OperationType.add, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(isFolder, forKey: .isFolder)

        case .remove(let path, let isFolder):
            try container.encode(OperationType.remove, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(isFolder, forKey: .isFolder)

        case .modify(let path, let isFolder):
            try container.encode(OperationType.modify, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(isFolder, forKey: .isFolder)

        case .move(let from, let to, let isFolder):
            try container.encode(OperationType.move, forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(isFolder, forKey: .isFolder)
        }
    }

    // MARK: - Computed Properties

    /// The primary path affected by this operation
    public var path: String {
        switch self {
        case .add(let path, _):
            return path
        case .remove(let path, _):
            return path
        case .modify(let path, _):
            return path
        case .move(_, let to, _):
            return to
        }
    }

    /// Whether this operation affects a folder
    public var isFolder: Bool {
        switch self {
        case .add(_, let isFolder):
            return isFolder
        case .remove(_, let isFolder):
            return isFolder
        case .modify(_, let isFolder):
            return isFolder
        case .move(_, _, let isFolder):
            return isFolder
        }
    }

    /// Human-readable description of the operation
    public var operationType: String {
        switch self {
        case .add:
            return "add"
        case .remove:
            return "remove"
        case .modify:
            return "modify"
        case .move:
            return "move"
        }
    }
}
