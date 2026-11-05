import Foundation
import Network

/// Tiny HTTP/1.1 server on 127.0.0.1 so Claude Code sessions can reach the app:
///   - the companion channel MCP server (registers, long-polls for voice messages, fetches screenshots)
///   - the Stop hook (hands over each finished reply so the app can speak it)
/// Loopback only; every request must carry the per-install token from
/// ~/Library/Application Support/ClaudeCompanion/token.
final class LocalServer {
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
    }
    struct Response {
        var status: Int = 200
        var json: Any = ["ok": true]
    }
    typealias Handler = (Request, @escaping (Response) -> Void) -> Void

    static let port: UInt16 = 47823
    let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.server")
    /// Called on the main queue.
    var handler: Handler?
    var onFailure: ((String) -> Void)?

    init() {
        token = LocalServer.loadOrCreateToken()
    }

    static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeCompanion", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func loadOrCreateToken() -> String {
        let url = supportDir.appendingPathComponent("token")
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 16 { return t }
        let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback          // never reachable from the network
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        l.newConnectionHandler = { [weak self] c in
            // Belt and braces: only accept loopback peers.
            if case .hostPort(let host, _) = c.endpoint, !"\(host)".hasPrefix("127.0.0.1"), !"\(host)".hasPrefix("::1") {
                c.cancel(); return
            }
            self?.accept(c)
        }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { DispatchQueue.main.async { self?.onFailure?("Local server failed: \(e)") } }
        }
        l.start(queue: queue)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.dispatch(req, on: c)
            } else if done || err != nil || buf.count > 32 << 20 {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private static func parse(_ buf: Data) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard buf.count - bodyStart >= len else { return nil }
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        var q: [String: String] = [:]
        comps?.queryItems?.forEach { q[$0.name] = $0.value ?? "" }
        return Request(method: String(first[0]), path: comps?.path ?? target, query: q, headers: headers,
                       body: buf.subdata(in: bodyStart..<(bodyStart + len)))
    }

    private func dispatch(_ req: Request, on c: NWConnection) {
        guard req.headers["x-companion-token"] == token || req.query["token"] == token else {
            send(Response(status: 403, json: ["error": "bad token"]), on: c)
            return
        }
        DispatchQueue.main.async {
            guard let h = self.handler else { self.send(Response(status: 503, json: ["error": "not ready"]), on: c); return }
            var answered = false
            h(req) { resp in
                guard !answered else { return }
                answered = true
                self.send(resp, on: c)
            }
        }
    }

    private func send(_ r: Response, on c: NWConnection) {
        let body = JSONSerialization.isValidJSONObject(r.json)
            ? ((try? JSONSerialization.data(withJSONObject: r.json)) ?? Data("{}".utf8))
            : Data("{\"error\":\"bad response\"}".utf8)
        let reason = r.status == 200 ? "OK" : (r.status == 204 ? "No Content" : "Error")
        var head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if r.status == 204 { head = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        var out = Data(head.utf8)
        if r.status != 204 { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}
