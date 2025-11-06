import Foundation
import ArgumentParser
import Diffalla

@available(macOS 13.0, *)
struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export patch in various formats"
    )

    @Argument(help: "Patch file to export")
    var patch: String

    @Option(name: .shortAndLong, help: "Output format (text, json, html, diff)")
    var format: String = "text"

    @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
    var output: String?

    func run() throws {
        // Validate patch file exists
        let patchURL = URL(fileURLWithPath: patch)
        guard FileManager.default.fileExists(atPath: patchURL.path) else {
            throw CLIError.patchNotFound(patch)
        }

        // Validate format
        let validFormats = ["text", "json", "html", "diff"]
        guard validFormats.contains(format.lowercased()) else {
            throw CLIError.invalidFormat(format, validFormats: validFormats)
        }

        // Load patch
        let patchObj = try Patch.open(at: patchURL)

        // Export to the requested format
        let exportedContent: String
        switch format.lowercased() {
        case "text":
            exportedContent = try patchObj.exportAsText()
        case "json":
            exportedContent = try patchObj.exportAsJSON()
        case "html":
            exportedContent = try patchObj.exportAsHTML()
        case "diff":
            exportedContent = try patchObj.exportAsDetailedDiff()
        default:
            throw CLIError.invalidFormat(format, validFormats: validFormats)
        }

        // Write output
        if let outputPath = output {
            let outputURL = URL(fileURLWithPath: outputPath)
            try exportedContent.write(to: outputURL, atomically: true, encoding: .utf8)
            print(Colors.success("✓ Exported to \(outputPath)"))
        } else {
            // Write to stdout
            print(exportedContent)
        }
    }
}
