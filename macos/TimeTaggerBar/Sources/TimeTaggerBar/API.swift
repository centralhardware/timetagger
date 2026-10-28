import Foundation

/// A TimeTagger record, as stored by the server. A running record has t1 == t2.
struct Record: Codable, Identifiable, Hashable {
    var key: String
    var mt: Int
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

    static func newKey() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<8).map { _ in chars.randomElement()! })
    }
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

/// Thin client over the TimeTagger v2 API (`<server>/api/v2/...`).
struct API {
    var baseURL: String
    var token: String

    private func url(_ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard !token.isEmpty, var comps = URLComponents(string: baseURL) else { throw APIError.notConfigured }
        comps.path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.path = (comps.path.isEmpty ? "" : "/" + comps.path) + "/api/v2/" + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.notConfigured }
        return url
    }

    private func send(_ req: URLRequest) async throws -> Data {
        var req = req
        req.setValue(token, forHTTPHeaderField: "authtoken")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    func records(from t1: Int, to t2: Int) async throws -> [Record] {
        let req = URLRequest(url: try url("records", [URLQueryItem(name: "timerange", value: "\(t1)-\(t2)")]))
        struct Resp: Decodable { let records: [Record] }
        return try JSONDecoder().decode(Resp.self, from: try await send(req)).records
    }

    func put(_ records: [Record]) async throws {
        var req = URLRequest(url: try url("records"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(records)
        struct Resp: Decodable { let failed: [String]; let errors: [String] }
        let resp = try JSONDecoder().decode(Resp.self, from: try await send(req))
        if !resp.failed.isEmpty { throw APIError.http(200, resp.errors.joined(separator: "; ")) }
    }

    /// Exchanges a username and password for a long-lived API token, the way the
    /// web app's login page does: credentials → web token → API token.
    static func login(baseURL: String, username: String, password: String) async throws -> String {
        struct Token: Decodable { let token: String }
        var req = URLRequest(url: try API(baseURL: baseURL, token: "-").url("bootstrap_authentication"))
        req.httpMethod = "POST"
        let creds = ["method": "usernamepassword", "username": username, "password": password]
        req.httpBody = try JSONEncoder().encode(creds).base64EncodedData()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        let webtoken = try JSONDecoder().decode(Token.self, from: data).token
        let apiData = try await API(baseURL: baseURL, token: webtoken).send(URLRequest(url: try API(baseURL: baseURL, token: webtoken).url("apitoken")))
        return try JSONDecoder().decode(Token.self, from: apiData).token
    }

    func version() async throws -> String {
        String(decoding: try await send(URLRequest(url: try url("version"))), as: UTF8.self)
    }
}
