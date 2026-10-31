import Foundation
import Citadel
import NIOCore
import NIOSSH

enum SSHServiceError: LocalizedError {
    case timeout
    case incomplete
    var errorDescription: String? {
        switch self {
        case .timeout: return "The connection timed out."
        case .incomplete: return "Add a host, username and password for this node first."
        }
    }
}

/// Runs a closure once at most; used to race work against a timeout.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = OnceGate()
        let work = Task {
            do {
                let value = try await operation()
                if gate.fire() { continuation.resume(returning: value) }
            } catch {
                if gate.fire() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if gate.fire() {
                work.cancel()
                continuation.resume(throwing: SSHServiceError.timeout)
            }
        }
    }
}

/// One-off SSH commands. Interactive terminals use `PTYConnection` instead.
enum SSHService {
    static func connect(_ node: NodeProfile) async throws -> SSHClient {
        guard node.isComplete else { throw SSHServiceError.incomplete }
        let username = node.username
        let password = node.password
        let settings = SSHClientSettings(
            host: node.host.trimmingCharacters(in: .whitespaces),
            port: node.port,
            authenticationMethod: { .passwordBased(username: username, password: password) },
            // Host keys are not pinned yet; see "Known limitations" in the README.
            hostKeyValidator: .acceptAnything()
        )
        return try await SSHClient.connect(to: settings)
    }

    /// Runs a command and returns everything it printed (stdout and stderr merged).
    static func run(_ node: NodeProfile, _ command: String, timeout: TimeInterval = 25) async throws -> String {
        try await withTimeout(timeout) {
            let client = try await connect(node)
            do {
                let buffer = try await client.executeCommand(command, maxResponseSize: 2_000_000, mergeStreams: true)
                try? await client.close()
                return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
            } catch {
                try? await client.close()
                throw error
            }
        }
    }

    /// Runs a long command and yields its output line by line as it arrives.
    static func streamLines(_ node: NodeProfile, _ command: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var client: SSHClient?
                do {
                    let c = try await connect(node)
                    client = c
                    var pending = ""
                    let events = try await c.executeCommandStream(command)
                    for try await event in events {
                        var chunk: ByteBuffer?
                        switch event {
                        case .stdout(let b): chunk = b
                        case .stderr(let b): chunk = b
                        default: break
                        }
                        guard let chunk else { continue }
                        pending += chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) ?? ""
                        while let newline = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<newline]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                            continuation.yield(line)
                            pending.removeSubrange(...newline)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(pending) }
                    try? await c.close()
                    continuation.finish()
                } catch {
                    if let client { try? await client.close() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Shell quoting and privileged execution

enum Shell {
    /// Wraps a string in single quotes so the shell treats it as one literal word.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `program` under `bash -c`, so the login shell of the remote user
    /// (bash, zsh, fish...) never has to understand it.
    static func bash(_ program: String) -> String {
        "bash -c " + quote(program)
    }

    /// Wraps a command so it runs as root: directly for root, otherwise via
    /// sudo using the node's password.
    static func privileged(_ command: String, node: NodeProfile) -> String {
        if node.username == "root" { return command }
        return "printf '%s\\n' \(quote(node.password)) | sudo -S -p '' \(command)"
    }
}

// MARK: - Interactive terminal session

/// Bridges a SwiftTerm view to an SSH pseudo-terminal.
final class PTYConnection: @unchecked Sendable {
    private var inputContinuation: AsyncStream<Data>.Continuation?
    private var resizeContinuation: AsyncStream<(Int, Int)>.Continuation?
    private var task: Task<Void, Never>?

    /// Called on an arbitrary thread with bytes to display.
    private let onOutput: @Sendable ([UInt8]) -> Void
    /// Called with short status lines ("Connecting...", errors).
    private let onStatus: @Sendable (String) -> Void

    init(onOutput: @escaping @Sendable ([UInt8]) -> Void, onStatus: @escaping @Sendable (String) -> Void) {
        self.onOutput = onOutput
        self.onStatus = onStatus
    }

    func start(node: NodeProfile, cols: Int, rows: Int) {
        stop()
        let (inputStream, inputCont) = AsyncStream<Data>.makeStream()
        let (resizeStream, resizeCont) = AsyncStream<(Int, Int)>.makeStream()
        inputContinuation = inputCont
        resizeContinuation = resizeCont
        let onOutput = self.onOutput
        let onStatus = self.onStatus

        task = Task {
            onStatus("Connecting to \(node.displayName)...\r\n")
            do {
                let client = try await SSHService.connect(node)
                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: max(cols, 20),
                    terminalRowHeight: max(rows, 5),
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([.ECHO: 1])
                )
                try await client.withPTY(request) { inbound, outbound in
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await event in inbound {
                                switch event {
                                case .stdout(let buffer), .stderr(let buffer):
                                    onOutput(Array(buffer.readableBytesView))
                                default:
                                    break
                                }
                            }
                        }
                        group.addTask {
                            for await data in inputStream {
                                try await outbound.write(ByteBuffer(bytes: [UInt8](data)))
                            }
                        }
                        group.addTask {
                            for await (c, r) in resizeStream {
                                try await outbound.changeSize(cols: c, rows: r, pixelWidth: 0, pixelHeight: 0)
                            }
                        }
                        // The session ends when the remote shell closes the output.
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
                try? await client.close()
                onStatus("\r\n[Session closed]\r\n")
            } catch is CancellationError {
                // Pane closed by the user.
            } catch {
                onStatus("\r\n[Connection failed: \(error.localizedDescription)]\r\n")
            }
        }
    }

    func send(_ bytes: ArraySlice<UInt8>) { inputContinuation?.yield(Data(bytes)) }
    func resize(cols: Int, rows: Int) { if cols > 0, rows > 0 { resizeContinuation?.yield((cols, rows)) } }

    func stop() {
        inputContinuation?.finish()
        resizeContinuation?.finish()
        inputContinuation = nil
        resizeContinuation = nil
        task?.cancel()
        task = nil
    }

    deinit { stop() }
}
