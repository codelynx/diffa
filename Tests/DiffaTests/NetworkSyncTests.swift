import XCTest
@testable import Diffa

final class NetworkSyncTests: XCTestCase {

    var localDir: URL!
    var remoteDir: URL!
    var server: SyncServer!
    var testPort: UInt16!

    override func setUp() {
        super.setUp()

        // Create temp directories
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("NetworkSyncTests-\(UUID().uuidString)")

        localDir = tempBase.appendingPathComponent("local")
        remoteDir = tempBase.appendingPathComponent("remote")

        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)

        // Use random port to avoid conflicts
        testPort = UInt16.random(in: 10000...60000)
    }

    override func tearDown() {
        // Stop server
        server?.stop()
        server = nil

        // Clean up temp directories
        if let localDir = localDir {
            try? FileManager.default.removeItem(at: localDir)
        }
        if let remoteDir = remoteDir {
            try? FileManager.default.removeItem(at: remoteDir)
        }

        super.tearDown()
    }

    // MARK: - Helper Methods

    private func startServer() throws {
        server = SyncServer(path: remoteDir, port: testPort)
        // Silence server logs in tests (SyncServer.log already prints)
        server.onLog = nil
        try server.startAsync()
    }

    private func createFile(at dir: URL, name: String, content: String) throws {
        let fileURL = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readFile(at dir: URL, name: String) -> String? {
        let fileURL = dir.appendingPathComponent(name)
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }

    private func fileExists(at dir: URL, name: String) -> Bool {
        let fileURL = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    private func listFiles(at dir: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile {
                let relativePath = url.path.replacingOccurrences(of: dir.path + "/", with: "")
                files.append(relativePath)
            }
        }
        return files.sorted()
    }

    // MARK: - Push Tests

    func testPushNewFiles() throws {
        // Setup: local has files, remote is empty
        try createFile(at: localDir, name: "file1.txt", content: "Hello")
        try createFile(at: localDir, name: "folder/file2.txt", content: "World")

        try startServer()

        // Push
        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify remote has the files
        XCTAssertEqual(readFile(at: remoteDir, name: "file1.txt"), "Hello")
        XCTAssertEqual(readFile(at: remoteDir, name: "folder/file2.txt"), "World")
    }

    func testPushUpdatesExistingFiles() throws {
        // Setup: both have same file but different content
        try createFile(at: localDir, name: "file.txt", content: "New Content")
        try createFile(at: remoteDir, name: "file.txt", content: "Old Content")

        try startServer()

        // Push
        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify remote has updated content
        XCTAssertEqual(readFile(at: remoteDir, name: "file.txt"), "New Content")
    }

    func testPushDeletesRemoteOnlyFiles() throws {
        // Setup: local has file1, remote has file1 + file2
        try createFile(at: localDir, name: "file1.txt", content: "Keep")
        try createFile(at: remoteDir, name: "file1.txt", content: "Old")
        try createFile(at: remoteDir, name: "file2.txt", content: "Delete Me")

        try startServer()

        // Push (should delete file2 from remote)
        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify remote mirrors local
        XCTAssertEqual(readFile(at: remoteDir, name: "file1.txt"), "Keep")
        XCTAssertFalse(fileExists(at: remoteDir, name: "file2.txt"), "file2.txt should be deleted")
    }

    // MARK: - Pull Tests

    func testPullNewFiles() throws {
        // Setup: remote has files, local is empty
        try createFile(at: remoteDir, name: "file1.txt", content: "Hello")
        try createFile(at: remoteDir, name: "folder/file2.txt", content: "World")

        try startServer()

        // Pull
        let client = SyncClient()
        client.onLog = nil
        try client.pull(localPath: localDir, from: "localhost", port: testPort)

        // Verify local has the files
        XCTAssertEqual(readFile(at: localDir, name: "file1.txt"), "Hello")
        XCTAssertEqual(readFile(at: localDir, name: "folder/file2.txt"), "World")
    }

    func testPullUpdatesExistingFiles() throws {
        // Setup: both have same file but different content
        try createFile(at: localDir, name: "file.txt", content: "Old Content")
        try createFile(at: remoteDir, name: "file.txt", content: "New Content")

        try startServer()

        // Pull
        let client = SyncClient()
        client.onLog = nil
        try client.pull(localPath: localDir, from: "localhost", port: testPort)

        // Verify local has updated content
        XCTAssertEqual(readFile(at: localDir, name: "file.txt"), "New Content")
    }

    func testPullDeletesLocalOnlyFiles() throws {
        // Setup: remote has file1, local has file1 + file2
        try createFile(at: localDir, name: "file1.txt", content: "Old")
        try createFile(at: localDir, name: "file2.txt", content: "Delete Me")
        try createFile(at: remoteDir, name: "file1.txt", content: "Keep")

        try startServer()

        // Pull (should delete file2 from local)
        let client = SyncClient()
        client.onLog = nil
        try client.pull(localPath: localDir, from: "localhost", port: testPort)

        // Verify local mirrors remote
        XCTAssertEqual(readFile(at: localDir, name: "file1.txt"), "Keep")
        XCTAssertFalse(fileExists(at: localDir, name: "file2.txt"), "file2.txt should be deleted")
    }

    // MARK: - Compression Tests

    func testPushCompressesLargeFiles() throws {
        // Create a large compressible file (>4KB)
        let largeContent = String(repeating: "This is compressible text content. ", count: 500)
        try createFile(at: localDir, name: "large.txt", content: largeContent)

        try startServer()

        var uploadMessages: [String] = []
        let client = SyncClient()
        client.onLog = { uploadMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify file was transferred
        XCTAssertEqual(readFile(at: remoteDir, name: "large.txt"), largeContent)

        // Verify compression was logged
        let compressionLog = uploadMessages.first { $0.contains("% saved") }
        XCTAssertNotNil(compressionLog, "Should log compression ratio")
    }

    func testPushDoesNotCompressSmallFiles() throws {
        // Create a small file (<4KB)
        try createFile(at: localDir, name: "small.txt", content: "Small content")

        try startServer()

        var uploadMessages: [String] = []
        let client = SyncClient()
        client.onLog = { uploadMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify file was transferred
        XCTAssertEqual(readFile(at: remoteDir, name: "small.txt"), "Small content")

        // Verify no compression logged
        let compressionLog = uploadMessages.first { $0.contains("% saved") }
        XCTAssertNil(compressionLog, "Small files should not be compressed")
    }

    // MARK: - Edge Cases

    func testPushEmptyDirectory() throws {
        // Local is empty, remote has files
        try createFile(at: remoteDir, name: "file.txt", content: "Delete")

        try startServer()

        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Remote should be empty
        XCTAssertFalse(fileExists(at: remoteDir, name: "file.txt"))
    }

    func testPullEmptyRemote() throws {
        // Remote is empty, local has files
        try createFile(at: localDir, name: "file.txt", content: "Delete")

        try startServer()

        let client = SyncClient()
        client.onLog = nil
        try client.pull(localPath: localDir, from: "localhost", port: testPort)

        // Local should be empty
        XCTAssertFalse(fileExists(at: localDir, name: "file.txt"))
    }

    func testSyncManyFiles() throws {
        // Create many files
        for i in 1...50 {
            try createFile(at: localDir, name: "file\(i).txt", content: "Content \(i)")
        }

        try startServer()

        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify all files transferred
        let remoteFiles = listFiles(at: remoteDir)
        XCTAssertEqual(remoteFiles.count, 50)
        for i in 1...50 {
            XCTAssertEqual(readFile(at: remoteDir, name: "file\(i).txt"), "Content \(i)")
        }
    }

    func testSyncNestedDirectories() throws {
        // Create nested structure
        try createFile(at: localDir, name: "a/b/c/deep.txt", content: "Deep")
        try createFile(at: localDir, name: "a/b/sibling.txt", content: "Sibling")
        try createFile(at: localDir, name: "top.txt", content: "Top")

        try startServer()

        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify structure
        XCTAssertEqual(readFile(at: remoteDir, name: "a/b/c/deep.txt"), "Deep")
        XCTAssertEqual(readFile(at: remoteDir, name: "a/b/sibling.txt"), "Sibling")
        XCTAssertEqual(readFile(at: remoteDir, name: "top.txt"), "Top")
    }

    func testSyncBinaryData() throws {
        // Create file with binary data
        let binaryData = Data((0..<1000).map { UInt8($0 % 256) })
        let fileURL = localDir.appendingPathComponent("binary.bin")
        try binaryData.write(to: fileURL)

        try startServer()

        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify binary data is identical
        let remoteData = try Data(contentsOf: remoteDir.appendingPathComponent("binary.bin"))
        XCTAssertEqual(remoteData, binaryData)
    }

    func testProgressCallback() throws {
        // Create a few files
        try createFile(at: localDir, name: "file1.txt", content: "One")
        try createFile(at: localDir, name: "file2.txt", content: "Two")
        try createFile(at: localDir, name: "file3.txt", content: "Three")

        try startServer()

        var progressCalls: [(String, Int, Int)] = []
        let client = SyncClient()
        client.onLog = nil
        client.onProgress = { path, current, total in
            progressCalls.append((path, current, total))
        }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Should have progress calls for each file
        XCTAssertEqual(progressCalls.count, 3)
        // Verify current/total progression
        for (i, call) in progressCalls.enumerated() {
            XCTAssertEqual(call.1, i + 1, "Current should increment")
            XCTAssertEqual(call.2, 3, "Total should be 3")
        }
    }

    // MARK: - Copy Optimization Tests

    func testPushCopyOptimizationForRename() throws {
        // Same content at different paths — should copy on server, not upload
        let content = "Same content for rename test"
        try createFile(at: localDir, name: "new_name.txt", content: content)
        try createFile(at: remoteDir, name: "old_name.txt", content: content)

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify correctness: remote has new_name.txt, not old_name.txt
        XCTAssertEqual(readFile(at: remoteDir, name: "new_name.txt"), content)
        XCTAssertFalse(fileExists(at: remoteDir, name: "old_name.txt"))

        // Verify optimization: copy happened, no upload
        let hasCopy = logMessages.contains { $0.contains("Copying (remote):") }
        let hasUpload = logMessages.contains { $0.contains("Uploading:") }
        XCTAssertTrue(hasCopy, "Should use remote copy for renamed file")
        XCTAssertFalse(hasUpload, "Should not upload when copy is possible")
    }

    func testPullCopyOptimizationForRename() throws {
        // Same content at different paths — should copy locally, not download
        let content = "Same content for pull rename test"
        try createFile(at: localDir, name: "old_name.txt", content: content)
        try createFile(at: remoteDir, name: "new_name.txt", content: content)

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.pull(localPath: localDir, from: "localhost", port: testPort)

        // Verify correctness: local has new_name.txt, not old_name.txt
        XCTAssertEqual(readFile(at: localDir, name: "new_name.txt"), content)
        XCTAssertFalse(fileExists(at: localDir, name: "old_name.txt"))

        // Verify optimization: local copy happened, no download
        let hasCopy = logMessages.contains { $0.contains("Copying (local):") }
        let hasDownload = logMessages.contains { $0.contains("Downloading:") }
        XCTAssertTrue(hasCopy, "Should use local copy for renamed file")
        XCTAssertFalse(hasDownload, "Should not download when copy is possible")
    }

    func testPushCopyOptimizationForDuplicate() throws {
        // Two local files with same content, remote has neither
        // First should upload, second should copy from the first
        let content = "Duplicate content for dedup test"
        try createFile(at: localDir, name: "a.txt", content: content)
        try createFile(at: localDir, name: "b.txt", content: content)

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify correctness
        XCTAssertEqual(readFile(at: remoteDir, name: "a.txt"), content)
        XCTAssertEqual(readFile(at: remoteDir, name: "b.txt"), content)

        // Verify optimization: one upload + one copy (sorted: a.txt uploads, b.txt copies)
        let uploadCount = logMessages.filter { $0.contains("Uploading:") }.count
        let copyCount = logMessages.filter { $0.contains("Copying (remote):") }.count
        XCTAssertEqual(uploadCount, 1, "Should upload first file")
        XCTAssertEqual(copyCount, 1, "Should copy second file from first")
    }

    func testCopyOverwriteExistingFile() throws {
        // Remote has target.txt with old content and source.txt with desired content
        // Local wants target.txt to have the new content — copy should overwrite
        let oldContent = "Old content"
        let newContent = "New content to copy"
        try createFile(at: localDir, name: "target.txt", content: newContent)
        try createFile(at: localDir, name: "source.txt", content: newContent)
        try createFile(at: remoteDir, name: "target.txt", content: oldContent)
        try createFile(at: remoteDir, name: "source.txt", content: newContent)

        try startServer()

        let client = SyncClient()
        client.onLog = nil
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify: target.txt was overwritten with new content via copy
        XCTAssertEqual(readFile(at: remoteDir, name: "target.txt"), newContent)
        XCTAssertEqual(readFile(at: remoteDir, name: "source.txt"), newContent)
    }

    func testPushSwappedContents() throws {
        // Classic swap: two files exchange their contents
        // hello.txt had "world", now has "hello"
        // world.txt had "hello", now has "world"
        try createFile(at: localDir, name: "hello.txt", content: "hello")
        try createFile(at: localDir, name: "world.txt", content: "world")
        try createFile(at: remoteDir, name: "hello.txt", content: "world")
        try createFile(at: remoteDir, name: "world.txt", content: "hello")

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Both files must have correct swapped content
        XCTAssertEqual(readFile(at: remoteDir, name: "hello.txt"), "hello")
        XCTAssertEqual(readFile(at: remoteDir, name: "world.txt"), "world")

        // Verify optimization: all copies, no uploads (content already on server)
        let hasUpload = logMessages.contains { $0.contains("Uploading:") }
        let copyCount = logMessages.filter { $0.contains("Copying (remote):") }.count
        XCTAssertFalse(hasUpload, "Swap should not require any uploads")
        XCTAssertGreaterThanOrEqual(copyCount, 2, "Swap should use server-side copies")
    }

    func testPushCopyAllPathsChangedSameContent() throws {
        // All paths differ but content is the same — zero transfers
        // Local: a.txt (E), b.txt (E)  →  Remote: c.txt (E), d.txt (E)
        let content = "Same content everywhere"
        try createFile(at: localDir, name: "a.txt", content: content)
        try createFile(at: localDir, name: "b.txt", content: content)
        try createFile(at: remoteDir, name: "c.txt", content: content)
        try createFile(at: remoteDir, name: "d.txt", content: content)

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify correctness: remote mirrors local
        XCTAssertEqual(readFile(at: remoteDir, name: "a.txt"), content)
        XCTAssertEqual(readFile(at: remoteDir, name: "b.txt"), content)
        XCTAssertFalse(fileExists(at: remoteDir, name: "c.txt"))
        XCTAssertFalse(fileExists(at: remoteDir, name: "d.txt"))

        // Verify optimization: copies only, no uploads
        let hasUpload = logMessages.contains { $0.contains("Uploading:") }
        let copyCount = logMessages.filter { $0.contains("Copying (remote):") }.count
        XCTAssertFalse(hasUpload, "Should not upload — content already on server")
        XCTAssertEqual(copyCount, 2, "Should copy both files from existing remote content")
    }

    func testPushThreeWayRotation() throws {
        // 3-way rotation: A→B→C→A (each file gets the next one's content)
        try createFile(at: localDir, name: "a.txt", content: "content_c")
        try createFile(at: localDir, name: "b.txt", content: "content_a")
        try createFile(at: localDir, name: "c.txt", content: "content_b")
        try createFile(at: remoteDir, name: "a.txt", content: "content_a")
        try createFile(at: remoteDir, name: "b.txt", content: "content_b")
        try createFile(at: remoteDir, name: "c.txt", content: "content_c")

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify correctness
        XCTAssertEqual(readFile(at: remoteDir, name: "a.txt"), "content_c")
        XCTAssertEqual(readFile(at: remoteDir, name: "b.txt"), "content_a")
        XCTAssertEqual(readFile(at: remoteDir, name: "c.txt"), "content_b")

        // Verify optimization: no uploads
        let hasUpload = logMessages.contains { $0.contains("Uploading:") }
        XCTAssertFalse(hasUpload, "3-way rotation should not require uploads")
    }

    func testCopyThenDeleteOrdering() throws {
        // Rename scenario: old.txt on remote should be used as copy source
        // then deleted — order matters
        let content = "Content that moves from old to new path"
        try createFile(at: localDir, name: "moved.txt", content: content)
        try createFile(at: remoteDir, name: "original.txt", content: content)

        try startServer()

        var logMessages: [String] = []
        let client = SyncClient()
        client.onLog = { logMessages.append($0) }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Verify correctness
        XCTAssertEqual(readFile(at: remoteDir, name: "moved.txt"), content)
        XCTAssertFalse(fileExists(at: remoteDir, name: "original.txt"))

        // Verify ordering: copy before delete in log
        let copyIndex = logMessages.firstIndex { $0.contains("Copying (remote):") }
        let deleteIndex = logMessages.firstIndex { $0.contains("Deleting (remote):") }
        XCTAssertNotNil(copyIndex, "Should have copy operation")
        XCTAssertNotNil(deleteIndex, "Should have delete operation")
        if let ci = copyIndex, let di = deleteIndex {
            XCTAssertTrue(ci < di, "Copy should execute before delete")
        }
    }
}
