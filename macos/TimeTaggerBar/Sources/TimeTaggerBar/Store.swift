import IOKit
import Foundation
import SwiftUI
import UserNotifications
import AppKit

enum Period: String, CaseIterable, Identifiable {
    case today = "Today", yesterday = "Yesterday", week = "This week", month = "This month"
    var id: String { rawValue }

    var range: (Int, Int) { range(in: .current) }

    /// The period's bounds as days in the given time zone ("today" in London starts at London midnight).
    func range(in timeZone: TimeZone) -> (Int, Int) {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let now = Date()
        let start: Date
        var end: Date
        switch self {
        case .today:
            start = cal.startOfDay(for: now)
            end = cal.date(byAdding: .day, value: 1, to: start)!
        case .yesterday:
            end = cal.startOfDay(for: now)
            start = cal.date(byAdding: .day, value: -1, to: end)!
        case .week:
            start = cal.dateInterval(of: .weekOfYear, for: now)!.start
            end = cal.date(byAdding: .day, value: 7, to: start)!
        case .month:
            let iv = cal.dateInterval(of: .month, for: now)!
            start = iv.start
            end = iv.end
        }
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }
}

@MainActor
final class Store: ObservableObject {
    @AppStorage("serverURL") var serverURL = "https://timetagger.centralhardware.me"
    @AppStorage("workTimeZone") var workTimeZoneID = "Europe/London"
    @AppStorage("showWorkTime") var showWorkTime = true
    @AppStorage("pauseOnSleep") var pauseOnSleep = true
    @AppStorage("username") var username = ""
    /// Where a ticket tag like #abc-123 opens; {key} becomes ABC-123. Empty turns the links off.
    @AppStorage("ticketURL") var ticketURL = ""
    /// Which project keys count as tickets ("ABC, XYZ"); empty accepts any. Read by Record.isTicket.
    @AppStorage("ticketPrefixes") var ticketPrefixes = ""
    /// What an untracked gap can be marked as, comma-separated, most common first.
    @AppStorage("breakKinds") var breakKindsText = "Lunch, Dinner, Breakfast, Coffee, Walk, Errand, Break"
    /// Settings kept on the server so every device shares them; UserDefaults is only the local copy.
    static let syncedKeys = ["ticketURL", "ticketPrefixes", "breakKinds"]
    /// Gap records (kind "gap") from the loaded range; kept out of `records` and `lately`
    /// so totals, history and the timeline only ever see work.
    @Published var gaps: [Record] = []
    @Published var workspaces: [Workspace] = []
    /// The workspace shown on this Mac (0: all). Only the choice is per device; the workspaces sync.
    @AppStorage("workspaceID") var workspaceID = 0
    /// What the server last held for each synced key, so pulling a value doesn't echo it back.
    private var syncedValues: [String: String] = [:]
    @AppStorage("remindIdle") var remindIdle = true
    @AppStorage("workStartHour") var workStartHour = 9
    @AppStorage("workEndHour") var workEndHour = 18
    /// Signed in while the keychain holds a refresh token; the server signing us out clears it.
    @Published var signedIn = Keychain.hasToken()
    let session = AuthSession()
    @Published var period: Period = .today
    @Published var records: [Record] = []
    @Published var running: [Record] = []
    @Published var error: String?
    @Published var lately: [Record] = []
    /// For autocomplete, most recently used first.
    @Published var tags: [String] = []
    @Published var serverVersion = "…"
    /// A newer release than this app, when GitHub has one.
    @Published var update: (version: String, url: URL)?
    /// The last change made from this app, until it is undone or goes stale.
    @Published var undoable: Change?
    private var lastNagged = 0

    struct Change {
        let label: String
        /// The records as they were, keyed by id; a record missing here was created by the change.
        let before: [String: Record]
        /// The records as the server saved them.
        let after: [Record]
        let at: Int
    }
    @Published var now = Int(Date().timeIntervalSince1970)

    private var tick: Timer?
    private var poll: Timer?
    /// The records that were running when the Mac went to sleep, and when it did.
    private var paused: [Record] = []
    private var sleptAt = 0

    init() {
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Int(Date().timeIntervalSince1970)
                // Undo is offered for a while, not forever.
                if let u = self.undoable, self.now - u.at > 30 { self.undoable = nil }
                if self.now % 60 == 0 { self.nagIfIdle() }
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { await checkForUpdate() }
        // Changes arrive through watchChanges(); the poll only covers a stream that is down.
        poll = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.didWake() }
            }
        }
        Task { await refresh() }
        Task { await watchChanges() }
    }

    /// Refreshes as soon as any client writes, reconnecting whenever the stream drops.
    private func watchChanges() async {
        while true {
            try? await api.watch { [weak self] in await self?.refresh() }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // Catch up on whatever was written while the stream was down.
            await refresh()
        }
    }

    /// Closing the lid stops the running record at that moment; the network may
    /// already be gone, so didWake() repeats the stop before resuming.
    /// Idle sleep with the lid open (or a desktop Mac) leaves the timer running.
    private func willSleep() {
        guard pauseOnSleep, !running.isEmpty, Self.lidClosed else { return }
        paused = running
        sleptAt = Int(Date().timeIntervalSince1970)
        let stopped = stoppedCopies(paused, at: sleptAt)
        Task { try? await api.put(stopped) }
    }

    /// Opening the lid resumes what was paused as a new record.
    private func didWake() async {
        guard !paused.isEmpty else { return }
        let toResume = paused
        paused = []
        // Give Wi-Fi a moment to come back.
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let t = Int(Date().timeIntervalSince1970)
        let resumed = toResume.map { Record(key: Record.newKey(), rev: 0, t1: t, t2: t, ds: $0.ds, tags: $0.tags, deleted: 0) }
        await save(stoppedCopies(toResume, at: sleptAt) + resumed)
    }

    /// Whether the built-in display's lid is shut, from IOPMrootDomain's AppleClamshellState;
    /// false on Macs without a lid.
    static var lidClosed: Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (v?.takeRetainedValue() as? Bool) ?? false
    }

    private func stoppedCopies(_ recs: [Record], at t: Int) -> [Record] {
        recs.map { var r = $0; r.t2 = max(t, r.t1 + 1); return r }
    }

    var api: API { API(baseURL: serverURL, session: session) }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var workTimeZone: TimeZone { TimeZone(identifier: workTimeZoneID) ?? .current }
    /// Days in the history and the timeline follow the work time zone, like "Worked today".
    var workCalendar: Calendar { var c = Calendar.current; c.timeZone = workTimeZone; return c }

    /// Clock time of a timestamp in the local or the work time zone.
    func clock(_ t: Int, work: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = work ? workTimeZone : .current
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
    }

    /// Short name of the work time zone's city ("Europe/London" → "London").
    /// "16:00–16:58", or "23:48–now" while running.
    func range(_ r: Record) -> String {
        clock(r.t1) + "–" + (r.isRunning ? "now" : clock(r.t2))
    }

    var workZoneName: String {
        workTimeZoneID.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? workTimeZoneID
    }

    /// The second time zone is only worth showing when it differs from the Mac's.
    var showsWorkZone: Bool {
        showWorkTime && workTimeZone.secondsFromGMT() != TimeZone.current.secondsFromGMT()
    }

    /// Today's total, with "today" counted in the work time zone (it starts at work-zone midnight),
    /// so it matches the day the employer sees rather than the local calendar day.
    var todayTotal: Int {
        var cal = Calendar.current
        cal.timeZone = workTimeZone
        let start = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        return lately.reduce(0) { $0 + max(0, ($1.isRunning ? now : $1.t2) - max($1.t1, start)) }
    }

    /// Menu bar text: today's total, preceded by the running timer when there is one.
    var menuTitle: String {
        let today = Self.format(todayTotal, seconds: false)
        guard let r = running.first else { return today }
        return Self.format(r.duration(now: now), seconds: false) + " · " + today
    }

    /// Hover text for the menu bar item: the running task's name, kept out of the bar itself.
    var menuTooltip: String {
        guard let r = running.first else { return "Not tracking" }
        return r.title
    }

    /// Starts the same task again: description, ticket and tags.
    func resume(_ r: Record) async {
        await start(r.ds, ticket: r.ticket, tags: r.tags)
    }

    /// Starts work on a ticket: resumes its latest task, or a bare record with just the ticket.
    func start(ticket: String) async {
        if let last = (running + lately + records).filter({ $0.ticket == ticket }).max(by: { $0.t1 < $1.t1 }) {
            await resume(last)
        } else {
            await start("", ticket: ticket)
        }
    }

    /// Biggest first; equal totals by name. A dictionary's order changes on every
    /// refresh, so without the tie-break two equal totals kept swapping places (and colours).
    nonisolated static func biggestFirst(_ a: (key: String, value: Int), _ b: (key: String, value: Int)) -> Bool {
        a.value != b.value ? a.value > b.value : a.key < b.key
    }

    /// Today's time per ticket, biggest first.
    var totalsByTicket: [(String, Int)] {
        var sums: [String: Int] = [:]
        let (p1, p2) = period.range(in: workTimeZone)
        for r in records {
            guard let t = r.ticket else { continue }
            let a = max(r.t1, p1), b = min(r.isRunning ? now : r.t2, p2)
            if b > a { sums[t, default: 0] += b - a }
        }
        return sums.sorted(by: Store.biggestFirst)
    }

    var totalsByTag: [(String, Int)] {
        var sums: [String: Int] = [:]
        let (p1, p2) = period.range(in: workTimeZone)
        for r in records {
            let t1 = max(r.t1, p1), t2 = min(r.isRunning ? now : r.t2, p2)
            guard t2 > t1 else { continue }
            let tags = r.tags.isEmpty ? ["untagged"] : r.tags
            for t in tags { sums[t, default: 0] += t2 - t1 }
        }
        return sums.sorted(by: Store.biggestFirst)
    }

    var total: Int {
        let (p1, p2) = period.range(in: workTimeZone)
        return records.reduce(0) { $0 + max(0, min($1.isRunning ? now : $1.t2, p2) - max($1.t1, p1)) }
    }

    func refresh() async {
        guard signedIn else { return }
        do {
            let (t1, t2) = period.range(in: workTimeZone)
            workspaces = (try? await api.workspaces()) ?? workspaces
            if workspaceID != 0, !workspaces.contains(where: { $0.id == Int64(workspaceID) }) { workspaceID = 0 }
            let period = try await api.records(from: t1, to: t2).filter { !$0.isDeleted }
            records = period.filter { !$0.isGap }.sorted { $0.t1 > $1.t1 }
            // Running records and today's total come from the last 30 days.
            let n = Int(Date().timeIntervalSince1970)
            let recent = try await api.records(from: n - 30 * 86400, to: n + 86400).filter { !$0.isDeleted }
            lately = recent.filter { !$0.isGap }
            gaps = Array(Dictionary((period + recent).filter(\.isGap).map { ($0.key, $0) }) { a, _ in a }.values)
            running = lately.filter(\.isRunning)
            // Autocomplete is a nicety: a server without the endpoint just offers none.
            tags = (try? await api.tags()) ?? tags
            serverVersion = (try? await api.version()) ?? "unreachable"
            await pullSettings()
            error = nil
        } catch APIError.signedOut {
            signedOutLocally()
            self.error = APIError.signedOut.localizedDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ recs: [Record], label: String? = nil, before: [Record] = []) async {
        do {
            let saved = try await api.put(recs)
            if let label {
                undoable = Change(label: label, before: Dictionary(before.map { ($0.key, $0) }) { a, _ in a },
                                  after: saved, at: Int(Date().timeIntervalSince1970))
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Puts back what the last change touched: edited records as they were, created ones deleted.
    func undo() async {
        guard let u = undoable else { return }
        undoable = nil
        let restore = u.after.map { saved -> Record in
            guard var old = u.before[saved.key] else { var r = saved; r.deleted = 1; return r }
            old.rev = saved.rev
            return old
        }
        await save(restore)
    }

    /// A notification when nothing is tracked during working hours on a weekday, at most every 30 minutes.
    /// Signed in, nothing running, inside working hours on a weekday.
    var idleInWorkHours: Bool {
        guard signedIn, running.isEmpty else { return false }
        var cal = Calendar.current
        cal.timeZone = workTimeZone
        let date = Date(timeIntervalSince1970: TimeInterval(now))
        let hour = cal.component(.hour, from: date)
        return !cal.isDateInWeekend(date) && hour >= workStartHour && hour < workEndHour
    }

    private func nagIfIdle() {
        guard remindIdle, idleInWorkHours else { return }
        // Give a short break a chance, and don't repeat too often.
        let lastStop = lately.map(\.t2).max() ?? 0
        guard now - lastStop > 15 * 60, now - lastNagged > 30 * 60 else { return }
        lastNagged = now
        let content = UNMutableNotificationContent()
        content.title = "Not tracking"
        content.body = "Nothing has been running for \(Self.format(now - lastStop, seconds: false))."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "idle", content: content, trigger: nil))
    }

    /// The outcome of the last update check, for Settings → About.
    @Published var updateStatus = ""

    func checkForUpdate() async {
        updateStatus = "Checking…"
        do {
            guard let latest = try await API.latestRelease() else {
                update = nil
                updateStatus = "No releases found"
                return
            }
            update = latest.version.compare(Self.appVersion, options: .numeric) == .orderedDescending ? latest : nil
            updateStatus = update == nil ? "Up to date" : ""
        } catch {
            updateStatus = "Couldn't check: \(error.localizedDescription)"
        }
    }

    /// The link for a ticket tag such as "abc-123", if a ticket URL is set and the tag looks like a key.
    func ticketLink(_ tag: String) -> URL? {
        guard !ticketURL.isEmpty, Record.isTicket(tag) else { return nil }
        return URL(string: ticketURL.replacingOccurrences(of: "{key}", with: tag.uppercased()))
    }

    /// Starts a new record, stopping whatever is running (like the web app's default).
    /// `at` backdates the start (from "25m ago" in the task field); whatever was running stops there.
    func start(_ description: String, ticket: String? = nil, tags: [String] = [], at: Int? = nil) async {
        let t = min(at ?? Int(Date().timeIntervalSince1970), Int(Date().timeIntervalSince1970))
        let stopped = running.map { r -> Record in var r = r; r.t2 = max(t, r.t1 + 1); return r }
        let new = Record(key: Record.newKey(), rev: 0, t1: t, t2: t, ds: description.trimmingCharacters(in: .whitespaces), tags: tags, deleted: 0, ticket: ticket)
        await save(stopped + [new], label: "Started \u{201C}\(new.ds)\u{201D}", before: running)
    }

    /// Starts work on a tag: resumes its latest task (description and tags), or a bare record with just the tag.
    func start(tag: String) async {
        if let last = (running + lately + records).filter({ $0.tags.contains(tag) }).max(by: { $0.t1 < $1.t1 }) {
            await resume(last)
        } else {
            await start("", tags: [tag])
        }
    }

    func stop(_ record: Record? = nil) async {
        let t = Int(Date().timeIntervalSince1970)
        let targets = record.map { [$0] } ?? running
        await save(targets.map { var r = $0; r.t2 = max(t, r.t1 + 1); return r }, label: "Stopped", before: targets)
    }

    /// The last few distinct tasks (description + tags), newest first, for one-click resume.
    var recentTasks: [Record] {
        // The running task is already on screen; it isn't "recent".
        var seen = Set(running.map(\.taskKey)), out: [Record] = []
        for r in (lately + records).sorted(by: { $0.t1 > $1.t1 }) where !r.isRunning && !r.isDeleted {
            let k = r.taskKey
            if seen.insert(k).inserted { out.append(r) }
            if out.count == 3 { break }
        }
        return out
    }

    /// Closes a gap or removes an overlap by moving the earlier record's end to `t`.
    func setEnd(_ record: Record, to t: Int) async {
        var r = record
        r.t2 = max(t, r.t1 + 1)
        await save([r], label: "Adjusted \u{201C}\(record.title)\u{201D}", before: [record])
    }

    func selectWorkspace(_ id: Int64?) async {
        workspaceID = Int(id ?? 0)
        await refresh()
    }

    func createWorkspace(_ name: String) async {
        do {
            let w = try await api.createWorkspace(name)
            await selectWorkspace(w.id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// A marked gap is a record of kind "gap" over it: still a gap on screen, never work.
    func gapRecord(from t1: Int, to t2: Int) -> Record? {
        gaps.first { !$0.isDeleted && $0.t1 < t2 && $0.t2 > t1 }
    }

    /// Names the gap [t1, t2] (creating its gap record), renames it, or with nil clears it.
    func markGap(from t1: Int, to t2: Int, as label: String?) async {
        if var g = gapRecord(from: t1, to: t2) {
            if let label { g.ds = label; g.t1 = t1; g.t2 = t2 } else { g.deleted = 1 }
            await save([g], label: label == nil ? "Cleared gap" : "Marked gap \u{201C}\(label!)\u{201D}", before: [gapRecord(from: t1, to: t2)!])
        } else if let label, t2 > t1 {
            let new = Record(key: Record.newKey(), rev: 0, t1: t1, t2: t2, ds: label, tags: [], deleted: 0, kind: "gap")
            await save([new], label: "Marked gap \u{201C}\(label)\u{201D}")
        }
    }

    var breakKinds: [String] {
        breakKindsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Takes the server's synced settings; one this Mac set before the server had any is uploaded.
    func pullSettings() async {
        guard let remote = try? await api.settings() else { return }   // an older server has no /settings
        let d = UserDefaults.standard
        for k in Store.syncedKeys {
            if let v = remote[k] {
                syncedValues[k] = v
                if d.string(forKey: k) != v { d.set(v, forKey: k); objectWillChange.send() }
            } else if let local = d.string(forKey: k) {
                await pushSetting(k, local)
            }
        }
    }

    /// Sends a synced setting the user just changed here.
    func pushSetting(_ key: String, _ value: String) async {
        guard signedIn, syncedValues[key] != value else { return }
        do {
            try await api.putSetting(key, value)
            syncedValues[key] = value
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Joins back-to-back sessions into the earliest one, which then runs to the latest end.
    func merge(_ recs: [Record]) async {
        let sorted = recs.sorted { $0.t1 < $1.t1 }
        guard var first = sorted.first, let last = sorted.last, sorted.count > 1 else { return }
        first.t2 = last.isRunning ? first.t1 : last.t2
        let gone = sorted.dropFirst().map { r -> Record in var r = r; r.deleted = 1; return r }
        await save([first] + gone, label: "Merged \(sorted.count) sessions", before: sorted)
    }

    func update(_ record: Record) async {
        await save([record], label: "Edited", before: (lately + records).filter { $0.key == record.key })
    }

    func delete(_ record: Record) async {
        var r = record
        r.deleted = 1
        await save([r], label: "Deleted \u{201C}\(record.ds)\u{201D}", before: [record])
    }

    func signIn(url: String, username: String, password: String) async throws {
        try await API(baseURL: url, session: session).login(username: username, password: password)
        serverURL = url
        self.username = username
        signedIn = true
        await refresh()
    }

    func signOut() async {
        await api.logout()
        signedOutLocally()
    }

    /// What's left to do once the session is gone, by choice or because the server ended it.
    private func signedOutLocally() {
        signedIn = false
        username = ""
        running = []
        records = []
        lately = []
    }

    nonisolated static func format(_ secs: Int, seconds: Bool = true) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return seconds ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", h, m)
    }
}
