import Foundation

/// A TimeTagger record as the app works with it: unix seconds, and t1 == t2 while running.
/// The server's v1 shape (ISO times, stop = null while running) is converted in `API`.
struct Record: Codable, Identifiable, Hashable {
    /// The server's numeric id as text; empty for a record the server hasn't created yet.
    var key: String
    /// The revision this copy was read at; 0 for a new record. A save is refused if the server has moved on.
    var rev: Int64
    var t1: Int
    var t2: Int
    var ds: String
    var deleted: Int?
    var st: Double?

    var id: String { key }
    var isRunning: Bool { t1 == t2 }
    var isDeleted: Bool { (deleted ?? 0) != 0 }

    func duration(now: Int = Int(Date().timeIntervalSince1970)) -> Int {
        (isRunning ? now : t2) - t1
    }

    /// Tags without the leading '#', in the order they appear.
    var tags: [String] {
        ds.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.hasPrefix("#") && $0.count > 1 }
            .map { String($0.dropFirst()).lowercased() }
    }

    /// A record that doesn't exist on the server yet; saving it creates it there.
    static func newKey() -> String { "" }
}

enum APIError: LocalizedError {
    case notConfigured
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Sign in from Settings."
        case let .http(code, body): return "HTTP \(code): \(body)"
        }
    }
}

/// The record as the v1 API sends and receives it.
private struct WireRecord: Codable {
    /// Absent for a new record: the server assigns it.
    var id: Int64?
    var start: Date
    var stop: Date?
    var description: String
    var deleted: Bool?
    var deletedAt: Date?
    var revision: Int64?

    init(_ r: Record) {
        id = Int64(r.key)
        start = Date(timeIntervalSince1970: TimeInterval(r.t1))
        stop = r.isRunning ? nil : Date(timeIntervalSince1970: TimeInterval(r.t2))
        description = r.ds
        deleted = r.isDeleted
        revision = r.rev == 0 ? nil : r.rev
    }

    var record: Record {
        let t1 = Int(start.timeIntervalSince1970)
        return Record(
            key: id.map(String.init) ?? "", rev: revision ?? 0, t1: t1,
            t2: stop.map { Int($0.timeIntervalSince1970) } ?? t1, ds: description,
            deleted: deletedAt == nil ? 0 : 1, st: nil
        )
    }
}

/// Thin client over the TimeTagger v1 API (`<server>/api/v1/...`).
struct API {
    var baseURL: String
    var token: String

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// The server writes ISO-8601 with fractional seconds when there are any.
    private static let decoder: JSONDecoder = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = fractional.date(from: s) ?? plain.date(from: s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }()

    private static let iso = ISO8601DateFormatter()

    private func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard var comps = URLComponents(string: baseURL) else { throw APIError.notConfigured }
        comps.path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.path = (comps.path.isEmpty ? "" : "/" + comps.path) + "/api/v1/" + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.notConfigured }
        return url
    }

    private func send(_ req: URLRequest, auth: Bool = true) async throws -> Data {
        var req = req
        if auth {
            guard !token.isEmpty else { throw APIError.notConfigured }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            struct ErrorBody: Decodable { let message: String }
            let message = (try? Self.decoder.decode(ErrorBody.self, from: data))?.message ?? String(decoding: data, as: UTF8.self)
            throw APIError.http(code, message)
        }
        return data
    }

    func records(from t1: Int, to t2: Int) async throws -> [Record] {
        let query = [
            URLQueryItem(name: "from", value: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(t1)))),
            URLQueryItem(name: "to", value: Self.iso.string(from: Date(timeIntervalSince1970: TimeInterval(t2)))),
        ]
        struct Resp: Decodable { let records: [WireRecord] }
        return try Self.decoder.decode(Resp.self, from: try await send(URLRequest(url: try url("records", query)))).records.map(\.record)
    }

    /// Writes the records in one transaction (e.g. stop one and start the next);
    /// records without a server id are created.
    func put(_ records: [Record]) async throws {
        var req = URLRequest(url: try url("records/batch"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Batch: Encodable { let records: [WireRecord] }
        req.httpBody = try Self.encoder.encode(Batch(records: records.map(WireRecord.init)))
        _ = try await send(req)
    }

    /// Signs in with HTTP Basic and returns a long-lived API token: session → web token → API token.
    static func login(baseURL: String, username: String, password: String) async throws -> String {
        struct Token: Decodable { let token: String }
        var req = URLRequest(url: try API(baseURL: baseURL, token: "").url("sessions"))
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            data = try await API(baseURL: baseURL, token: "").send(req, auth: false)
        } catch APIError.http(401, _) {
            throw APIError.http(401, "Wrong username or password")
        }
        let web = API(baseURL: baseURL, token: try decoder.decode(Token.self, from: data).token)
        var tokenReq = URLRequest(url: try web.url("tokens"))
        tokenReq.httpMethod = "POST"
        return try decoder.decode(Token.self, from: try await web.send(tokenReq)).token
    }

    /// Follows the server's change stream, calling onChange after every write by any client.
    /// Returns when the stream ends; throws when it can't be opened.
    func watch(onChange: @escaping () async -> Void) async throws {
        guard !token.isEmpty else { throw APIError.notConfigured }
        var req = URLRequest(url: try url("changes/stream"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The server sends a heartbeat every 30 s, so a silent minute means the connection is gone.
        req.timeoutInterval = 90
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, "change stream unavailable") }
        for try await line in bytes.lines where line == "event: change" {
            await onChange()
        }
    }

    func version() async throws -> String {
        struct Version: Decodable { let version: String }
        return try Self.decoder.decode(Version.self, from: try await send(URLRequest(url: try url("version")), auth: false)).version
    }
}
