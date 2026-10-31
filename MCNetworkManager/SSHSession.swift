import Foundation
import Citadel
import NIOCore
import SwiftTerm

/// One interactive SSH terminal (a pane in the Dual SSH tab).
@MainActor
final class SSHSession: ObservableObject {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Set by the SwiftUI terminal wrapper.
    weak var terminal: TerminalView?

    private var client: SSHClient?
    private var runTask: Task<Void, Never>?
    private var outbound: TTYStdinWriter?
    private var inputContinuation: AsyncStream<ByteBuffer>.Continuation?

    var isActive: Bool { state == .connecting || state == .connected }

    func connect(host: String, user: String, password: String) {
        guard !isActive else { return }
        state = .connecting
        terminal?.feed(text: "Connecting to \(user)@\(host)...\r\n")

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await SSHClient.connect(
                    host: host,
                    authenticationMethod: .passwordBased(username: user, password: password),
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
                self.client = client

                let (input, continuation) = AsyncStream<ByteBuffer>.makeStream()
                self.inputContinuation = continuation
                self.state = .connected

                try await client.withTTY { inbound, writer in
                    self.outbound = writer
                    let size = self.currentSize()
                    try? await writer.changeSize(cols: size.cols, rows: size.rows, pixelWidth: 0, pixelHeight: 0)

                    // Keystrokes are written one at a time, in order.
                    let pump = Task {
                        for await bytes in input {
                            try? await writer.write(bytes)
                        }
                    }
                    defer { pump.cancel() }

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            let bytes = Array(buffer.readableBytesView)
                            self.terminal?.feed(byteArray: bytes[...])
                        default:
                            break
                        }
                    }
                }
                self.finish(message: "\r\n[Session closed]\r\n", failure: nil)
            } catch {
                // disconnect() cancels this task and has already reset the state.
                if Task.isCancelled { return }
                self.finish(message: "\r\n[Connection error] \(error.localizedDescription)\r\n",
                            failure: error.localizedDescription)
            }
        }
    }

    func disconnect() {
        runTask?.cancel()
        inputContinuation?.finish()
        let client = self.client
        Task { try? await client?.close() }
        finish(message: "\r\n[Disconnected]\r\n", failure: nil)
    }

    /// Called by the terminal view for every keystroke.
    func send(_ data: ArraySlice<UInt8>) {
        inputContinuation?.yield(ByteBuffer(bytes: Array(data)))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, let outbound else { return }
        Task { try? await outbound.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    private func currentSize() -> (cols: Int, rows: Int) {
        guard let t = terminal?.getTerminal() else { return (80, 24) }
        return (t.cols > 0 ? t.cols : 80, t.rows > 0 ? t.rows : 24)
    }

    private func finish(message: String, failure: String?) {
        guard state != .idle || failure != nil else { return }
        terminal?.feed(text: message)
        state = failure.map { .failed($0) } ?? .idle
        outbound = nil
        inputContinuation = nil
        client = nil
        runTask = nil
    }
}
