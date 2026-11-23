import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // where URLSession lives on Linux; only the test harness builds there
#endif

/// HTTP client for the Samsung's listener (port 8765).
struct ReceiverClient {
    let host: String
    let port: Int

    struct PingResponse: Decodable {
        let lastSnapshotHash: String
        let count: Int
        /// The Samsung's current addresses (nil when it has none of that kind).
        let tailscale: String?
        let lan: String?
    }
    struct PushResponse: Decodable {
        let added: Int; let updated: Int; let deleted: Int; let total: Int
        /// Contacts the Samsung could not save.
        let failed: Int?
    }
    struct PairStartResponse: Decodable { let session: String; let pub: String; let device: String }
    struct PairInfo: Decodable { let code: String; let device: String; let port: Int; let tailscale: String?; let lan: String? }
    enum PairFinish { case pending; case sealed(Data) }

    private struct ErrorBody: Decodable { let error: String }

    /// Builds the request URL. `host` is typed by hand in places, so accept
    /// "100.1.2.3", "phone.tailnet.ts.net", "100.1.2.3:8765", a pasted "http://…" and IPv6.
    func url(_ path: String) throws -> URL {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = port
        if h.lowercased().hasPrefix("http://") { h.removeFirst(7) }
        while h.hasSuffix("/") { h.removeLast() }
        let colons = h.filter { $0 == ":" }.count
        if colons == 1, let i = h.lastIndex(of: ":"),
           let typed = Int(h[h.index(after: i)...]), (1...65535).contains(typed) {
            p = typed
            h = String(h[..<i])
        } else if colons > 1, !h.hasPrefix("[") {
            h = "[\(h)]"
        }
        guard !h.isEmpty, !h.contains(" "), let url = URL(string: "http://\(h):\(p)/\(path)") else {
            throw SyncError.message("\"\(host)\" is not a valid address for the Samsung")
        }
        return url
    }

    private static let quick: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c)
    }()

    private static let slow: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300 // the Samsung answers only after saving every contact
        return URLSession(configuration: c)
    }()

    private func send(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json",
                      headers: [String: String] = [:], session: URLSession = quick) async throws -> (Int, Data) {
        var req = URLRequest(url: try url(path))
        req.httpMethod = method
        req.httpBody = body
        if body != nil { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func check(_ status: Int, _ data: Data, ok: Set<Int> = [200]) throws {
        guard ok.contains(status) else {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            throw SyncError.http(status, msg)
        }
    }

    private func auth(_ code: String) -> [String: String] {
        ["Authorization": "Bearer \(Proto.authToken(code))"]
    }

    /// Asks the Samsung which snapshot it holds. Sending our own hash lets the Samsung
    /// show whether this check-in found it up to date or has changes coming.
    func ping(code: String, snapshotHash: String) async throws -> PingResponse {
        var h = auth(code)
        h["X-Snapshot-Hash"] = snapshotHash
        let (s, d) = try await send("POST", "v1/ping", headers: h)
        try check(s, d)
        return try JSONDecoder().decode(PingResponse.self, from: d)
    }

    func push(blob: Data, code: String, snapshotHash: String, allowEmpty: Bool) async throws -> PushResponse {
        var h = auth(code)
        h["X-Snapshot-Hash"] = snapshotHash
        if allowEmpty { h["X-Allow-Empty"] = "1" }
        let (s, d) = try await send("PUT", "v1/contacts", body: blob, contentType: "application/octet-stream",
                                    headers: h, session: Self.slow)
        try check(s, d)
        return try JSONDecoder().decode(PushResponse.self, from: d)
    }

    func pairStart(pub: Data, device: String) async throws -> PairStartResponse {
        let body = try JSONSerialization.data(withJSONObject: ["pub": pub.base64EncodedString(), "device": device])
        let (s, d) = try await send("POST", "v1/pair/start", body: body)
        try check(s, d)
        return try JSONDecoder().decode(PairStartResponse.self, from: d)
    }

    func pairFinish(session: String) async throws -> PairFinish {
        let body = try JSONSerialization.data(withJSONObject: ["session": session])
        let (s, d) = try await send("POST", "v1/pair/finish", body: body)
        if s == 202 { return .pending }
        try check(s, d)
        struct Sealed: Decodable { let sealed: String }
        guard let blob = Data(base64Encoded: try JSONDecoder().decode(Sealed.self, from: d).sealed) else {
            throw SyncError.message("Bad pairing response")
        }
        return .sealed(blob)
    }
}
