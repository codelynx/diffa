import Foundation

/// Generates synthetic file datasets for benchmarking
///
/// Creates directory trees with a specified number of files,
/// using deterministic random content based on a seed.
struct DatasetGenerator {
    /// Generate a dataset with specified characteristics
    ///
    /// - Parameters:
    ///   - directory: Directory to create dataset in
    ///   - fileCount: Number of files to create
    ///   - avgFileSize: Average file size in bytes
    ///   - seed: Random seed for deterministic generation
    func generateDataset(
        at directory: URL,
        fileCount: Int,
        avgFileSize: Int,
        seed: UInt64
    ) throws {
        let fileManager = FileManager.default

        // Create root directory
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Initialize random generator with seed
        var rng = SeededRandomGenerator(seed: seed)

        // Generate directory structure (10% of files in subdirectories)
        let subdirCount = max(1, fileCount / 100)
        var subdirs: [URL] = [directory]

        for i in 0..<subdirCount {
            let subdirPath = directory.appendingPathComponent("subdir_\(i)")
            try fileManager.createDirectory(at: subdirPath, withIntermediateDirectories: true)
            subdirs.append(subdirPath)
        }

        // Generate files
        for i in 0..<fileCount {
            // Choose directory (90% root, 10% subdirs)
            let dirIndex = rng.next() % 100 < 90 ? 0 : Int(rng.next()) % subdirs.count
            let parentDir = subdirs[dirIndex]

            // Generate filename
            let filename = "file_\(String(format: "%06d", i)).txt"
            let fileURL = parentDir.appendingPathComponent(filename)

            // Generate file content (vary size by ±50%)
            let minSize = avgFileSize / 2
            let maxSize = avgFileSize + avgFileSize / 2
            let fileSize = minSize + Int(rng.next()) % (maxSize - minSize)

            // Create content
            let content = generateContent(size: fileSize, rng: &rng)
            try content.write(to: fileURL, atomically: false, encoding: .utf8)
        }

        print("Generated dataset: \(fileCount) files in \(directory.path)")
    }

    private func generateContent(size: Int, rng: inout SeededRandomGenerator) -> String {
        // Generate random but deterministic content
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit",
                     "sed", "do", "eiusmod", "tempor", "incididunt", "ut", "labore", "et", "dolore",
                     "magna", "aliqua", "enim", "ad", "minim", "veniam", "quis", "nostrud"]

        var content = ""
        content.reserveCapacity(size)

        while content.count < size {
            let wordIndex = Int(rng.next()) % words.count
            content += words[wordIndex]
            content += " "

            // Add newline every ~80 characters
            if rng.next() % 10 == 0 {
                content += "\n"
            }
        }

        return String(content.prefix(size))
    }
}

/// Seeded random number generator for deterministic datasets
struct SeededRandomGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    /// Generate next random number using xorshift64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
