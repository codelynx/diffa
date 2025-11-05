# Operation Review: Patching (Create, Apply, Revert)

This document reviews the patching operation which creates transformation descriptions and executes them.

## Core Concept

A **Patch** is a serializable set of operations that describes how to transform directory A into directory B.

**Key requirement:** Patches must support **revert** - the ability to undo the transformation.

```
Difference (comparison result)
    ↓
Patch (transformation description)
    ↓
Apply → Transform A into B
    ↓
Revert → Restore A from B
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Patch (SQLite-based)                           │
│  ┌────────────────────────────────────────────┐ │
│  │ Database: patch.sqlite                     │ │
│  │                                            │ │
│  │ Table: operations                          │ │
│  │   - sequence_order                         │ │
│  │   - type (add/remove/modify/move)          │ │
│  │   - path, path_to                          │ │
│  │   - content_blob                           │ │
│  │   - metadata_json                          │ │
│  │                                            │ │
│  │ Table: revert_data                         │ │
│  │   - path                                   │ │
│  │   - original_content_blob                  │ │
│  │   - original_metadata_json                 │ │
│  │                                            │ │
│  │ Table: metadata                            │ │
│  │   - version                                │ │
│  │   - created_date                           │ │
│  │   - source_checksum                        │ │
│  │   - target_checksum                        │ │
│  └────────────────────────────────────────────┘ │
│                                                 │
│  Export Functions (for human inspection):       │
│  • exportAsText() → diff-style text             │
│  • exportAsJSON() → full data export            │
│  • exportAsDetailedDiff() → git-style diff      │
│  • exportAsHTML() → interactive browser view    │
└─────────────────────────────────────────────────┘
```

**Key points:**
- **Storage:** SQLite database (optimized for scale: 100k+ files, GBs of data)
- **Operations:** Stored sequentially in `operations` table
- **Revert data:** Preserved in `revert_data` table for rollback
- **Export:** Human-readable formats available via export functions
- **Design philosophy:** Optimize for large cases, accept minor overhead for small cases

## Operation 1: Create Patch from Difference

### Input
```swift
let diff = try Difference.compare(source: snapshotA, destination: snapshotB)
```

### Process

**Step 1: Analyze difference results**

Query the difference for all changes:
```swift
let added = diff.added       // Files in B, not in A
let removed = diff.removed   // Files in A, not in B
let modified = diff.modified // Files in both but different
```

**Step 2: Create patch operations**

For each change type, create corresponding operation:

```swift
var operations: [PatchOperation] = []

// For added files: need to create them
for item in added {
    let content = try readFile(from: destination, path: item.path)
    operations.append(.add(
        path: item.path,
        content: content,
        metadata: item.metadata
    ))
}

// For removed files: need to delete them
for item in removed {
    operations.append(.remove(path: item.path))
}

// For modified files: need to update them
for item in modified {
    let content = try readFile(from: destination, path: item.path)
    operations.append(.modify(
        path: item.path,
        content: content,
        metadata: item.metadata
    ))
}
```

**Step 3: Detect moves (optimization)**

```swift
// Find files with same hash but different paths
let moveCandidates = findPotentialMoves(removed: removed, added: added)

for (removedItem, addedItem) in moveCandidates {
    // Replace remove + add with move
    operations.removeAll {
        $0.isRemove(removedItem.path) || $0.isAdd(addedItem.path)
    }
    operations.append(.move(from: removedItem.path, to: addedItem.path))
}
```

**Step 4: Create revert data (if requested)**

For operations that destroy data, preserve original content:

```swift
var revertData = RevertData(
    originalFiles: [:],
    cacheLocation: cacheDirectory ?? temporaryDirectory()
)

// For remove operations: save file content
for case let .remove(path) in operations {
    let originalContent = try readFile(from: source, path: path)
    let originalMetadata = try readMetadata(from: source, path: path)

    if originalContent.count < inlineThreshold {
        // Store inline (small file)
        revertData.originalFiles[path] = OriginalFileData(
            path: path,
            content: originalContent,
            cacheReference: nil,
            metadata: originalMetadata
        )
    } else {
        // Store in cache (large file)
        let cacheFileName = UUID().uuidString
        try originalContent.write(to: cacheLocation.appendingPathComponent(cacheFileName))
        revertData.originalFiles[path] = OriginalFileData(
            path: path,
            content: nil,
            cacheReference: cacheFileName,
            metadata: originalMetadata
        )
    }
}

// For modify operations: save original content
for case let .modify(path, _, _) in operations {
    // Same logic as remove - save original before overwriting
    // ...
}
```

**Step 5: Create patch metadata**

```swift
let metadata = PatchMetadata(
    createdDate: Date(),
    sourceChecksum: snapshotA.calculateChecksum(),
    targetChecksum: snapshotB.calculateChecksum(),
    version: "1.0"
)
```

**Step 6: Create and return patch**

```swift
let patch = Patch(
    operations: operations,
    metadata: metadata,
    revertData: includeRevertData ? revertData : nil
)

return patch
```

### Result

```swift
let patch = try Patch.create(
    from: diff,
    includeRevertData: true,
    cacheDirectory: URL(fileURLWithPath: "/tmp/patch-cache"),
    inlineThreshold: 1_048_576  // 1 MB
)

// Patch can be serialized
try patch.save(to: URL(fileURLWithPath: "transformation.patch"))
```

**What we have:**
- List of operations describing transformation
- Original content preserved for revert
- Metadata for verification
- Serializable to disk

## Operation 2: Apply Patch

### Input
```swift
let patch = try Patch.load(from: URL(fileURLWithPath: "transformation.patch"))
let target = URL(fileURLWithPath: "/path/to/directory")
```

### Process

**Step 1: Verify patch applicability (optional)**

```swift
// Calculate current checksum
let currentChecksum = try calculateDirectoryChecksum(target)

// Compare to expected source checksum
if let expectedSource = patch.metadata.sourceChecksum {
    guard currentChecksum == expectedSource else {
        throw PatchError.checksumMismatch(
            expected: expectedSource,
            actual: currentChecksum
        )
    }
}
```

**Step 2: Execute operations sequentially**

```swift
for operation in patch.operations {
    switch operation {
    case .add(let path, let content, let metadata):
        // Create parent directories if needed
        try createParentDirectories(for: target.appendingPathComponent(path))

        // Write file content
        try content.write(to: target.appendingPathComponent(path))

        // Apply metadata
        try applyMetadata(metadata, to: target.appendingPathComponent(path))

    case .remove(let path):
        // Delete file
        try FileManager.default.removeItem(at: target.appendingPathComponent(path))

    case .modify(let path, let content, let metadata):
        // Overwrite file content
        try content.write(to: target.appendingPathComponent(path))

        // Update metadata
        try applyMetadata(metadata, to: target.appendingPathComponent(path))

    case .move(let from, let to):
        // Create parent directories for destination if needed
        try createParentDirectories(for: target.appendingPathComponent(to))

        // Move file
        try FileManager.default.moveItem(
            at: target.appendingPathComponent(from),
            to: target.appendingPathComponent(to)
        )
    }
}
```

**Step 3: Verify result (optional)**

```swift
// Calculate checksum after applying
let resultChecksum = try calculateDirectoryChecksum(target)

// Compare to expected target checksum
if let expectedTarget = patch.metadata.targetChecksum {
    guard resultChecksum == expectedTarget else {
        throw PatchError.verificationFailed(
            expected: expectedTarget,
            actual: resultChecksum
        )
    }
}
```

### Result

```swift
try await patch.apply(to: target)
// Directory transformed from state A to state B
```

## Operation 3: Revert Patch

### Input
```swift
let patch = try Patch.load(from: URL(fileURLWithPath: "transformation.patch"))
let target = URL(fileURLWithPath: "/path/to/directory")
```

### Process

**Step 1: Verify revert data exists**

```swift
guard let revertData = patch.revertData else {
    throw PatchError.revertDataNotAvailable
}
```

**Step 2: Execute operations in reverse**

```swift
// Process operations in reverse order
for operation in patch.operations.reversed() {
    switch operation {
    case .add(let path, _, _):
        // Undo add = remove file
        try FileManager.default.removeItem(at: target.appendingPathComponent(path))

    case .remove(let path):
        // Undo remove = restore file
        guard let originalData = revertData.originalFiles[path] else {
            throw PatchError.revertDataMissing(path: path)
        }

        // Create parent directories if needed
        try createParentDirectories(for: target.appendingPathComponent(path))

        // Restore content
        if let inlineContent = originalData.content {
            // Small file - content stored inline
            try inlineContent.write(to: target.appendingPathComponent(path))
        } else if let cacheRef = originalData.cacheReference {
            // Large file - content in cache
            let cacheURL = revertData.cacheLocation!.appendingPathComponent(cacheRef)
            try FileManager.default.copyItem(
                at: cacheURL,
                to: target.appendingPathComponent(path)
            )
        }

        // Restore metadata
        try applyMetadata(originalData.metadata, to: target.appendingPathComponent(path))

    case .modify(let path, _, _):
        // Undo modify = restore original content
        guard let originalData = revertData.originalFiles[path] else {
            throw PatchError.revertDataMissing(path: path)
        }

        // Restore content (same logic as remove)
        if let inlineContent = originalData.content {
            try inlineContent.write(to: target.appendingPathComponent(path))
        } else if let cacheRef = originalData.cacheReference {
            let cacheURL = revertData.cacheLocation!.appendingPathComponent(cacheRef)
            try FileManager.default.copyItem(
                at: cacheURL,
                to: target.appendingPathComponent(path)
            )
        }

        // Restore metadata
        try applyMetadata(originalData.metadata, to: target.appendingPathComponent(path))

    case .move(let from, let to):
        // Undo move = move back
        try FileManager.default.moveItem(
            at: target.appendingPathComponent(to),
            to: target.appendingPathComponent(from)
        )
    }
}
```

**Step 3: Verify result (optional)**

```swift
// After revert, directory should match source checksum
let resultChecksum = try calculateDirectoryChecksum(target)

if let expectedSource = patch.metadata.sourceChecksum {
    guard resultChecksum == expectedSource else {
        throw PatchError.revertVerificationFailed(
            expected: expectedSource,
            actual: resultChecksum
        )
    }
}
```

### Result

```swift
try await patch.revert(on: target)
// Directory restored from state B back to state A
```

## Storage Strategy

### SQLite-Based Approach

**Design philosophy:**
- Optimize for **large cases** (100k+ files, GBs of data)
- Accept minor overhead for small cases (e.g., 10ms vs 1ms for 10 files)
- User doesn't notice overhead for small patches
- Large patches work reliably without crashes

**Storage structure:**
```
Patch file: deploy.patch.sqlite (self-contained database)
├── operations table (all patch operations)
│   ├── Indexed by sequence_order
│   ├── Efficient queries
│   └── Content stored as BLOBs
├── revert_data table (original content for rollback)
│   ├── Indexed by path
│   └── Content stored as BLOBs
└── metadata table (patch metadata)
    ├── version, dates, checksums
    └── Single row
```

**Benefits:**
- **Scalable:** Handles 100k+ files without memory issues
- **Fast:** Indexed queries, streaming support
- **Reliable:** ACID transactions, crash recovery
- **Self-contained:** Single file (portable, easy to distribute)
- **Efficient:** Compressed BLOBs, minimal overhead

**Trade-off:**
- Not human-readable directly
- Solution: Export functions (see Serialization Format section)

## Serialization Format

### Storage: SQLite (Optimized, Not Human-Readable)

Patches are stored as SQLite databases for efficiency and scalability.

**Why SQLite:**
- ✅ Handles large datasets (100k+ files, GBs of data)
- ✅ Fast indexed queries
- ✅ ACID transactions
- ✅ Single file (portable)
- ✅ Industry-standard, battle-tested
- ❌ Not human-readable

### Presentation: Export Functions (Human-Readable)

**Architecture:** Separate storage (optimized) from presentation (readable)

Since SQLite is not human-readable, we provide export functions to generate readable formats:

#### 1. Export as Text (Quick Overview)

```swift
extension Patch {
    /// Export as diff-style text (like git diff)
    func exportAsText(to url: URL? = nil) throws -> String {
        var output = ""

        // Header
        output += "Patch: \(metadata.version)\n"
        output += "Created: \(metadata.createdDate)\n"
        output += "Operations: \(try getOperationCount())\n\n"

        // List operations
        for op in try getOperations() {
            switch op {
            case .add(let path, _, _):
                output += "+ \(path) (\(formatBytes(size)))\n"
            case .remove(let path):
                output += "- \(path)\n"
            case .modify(let path, _, _):
                output += "M \(path) (\(formatBytes(size)))\n"
            case .move(let from, let to):
                output += "→ \(from) → \(to)\n"
            }
        }

        // Statistics
        output += "\nSummary:\n"
        output += "  Added: \(try getOperationCount(type: .add))\n"
        output += "  Removed: \(try getOperationCount(type: .remove))\n"
        output += "  Modified: \(try getOperationCount(type: .modify))\n"
        output += "  Moved: \(try getOperationCount(type: .move))\n"

        if let url = url {
            try output.write(to: url, atomically: true, encoding: .utf8)
        }

        return output
    }
}
```

**Output example:**
```
Patch: 1.0
Created: 2024-01-15T10:30:00Z
Operations: 1,523

+ src/newfile.swift (2.4 KB)
- old/deprecated.swift
M src/updated.swift (15.2 KB)
→ old/moved.swift → new/moved.swift
...

Summary:
  Added: 523
  Removed: 150
  Modified: 800
  Moved: 50
```

#### 2. Export as JSON (Full Data)

```swift
extension Patch {
    /// Export as JSON (full data, for tools/scripts)
    func exportAsJSON(to url: URL? = nil) throws -> String {
        let export = PatchExport(
            metadata: metadata,
            operations: try getOperations(),
            statistics: PatchStatistics(
                totalOperations: try getOperationCount(),
                added: try getOperationCount(type: .add),
                removed: try getOperationCount(type: .remove),
                modified: try getOperationCount(type: .modify),
                moved: try getOperationCount(type: .move)
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)
        let json = String(data: data, encoding: .utf8)!

        if let url = url {
            try data.write(to: url)
        }

        return json
    }
}
```

#### 3. Export as Detailed Diff (Git-Style)

```swift
extension Patch {
    /// Export detailed diff with content preview
    func exportAsDetailedDiff(
        to url: URL? = nil,
        contextLines: Int = 3
    ) throws -> String {
        var output = ""

        for op in try getOperations() {
            switch op {
            case .add(let path, let content, _):
                output += "diff --git a/\(path) b/\(path)\n"
                output += "new file\n"
                output += "--- /dev/null\n"
                output += "+++ b/\(path)\n"
                output += previewContent(content, prefix: "+")
                output += "\n"

            case .remove(let path):
                output += "diff --git a/\(path) b/\(path)\n"
                output += "deleted file\n"
                output += "--- a/\(path)\n"
                output += "+++ /dev/null\n\n"

            case .modify(let path, let content, _):
                output += "diff --git a/\(path) b/\(path)\n"
                output += "--- a/\(path)\n"
                output += "+++ b/\(path)\n"
                output += previewContent(content, prefix: " ")
                output += "\n"

            case .move(let from, let to):
                output += "diff --git a/\(from) b/\(to)\n"
                output += "rename from \(from)\n"
                output += "rename to \(to)\n\n"
            }
        }

        if let url = url {
            try output.write(to: url, atomically: true, encoding: .utf8)
        }

        return output
    }
}
```

#### 4. Export as HTML (Browser-Friendly)

```swift
extension Patch {
    /// Export as HTML (styled, interactive view in browser)
    func exportAsHTML(
        to url: URL? = nil,
        includeContentPreview: Bool = true,
        maxPreviewLines: Int = 50
    ) throws -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Patch: \(metadata.version)</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                    max-width: 1200px;
                    margin: 0 auto;
                    padding: 20px;
                    background: #f5f5f5;
                }
                .header {
                    background: white;
                    padding: 20px;
                    border-radius: 8px;
                    margin-bottom: 20px;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                }
                .stats {
                    display: grid;
                    grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
                    gap: 15px;
                    margin: 20px 0;
                }
                .stat-card {
                    background: white;
                    padding: 15px;
                    border-radius: 8px;
                    text-align: center;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                }
                .stat-number {
                    font-size: 2em;
                    font-weight: bold;
                    margin: 10px 0;
                }
                .stat-label {
                    color: #666;
                    font-size: 0.9em;
                }
                .operations {
                    background: white;
                    padding: 20px;
                    border-radius: 8px;
                    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
                }
                .operation {
                    padding: 10px;
                    margin: 5px 0;
                    border-left: 3px solid #ccc;
                    font-family: 'Monaco', 'Courier New', monospace;
                    font-size: 0.9em;
                }
                .op-add { border-left-color: #28a745; background: #f0fff4; }
                .op-remove { border-left-color: #dc3545; background: #fff5f5; }
                .op-modify { border-left-color: #ffc107; background: #fffef0; }
                .op-move { border-left-color: #17a2b8; background: #f0f9ff; }
                .op-icon {
                    display: inline-block;
                    width: 30px;
                    font-weight: bold;
                }
                .path { color: #333; }
                .size { color: #999; font-size: 0.85em; }
                .content-preview {
                    margin-top: 10px;
                    padding: 10px;
                    background: #f8f9fa;
                    border-radius: 4px;
                    overflow-x: auto;
                    max-height: 300px;
                    overflow-y: auto;
                }
                .content-preview pre {
                    margin: 0;
                    font-size: 0.85em;
                }
                details { margin: 10px 0; }
                summary {
                    cursor: pointer;
                    padding: 5px;
                    background: #e9ecef;
                    border-radius: 4px;
                }
                summary:hover { background: #dee2e6; }
            </style>
        </head>
        <body>
            <div class="header">
                <h1>Patch: \(metadata.version)</h1>
                <p><strong>Created:</strong> \(formatDate(metadata.createdDate))</p>
                <p><strong>Total Operations:</strong> \(try getOperationCount())</p>
            </div>

            <div class="stats">
                <div class="stat-card">
                    <div class="stat-number" style="color: #28a745;">
                        \(try getOperationCount(type: .add))
                    </div>
                    <div class="stat-label">Added</div>
                </div>
                <div class="stat-card">
                    <div class="stat-number" style="color: #dc3545;">
                        \(try getOperationCount(type: .remove))
                    </div>
                    <div class="stat-label">Removed</div>
                </div>
                <div class="stat-card">
                    <div class="stat-number" style="color: #ffc107;">
                        \(try getOperationCount(type: .modify))
                    </div>
                    <div class="stat-label">Modified</div>
                </div>
                <div class="stat-card">
                    <div class="stat-number" style="color: #17a2b8;">
                        \(try getOperationCount(type: .move))
                    </div>
                    <div class="stat-label">Moved</div>
                </div>
            </div>

            <div class="operations">
                <h2>Operations</h2>
        """

        // Add operations
        for op in try getOperations() {
            switch op {
            case .add(let path, let content, _):
                html += """
                <div class="operation op-add">
                    <span class="op-icon">+</span>
                    <span class="path">\(escapeHTML(path))</span>
                    <span class="size">(\(formatBytes(Int64(content.count))))</span>
                """
                if includeContentPreview {
                    html += """
                    <details>
                        <summary>Show content preview</summary>
                        <div class="content-preview">
                            <pre>\(escapeHTML(previewContent(content, maxLines: maxPreviewLines)))</pre>
                        </div>
                    </details>
                    """
                }
                html += "</div>\n"

            case .remove(let path):
                html += """
                <div class="operation op-remove">
                    <span class="op-icon">-</span>
                    <span class="path">\(escapeHTML(path))</span>
                </div>
                """

            case .modify(let path, let content, _):
                html += """
                <div class="operation op-modify">
                    <span class="op-icon">M</span>
                    <span class="path">\(escapeHTML(path))</span>
                    <span class="size">(\(formatBytes(Int64(content.count))))</span>
                """
                if includeContentPreview {
                    html += """
                    <details>
                        <summary>Show content preview</summary>
                        <div class="content-preview">
                            <pre>\(escapeHTML(previewContent(content, maxLines: maxPreviewLines)))</pre>
                        </div>
                    </details>
                    """
                }
                html += "</div>\n"

            case .move(let from, let to):
                html += """
                <div class="operation op-move">
                    <span class="op-icon">→</span>
                    <span class="path">\(escapeHTML(from)) → \(escapeHTML(to))</span>
                </div>
                """
            }
        }

        html += """
            </div>
        </body>
        </html>
        """

        if let url = url {
            try html.write(to: url, atomically: true, encoding: .utf8)
        }

        return html
    }

    private func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func previewContent(_ data: Data, maxLines: Int) -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            return "[Binary content]"
        }
        let lines = text.components(separatedBy: .newlines)
        if lines.count > maxLines {
            return lines.prefix(maxLines).joined(separator: "\n")
                + "\n\n... (\(lines.count - maxLines) more lines)"
        }
        return text
    }
}
```

**Features:**
- Styled, responsive HTML with CSS
- Color-coded operations (green for add, red for remove, etc.)
- Statistics dashboard with visual cards
- Expandable content preview (click to show/hide)
- Mobile-friendly design
- No external dependencies (self-contained HTML)

### Usage Examples

```swift
// Load patch from SQLite
let patch = try Patch.load(from: "deploy.patch.sqlite")

// Quick overview (text)
print(try patch.exportAsText())

// Full data export (JSON) - for tools/scripts
try patch.exportAsJSON(to: "patch-details.json")

// Git-style diff - for review
try patch.exportAsDetailedDiff(to: "patch.diff")

// HTML view - for browser inspection
try patch.exportAsHTML(to: "patch-review.html")
// Open patch-review.html in browser for interactive view
```

### Architecture Benefits

✅ **Best of both worlds:**
- Storage optimized for performance (SQLite)
- Presentation optimized for humans (text/JSON)

✅ **No compromises:**
- Fast, scalable operations (SQLite)
- Easy inspection and debugging (export functions)

✅ **Tool integration:**
- JSON export → pipe to other tools
- Text export → read directly in terminal
- Diff export → code review workflows
- HTML export → interactive browser inspection

✅ **Separation of concerns:**
- Storage format can evolve independently
- Export formats can be added without breaking storage

## API Design

```swift
struct Patch {
    let databaseURL: URL  // Path to .sqlite file

    // Create patch from difference
    static func create(
        from difference: Difference<T>,
        saveTo url: URL,  // Where to save .sqlite file
        includeRevertData: Bool = true
    ) async throws -> Patch

    // Apply patch forward
    func apply(
        to target: URL,
        progress: ((PatchProgress) -> Void)? = nil
    ) async throws

    // Revert patch (undo)
    func revert(
        on target: URL,
        progress: ((PatchProgress) -> Void)? = nil
    ) async throws

    // Load existing patch
    static func load(from url: URL) throws -> Patch

    // Query operations
    func getOperations() throws -> [PatchOperation]
    func getOperationCount() throws -> Int
    func getOperationCount(type: OperationType) throws -> Int

    // Export functions (human-readable formats)
    func exportAsText(to url: URL? = nil) throws -> String
    func exportAsJSON(to url: URL? = nil) throws -> String
    func exportAsDetailedDiff(
        to url: URL? = nil,
        contextLines: Int = 3
    ) throws -> String
    func exportAsHTML(
        to url: URL? = nil,
        includeContentPreview: Bool = true,
        maxPreviewLines: Int = 50
    ) throws -> String

    // Metadata access
    var metadata: PatchMetadata { get throws }
}

enum PatchOperation {
    case add(path: String, content: Data, metadata: Metadata)
    case remove(path: String)
    case modify(path: String, content: Data, metadata: Metadata)
    case move(from: String, to: String)
}

enum OperationType {
    case add, remove, modify, move
}

struct PatchMetadata {
    let createdDate: Date
    let sourceChecksum: String?
    let targetChecksum: String?
    let version: String
}

struct PatchProgress {
    var currentOperation: String
    var operationsCompleted: Int
    var totalOperations: Int
    var bytesProcessed: Int64
}

// Supporting structures for export
struct PatchExport: Codable {
    let metadata: PatchMetadata
    let operations: [PatchOperation]
    let statistics: PatchStatistics
}

struct PatchStatistics: Codable {
    let totalOperations: Int
    let added: Int
    let removed: Int
    let modified: Int
    let moved: Int
}
```

## Use Cases

### Deployment Package

```swift
// Create patch for deployment
let before = try await Snapshot.create(from: production, saveTo: "before.sqlite")
let after = try await Snapshot.create(from: staging, saveTo: "after.sqlite")
let diff = try Difference.compare(source: before, destination: after)

// Create patch (SQLite format)
let patch = try await Patch.create(
    from: diff,
    saveTo: URL(fileURLWithPath: "deploy-v2.0.patch.sqlite"),
    includeRevertData: true
)

// Inspect patch before deployment
print(try patch.exportAsText())
// Output:
// Patch: 1.0
// Created: 2024-01-15T10:30:00Z
// Operations: 1,523
// + src/newfile.swift (2.4 KB)
// ...

// On production server
let patch = try Patch.load(from: "deploy-v2.0.patch.sqlite")
try await patch.apply(to: production)

// Verify deployment
print("Deployed successfully!")
```

### Install/Uninstall

```swift
// Installation
let patch = try Patch.load(from: "installer.patch.sqlite")

// Inspect what will be installed
print(try patch.exportAsText())

try await patch.apply(to: installLocation)
print("Installed \(try patch.getOperationCount()) files")

// Uninstallation (revert)
try await patch.revert(on: installLocation)
// Everything installed is now removed
```

### Debugging and Review

```swift
// Load patch for inspection
let patch = try Patch.load(from: "update.patch.sqlite")

// Quick summary (terminal)
print(try patch.exportAsText())

// Interactive review (browser)
try patch.exportAsHTML(to: "review.html")
// Open review.html in browser:
// - Visual statistics dashboard
// - Color-coded operations
// - Click to expand content preview

// Detailed review (git-style diff)
try patch.exportAsDetailedDiff(to: "review.diff")
// Share review.diff with team for code review

// Export full data for analysis
try patch.exportAsJSON(to: "analysis.json")
// Use analysis.json with custom scripts/tools
```

## Error Handling

### Common Errors

```swift
enum PatchError: Error {
    case checksumMismatch(expected: String, actual: String)
    case verificationFailed(expected: String, actual: String)
    case revertDataNotAvailable
    case revertDataMissing(path: String)
    case operationFailed(operation: PatchOperation, reason: String)
    case cacheNotFound(reference: String)
    case insufficientDiskSpace
    case permissionDenied(path: String)
}
```

### Partial Application

**Question:** What happens if apply fails halfway?

**Options:**
1. **No rollback** - Leave in partial state (simple)
2. **Automatic rollback** - Revert on error (complex)
3. **Transaction log** - Record what was done, allow manual recovery

**Recommendation:** Start with option 1 (no automatic rollback), add transaction log later if needed.

## Review Summary

✅ **Patch creation** - Convert Difference to operation list (stored in SQLite)
✅ **Revert data** - Preserve original content (SQLite `revert_data` table)
✅ **Apply** - Execute operations forward
✅ **Revert** - Execute operations in reverse
✅ **Serialization** - SQLite-based storage (efficient, scalable)
✅ **Move detection** - Optimize by detecting file moves
✅ **Verification** - Optional checksum validation
✅ **Export functions** - Human-readable formats (text, JSON, diff)

### Key Design Decisions

1. **SQLite over JSON/Binary:**
   - Optimized for large cases (100k+ files, GBs of data)
   - Accept minor overhead for small cases (user won't notice)
   - Self-contained, portable, ACID-compliant

2. **Storage vs Presentation:**
   - Storage: SQLite (not human-readable, but efficient)
   - Presentation: Export functions (human-readable when needed)
   - Best of both worlds: performance + debuggability

3. **Export Functions:**
   - `exportAsText()` - Quick overview
   - `exportAsJSON()` - Full data for tools
   - `exportAsDetailedDiff()` - Git-style diff for review
   - `exportAsHTML()` - Interactive browser view with styling

4. **Revert Support:**
   - All operations include revert data (optional)
   - Stored in `revert_data` table
   - Enables undo/rollback functionality

**Ready for implementation?** YES

If any concerns, document them here before proceeding to implementation.
