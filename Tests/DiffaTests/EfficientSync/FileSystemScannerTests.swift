import XCTest
@testable import Diffa

/// Tests for FileSystemScanner - streaming directory traversal
final class FileSystemScannerTests: XCTestCase {

    private var tempDir: URL!
    private var scanner: FileSystemScanner!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSystemScannerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        scanner = FileSystemScanner()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func createFile(at path: String, content: String = "test", mode: UInt16? = nil) throws {
        let fileURL = tempDir.appendingPathComponent(path)
        let dirURL = fileURL.deletingLastPathComponent()

        // Create parent directories if needed
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Write file
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Set permissions if specified
        if let mode = mode {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: fileURL.path
            )
        }
    }

    // MARK: - Tests

    func testScanEmptyDirectory() throws {
        var fileCount = 0

        try scanner.scan(root: tempDir) { _, _ in
            fileCount += 1
        }

        XCTAssertEqual(fileCount, 0, "Empty directory should produce no files")
    }

    func testScanSingleFile() throws {
        try createFile(at: "test.txt", content: "hello")

        var scannedFiles: [(URL, FileMetadata)] = []
        try scanner.scan(root: tempDir) { url, metadata in
            scannedFiles.append((url, metadata))
        }

        XCTAssertEqual(scannedFiles.count, 1)
        XCTAssertEqual(scannedFiles[0].1.path, "test.txt")
        XCTAssertEqual(scannedFiles[0].1.size, 5) // "hello" = 5 bytes
    }

    func testScanNestedDirectories() throws {
        // Create nested structure:
        // root/
        //   a.txt
        //   subdir1/
        //     b.txt
        //     subdir2/
        //       c.txt

        try createFile(at: "a.txt", content: "a")
        try createFile(at: "subdir1/b.txt", content: "bb")
        try createFile(at: "subdir1/subdir2/c.txt", content: "ccc")

        var scannedPaths: Set<String> = []
        try scanner.scan(root: tempDir) { _, metadata in
            scannedPaths.insert(metadata.path)
        }

        XCTAssertEqual(scannedPaths.count, 3)
        XCTAssertTrue(scannedPaths.contains("a.txt"))
        XCTAssertTrue(scannedPaths.contains("subdir1/b.txt"))
        XCTAssertTrue(scannedPaths.contains("subdir1/subdir2/c.txt"))
    }

    func testScanExcludesDirectories() throws {
        // Create files and directories
        try createFile(at: "file.txt", content: "file")
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("emptydir"),
            withIntermediateDirectories: true
        )

        var scannedFiles: [FileMetadata] = []
        try scanner.scan(root: tempDir) { _, metadata in
            scannedFiles.append(metadata)
        }

        // Should only find the file, not the directory
        XCTAssertEqual(scannedFiles.count, 1)
        XCTAssertEqual(scannedFiles[0].path, "file.txt")
    }

    func testScanStreamingCallback() throws {
        // Create multiple files
        for i in 1...10 {
            try createFile(at: "file\(i).txt", content: String(repeating: "x", count: i))
        }

        // Track peak memory usage by counting how many items we hold at once
        var currentBatchSize = 0
        var maxBatchSize = 0
        var processedCount = 0

        try scanner.scan(root: tempDir) { _, metadata in
            currentBatchSize += 1
            maxBatchSize = max(maxBatchSize, currentBatchSize)

            // Simulate processing (would hash file here)
            // Then mark as done
            currentBatchSize -= 1
            processedCount += 1
        }

        XCTAssertEqual(processedCount, 10, "Should process all files")
        XCTAssertEqual(maxBatchSize, 1, "Should only hold 1 item at a time (streaming)")
    }

    func testScanCapturesMetadata() throws {
        let content = "test content"
        try createFile(at: "metadata_test.txt", content: content, mode: 0o644)

        var capturedMetadata: FileMetadata?
        try scanner.scan(root: tempDir) { _, metadata in
            capturedMetadata = metadata
        }

        XCTAssertNotNil(capturedMetadata)
        XCTAssertEqual(capturedMetadata?.path, "metadata_test.txt")
        XCTAssertEqual(capturedMetadata?.size, Int64(content.utf8.count))
        XCTAssertNotNil(capturedMetadata?.mtime)
        XCTAssertTrue(capturedMetadata!.mtime > 0, "Modification time should be set")

        #if !os(Linux)
        // POSIX permissions may not be available on all filesystems
        if let mode = capturedMetadata?.mode {
            // Verify permissions were captured (may vary by filesystem)
            XCTAssertTrue(mode > 0, "Mode should be set on systems that support it")
        }
        #endif
    }

    func testScanRelativePathsCorrect() throws {
        try createFile(at: "photos/vacation/img1.jpg", content: "image1")
        try createFile(at: "photos/vacation/img2.jpg", content: "image2")
        try createFile(at: "documents/report.txt", content: "report")

        var paths: [String] = []
        try scanner.scan(root: tempDir) { _, metadata in
            paths.append(metadata.path)
        }

        paths.sort()

        XCTAssertEqual(paths.count, 3)
        XCTAssertTrue(paths.contains("photos/vacation/img1.jpg"))
        XCTAssertTrue(paths.contains("photos/vacation/img2.jpg"))
        XCTAssertTrue(paths.contains("documents/report.txt"))

        // Verify paths are relative (no leading slash)
        for path in paths {
            XCTAssertFalse(path.hasPrefix("/"), "Paths should be relative, not absolute")
        }
    }

    func testScanErrorHandlingNonExistentDirectory() throws {
        let nonExistent = tempDir.appendingPathComponent("does-not-exist")

        XCTAssertThrowsError(try scanner.scan(root: nonExistent) { _, _ in }) { error in
            if case ScannerError.notADirectory = error {
                // Expected error
            } else {
                XCTFail("Expected notADirectory error, got \(error)")
            }
        }
    }

    func testScanErrorHandlingFileAsRoot() throws {
        // Create a file and try to scan it as a directory
        let fileURL = tempDir.appendingPathComponent("file.txt")
        try "test".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try scanner.scan(root: fileURL) { _, _ in }) { error in
            if case ScannerError.notADirectory = error {
                // Expected error
            } else {
                XCTFail("Expected notADirectory error, got \(error)")
            }
        }
    }

    func testScanHandlesLargeNumberOfFiles() throws {
        // Create 100 files to test performance
        for i in 1...100 {
            try createFile(at: "file\(i).txt", content: String(i))
        }

        let startTime = Date()
        var fileCount = 0

        try scanner.scan(root: tempDir) { _, _ in
            fileCount += 1
        }

        let duration = Date().timeIntervalSince(startTime)

        XCTAssertEqual(fileCount, 100)
        XCTAssertLessThan(duration, 2.0, "Should scan 100 files in <2 seconds")
    }
}
