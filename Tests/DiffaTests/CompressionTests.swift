import XCTest
@testable import Diffa

final class CompressionTests: XCTestCase {

    // MARK: - SyncCompression Tests

    func testShouldCompressLargeTextFile() {
        XCTAssertTrue(SyncCompression.shouldCompress(path: "file.txt", size: 10000))
        XCTAssertTrue(SyncCompression.shouldCompress(path: "code.swift", size: 5000))
        XCTAssertTrue(SyncCompression.shouldCompress(path: "data.json", size: 8000))
    }

    func testShouldNotCompressSmallFile() {
        XCTAssertFalse(SyncCompression.shouldCompress(path: "file.txt", size: 100))
        XCTAssertFalse(SyncCompression.shouldCompress(path: "file.txt", size: 4095))
    }

    func testShouldNotCompressAlreadyCompressed() {
        XCTAssertFalse(SyncCompression.shouldCompress(path: "image.jpg", size: 100000))
        XCTAssertFalse(SyncCompression.shouldCompress(path: "video.mp4", size: 100000))
        XCTAssertFalse(SyncCompression.shouldCompress(path: "archive.zip", size: 100000))
        XCTAssertFalse(SyncCompression.shouldCompress(path: "archive.tar.gz", size: 100000))
        XCTAssertFalse(SyncCompression.shouldCompress(path: "document.pdf", size: 100000))
    }

    func testCompressAndDecompress() {
        // Create compressible data (repeated text compresses well)
        let originalText = String(repeating: "Hello, World! This is a test. ", count: 500)
        let originalData = originalText.data(using: .utf8)!

        // Compress
        guard let compressed = SyncCompression.compress(originalData) else {
            XCTFail("Compression failed")
            return
        }

        // Verify compression achieved reduction
        XCTAssertLessThan(compressed.count, originalData.count)
        print("Original: \(originalData.count), Compressed: \(compressed.count), Ratio: \(100 - compressed.count * 100 / originalData.count)%")

        // Decompress
        guard let decompressed = SyncCompression.decompress(compressed, originalSize: originalData.count) else {
            XCTFail("Decompression failed")
            return
        }

        // Verify round-trip
        XCTAssertEqual(decompressed, originalData)
        XCTAssertEqual(String(data: decompressed, encoding: .utf8), originalText)
    }

    func testCompressIncompressibleData() {
        // Random data doesn't compress well
        var randomData = Data(count: 10000)
        randomData.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            for i in 0..<10000 {
                ptr[i] = UInt8.random(in: 0...255)
            }
        }

        // Compression should return nil for incompressible data
        let compressed = SyncCompression.compress(randomData)
        XCTAssertNil(compressed, "Random data should not compress")
    }

    func testCompressEmptyData() {
        let emptyData = Data()
        let result = SyncCompression.compress(emptyData)
        XCTAssertEqual(result, emptyData)
    }

    // MARK: - FilePayload Tests

    func testFilePayloadEncodeDecodeUncompressed() {
        let path = "test/file.txt"
        let data = "Hello, World!".data(using: .utf8)!

        let payload = FilePayload(path: path, data: data)
        let encoded = payload.encode()

        guard let decoded = FilePayload.decode(encoded) else {
            XCTFail("Decoding failed")
            return
        }

        XCTAssertEqual(decoded.path, path)
        XCTAssertEqual(decoded.data, data)
        XCTAssertFalse(decoded.isCompressed)
        XCTAssertEqual(decoded.originalSize, data.count)
    }

    func testFilePayloadEncodeDecodeCompressed() {
        let path = "test/file.txt"
        let originalData = String(repeating: "Test data ", count: 1000).data(using: .utf8)!

        guard let compressedData = SyncCompression.compress(originalData) else {
            XCTFail("Compression failed")
            return
        }

        let payload = FilePayload(path: path, data: compressedData, isCompressed: true, originalSize: originalData.count)
        let encoded = payload.encode()

        guard let decoded = FilePayload.decode(encoded) else {
            XCTFail("Decoding failed")
            return
        }

        XCTAssertEqual(decoded.path, path)
        XCTAssertEqual(decoded.data, compressedData)
        XCTAssertTrue(decoded.isCompressed)
        XCTAssertEqual(decoded.originalSize, originalData.count)

        // Verify decompression
        guard let decompressedData = decoded.decompressedData() else {
            XCTFail("Decompression failed")
            return
        }
        XCTAssertEqual(decompressedData, originalData)
    }

    func testFilePayloadCreateAutoCompresses() {
        let path = "test/large.txt"
        let data = String(repeating: "Compressible text content ", count: 500).data(using: .utf8)!

        let payload = FilePayload.create(path: path, data: data)

        XCTAssertTrue(payload.isCompressed)
        XCTAssertLessThan(payload.data.count, data.count)
        XCTAssertEqual(payload.originalSize, data.count)

        // Verify we can decompress
        let decompressed = payload.decompressedData()
        XCTAssertEqual(decompressed, data)
    }

    func testFilePayloadCreateSkipsSmallFiles() {
        let path = "test/small.txt"
        let data = "Small".data(using: .utf8)!

        let payload = FilePayload.create(path: path, data: data)

        XCTAssertFalse(payload.isCompressed)
        XCTAssertEqual(payload.data, data)
    }

    func testFilePayloadCreateSkipsAlreadyCompressed() {
        let path = "test/image.jpg"
        let data = Data(repeating: 0x42, count: 10000)

        let payload = FilePayload.create(path: path, data: data)

        XCTAssertFalse(payload.isCompressed)
        XCTAssertEqual(payload.data, data)
    }

    func testFilePayloadBackwardCompatibility() {
        // Old format: just "path\n<data>"
        let path = "test/file.txt"
        let data = "Hello".data(using: .utf8)!

        var oldFormat = Data()
        oldFormat.append((path + "\n").data(using: .utf8)!)
        oldFormat.append(data)

        guard let decoded = FilePayload.decode(oldFormat) else {
            XCTFail("Decoding old format failed")
            return
        }

        XCTAssertEqual(decoded.path, path)
        XCTAssertEqual(decoded.data, data)
        XCTAssertFalse(decoded.isCompressed)
    }
}
