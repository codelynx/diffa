import XCTest
@testable import Diffa

final class MoveDetectorTests: XCTestCase {

    // MARK: - Step 3: Move Detection Tests

    func testDetectSimpleMove() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        // Create file in dir1
        let file1 = dir1.appendingPathComponent("original.txt")
        try "Test content for move detection".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot of dir1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.db")
        let engine = SnapshotEngine()
        let snapshot1 = try await engine.createSnapshot(
            from: dir1,
            saveTo: snapshot1URL,
            options: ScanOptions()
        )

        // Move file to new name in dir2
        let file2 = dir2.appendingPathComponent("renamed.txt")
        try "Test content for move detection".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot of dir2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.db")
        let snapshot2 = try await engine.createSnapshot(
            from: dir2,
            saveTo: snapshot2URL,
            options: ScanOptions()
        )

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect moves
        let detector = MoveDetector()
        let moves = try detector.detectMoves(difference: difference)

        // Should detect one move
        XCTAssertEqual(moves.count, 1, "Should detect one move")

        let move = moves[0]
        XCTAssertEqual(move.fromPath, "original.txt", "From path should match")
        XCTAssertEqual(move.toPath, "renamed.txt", "To path should match")
        XCTAssertFalse(move.hash.isEmpty, "Hash should be present")
        XCTAssertGreaterThan(move.size, 0, "Size should be positive")
    }

    func testDetectMoveToSubdirectory() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        // Create file in root of dir1
        let file1 = dir1.appendingPathComponent("file.txt")
        try "Move to subdirectory test".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot of dir1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.db")
        let engine = SnapshotEngine()
        let snapshot1 = try await engine.createSnapshot(
            from: dir1,
            saveTo: snapshot1URL,
            options: ScanOptions()
        )

        // Move file to subdirectory in dir2
        let subdir = dir2.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let file2 = subdir.appendingPathComponent("file.txt")
        try "Move to subdirectory test".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot of dir2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.db")
        let snapshot2 = try await engine.createSnapshot(
            from: dir2,
            saveTo: snapshot2URL,
            options: ScanOptions()
        )

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect moves
        let detector = MoveDetector()
        let moves = try detector.detectMoves(difference: difference)

        // Should detect one move
        XCTAssertEqual(moves.count, 1, "Should detect one move to subdirectory")

        let move = moves[0]
        XCTAssertEqual(move.fromPath, "file.txt", "From path should be root")
        XCTAssertEqual(move.toPath, "subdir/file.txt", "To path should be in subdirectory")
    }

    func testDetectMultipleMoves() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        // Create multiple files in dir1
        let file1a = dir1.appendingPathComponent("a.txt")
        let file1b = dir1.appendingPathComponent("b.txt")
        let file1c = dir1.appendingPathComponent("c.txt")
        try "Content A".write(to: file1a, atomically: true, encoding: .utf8)
        try "Content B".write(to: file1b, atomically: true, encoding: .utf8)
        try "Content C".write(to: file1c, atomically: true, encoding: .utf8)

        // Create snapshot of dir1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.db")
        let engine = SnapshotEngine()
        let snapshot1 = try await engine.createSnapshot(
            from: dir1,
            saveTo: snapshot1URL,
            options: ScanOptions()
        )

        // Rename all files in dir2
        let file2a = dir2.appendingPathComponent("alpha.txt")
        let file2b = dir2.appendingPathComponent("beta.txt")
        let file2c = dir2.appendingPathComponent("gamma.txt")
        try "Content A".write(to: file2a, atomically: true, encoding: .utf8)
        try "Content B".write(to: file2b, atomically: true, encoding: .utf8)
        try "Content C".write(to: file2c, atomically: true, encoding: .utf8)

        // Create snapshot of dir2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.db")
        let snapshot2 = try await engine.createSnapshot(
            from: dir2,
            saveTo: snapshot2URL,
            options: ScanOptions()
        )

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect moves
        let detector = MoveDetector()
        let moves = try detector.detectMoves(difference: difference)

        // Should detect three moves
        XCTAssertEqual(moves.count, 3, "Should detect three moves")

        // Verify all moves are detected
        let fromPaths = Set(moves.map { $0.fromPath })
        let toPaths = Set(moves.map { $0.toPath })

        XCTAssertTrue(fromPaths.contains("a.txt"), "Should detect move from a.txt")
        XCTAssertTrue(fromPaths.contains("b.txt"), "Should detect move from b.txt")
        XCTAssertTrue(fromPaths.contains("c.txt"), "Should detect move from c.txt")

        XCTAssertTrue(toPaths.contains("alpha.txt"), "Should detect move to alpha.txt")
        XCTAssertTrue(toPaths.contains("beta.txt"), "Should detect move to beta.txt")
        XCTAssertTrue(toPaths.contains("gamma.txt"), "Should detect move to gamma.txt")
    }

    func testDetectNoMoves() async throws {
        // Create temporary directories
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        // Create file in dir1
        let file1 = dir1.appendingPathComponent("file1.txt")
        try "Content 1".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot of dir1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.db")
        let engine = SnapshotEngine()
        let snapshot1 = try await engine.createSnapshot(
            from: dir1,
            saveTo: snapshot1URL,
            options: ScanOptions()
        )

        // Create different file in dir2 (not a move)
        let file2 = dir2.appendingPathComponent("file2.txt")
        try "Content 2".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot of dir2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.db")
        let snapshot2 = try await engine.createSnapshot(
            from: dir2,
            saveTo: snapshot2URL,
            options: ScanOptions()
        )

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect moves
        let detector = MoveDetector()
        let moves = try detector.detectMoves(difference: difference)

        // Should detect no moves (only add and delete)
        XCTAssertEqual(moves.count, 0, "Should detect no moves when content differs")

        // Verify we have additions and removals
        let removed = try difference.removed
        let added = try difference.added
        XCTAssertEqual(removed.count, 1, "Should have one removal")
        XCTAssertEqual(added.count, 1, "Should have one addition")
    }

    func testDetectMoveVsCopy() async throws {
        // Test distinguishing move from copy:
        // - Move: file removed from one location, same content added elsewhere
        // - Copy: file exists in both locations

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dir1 = tempDir.appendingPathComponent("dir1")
        let dir2 = tempDir.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        // Create file in dir1
        let file1 = dir1.appendingPathComponent("original.txt")
        try "Shared content".write(to: file1, atomically: true, encoding: .utf8)

        // Create snapshot of dir1
        let snapshot1URL = tempDir.appendingPathComponent("snapshot1.db")
        let engine = SnapshotEngine()
        let snapshot1 = try await engine.createSnapshot(
            from: dir1,
            saveTo: snapshot1URL,
            options: ScanOptions()
        )

        // For copy scenario: keep original and add copy in dir2
        // For move scenario: only new location in dir2
        // Let's test move scenario
        let file2 = dir2.appendingPathComponent("copy.txt")
        try "Shared content".write(to: file2, atomically: true, encoding: .utf8)

        // Create snapshot of dir2
        let snapshot2URL = tempDir.appendingPathComponent("snapshot2.db")
        let snapshot2 = try await engine.createSnapshot(
            from: dir2,
            saveTo: snapshot2URL,
            options: ScanOptions()
        )

        // Compare snapshots
        let difference = try Difference.compare(source: snapshot1, destination: snapshot2)

        // Detect moves
        let detector = MoveDetector()
        let moves = try detector.detectMoves(difference: difference)

        // Should detect as move (original removed, copy added with same hash)
        XCTAssertEqual(moves.count, 1, "Should detect one move")

        let move = moves[0]
        XCTAssertEqual(move.fromPath, "original.txt")
        XCTAssertEqual(move.toPath, "copy.txt")

        // Verify that after detecting the move, there are no remaining additions/removals
        let (detectedMoves, additions, removals) = try detector.detectMovesWithRemainder(difference: difference)
        XCTAssertEqual(detectedMoves.count, 1, "Should detect one move")
        XCTAssertEqual(additions.count, 0, "Should have no remaining additions (files without hash)")
        XCTAssertEqual(removals.count, 0, "Should have no remaining removals (files without hash)")
    }
}
