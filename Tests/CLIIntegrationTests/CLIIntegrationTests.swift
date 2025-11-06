import XCTest
import Foundation

@available(macOS 13.0, *)
final class CLIIntegrationTests: XCTestCase {

    var tempDir: URL!
    var cliPath: URL!

    override func setUp() async throws {
        // Create temporary directory for tests
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("diffalla-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Find CLI executable
        cliPath = try findCLI()
    }

    override func tearDown() async throws {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helper Functions

    func findCLI() throws -> URL {
        // Look for built CLI in .build directory
        let currentDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Try debug build first
        let debugPath = currentDir
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("diffalla")

        if FileManager.default.fileExists(atPath: debugPath.path) {
            return debugPath
        }

        // Try release build
        let releasePath = currentDir
            .appendingPathComponent(".build")
            .appendingPathComponent("release")
            .appendingPathComponent("diffalla")

        if FileManager.default.fileExists(atPath: releasePath.path) {
            return releasePath
        }

        throw TestError.cliNotFound("CLI not found at \(debugPath.path) or \(releasePath.path)")
    }

    struct CLIResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    func runCLI(_ args: [String]) throws -> CLIResult {
        let process = Process()
        process.executableURL = cliPath
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    func createTestDirectory(name: String, files: [String: String]) throws -> URL {
        let dir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (path, content) in files {
            let fileURL = dir.appendingPathComponent(path)
            let dirURL = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return dir
    }

    // MARK: - Basic Tests

    func testVersion() throws {
        let result = try runCLI(["--version"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("0.9.0") || result.stdout.contains("1.0.0"))
    }

    func testHelp() throws {
        let result = try runCLI(["--help"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("USAGE"))
        XCTAssertTrue(result.stdout.contains("snapshot"))
        XCTAssertTrue(result.stdout.contains("compare"))
        XCTAssertTrue(result.stdout.contains("patch"))
        XCTAssertTrue(result.stdout.contains("sync"))
    }

    func testUnknownCommand() throws {
        let result = try runCLI(["unknown-command"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - Snapshot Command Tests

    func testSnapshotCommand() throws {
        // Create test directory
        let testDir = try createTestDirectory(name: "snapshot-test", files: [
            "file1.txt": "content1",
            "file2.txt": "content2",
            "subdir/file3.txt": "content3"
        ])

        let snapshotPath = tempDir.appendingPathComponent("test.snapshot").path

        // Create snapshot
        let result = try runCLI(["snapshot", testDir.path, "-o", snapshotPath])
        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout), stderr: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath))
        XCTAssertTrue(result.stdout.contains("Files:") || result.stdout.contains("Snapshot created"))
    }

    func testSnapshotInvalidDirectory() throws {
        let invalidPath = tempDir.appendingPathComponent("nonexistent").path
        let snapshotPath = tempDir.appendingPathComponent("test.snapshot").path

        let result = try runCLI(["snapshot", invalidPath, "-o", snapshotPath])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    func testSnapshotWithFlags() throws {
        let testDir = try createTestDirectory(name: "snapshot-flags", files: [
            "file.txt": "content",
            "excluded.log": "should be excluded"
        ])

        let snapshotPath = tempDir.appendingPathComponent("test-flags.snapshot").path

        // Create snapshot with exclude pattern
        let result = try runCLI(["snapshot", testDir.path, "-o", snapshotPath, "--exclude", "*.log"])
        XCTAssertEqual(result.exitCode, 0, "stdout: \(result.stdout), stderr: \(result.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotPath))
    }

    // MARK: - Compare Command Tests

    func testCompareIdenticalDirectories() throws {
        let dir1 = try createTestDirectory(name: "compare-a", files: [
            "file.txt": "content"
        ])
        let dir2 = try createTestDirectory(name: "compare-b", files: [
            "file.txt": "content"
        ])

        let result = try runCLI(["compare", dir1.path, dir2.path])
        XCTAssertEqual(result.exitCode, 0, "Identical directories should exit 0: stdout=\(result.stdout), stderr=\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("identical") || result.stdout.contains("0 files"), "Expected 'identical' or '0 files', got: \(result.stdout)")
    }

    func testCompareDifferentDirectories() throws {
        let dir1 = try createTestDirectory(name: "compare-c", files: [
            "file1.txt": "content1"
        ])
        let dir2 = try createTestDirectory(name: "compare-d", files: [
            "file2.txt": "content2"
        ])

        let result = try runCLI(["compare", dir1.path, dir2.path])
        XCTAssertEqual(result.exitCode, 1, "Different directories should exit 1")
        XCTAssertTrue(result.stdout.contains("Added") || result.stdout.contains("Removed"))
    }

    func testCompareWithSummary() throws {
        let dir1 = try createTestDirectory(name: "compare-e", files: [
            "file1.txt": "content1"
        ])
        let dir2 = try createTestDirectory(name: "compare-f", files: [
            "file1.txt": "modified",
            "file2.txt": "content2"
        ])

        let result = try runCLI(["compare", dir1.path, dir2.path, "--summary"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("Added:") || result.stdout.contains("Modified:"))
    }

    // MARK: - Patch Command Tests

    func testPatchCreateApply() throws {
        // Create source and destination directories
        let source = try createTestDirectory(name: "patch-source", files: [
            "file1.txt": "content1"
        ])
        let dest = try createTestDirectory(name: "patch-dest", files: [
            "file1.txt": "content1",
            "file2.txt": "content2"
        ])

        let patchPath = tempDir.appendingPathComponent("test.patch").path

        // Create patch
        let createResult = try runCLI(["patch", "create", source.path, dest.path, "-o", patchPath])
        XCTAssertEqual(createResult.exitCode, 0, "stderr: \(createResult.stderr)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: patchPath))

        // Apply patch to source directory
        let applyResult = try runCLI(["patch", "apply", patchPath, source.path])
        XCTAssertEqual(applyResult.exitCode, 0, "stderr: \(applyResult.stderr)")

        // Verify file2.txt was added
        let file2URL = source.appendingPathComponent("file2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2URL.path))
        let content = try String(contentsOf: file2URL, encoding: .utf8)
        XCTAssertEqual(content, "content2")
    }

    func testPatchDryRun() throws {
        let source = try createTestDirectory(name: "patch-dry-source", files: [
            "file1.txt": "content1"
        ])
        let dest = try createTestDirectory(name: "patch-dry-dest", files: [
            "file1.txt": "content1",
            "file2.txt": "content2"
        ])

        let patchPath = tempDir.appendingPathComponent("test-dry.patch").path

        // Create patch
        _ = try runCLI(["patch", "create", source.path, dest.path, "-o", patchPath])

        // Dry run apply
        let dryResult = try runCLI(["patch", "apply", patchPath, source.path, "--dry-run"])
        XCTAssertEqual(dryResult.exitCode, 0)
        XCTAssertTrue(dryResult.stdout.contains("Dry Run") || dryResult.stdout.contains("dry run"))

        // Verify file2.txt was NOT added (dry run)
        let file2URL = source.appendingPathComponent("file2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2URL.path))
    }

    func testPatchRevert() throws {
        let source = try createTestDirectory(name: "patch-revert-source", files: [
            "file1.txt": "original"
        ])
        let dest = try createTestDirectory(name: "patch-revert-dest", files: [
            "file1.txt": "modified"
        ])

        let patchPath = tempDir.appendingPathComponent("test-revert.patch").path

        // Create reversible patch
        _ = try runCLI(["patch", "create", source.path, dest.path, "-o", patchPath, "--reversible"])

        // Apply patch
        _ = try runCLI(["patch", "apply", patchPath, source.path])

        // Verify modification
        let file1URL = source.appendingPathComponent("file1.txt")
        var content = try String(contentsOf: file1URL, encoding: .utf8)
        XCTAssertEqual(content, "modified")

        // Revert patch
        let revertResult = try runCLI(["patch", "revert", patchPath, source.path])
        XCTAssertEqual(revertResult.exitCode, 0, "stderr: \(revertResult.stderr)")

        // Verify reverted to original
        content = try String(contentsOf: file1URL, encoding: .utf8)
        XCTAssertEqual(content, "original")
    }

    func testPatchRevertNonReversible() throws {
        let source = try createTestDirectory(name: "patch-nonrev-source", files: ["file.txt": "a"])
        let dest = try createTestDirectory(name: "patch-nonrev-dest", files: ["file.txt": "b"])

        let patchPath = tempDir.appendingPathComponent("nonreversible.patch").path

        // Create non-reversible patch (no --reversible flag)
        _ = try runCLI(["patch", "create", source.path, dest.path, "-o", patchPath])
        _ = try runCLI(["patch", "apply", patchPath, source.path])

        // Try to revert - should fail
        let revertResult = try runCLI(["patch", "revert", patchPath, source.path])
        XCTAssertNotEqual(revertResult.exitCode, 0, "Non-reversible patch should not be revertable")
        XCTAssertTrue(revertResult.stdout.contains("not reversible") || revertResult.stdout.contains("no revert data"))
    }

    // MARK: - Sync Command Tests

    func testSyncUnidirectional() throws {
        let source = try createTestDirectory(name: "sync-source", files: [
            "file1.txt": "content1",
            "file2.txt": "content2"
        ])
        let dest = try createTestDirectory(name: "sync-dest", files: [
            "file1.txt": "old content"
        ])

        let result = try runCLI(["sync", source.path, dest.path])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        // Verify file2.txt was synced
        let file2URL = dest.appendingPathComponent("file2.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2URL.path))

        // Verify file1.txt was updated
        let file1Content = try String(contentsOf: dest.appendingPathComponent("file1.txt"), encoding: .utf8)
        XCTAssertEqual(file1Content, "content1")
    }

    func testSyncDryRun() throws {
        let source = try createTestDirectory(name: "sync-dry-source", files: [
            "file.txt": "new content"
        ])
        let dest = try createTestDirectory(name: "sync-dry-dest", files: [:])

        let result = try runCLI(["sync", source.path, dest.path, "--dry-run"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("DRY RUN") || result.stdout.contains("dry run"))

        // Verify nothing was actually synced
        let fileURL = dest.appendingPathComponent("file.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSyncWithDeleteFlag() throws {
        let source = try createTestDirectory(name: "sync-del-source", files: [
            "file1.txt": "keep"
        ])
        let dest = try createTestDirectory(name: "sync-del-dest", files: [
            "file1.txt": "keep",
            "file2.txt": "delete me"
        ])

        let result = try runCLI(["sync", source.path, dest.path, "--delete"])
        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")

        // Verify file2.txt was deleted
        let file2URL = dest.appendingPathComponent("file2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file2URL.path))

        // Verify file1.txt still exists
        let file1URL = dest.appendingPathComponent("file1.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1URL.path))
    }

    func testSyncBidirectionalRejectsDelete() throws {
        let dir1 = try createTestDirectory(name: "sync-bi-a", files: ["a.txt": "a"])
        let dir2 = try createTestDirectory(name: "sync-bi-b", files: ["b.txt": "b"])

        // Should reject --delete with --bidirectional
        let result = try runCLI(["sync", dir1.path, dir2.path, "--bidirectional", "--delete"])
        XCTAssertEqual(result.exitCode, 2, "Should exit with usage error code")
        XCTAssertTrue(result.stdout.contains("cannot be used") || result.stdout.contains("bidirectional"))
    }

    // MARK: - Export Command Tests

    func testExportCommand() throws {
        let source = try createTestDirectory(name: "export-source", files: ["a.txt": "a"])
        let dest = try createTestDirectory(name: "export-dest", files: ["b.txt": "b"])

        let patchPath = tempDir.appendingPathComponent("export.patch").path
        _ = try runCLI(["patch", "create", source.path, dest.path, "-o", patchPath])

        // Export as text
        let exportResult = try runCLI(["export", patchPath, "-f", "text"])
        XCTAssertEqual(exportResult.exitCode, 0, "stderr: \(exportResult.stderr)")
        XCTAssertFalse(exportResult.stdout.isEmpty)

        // Export to file
        let outputPath = tempDir.appendingPathComponent("export.txt").path
        let fileResult = try runCLI(["export", patchPath, "-f", "text", "-o", outputPath])
        XCTAssertEqual(fileResult.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
    }

    func testExportInvalidFormat() throws {
        let source = try createTestDirectory(name: "export-fmt-source", files: ["a.txt": "a"])
        let dest = try createTestDirectory(name: "export-fmt-dest", files: ["b.txt": "b"])

        let patchPath = tempDir.appendingPathComponent("export-fmt.patch").path
        _ = try runCLI(["patch", "create", source.path, dest.path, "-o", patchPath])

        let result = try runCLI(["export", patchPath, "-f", "invalid-format"])
        XCTAssertNotEqual(result.exitCode, 0)
    }

    // MARK: - Verify Command Tests

    func testVerifyMatchingDirectory() throws {
        let testDir = try createTestDirectory(name: "verify-match", files: [
            "file1.txt": "content1",
            "file2.txt": "content2"
        ])

        let snapshotPath = tempDir.appendingPathComponent("verify.snapshot").path
        _ = try runCLI(["snapshot", testDir.path, "-o", snapshotPath])

        // Verify should succeed (exit 0)
        let result = try runCLI(["verify", testDir.path, snapshotPath])
        XCTAssertEqual(result.exitCode, 0, "Matching directory should exit 0")
        XCTAssertTrue(result.stdout.contains("successful") || result.stdout.contains("matches"))
    }

    func testVerifyModifiedDirectory() throws {
        let testDir = try createTestDirectory(name: "verify-modified", files: [
            "file.txt": "original"
        ])

        let snapshotPath = tempDir.appendingPathComponent("verify-mod.snapshot").path
        _ = try runCLI(["snapshot", testDir.path, "-o", snapshotPath])

        // Modify directory
        try "modified".write(to: testDir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Verify should fail (exit 1)
        let result = try runCLI(["verify", testDir.path, snapshotPath])
        XCTAssertEqual(result.exitCode, 1, "Modified directory should exit 1")
        XCTAssertTrue(result.stdout.contains("failed") || result.stdout.contains("Modified"))
    }

    func testVerifyWithShowDiff() throws {
        let testDir = try createTestDirectory(name: "verify-diff", files: [
            "file.txt": "original"
        ])

        let snapshotPath = tempDir.appendingPathComponent("verify-diff.snapshot").path
        _ = try runCLI(["snapshot", testDir.path, "-o", snapshotPath])

        // Add a new file
        try "new".write(to: testDir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

        let result = try runCLI(["verify", testDir.path, snapshotPath, "--show-diff"])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stdout.contains("new.txt") || result.stdout.contains("Added"))
    }

    // MARK: - Error Handling Tests

    func testErrorHandling() throws {
        // Test missing required argument
        let result1 = try runCLI(["snapshot"])
        XCTAssertNotEqual(result1.exitCode, 0)

        // Test invalid option
        let result2 = try runCLI(["snapshot", "/tmp", "--invalid-option"])
        XCTAssertNotEqual(result2.exitCode, 0)

        // Test nonexistent patch file
        let result3 = try runCLI(["patch", "apply", "/nonexistent.patch", "/tmp"])
        XCTAssertNotEqual(result3.exitCode, 0)
    }
}

enum TestError: Error {
    case cliNotFound(String)
}
