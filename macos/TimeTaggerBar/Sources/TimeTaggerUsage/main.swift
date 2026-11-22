import AppKit
import ApplicationServices
import CoreGraphics

// TimeTaggerUsage: a LaunchAgent (registered by TimeTaggerBar through SMAppService) that records
// what is in front and uploads it to the TimeTagger server, which stores it in ClickHouse.
// It runs whether or not the menu bar app is open.
//
// Two kinds of block:
// - "app": an app was frontmost, with its focused window's title (needs the Accessibility
//   permission; without it titles stay empty). A new app or a new title starts a new block.
// - "away": nobody at the Mac, with the reason: "idle" (no input for 5 min, back-dated to the
//   last input), "lock" or "sleep". A lock or sleep block ending is a pickup.
// The open block is re-sent with a later stop on every flush (the server keeps the latest stop
// per device + start), so the server is never more than a minute behind. Blocks the server
// hasn't taken yet are kept in a file and retried, so nothing is lost offline.

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
    var kind: String
    var bundleId: String
    var appName: String
    var title: String
    var start: Date
    var stop: Date

    var length: TimeInterval { stop.timeIntervalSince(start) }
}

/// No input for this long counts as away; the away block starts at the last input.
let idleLimit: TimeInterval = 5 * 60
/// App blocks shorter than this (alt-tabbing through) are dropped.
let minBlock: TimeInterval = 2
/// A title change this soon after the block began renames it instead of splitting it
/// (a page still loading, a terminal redrawing its title).
let titleSettle: TimeInterval = 5
/// Long blocks are cut so one upload stays small and a crash loses little.
let maxBlock: TimeInterval = 3600
let device = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

@MainActor
final class Recorder {
    /// The open block: an app in front, or an away stretch.
    private var current: Block?
    private var pending: [Block] = []
    private let pendingFile = AgentConfig.dir.appendingPathComponent("usage-pending.json")
    private var uploading = false

    private var isAway: Bool { current?.kind == "away" }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() {
        try? FileManager.default.createDirectory(at: AgentConfig.dir, withIntermediateDirectories: true)
        pending = (try? Data(contentsOf: pendingFile)).flatMap { try? Self.decoder.decode([Block].self, from: $0) } ?? []
        // Asks once for Accessibility (System Settings lists it as TimeTaggerUsage); titles stay empty until granted.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.showApp(app) }
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.goAway("sleep", at: Date()) } }
        }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.goAway("lock", at: Date()) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.comeBack() } }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.goAway("lock", at: Date()) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.comeBack() }
        }

        showApp(NSWorkspace.shared.frontmostApplication)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
    }

    /// Seconds since the last keyboard or mouse input anywhere.
    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// The focused window's title of the app, or "" without Accessibility or a window.
    private static func title(of app: NSRunningApplication) -> String {
        guard AXIsProcessTrusted() else { return "" }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &win) == .success, let win else { return "" }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return "" }
        return String(((title as? String) ?? "").prefix(1024))
    }

    /// Starts an app block for the frontmost app, unless nobody is at the Mac.
    private func showApp(_ app: NSRunningApplication?) {
        guard !isAway else { return }
        let now = Date()
        close(at: now)
        guard let app, let bundle = app.bundleIdentifier else { return }
        current = Block(device: device, kind: "app", bundleId: bundle, appName: app.localizedName ?? bundle,
                        title: Self.title(of: app), start: now, stop: now)
    }

    private func close(at t: Date) {
        guard var b = current else { return }
        current = nil
        b.stop = max(b.start, t)
        if b.kind == "app" && b.length < minBlock { return }
        enqueue(b)
    }

    /// Replaces an earlier copy of the same block (same start) so the queue holds the latest stop.
    private func enqueue(_ b: Block) {
        if let i = pending.lastIndex(where: { $0.start == b.start && $0.device == b.device }) { pending[i] = b } else { pending.append(b) }
        save()
    }

    /// An idle stretch that turns into a lock or sleep becomes a block of its own, so the pickup
    /// is counted; a sleep that follows a lock (or the reverse) stays one block.
    private func goAway(_ reason: String, at t: Date) {
        if let b = current, b.kind == "away" {
            guard b.bundleId == "idle", reason != "idle" else { return }
        }
        close(at: t)
        current = Block(device: device, kind: "away", bundleId: reason, appName: reason, title: "", start: t, stop: t)
    }

    private func comeBack() {
        guard isAway else { return }
        // Woken, but the lock screen is up: still away.
        if Self.screenLocked { return goAway("lock", at: Date()) }
        close(at: Date())
        showApp(NSWorkspace.shared.frontmostApplication)
    }

    private func tick() {
        let now = Date()
        let idle = idleSeconds
        if !isAway, idle >= idleLimit {
            return goAway("idle", at: now.addingTimeInterval(-idle))
        }
        if isAway {
            if current?.bundleId == "idle", idle < idleLimit, !Self.screenLocked { return comeBack() }
        } else if let b = current, let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == b.bundleId {
            let title = Self.title(of: app)
            if title != b.title {
                if now.timeIntervalSince(b.start) < titleSettle {
                    current?.title = title
                } else {
                    close(at: now)
                    current = Block(device: device, kind: "app", bundleId: b.bundleId, appName: b.appName, title: title, start: now, stop: now)
                }
            }
        }
        guard var b = current else { return }
        b.stop = now
        if b.length >= maxBlock {
            enqueue(b)
            b.start = now
        }
        current = b
    }

    private func save() {
        // Offline for weeks shouldn't grow without bound: keep the newest ~20k blocks.
        if pending.count > 20_000 { pending.removeFirst(pending.count - 20_000) }
        try? Self.encoder.encode(pending).write(to: pendingFile, options: .atomic)
    }

    private func flush() {
        guard !uploading, let config = AgentConfig.load() else { return }
        let sent = Array(pending.prefix(500))
        var batch = sent
        if let b = current, b.kind == "away" || b.length >= minBlock { batch.append(b) }
        guard !batch.isEmpty else { return }
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
        if code == 422 { NSLog("TimeTaggerUsage: server rejected a batch, dropping it"); return true }
        return (200..<300).contains(code)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let recorder = MainActor.assumeIsolated { Recorder() }
app.run()
