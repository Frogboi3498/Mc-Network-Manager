import Foundation
import Citadel
import NIOCore

/// Thin wrapper around Citadel's SSHClient for one-off commands (provisioning, monitoring).
final class RemoteClient {
    let client: SSHClient

    private init(client: SSHClient) { self.client = client }

    static func connect(host: String, user: String, password: String) async throws -> RemoteClient {
        let client = try await SSHClient.connect(
            host: host,
            authenticationMethod: .passwordBased(username: user, password: password),
            // Hosts are your own machines reached over your LAN or tailnet. See README (Security notes).
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        return RemoteClient(client: client)
    }

    /// Runs a command and returns stdout.
    func run(_ command: String) async throws -> String {
        let buffer = try await client.executeCommand(command)
        return String(buffer: buffer)
    }

    /// Runs a command and reports output as it arrives. Throws if the command exits non-zero.
    func stream(_ command: String, onText: @escaping (String) -> Void) async throws {
        let events = try await client.executeCommandStream(command)
        for try await event in events {
            switch event {
            case .stdout(let buffer): onText(String(buffer: buffer))
            case .stderr(let buffer): onText(String(buffer: buffer))
            default: break
            }
        }
    }

    func close() async {
        try? await client.close()
    }
}
