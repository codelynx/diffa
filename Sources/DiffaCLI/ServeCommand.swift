#if canImport(Network)
import Foundation
import ArgumentParser
import Diffa

@available(macOS 13.0, *)
struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start sync server (daemon mode)"
    )

    @Option(name: .long, help: "Directory to serve")
    var path: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: UInt16 = 8080

    func run() throws {
        let url = URL(fileURLWithPath: path).standardized

        // Verify path exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("Path does not exist or is not a directory: \(path)")
        }

        print("Starting Diffa sync server...")
        print("  Path: \(url.path)")
        print("  Port: \(port)")
        print("")

        let server = SyncServer(path: url, port: port)
        server.onLog = { print($0) }
        try server.start()
    }
}
#endif // canImport(Network)
