import Foundation
import Network

struct MinecraftStatus: Equatable {
    var version: String
    var online: Int
    var max: Int
    var motd: String
    var latencyMS: Int
}

enum PingError: LocalizedError {
    case timeout, closed, malformed
    var errorDescription: String? {
        switch self {
        case .timeout: return "No response"
        case .closed: return "Connection closed"
        case .malformed: return "Unexpected reply"
        }
    }
}

/// Implements the Minecraft Java "server list ping" so the dashboard can show
/// live player counts without anything installed on the server.
enum MinecraftPing {
    static func ping(host: String, port: Int, timeout: TimeInterval = 4) async throws -> MinecraftStatus {
        try await withCheckedThrowingContinuation { continuation in
            let session = PingSession(host: host, port: port, timeout: timeout) { result in
                continuation.resume(with: result)
            }
            session.start()
        }
    }

    // MARK: Packet helpers (internal for testing)

    static func varInt(_ value: Int) -> [UInt8] {
        var v = UInt32(truncatingIfNeeded: value)
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    /// Reads a VarInt starting at `index`; nil if the buffer is too short.
    static func readVarInt(_ bytes: [UInt8], at index: inout Int) -> Int? {
        var result = 0
        var shift = 0
        var i = index
        while i < bytes.count {
            let b = bytes[i]
            i += 1
            result |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { index = i; return result }
            shift += 7
            if shift > 35 { return nil }
        }
        return nil
    }

    static func packet(id: Int, payload: [UInt8]) -> [UInt8] {
        let body = varInt(id) + payload
        return varInt(body.count) + body
    }

    static func handshake(host: String, port: Int) -> [UInt8] {
        let hostBytes = Array(host.utf8)
        let payload = varInt(767) + varInt(hostBytes.count) + hostBytes
            + [UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)] + varInt(1)
        return packet(id: 0, payload: payload)
    }

    /// Parses the status packet bytes into a status; nil means "need more data".
    static func parseStatus(_ bytes: [UInt8], latencyMS: Int) throws -> MinecraftStatus? {
        var i = 0
        guard let length = readVarInt(bytes, at: &i) else { return nil }
        guard bytes.count - i >= length else { return nil }
        guard let id = readVarInt(bytes, at: &i), id == 0 else { throw PingError.malformed }
        guard let jsonLen = readVarInt(bytes, at: &i), bytes.count - i >= jsonLen else { return nil }
        let json = Data(bytes[i..<(i + jsonLen)])
        guard let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw PingError.malformed }

        let version = (obj["version"] as? [String: Any])?["name"] as? String ?? "?"
        let players = obj["players"] as? [String: Any]
        let online = players?["online"] as? Int ?? 0
        let max = players?["max"] as? Int ?? 0
        return MinecraftStatus(version: version, online: online, max: max,
                               motd: plainText(obj["description"]), latencyMS: latencyMS)
    }

    /// The description can be a string or a nested chat component.
    static func plainText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let dict = value as? [String: Any] else { return "" }
        var out = dict["text"] as? String ?? ""
        for extra in dict["extra"] as? [Any] ?? [] { out += plainText(extra) }
        return out
    }
}

private final class PingSession: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let timeout: TimeInterval
    private let completion: (Result<MinecraftStatus, Error>) -> Void
    private let queue = DispatchQueue(label: "mc.ping")
    private var connection: NWConnection?
    private var buffer: [UInt8] = []
    private var finished = false
    private var started = Date()
    /// Keeps this object alive until the ping finishes; callers do not hold on to it.
    private var keepAlive: PingSession?

    init(host: String, port: Int, timeout: TimeInterval, completion: @escaping (Result<MinecraftStatus, Error>) -> Void) {
        self.host = host
        self.port = port
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        keepAlive = self
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            finish(.failure(PingError.malformed)); return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn
        started = Date()
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let data = MinecraftPing.handshake(host: self.host, port: self.port)
                    + MinecraftPing.packet(id: 0, payload: [])
                conn.send(content: Data(data), completion: .contentProcessed { error in
                    if let error { self.finish(.failure(error)) } else { self.receive() }
                })
            case .failed(let error): self.finish(.failure(error))
            case .cancelled: self.finish(.failure(PingError.closed))
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(PingError.timeout)) }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(.failure(error)); return }
            if let data { self.buffer.append(contentsOf: data) }
            let latency = Int(Date().timeIntervalSince(self.started) * 1000)
            do {
                if let status = try MinecraftPing.parseStatus(self.buffer, latencyMS: latency) {
                    self.finish(.success(status)); return
                }
            } catch {
                self.finish(.failure(error)); return
            }
            if isComplete { self.finish(.failure(PingError.closed)) } else { self.receive() }
        }
    }

    private func finish(_ result: Result<MinecraftStatus, Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            self.connection?.cancel()
            self.completion(result)
            self.keepAlive = nil
        }
    }
}
