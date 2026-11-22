import AppKit
import CoreGraphics

// TimeTaggerUsage: a LaunchAgent (registered by TimeTaggerBar through SMAppService) that records
// which app is frontmost and uploads the blocks to the TimeTagger server, which stores them in
// ClickHouse. It runs whether or not the menu bar app is open.
//
// A block ends when another app comes to the front, the user goes idle, the screen locks or sleeps,
// or the Mac sleeps. The open block is re-sent with a later stop on every flush (the server keeps
// the latest stop per device + start), so the server is never more than a minute behind.
// Blocks the server hasn't taken yet are kept in a file and retried, so nothing is lost offline.

/// Written by TimeTaggerBar when app usage is turned on: where to send and the API key to use.
struct AgentConfig: Codable {
    var serverURL: String
    var apiKey: String

    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TimeTaggerBar", isDirectory: true)
    static let file = dir.appendingPathComponent("usage-agent.json")
    static func load() -> AgentConfig? { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(AgentConfig.self, from: $0) } }
}

struct Block: Codable, Equatable {
    var device: String
    var bundleId: String
    var appName: String
    var start: Date
    var stop: Date
}

/// No input for this long counts as away; the block ends at the last input.
let idleLimit: TimeInterval = 5 * 60
/// Blocks shorter than this (alt-tabbing through) are dropped.
let minBlock: TimeInterval = 2
let device = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

@MainActor
final class Recorder {
    private var current: Block?
    private var away = false
    private var pending: [Block] = []
    private let pendingFile = AgentConfig.dir.appendingPathComponent("usage-pending.json")
    private var uploading = false

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() {
        try? FileManager.default.createDirectory(at: AgentConfig.dir, withIntermediateDirectories: true)
        pending = (try? Data(contentsOf: pendingFile)).flatMap { try? Self.decoder.decode([Block].self, from: $0) } ?? []

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.switchTo(app) }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.goAway(at: Date()) } }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.comeBack() } }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.goAway(at: Date()) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.comeBack() }
        }

        switchTo(NSWorkspace.shared.frontmostApplication)
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
    }

    /// Seconds since the last keyboard or mouse input anywhere.
    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func switchTo(_ app: NSRunningApplication?) {
        let now = Date()
        close(at: now)
        guard !away, let app, let bundle = app.bundleIdentifier else { return }
        current = Block(device: device, bundleId: bundle, appName: app.localizedName ?? bundle, start: now, stop: now)
    }

    private func close(at t: Date) {
        guard var b = current else { return }
        current = nil
        b.stop = max(b.start, t)
        guard b.stop.timeIntervalSince(b.start) >= minBlock else { return }
        enqueue(b)
    }

    /// Replaces an earlier copy of the same block (same start) so the queue holds the latest stop.
    private func enqueue(_ b: Block) {
        if let i = pending.lastIndex(where: { $0.start == b.start && $0.device == b.device }) { pending[i] = b } else { pending.append(b) }
        save()
    }

    private func goAway(at t: Date) {
        close(at: t)
        away = true
    }

    private func comeBack() {
        guard away else { return }
        away = false
        switchTo(NSWorkspace.shared.frontmostApplication)
    }

    private func tick() {
        let idle = idleSeconds
        if !away, idle >= idleLimit {
            goAway(at: Date().addingTimeInterval(-idle))
        } else if away, idle < idleLimit, NSWorkspace.shared.frontmostApplication != nil, !Self.screenLocked {
            comeBack()
        } else if var b = current {
            // Blocks are capped at an hour so a single upload stays small and a crash loses little.
            b.stop = Date()
            if b.stop.timeIntervalSince(b.start) >= 3600 {
                enqueue(b)
                current = Block(device: b.device, bundleId: b.bundleId, appName: b.appName, start: b.stop, stop: b.stop)
            } else {
                current = b
            }
        }
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func save() {
        // Offline for weeks shouldn't grow without bound: keep the newest ~10k blocks.
        if pending.count > 10_000 { pending.removeFirst(pending.count - 10_000) }
        try? Self.encoder.encode(pending).write(to: pendingFile, options: .atomic)
    }

    private func flush() {
        guard !uploading, let config = AgentConfig.load() else { return }
        var batch = Array(pending.prefix(500))
        if let b = current, b.stop.timeIntervalSince(b.start) >= minBlock, batch.count < 500 { batch.append(b) }
        guard !batch.isEmpty else { return }
        let sent = Array(pending.prefix(500))
        uploading = true
        Task {
            defer { uploading = false }
            guard await upload(batch, config) else { return }
            // Drop what was sent, unless it changed meanwhile (a later stop for the same block).
            pending.removeAll { b in sent.contains(b) }
            save()
        }
    }

    private func upload(_ blocks: [Block], _ config: AgentConfig) async -> Bool {
        guard var comps = URLComponents(string: config.serverURL) else { return false }
        let base = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        comps.path = (base.isEmpty ? "" : "/" + base) + "/api/v1/usage"
        guard let url = comps.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("TimeTaggerUsage", forHTTPHeaderField: "User-Agent")
        struct Body: Encodable { let blocks: [Block] }
        req.httpBody = try? Self.encoder.encode(Body(blocks: blocks))
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 422 means the batch itself is bad; retrying it forever would block everything behind it.
        if code == 422 { NSLog("TimeTaggerUsage: server rejected a batch, dropping it") ; return true }
        return (200..<300).contains(code)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let recorder = MainActor.assumeIsolated { Recorder() }
app.run()
