import XCTest
@testable import Diffa

#if canImport(Network)
import Network

@available(macOS 10.14, *)
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
        server.onLog = { print("[Server] \($0)") }
        try server.startAsync()
        // Give server a moment to be ready
        Thread.sleep(forTimeInterval: 0.1)
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { message in
            print("[Client] \(message)")
            uploadMessages.append(message)
        }
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
        client.onLog = { message in
            print("[Client] \(message)")
            uploadMessages.append(message)
        }
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
        client.onLog = { print("[Client] \($0)") }
        try client.push(localPath: localDir, to: "localhost", port: testPort)

        // Remote should be empty
        XCTAssertFalse(fileExists(at: remoteDir, name: "file.txt"))
    }

    func testPullEmptyRemote() throws {
        // Remote is empty, local has files
        try createFile(at: localDir, name: "file.txt", content: "Delete")

        try startServer()

        let client = SyncClient()
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
        client.onLog = { print("[Client] \($0)") }
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
}
#endif
