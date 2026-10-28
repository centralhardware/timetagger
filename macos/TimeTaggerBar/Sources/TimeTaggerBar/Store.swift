import Foundation
import SwiftUI

enum Period: String, CaseIterable, Identifiable {
    case today = "Today", yesterday = "Yesterday", week = "This week", month = "This month"
    var id: String { rawValue }

    var range: (Int, Int) {
        let cal = Calendar.current
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
    @AppStorage("serverURL") var serverURL = "https://timetagger.app/timetagger"
    @Published var token = Keychain.load()
    @Published var period: Period = .today
    @Published var records: [Record] = []
    @Published var running: [Record] = []
    @Published var recent: [String] = []
    @Published var error: String?
    @Published var now = Int(Date().timeIntervalSince1970)

    private var tick: Timer?
    private var poll: Timer?

    init() {
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Int(Date().timeIntervalSince1970) }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    var api: API { API(baseURL: serverURL, token: token) }

    var menuTitle: String {
        guard let r = running.first else { return "" }
        return Self.format(r.duration(now: now), seconds: false)
    }

    var totalsByTag: [(String, Int)] {
        var sums: [String: Int] = [:]
        let (p1, p2) = period.range
        for r in records {
            let t1 = max(r.t1, p1), t2 = min(r.isRunning ? now : r.t2, p2)
            guard t2 > t1 else { continue }
            let tags = r.tags.isEmpty ? ["untagged"] : r.tags
            for t in tags { sums[t, default: 0] += t2 - t1 }
        }
        return sums.sorted { $0.value > $1.value }
    }

    var total: Int {
        let (p1, p2) = period.range
        return records.reduce(0) { $0 + max(0, min($1.isRunning ? now : $1.t2, p2) - max($1.t1, p1)) }
    }

    func refresh() async {
        do {
            let (t1, t2) = period.range
            records = try await api.records(from: t1, to: t2)
                .filter { !$0.isDeleted }
                .sorted { $0.t1 > $1.t1 }
            // Running records and recent descriptions come from the last 30 days.
            let n = Int(Date().timeIntervalSince1970)
            let lately = try await api.records(from: n - 30 * 86400, to: n + 86400).filter { !$0.isDeleted }
            running = lately.filter(\.isRunning)
            var seen = Set<String>()
            recent = lately.sorted { $0.t1 > $1.t1 }.map(\.ds)
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .prefix(10).map { $0 }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ recs: [Record]) async {
        let mt = Int(Date().timeIntervalSince1970)
        do {
            try await api.put(recs.map { var r = $0; r.mt = mt; return r })
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts a new record, stopping whatever is running (like the web app's default).
    func start(_ description: String) async {
        let t = Int(Date().timeIntervalSince1970)
        let stopped = running.map { r -> Record in var r = r; r.t2 = max(t, r.t1 + 1); return r }
        let new = Record(key: Record.newKey(), mt: t, t1: t, t2: t, ds: description.trimmingCharacters(in: .whitespaces), deleted: 0)
        await save(stopped + [new])
    }

    func stop(_ record: Record? = nil) async {
        let t = Int(Date().timeIntervalSince1970)
        let targets = record.map { [$0] } ?? running
        await save(targets.map { var r = $0; r.t2 = max(t, r.t1 + 1); return r })
    }

    func update(_ record: Record) async { await save([record]) }

    func delete(_ record: Record) async {
        var r = record
        r.deleted = 1
        await save([r])
    }

    func saveSettings(url: String, token: String) async {
        serverURL = url
        self.token = token
        Keychain.save(token)
        await refresh()
    }

    static func format(_ secs: Int, seconds: Bool = true) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        return seconds ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", h, m)
    }
}
