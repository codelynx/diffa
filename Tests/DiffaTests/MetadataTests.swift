import XCTest
@testable import Diffa

final class MetadataTests: XCTestCase {

    // MARK: - Metadata Equality Tests

    func testMetadataEquality() throws {
        let date = Date()
        let perms = FilePermissions(posix: 0o755)

        let metadata1 = Metadata(
            modificationDate: date,
            size: 1024,
            permissions: perms,
            owner: "alice",
            group: "staff"
        )

        let metadata2 = Metadata(
            modificationDate: date,
            size: 1024,
            permissions: perms,
            owner: "alice",
            group: "staff"
        )

        // Should be equal
        XCTAssertEqual(metadata1, metadata2)
    }

    func testMetadataInequality() throws {
        let date = Date()
        let perms = FilePermissions(posix: 0o755)

        let metadata1 = Metadata(
            modificationDate: date,
            size: 1024,
            permissions: perms
        )

        let metadata2 = Metadata(
            modificationDate: date,
            size: 2048,  // Different size
            permissions: perms
        )

        // Should not be equal
        XCTAssertNotEqual(metadata1, metadata2)
    }

    func testMetadataWithoutOwnership() throws {
        let date = Date()
        let perms = FilePermissions(posix: 0o644)

        let metadata = Metadata(
            modificationDate: date,
            size: 512,
            permissions: perms
        )

        // Owner and group should be nil
        XCTAssertNil(metadata.owner)
        XCTAssertNil(metadata.group)
    }

    // MARK: - FilePermissions Conversion Tests

    func testFilePermissionsConversion() throws {
        // Test common permission combinations
        let testCases: [(UInt16, String, String)] = [
            (0o755, "rwxr-xr-x", "755"),  // Executable
            (0o644, "rw-r--r--", "644"),  // Regular file
            (0o600, "rw-------", "600"),  // Private file
            (0o777, "rwxrwxrwx", "777"),  // All permissions
            (0o000, "---------", "0"),    // No permissions
            (0o700, "rwx------", "700"),  // Owner only
            (0o444, "r--r--r--", "444"),  // Read-only
        ]

        for (posix, expectedSymbolic, expectedOctal) in testCases {
            let perms = FilePermissions(posix: posix)
            XCTAssertEqual(perms.symbolic, expectedSymbolic, "Failed for \(String(format: "0o%o", posix))")
            XCTAssertEqual(perms.octalString, expectedOctal, "Octal string failed for \(String(format: "0o%o", posix))")
        }
    }

    func testFilePermissionsEquality() throws {
        let perms1 = FilePermissions(posix: 0o755)
        let perms2 = FilePermissions(posix: 0o755)
        let perms3 = FilePermissions(posix: 0o644)

        XCTAssertEqual(perms1, perms2)
        XCTAssertNotEqual(perms1, perms3)
    }

    func testFilePermissionsSymbolicFormat() throws {
        let perms = FilePermissions(posix: 0o755)

        // Should be exactly 9 characters
        XCTAssertEqual(perms.symbolic.count, 9)

        // Should start with 'r' (owner read)
        XCTAssertTrue(perms.symbolic.hasPrefix("r"))

        // Should contain 'x' (owner execute)
        XCTAssertTrue(perms.symbolic.contains("x"))
    }

    // MARK: - Metadata Codable Tests

    func testMetadataCodable() throws {
        let date = Date()
        let perms = FilePermissions(posix: 0o755)

        let original = Metadata(
            modificationDate: date,
            size: 1024,
            permissions: perms,
            owner: "alice",
            group: "staff"
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(original)

        // Decode from JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Metadata.self, from: jsonData)

        // Should be equal
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(original.modificationDate.timeIntervalSince1970,
                       decoded.modificationDate.timeIntervalSince1970,
                       accuracy: 1.0)
    }

    func testMetadataCodableWithoutOwnership() throws {
        let date = Date()
        let perms = FilePermissions(posix: 0o644)

        let original = Metadata(
            modificationDate: date,
            size: 512,
            permissions: perms
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(original)

        // Decode from JSON
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Metadata.self, from: jsonData)

        // Should be equal
        XCTAssertEqual(original, decoded)
        XCTAssertNil(decoded.owner)
        XCTAssertNil(decoded.group)
    }

    func testFilePermissionsCodable() throws {
        let original = FilePermissions(posix: 0o755)

        // Encode to JSON
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(original)

        // Decode from JSON
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FilePermissions.self, from: jsonData)

        // Should be equal
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.posix, 0o755)
        XCTAssertEqual(decoded.symbolic, "rwxr-xr-x")
    }

    func testMetadataJSONStructure() throws {
        let date = Date(timeIntervalSince1970: 1699200000) // Fixed date for reproducible test
        let perms = FilePermissions(posix: 0o644)

        let metadata = Metadata(
            modificationDate: date,
            size: 1024,
            permissions: perms,
            owner: "testuser",
            group: "testgroup"
        )

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(metadata)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Verify JSON contains expected fields
        XCTAssertTrue(jsonString.contains("\"owner\""))
        XCTAssertTrue(jsonString.contains("\"group\""))
        XCTAssertTrue(jsonString.contains("\"permissions\""))
        XCTAssertTrue(jsonString.contains("\"size\""))
    }

    func testFilePermissionsJSONFormat() throws {
        let perms = FilePermissions(posix: 0o755)

        // Encode to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(perms)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        // Verify only 'posix' is encoded, NOT 'symbolic'
        XCTAssertTrue(jsonString.contains("\"posix\""), "JSON should contain 'posix' field")
        XCTAssertFalse(jsonString.contains("\"symbolic\""), "JSON should NOT contain 'symbolic' field (it's computed)")
        XCTAssertFalse(jsonString.contains("rwxr-xr-x"), "JSON should NOT contain symbolic representation")

        // Verify posix value
        XCTAssertTrue(jsonString.contains("493"), "JSON should contain posix value (755 octal = 493 decimal)")

        // Decode and verify symbolic is computed correctly
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FilePermissions.self, from: jsonData)
        XCTAssertEqual(decoded.symbolic, "rwxr-xr-x", "Symbolic should be computed from posix on decode")
    }

    func testFilePermissionsConsistencyAfterRoundTrip() throws {
        // This test verifies we can't have mismatched posix/symbolic
        // after encoding/decoding (the issue from the feedback)
        let original = FilePermissions(posix: 0o755)

        // Encode
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(original)

        // Decode
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FilePermissions.self, from: jsonData)

        // Symbolic MUST match posix (impossible to be inconsistent now)
        XCTAssertEqual(decoded.posix, 0o755)
        XCTAssertEqual(decoded.symbolic, "rwxr-xr-x")
        XCTAssertEqual(decoded.symbolic, FilePermissions(posix: 0o755).symbolic)

        // Even if we somehow got malformed JSON, symbolic would be recomputed
        let malformedJSON = """
        {"posix":420}
        """.data(using: .utf8)!

        let decodedMalformed = try decoder.decode(FilePermissions.self, from: malformedJSON)
        XCTAssertEqual(decodedMalformed.posix, 420) // 0o644
        XCTAssertEqual(decodedMalformed.symbolic, "rw-r--r--") // Always computed correctly
    }
}
