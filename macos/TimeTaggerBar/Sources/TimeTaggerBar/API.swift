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
    /// The server no longer accepts the refresh token: sign in again.
    case signedOut
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Sign in from Settings."
        case .signedOut: return "Signed out. Sign in again from Settings."
        case let .http(code, body): return "HTTP \(code): \(body)"
        }
    }
}

/// What a login or refresh returns.
struct TokenPair: Decodable {
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
}

/// Holds the access token in memory and the refresh token in the keychain, and trades
/// the refresh token for a new pair shortly before the access token runs out.
actor AuthSession {
    private var access: (token: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    func adopt(_ pair: TokenPair) {
        access = (pair.accessToken, pair.accessExpiresAt)
        Keychain.save(pair.refreshToken)
    }

    func clear() {
        access = nil
        Keychain.save("")
    }

    /// Forgets the access token, e.g. after the server turned it down.
    func expireAccess() { access = nil }

    /// A current access token, refreshing first when it has under a minute left.
    func accessToken(_ api: API) async throws -> String {
        if let a = access, a.expires.timeIntervalSinceNow > 60 { return a.token }
        // Concurrent callers share one refresh: a second use of the old refresh token would end the session.
        if let refreshing { return try await refreshing.value }
        let refresh = Keychain.load()
        guard !refresh.isEmpty else { throw APIError.notConfigured }
        let task = Task { () throws -> String in
            do {
                let pair = try await api.refresh(refresh)
                self.adopt(pair)
                return pair.accessToken
            } catch APIError.http(401, _) {
                self.clear()
                throw APIError.signedOut
            }
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
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
    var session: AuthSession

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

    private func send(_ req: URLRequest, auth: Bool = true, retried: Bool = false) async throws -> Data {
        var req = req
        if auth {
            req.setValue("Bearer \(try await session.accessToken(self))", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // An access token can die early (a server restart without a fixed key): refresh once and retry.
        if auth, code == 401, !retried {
            await session.expireAccess()
            return try await send(req, auth: true, retried: true)
        }
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

    /// The tags in use, most recently used first.
    func tags() async throws -> [String] {
        struct Resp: Decodable { let tags: [String] }
        return try Self.decoder.decode(Resp.self, from: try await send(URLRequest(url: try url("records/tags")))).tags
    }

    /// Writes the records in one transaction (e.g. stop one and start the next);
    /// records without a server id are created.
    @discardableResult
    func put(_ records: [Record]) async throws -> [Record] {
        var req = URLRequest(url: try url("records/batch"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Batch: Codable { let records: [WireRecord] }
        req.httpBody = try Self.encoder.encode(Batch(records: records.map(WireRecord.init)))
        return try Self.decoder.decode(Batch.self, from: try await send(req)).records.map(\.record)
    }

    /// Records whose description contains `text`, across all time, newest first.
    func search(_ text: String) async throws -> [Record] {
        struct Resp: Decodable { let records: [WireRecord] }
        let data = try await send(URLRequest(url: try url("records", [URLQueryItem(name: "q", value: text)])))
        return try Self.decoder.decode(Resp.self, from: data).records.map(\.record).sorted { $0.t1 > $1.t1 }
    }

    /// The newest TimeTaggerBar release on GitHub: its version and page.
    static func latestRelease() async throws -> (version: String, url: URL)? {
        struct Release: Decodable { let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool }
        let url = URL(string: "https://api.github.com/repos/centralhardware/timetagger/releases?per_page=20")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let prefix = "macos-v"
        return try JSONDecoder().decode([Release].self, from: data)
            .first { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(prefix) }
            .map { (String($0.tag_name.dropFirst(prefix.count)), $0.html_url) }
    }

    /// Signs in with username and password; the session keeps the tokens.
    func login(username: String, password: String) async throws {
        struct Body: Encodable { let username: String; let password: String }
        do {
            let data = try await post("auth/login", Body(username: username, password: password), auth: false)
            await session.adopt(try Self.decoder.decode(TokenPair.self, from: data))
        } catch APIError.http(401, _) {
            throw APIError.http(401, "Wrong username or password")
        }
    }

    /// Ends this session on the server too, so the refresh token is dead even if it was copied.
    func logout() async {
        struct Body: Encodable { let refreshToken: String }
        let refresh = Keychain.load()
        if !refresh.isEmpty { _ = try? await post("auth/logout", Body(refreshToken: refresh), auth: false) }
        await session.clear()
    }

    fileprivate func refresh(_ token: String) async throws -> TokenPair {
        struct Body: Encodable { let refreshToken: String }
        return try Self.decoder.decode(TokenPair.self, from: try await post("auth/refresh", Body(refreshToken: token), auth: false))
    }

    private func post(_ path: String, _ body: some Encodable, auth: Bool = true) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(body)
        return try await send(req, auth: auth)
    }

    private func delete(_ path: String) async throws {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "DELETE"
        _ = try await send(req)
    }

    /// A signed-in device, as the server lists it.
    struct SignedInSession: Decodable, Identifiable {
        let id: String
        let userAgent: String?
        let lastRefreshedAt: Date
    }

    func sessions() async throws -> [SignedInSession] {
        struct Resp: Decodable { let sessions: [SignedInSession] }
        return try Self.decoder.decode(Resp.self, from: try await send(URLRequest(url: try url("auth/sessions")))).sessions
    }

    func endSession(_ id: String) async throws { try await delete("auth/sessions/\(id)") }

    struct ApiKey: Decodable, Identifiable {
        let id: Int64
        let name: String
        let prefix: String
        let createdAt: Date
        let lastUsedAt: Date?
        /// Only in the answer to its creation.
        let key: String?
    }

    func apiKeys() async throws -> [ApiKey] {
        struct Resp: Decodable { let apiKeys: [ApiKey] }
        return try Self.decoder.decode(Resp.self, from: try await send(URLRequest(url: try url("api-keys")))).apiKeys
    }

    func createApiKey(name: String) async throws -> ApiKey {
        struct Body: Encodable { let name: String }
        return try Self.decoder.decode(ApiKey.self, from: try await post("api-keys", Body(name: name)))
    }

    func revokeApiKey(_ id: Int64) async throws { try await delete("api-keys/\(id)") }

    /// Follows the server's change stream, calling onChange after every write by any client.
    /// Returns when the stream ends; throws when it can't be opened.
    func watch(onChange: @escaping () async -> Void) async throws {
        var req = URLRequest(url: try url("changes/stream"))
        // Checked when the stream opens; it stays open past the token's expiry.
        req.setValue("Bearer \(try await session.accessToken(self))", forHTTPHeaderField: "Authorization")
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
