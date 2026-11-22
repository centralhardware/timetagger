import Foundation
import ServiceManagement

/// Turns the TimeTaggerUsage LaunchAgent on and off. Turning it on creates an API key for it
/// (it runs without the app, so it can't share the app's session) and writes it, with the server,
/// to a file only this user can read; turning it off revokes the key and removes the file.
enum UsageAgent {
    static let plistName = "app.timetagger.usage.plist"
    static var service: SMAppService { SMAppService.agent(plistName: plistName) }
    /// Registered, even if macOS still waits for approval in Login Items.
    static var enabled: Bool { [.enabled, .requiresApproval].contains(service.status) }

    private struct Config: Codable { var serverURL: String; var apiKey: String; var apiKeyID: Int64? }
    private static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TimeTaggerBar", isDirectory: true)
    private static let file = dir.appendingPathComponent("usage-agent.json")

    static func enable(api: API) async throws {
        let name = "App usage (\(Host.current().localizedName ?? "Mac"))"
        let key = try await api.createApiKey(name: name)
        guard let secret = key.key else { throw APIError.http(0, "the server did not return the new API key") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Config(serverURL: api.baseURL, apiKey: secret, apiKeyID: key.id))
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        try service.register()
    }

    static func disable(api: API) async {
        try? await service.unregister()
        if let data = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Config.self, from: data), let id = c.apiKeyID {
            try? await api.revokeApiKey(id)
        }
        try? FileManager.default.removeItem(at: file)
    }
}
