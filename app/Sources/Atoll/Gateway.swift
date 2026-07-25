import Foundation
import Network

/// Local event gateway: minimal HTTP server bound to 127.0.0.1 on a random port.
/// Routes:
///   POST /hook/{source}  — bridge event ingestion (token required)
///   GET  /sessions       — debug dump of current session state (token required)
final class Gateway {
    private var listener: NWListener?
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let store: SessionStore
    var onFailure: ((String) -> Void)?
    /// Held connections for pending interactive requests, keyed by pending ID.
    private var held: [String: NWConnection] = [:]
    private let heldLock = NSLock()

    init(store: SessionStore) {
        self.store = store
        Task { @MainActor in
            store.resolver = { [weak self] id, body in
                self?.resolve(id: id, body: body)
            }
        }
    }

    /// Answer a held hook connection with the decision JSON and release it.
    func resolve(id: String, body: Data) {
        guard let conn = takeHeld(id) else { return }
        respond(conn, status: "200 OK", body: body, contentType: "application/json")
    }

    // Sync wrappers keep NSLock usage out of async contexts (Swift 6 rule).
    nonisolated private func putHeld(_ id: String, _ conn: NWConnection) {
        heldLock.lock(); held[id] = conn; heldLock.unlock()
    }

    nonisolated private func takeHeld(_ id: String) -> NWConnection? {
        heldLock.lock(); defer { heldLock.unlock() }
        return held.removeValue(forKey: id)
    }

    nonisolated private func isHeld(_ id: String) -> Bool {
        heldLock.lock(); defer { heldLock.unlock() }
        return held[id] != nil
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 0)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.serve(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port else {
                    self.fail("Gateway ready without a listening port")
                    return
                }
                do {
                    try self.writeEndpointFile(port: port.rawValue)
                    NSLog("Atoll gateway listening on 127.0.0.1:\(port.rawValue)")
                } catch {
                    self.fail("Cannot write the endpoint file: \(error)")
                }
            case .failed(let error):
                self.fail("Gateway listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func writeEndpointFile(port: UInt16) throws {
        let runDir = URL(fileURLWithPath: NSString(string: "~/.atoll/run").expandingTildeInPath)
        try Self.writeEndpointFile(port: port, token: token, runDirectory: runDir)
    }

    static func writeEndpointFile(port: UInt16, token: String, runDirectory: URL) throws {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let endpoint = runDirectory.appendingPathComponent("endpoint")
        let content = "ATOLL_PORT=\(port)\nATOLL_TOKEN=\(token)\n"
        try content.write(to: endpoint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpoint.path)
    }

    private func fail(_ message: String) {
        NSLog("Atoll \(message)")
        listener?.cancel()
        onFailure?(message)
    }

    // MARK: - HTTP handling

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            if let request = HTTPRequest.parse(buf) {
                self.route(request, conn)
            } else if complete {
                conn.cancel()
            } else if buf.count > 8 << 20 {
                conn.cancel()
            } else {
                self.receiveRequest(conn, buffer: buf)
            }
        }
    }

    /// Constant-time token compare (defense-in-depth; the gateway is 127.0.0.1
    /// only, but avoid leaking length/prefix via early-exit ==).
    private func tokenMatches(_ provided: String?) -> Bool {
        guard let provided, provided.utf8.count == token.utf8.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(provided.utf8, token.utf8) { diff |= a ^ b }
        return diff == 0
    }

    private func route(_ req: HTTPRequest, _ conn: NWConnection) {
        guard tokenMatches(req.headers["x-atoll-token"]) else {
            respond(conn, status: "401 Unauthorized", body: Data())
            return
        }
        if req.method == "POST", req.path.hasPrefix("/hook/") {
            let source = String(req.path.dropFirst("/hook/".count))
            let form = HTTPRequest.parseForm(req.body)

            // Interactive request: hold the connection until the user decides.
            // Interactive request parsing is shared by verified Claude-compatible
            // agents; the response encoder below remains source-specific.
            if AgentCatalog.approveCapableIDs.contains(source),
               let pendingReq = ClaudeCodec.pending(form: form, source: source) {
                Task { @MainActor in
                    // "始终允许" rule hit: answer immediately, no card.
                    if self.store.autoAllows(pendingReq) {
                        self.respond(conn, status: "200 OK",
                                     body: HookDecisionCodec.encode(.allow, for: pendingReq),
                                     contentType: "application/json")
                        return
                    }
                    let override = form["approval_route"].flatMap(ApprovalRoute.init(rawValue:))
                    let route = override ?? ApprovalRouter.effectiveRoute(for: pendingReq, store: self.store)
                    if let override {
                        NSLog("ApprovalRouter source=\(source) requestOverride=\(override.rawValue)")
                    }
                    if route == .native {
                        // Empty hook output delegates the decision to the agent's
                        // native approval UI. Do not create a second Atoll card.
                        self.respond(conn, status: "200 OK", body: Data(),
                                     contentType: "application/json")
                        return
                    }
                    self.putHeld(pendingReq.id, conn)
                    self.monitorHeldConnection(conn, pendingID: pendingReq.id)
                    // Drop the card if the CLI side goes away (ctrl-C, hook timeout).
                    conn.stateUpdateHandler = { [weak self] state in
                        if case .failed = state { self?.abandon(pendingReq.id) }
                        if case .cancelled = state { self?.abandon(pendingReq.id) }
                    }
                    // Grace delay: only surface the card if the request is still
                    // held after 350ms. Auto-approved requests (auto/bypass mode)
                    // close the connection almost immediately → no flicker; genuine
                    // waits stay held and surface.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Tuning.approvalGraceDelay) { [weak self] in
                        guard let self, self.isHeld(pendingReq.id) else { return }
                        self.store.addPending(pendingReq)
                    }
                }
                return
            }

            let event = Normalizer.normalize(source: source, form: form)
            if let event {
                Task { @MainActor in
                    self.store.apply(event)
                    self.store.noteSourceSeen(source)
                }
            }
            respond(conn, status: "200 OK", body: Data())
        } else if req.method == "POST", req.path == "/decide" {
            // Debug/automation endpoint: {"id": "...", "action": "allow|deny|answers|feedback", ...}
            handleDecide(req, conn)
        } else if req.method == "POST", req.path == "/jump" {
            // Debug/automation: same code path as clicking a session card.
            guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
                  let key = obj["sessionKey"] as? String else {
                respond(conn, status: "400 Bad Request", body: Data())
                return
            }
            Task { @MainActor in
                if let session = self.store.sessions[key] { JumpEngine.jump(to: session) }
                self.respond(conn, status: "200 OK", body: Data("ok".utf8))
            }
        } else if req.method == "GET", req.path == "/sessions" {
            Task { @MainActor in
                let json = self.store.debugJSON()
                self.respond(conn, status: "200 OK", body: json, contentType: "application/json")
            }
        } else {
            respond(conn, status: "404 Not Found", body: Data())
        }
    }

    private func abandon(_ pendingID: String) {
        if takeHeld(pendingID) != nil {
            Task { @MainActor in self.store.dropPending(id: pendingID) }
        }
    }

    /// Once a request is held, continue receiving only to observe the peer's FIN.
    /// Without this read, Network.framework may leave a card visible after the
    /// terminal resolves the request and its bridge process closes the socket.
    private func monitorHeldConnection(_ conn: NWConnection, pendingID: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self else { return }
            if complete || error != nil {
                self.abandon(pendingID)
            } else if self.isHeld(pendingID) {
                self.monitorHeldConnection(conn, pendingID: pendingID)
            }
        }
    }

    private func handleDecide(_ req: HTTPRequest, _ conn: NWConnection) {
        guard let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any],
              let id = obj["id"] as? String,
              let action = obj["action"] as? String
        else {
            respond(conn, status: "400 Bad Request", body: Data())
            return
        }
        let decision: Decision
        switch action {
        case "allow": decision = .allow
        case "alwaysAllow": decision = .alwaysAllow
        case "planAllow": decision = .planAllow(mode: obj["mode"] as? String ?? "default")
        case "deny": decision = .deny(reason: obj["reason"] as? String ?? "")
        case "feedback": decision = .planFeedback(obj["text"] as? String ?? "")
        case "answers":
            var answers: [Int: [String]] = [:]
            for (k, v) in (obj["answers"] as? [String: [String]]) ?? [:] {
                if let idx = Int(k) { answers[idx] = v }
            }
            decision = .answers(answers)
        default:
            respond(conn, status: "400 Bad Request", body: Data())
            return
        }
        Task { @MainActor in
            self.store.decide(id, decision)
            self.respond(conn, status: "200 OK", body: Data("ok".utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: Data, contentType: String = "text/plain") {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - Minimal HTTP request parsing

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil until the buffer contains a complete request (headers + Content-Length body).
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerStr = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = headerStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers, body: body)
    }

    static func parseForm(_ body: Data) -> [String: String] {
        guard let str = String(data: body, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in str.components(separatedBy: "&") {
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<eq])
            let raw = String(pair[pair.index(after: eq)...]).replacingOccurrences(of: "+", with: " ")
            result[key] = raw.removingPercentEncoding ?? raw
        }
        return result
    }
}
