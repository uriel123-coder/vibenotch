import Foundation
import Network

struct HookRequest {
    let src: String
    let evt: String
    let body: [String: Any]
}

/// One pending HTTP response. `onGone` fires if the hook process disconnects before we answer.
final class HookReply {
    private let connection: NWConnection
    private var sent = false
    var onGone: (() -> Void)?

    init(_ connection: NWConnection) { self.connection = connection }

    func send(_ body: String) {
        guard !sent else { return }
        sent = true
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    fileprivate func watchForDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, done, error in
            guard let self, !self.sent else { return }
            if done || error != nil {
                self.sent = true
                self.connection.cancel()
                self.onGone?()
            } else {
                self.watchForDisconnect()
            }
        }
    }
}

/// Tiny loopback HTTP server the hook script talks to. Port + token live in ~/.vibenotch/server.
final class HookServer {
    static let shared = HookServer()

    var onRequest: ((HookRequest, HookReply) -> Void)?
    private var listener: NWListener?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var configFile: URL { Paths.bridge.appendingPathComponent("server") }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else { return }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            if case .ready = state, let port = listener?.port?.rawValue { self?.writeConfig(port) }
        }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        guard let listener else { return }
        listener.cancel()
        let mine = (try? String(contentsOf: configFile, encoding: .utf8))?.contains(token) == true
        if mine { try? FileManager.default.removeItem(at: configFile) }
    }

    private func writeConfig(_ port: UInt16) {
        try? "\(port) \(token)\n".write(to: configFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = self.parse(buf) {
                self.dispatch(c, req)
            } else if done || error != nil || buf.count > 16 << 20 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    private func parse(_ buf: Data) -> (path: String, headers: [String: String], body: Data)? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buf[buf.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[sep.upperBound...]
        guard body.count >= length else { return nil }
        return (String(parts[1]), headers, Data(body.prefix(length)))
    }

    private func dispatch(_ c: NWConnection, _ req: (path: String, headers: [String: String], body: Data)) {
        let reply = HookReply(c)
        guard req.headers["x-token"] == token,
              let comps = URLComponents(string: "http://localhost" + req.path) else {
            reply.send("")
            return
        }
        let q = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var body = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
        if let tty = q["tty"], tty.hasPrefix("ttys") { body["_tty"] = "/dev/" + tty }
        if let term = q["term"], !term.isEmpty { body["_term"] = term }
        reply.watchForDisconnect()
        onRequest?(HookRequest(src: q["src"] ?? "", evt: q["evt"] ?? "", body: body), reply)
    }
}
