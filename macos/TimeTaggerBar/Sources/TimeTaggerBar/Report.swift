import AppKit
import Foundation

enum Grouping: String, CaseIterable, Identifiable {
    case tags, description, none
    var id: String { rawValue }
}

enum GroupPeriod: String, CaseIterable, Identifiable {
    case none, day, week, month, quarter, year
    var id: String { rawValue }
}

enum DurationFormat: String, CaseIterable, Identifiable {
    case h0 = "9", hm = "9:07", hms = "9:07:24", h1 = "9.1", h2 = "9.12", h3 = "9.123"
    var id: String { rawValue }

    func format(_ secs: Int) -> String {
        let h = Double(secs) / 3600
        switch self {
        case .h0: return String(Int(h.rounded()))
        case .hm: return Store.format(secs, seconds: false)
        case .hms: return Store.format(secs)
        case .h1: return String(format: "%.1f", h)
        case .h2: return String(format: "%.2f", h)
        case .h3: return String(format: "%.3f", h)
        }
    }
}

struct ReportOptions: Equatable {
    var period: Period = .week
    var tags = ""
    var grouping: Grouping = .tags
    var groupPeriod: GroupPeriod = .none
    var workZone = true
    var duration: DurationFormat = .hm
    var showRecords = true
    var excludeTags = false
    var hideSecondaryTags = false
}

/// One row of the report table; header rows carry a subtotal.
struct ReportRow: Identifiable, Equatable {
    let id = UUID()
    var isHeader: Bool
    var cells: [String]
}

/// Builds the same table as the web app's report dialog ("Copy table").
struct ReportBuilder {
    let options: ReportOptions
    let timeZone: TimeZone

    var columns: [String] {
        options.excludeTags
            ? ["Total", "Duration", "Date", "Start", "Stop", "Description"]
            : ["Total", "Tags", "Duration", "Date", "Start", "Stop", "Description"]
    }

    func rows(_ records: [Record], from p1: Int, to p2: Int) -> [ReportRow] {
        let wanted = options.tags.replacingOccurrences(of: "#", with: "")
            .split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.lowercased() }
        let recs = records
            .filter { r in wanted.allSatisfy { r.tags.contains($0) } }
            .sorted { $0.t1 < $1.t1 }

        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = timeZone
        let now = Int(Date().timeIntervalSince1970)
        func clipped(_ r: Record) -> Int { max(0, min(r.isRunning ? now : r.t2, p2) - max(r.t1, p1)) }

        var out: [ReportRow] = []
        var periods: [(String, [Record])] = []
        for r in recs {
            let key = periodName(r.t1, cal)
            if periods.last?.0 == key { periods[periods.count - 1].1.append(r) } else { periods.append((key, [r])) }
        }
        for (pname, precs) in periods {
            if options.groupPeriod != .none {
                out.append(header(total: precs.reduce(0) { $0 + clipped($1) }, label: pname))
            }
            var groups: [(String, [Record])] = []
            for r in precs {
                let key = groupKey(r)
                if let i = groups.firstIndex(where: { $0.0 == key }) { groups[i].1.append(r) } else { groups.append((key, [r])) }
            }
            if options.grouping != .none { groups.sort { $0.0 < $1.0 } }
            for (gname, grecs) in groups {
                if options.grouping != .none {
                    out.append(header(total: grecs.reduce(0) { $0 + clipped($1) }, label: gname))
                }
                guard options.showRecords else { continue }
                for r in grecs { out.append(recordRow(r, duration: clipped(r))) }
            }
        }
        return out
    }

    private func tags(_ r: Record) -> [String] {
        let t = r.tags
        return options.hideSecondaryTags ? Array(t.prefix(1)) : t
    }

    private func groupKey(_ r: Record) -> String {
        switch options.grouping {
        case .tags: return tags(r).map { "#" + $0 }.joined(separator: " ")
        case .description: return description(r)
        case .none: return ""
        }
    }

    private func description(_ r: Record) -> String {
        guard options.excludeTags else { return r.ds }
        return r.ds.split(separator: " ").filter { !$0.hasPrefix("#") }.joined(separator: " ")
    }

    private func periodName(_ t: Int, _ cal: Calendar) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(t))
        let c = cal.dateComponents([.year, .month, .day, .weekOfYear, .yearForWeekOfYear], from: d)
        switch options.groupPeriod {
        case .none: return ""
        case .day: return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        case .week: return String(format: "%04d W%02d", c.yearForWeekOfYear!, c.weekOfYear!)
        case .month: return String(format: "%04d-%02d", c.year!, c.month!)
        case .quarter: return "\(c.year!) Q\((c.month! - 1) / 3 + 1)"
        case .year: return "\(c.year!)"
        }
    }

    private func header(total: Int, label: String) -> ReportRow {
        var cells = Array(repeating: "", count: columns.count)
        cells[0] = options.duration.format(total)
        cells[options.excludeTags ? columns.count - 1 : 1] = label
        return ReportRow(isHeader: true, cells: cells)
    }

    private func recordRow(_ r: Record, duration: Int) -> ReportRow {
        let date = DateFormatter(), time = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        time.dateFormat = "HH:mm"
        date.timeZone = timeZone
        time.timeZone = timeZone
        let t1 = Date(timeIntervalSince1970: TimeInterval(r.t1))
        let t2 = Date(timeIntervalSince1970: TimeInterval(r.t2))
        var cells = ["", options.duration.format(duration), date.string(from: t1),
                     time.string(from: t1), r.isRunning ? "" : time.string(from: t2), description(r)]
        if !options.excludeTags { cells.insert(tags(r).map { "#" + $0 }.joined(separator: " "), at: 1) }
        return ReportRow(isHeader: false, cells: cells)
    }

    /// Puts the table on the pasteboard as TSV and HTML, so spreadsheets keep the columns.
    static func copy(columns: [String], rows: [ReportRow]) {
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
        let tsv = ([columns] + rows.map(\.cells)).map { $0.map(clean).joined(separator: "\t") }.joined(separator: "\n")
        let esc = { (s: String) in
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let head = "<tr>" + columns.map { "<th>\(esc($0))</th>" }.joined() + "</tr>"
        let body = rows.map { row in
            "<tr>" + row.cells.map { row.isHeader ? "<td><b>\(esc($0))</b></td>" : "<td>\(esc($0))</td>" }.joined() + "</tr>"
        }.joined()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("<table>\(head)\(body)</table>", forType: .html)
        pb.setString(tsv, forType: .string)
    }
}
