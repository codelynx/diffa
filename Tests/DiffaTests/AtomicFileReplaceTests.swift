import XCTest
@testable import Diffa
import Foundation

final class AtomicFileReplaceTests: XCTestCase {
    var tempDir: URL!
    var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("DiffaAtomicReplaceTests-\(UUID().uuidString)")
        try! fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if fileManager.fileExists(atPath: tempDir.path) {
            try? fileManager.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    /// Names in tempDir, ignoring nothing — staging leftovers must show up here
    private func directoryContents(_ url: URL) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: url.path).sorted()
    }

    // MARK: - stagingURL

    func testStagingURLIsFreshAndDistinct() throws {
        let destination = tempDir.appendingPathComponent("out.diffa")
        let first = try AtomicFileReplace.stagingURL(for: destination)
        let second = try AtomicFileReplace.stagingURL(for: destination)
        defer {
            AtomicFileReplace.discardStaging(first)
            AtomicFileReplace.discardStaging(second)
        }

        XCTAssertNotEqual(first, destination)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(fileManager.fileExists(atPath: first.path))
        XCTAssertTrue(first.lastPathComponent.hasPrefix(".out.diffa."))
    }

    // MARK: - replaceItem

    func testReplaceOverwritesExistingFile() throws {
        let destination = tempDir.appendingPathComponent("file.txt")
        try "old".write(to: destination, atomically: false, encoding: .utf8)

        let staging = try AtomicFileReplace.stagingURL(for: destination)
        defer { AtomicFileReplace.discardStaging(staging) }
        try "new".write(to: staging, atomically: false, encoding: .utf8)

        try AtomicFileReplace.replaceItem(at: destination, withItemAt: staging)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new")
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
    }

    func testReplaceMovesIntoPlaceWhenDestinationMissing() throws {
        let destination = tempDir.appendingPathComponent("fresh.txt")

        let staging = try AtomicFileReplace.stagingURL(for: destination)
        defer { AtomicFileReplace.discardStaging(staging) }
        try "content".write(to: staging, atomically: false, encoding: .utf8)

        try AtomicFileReplace.replaceItem(at: destination, withItemAt: staging)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "content")
        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
    }

    func testFailedReplaceLeavesDestinationUntouched() throws {
        let destination = tempDir.appendingPathComponent("keep.txt")
        try "precious".write(to: destination, atomically: false, encoding: .utf8)

        // Staging file never written, so the swap must fail
        let staging = try AtomicFileReplace.stagingURL(for: destination)
        defer { AtomicFileReplace.discardStaging(staging) }

        XCTAssertThrowsError(try AtomicFileReplace.replaceItem(at: destination, withItemAt: staging))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "precious")
    }

    func testFailedReplaceOverDirectoryLeavesBothInPlace() throws {
        #if canImport(Darwin)
        throw XCTSkip("replaceItemAt semantics for file-over-directory differ on Darwin")
        #else
        // A non-empty directory can't be replaced by a file
        let destination = tempDir.appendingPathComponent("folder")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        try "inside".write(to: destination.appendingPathComponent("child.txt"), atomically: false, encoding: .utf8)

        let staging = try AtomicFileReplace.stagingURL(for: destination)
        defer { AtomicFileReplace.discardStaging(staging) }
        try "new".write(to: staging, atomically: false, encoding: .utf8)

        XCTAssertThrowsError(try AtomicFileReplace.replaceItem(at: destination, withItemAt: staging)) { error in
            XCTAssertTrue(error is FileReplaceError, "Expected FileReplaceError, got \(error)")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: destination.appendingPathComponent("child.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: staging.path), "Source stays for the caller to discard")
        #endif
    }

    func testDiscardStagingRemovesLeftoverAndNeverTheDestination() throws {
        let destination = tempDir.appendingPathComponent("dest.txt")
        try "keep".write(to: destination, atomically: false, encoding: .utf8)

        let staging = try AtomicFileReplace.stagingURL(for: destination)
        try "abandoned".write(to: staging, atomically: false, encoding: .utf8)

        AtomicFileReplace.discardStaging(staging)

        XCTAssertFalse(fileManager.fileExists(atPath: staging.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep")
        XCTAssertEqual(try directoryContents(tempDir), ["dest.txt"])
    }

    // MARK: - SnapshotEngine.createSnapshot(atomicallySavingTo:)

    private func makeSourceDirectory(_ name: String, files: [String: String]) throws -> URL {
        let dir = tempDir.appendingPathComponent(name)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, content) in files {
            try content.write(to: dir.appendingPathComponent(path), atomically: false, encoding: .utf8)
        }
        return dir
    }

    func testAtomicSnapshotCreatesNewFile() async throws {
        let source = try makeSourceDirectory("src", files: ["a.txt": "a", "b.txt": "b"])
        let output = tempDir.appendingPathComponent("out")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        let destination = output.appendingPathComponent("snap.diffa")

        let snapshot = try await SnapshotEngine().createSnapshot(
            from: source, atomicallySavingTo: destination, options: ScanOptions())

        XCTAssertEqual(snapshot.metadata.totalFiles, 2)
        XCTAssertEqual(snapshot.databaseURL.standardizedFileURL, destination.standardizedFileURL)
        XCTAssertEqual(try directoryContents(output), ["snap.diffa"], "No staging leftovers")
    }

    func testAtomicSnapshotReplacesExistingSnapshot() async throws {
        let output = tempDir.appendingPathComponent("out")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        let destination = output.appendingPathComponent("snap.diffa")

        let first = try makeSourceDirectory("first", files: ["one.txt": "1"])
        _ = try await SnapshotEngine().createSnapshot(
            from: first, atomicallySavingTo: destination, options: ScanOptions())

        let second = try makeSourceDirectory("second", files: ["x.txt": "x", "y.txt": "y", "z.txt": "z"])
        _ = try await SnapshotEngine().createSnapshot(
            from: second, atomicallySavingTo: destination, options: ScanOptions())

        let reopened = try Snapshot.open(at: destination)
        XCTAssertEqual(reopened.metadata.totalFiles, 3)
        XCTAssertEqual(try directoryContents(output), ["snap.diffa"], "No staging leftovers")
    }

    func testFailedAtomicSnapshotPreservesExistingSnapshot() async throws {
        let output = tempDir.appendingPathComponent("out")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        let destination = output.appendingPathComponent("snap.diffa")

        let original = try makeSourceDirectory("original", files: ["keep.txt": "keep"])
        _ = try await SnapshotEngine().createSnapshot(
            from: original, atomicallySavingTo: destination, options: ScanOptions())
        let originalBytes = try Data(contentsOf: destination)

        // Scanning a directory that doesn't exist must fail
        let missing = tempDir.appendingPathComponent("does-not-exist")
        do {
            _ = try await SnapshotEngine().createSnapshot(
                from: missing, atomicallySavingTo: destination, options: ScanOptions())
            XCTFail("Expected scan of a missing directory to throw")
        } catch {
            // expected
        }

        XCTAssertEqual(try Data(contentsOf: destination), originalBytes, "Existing snapshot must be untouched")
        XCTAssertEqual(try Snapshot.open(at: destination).metadata.totalFiles, 1)
        XCTAssertEqual(try directoryContents(output), ["snap.diffa"], "Staging file must be cleaned up")
    }

    func testSnapshotOfMissingDirectoryThrowsBeforeCreatingFile() async throws {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let destination = tempDir.appendingPathComponent("snap.diffa")

        do {
            _ = try await SnapshotEngine().createSnapshot(
                from: missing, saveTo: destination, options: ScanOptions())
            XCTFail("Expected scan of a missing directory to throw")
        } catch DiffaError.fileNotFound(let path) {
            XCTAssertEqual(path, missing.path)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: destination.path), "No empty snapshot left behind")
    }
}
