import Foundation
import ArgumentParser
import Diffa

struct PullCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Pull from remote server to local directory"
    )

    @Argument(help: "Local directory to pull into")
    var localPath: String

    @Argument(help: "Remote server (host:port)")
    var remote: String

    func run() throws {
        let url = URL(fileURLWithPath: localPath).standardized

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            print("Created directory: \(url.path)")
        }

        // Verify it's a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("Path is not a directory: \(localPath)")
        }

        // Parse remote
        let (host, port) = try parseRemote(remote)

        print("Pulling from \(host):\(port) to \(url.path)...")
        print("")

        let client = SyncClient()
        client.onLog = { print($0) }
        try client.pull(localPath: url, from: host, port: port)
    }

    private func parseRemote(_ remote: String) throws -> (String, UInt16) {
        let parts = remote.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            throw ValidationError("Invalid remote format. Use host:port (e.g., 192.168.1.10:8080)")
        }
        return (String(parts[0]), port)
    }
}
