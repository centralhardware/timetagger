import Foundation

/// One line typed into the task field, e.g. "SM-1176 fix login #call 25m ago":
/// ticket keys and #words become tags, "25m ago" / "1h ago" / "at 14:30" backdate the start.
struct QuickEntry: Equatable {
    var ds = ""
    var tags: [String] = []
    /// Start time when the text names one; nil means now.
    var start: Int?

    var isEmpty: Bool { ds.isEmpty && tags.isEmpty }

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> QuickEntry {
        var e = QuickEntry()
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)

        // "<n>m ago" / "<n>h ago" / "<n>min ago" at the end.
        if words.count >= 2, words.last!.lowercased() == "ago",
           let secs = duration(words[words.count - 2]) {
            e.start = Int(now.timeIntervalSince1970) - secs
            words.removeLast(2)
        } else if words.count >= 2, ["at", "since"].contains(words[words.count - 2].lowercased()),
                  let t = clock(words.last!, now: now, calendar: calendar) {
            e.start = t
            words.removeLast(2)
        }

        var rest: [String] = []
        for w in words {
            if w.hasPrefix("#") {
                e.tags += Record.parseTags(w).filter { !e.tags.contains($0) }
            } else if Record.isTicket(w.lowercased()), !e.tags.contains(w.lowercased()) {
                e.tags.append(w.lowercased())
            } else {
                rest.append(w)
            }
        }
        e.ds = rest.joined(separator: " ")
        return e
    }

    /// "25m", "25min", "1h", "1.5h" → seconds.
    static func duration(_ w: String) -> Int? {
        let s = w.lowercased()
        for (suffix, mul) in [("min", 60.0), ("m", 60.0), ("h", 3600.0)] where s.hasSuffix(suffix) {
            if let n = Double(s.dropLast(suffix.count)), n > 0, n < 24 * 60 { return Int(n * mul) }
        }
        return nil
    }

    /// "14:30" today; a time later than now means yesterday.
    static func clock(_ w: String, now: Date, calendar: Calendar) -> Int? {
        let p = w.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]), (0..<24).contains(h), (0..<60).contains(m),
              var d = calendar.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
        if d > now { d = calendar.date(byAdding: .day, value: -1, to: d)! }
        return Int(d.timeIntervalSince1970)
    }
}
