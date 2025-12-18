import Foundation
import ArgumentParser
import Diffa

@available(macOS 13.0, *)
struct PushCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push local directory to remote server"
    )

    @Argument(help: "Local directory to push")
    var localPath: String

    @Argument(help: "Remote server (host:port)")
    var remote: String

    func run() throws {
        let url = URL(fileURLWithPath: localPath).standardized

        // Verify path exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ValidationError("Path does not exist or is not a directory: \(localPath)")
        }

        // Parse remote
        let (host, port) = try parseRemote(remote)

        print("Pushing \(url.path) to \(host):\(port)...")
        print("")

        let client = SyncClient()
        client.onLog = { print($0) }
        try client.push(localPath: url, to: host, port: port)
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
