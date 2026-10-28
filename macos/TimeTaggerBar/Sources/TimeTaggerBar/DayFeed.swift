import Foundation

/// Records grouped by day, newest first, reaching a week further back each time
/// the end of the list scrolls into view. Shared by the menu and the History window.
@MainActor
final class DayFeed: ObservableObject {
    struct Day: Identifiable {
        let id: Date
        let records: [Record]
    }

    /// Weeks loaded per step back.
    private static let chunkDays = 7
    /// Two months in a row with nothing logged is taken as the start of the history.
    private static let emptyChunksToStop = 9

    @Published private(set) var records: [Record] = []
    @Published private(set) var reachedEnd = false
    /// Start of the oldest day loaded so far.
    private var oldest = Calendar.current.date(byAdding: .day, value: -(chunkDays - 1), to: Calendar.current.startOfDay(for: Date()))!
    private var emptyChunks = 0
    private var loading = false

    func days() -> [Day] { Self.group(records) }

    nonisolated static func group(_ records: [Record]) -> [Day] {
        let groups = Dictionary(grouping: records) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.t1))) }
        return groups.keys.sorted(by: >).map { Day(id: $0, records: groups[$0]!.sorted { $0.t1 > $1.t1 }) }
    }

    /// Re-reads everything loaded so far, e.g. after a write here or on another device.
    func reload(_ api: API) async throws {
        records = try await fetch(api, from: oldest, to: tomorrow)
    }

    /// Steps one chunk further back; a no-op while a load is running or once the start is reached.
    func loadMore(_ api: API) async throws {
        guard !loading, !reachedEnd else { return }
        loading = true
        defer { loading = false }
        let from = Calendar.current.date(byAdding: .day, value: -Self.chunkDays, to: oldest)!
        let older = try await fetch(api, from: from, to: oldest)
        oldest = from
        records += older
        emptyChunks = older.isEmpty ? emptyChunks + 1 : 0
        reachedEnd = emptyChunks >= Self.emptyChunksToStop
    }

    private var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))! }

    /// Records that started in [from, to), so a record crossing midnight belongs to one day only.
    private func fetch(_ api: API, from: Date, to: Date) async throws -> [Record] {
        let t1 = Int(from.timeIntervalSince1970), t2 = Int(to.timeIntervalSince1970)
        return try await api.records(from: t1, to: t2).filter { !$0.isDeleted && $0.t1 >= t1 && $0.t1 < t2 }
    }
}
