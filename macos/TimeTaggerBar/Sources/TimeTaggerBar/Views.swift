import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @State private var editing: Record?
    @State private var showSettings = false
    /// The day the list shows: today whenever the menu opens, ‹ › to move.
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var dayRecords: [Record] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let err = store.error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            if let r = store.running.first {
                runningCard(r)
                taskField("Switch to… #tag", icon: "play")
            } else {
                idleCard
            }

            daySection

            Divider()

            HStack(spacing: 10) {
                Text("Today").foregroundStyle(.secondary)
                Text(Store.format(store.todayTotal, seconds: false)).bold().monospacedDigit()
                Spacer()
                Button("History") {
                    openWindow(id: "history")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Report") {
                    openWindow(id: "report")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Menu {
                    Text("TimeTaggerBar \(Store.appVersion)")
                    Divider()
                    Button("Settings…") { showSettings = true }
                    Button("Refresh") { Task { await store.refresh() } }
                    Divider()
                    Button("Quit TimeTaggerBar") { NSApp.terminate(nil) }
                } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("More")
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .sheet(item: $editing) { r in
            EditRecordView(record: r).environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store).padding()
        }
        .onAppear { day = Calendar.current.startOfDay(for: Date()) }
        // Reload when the day changes and whenever the store has refreshed (a write here or anywhere else).
        .task(id: "\(day.timeIntervalSince1970)-\(store.lately.hashValue)") { await loadDay() }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous day")
                Text(isToday ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.callout.weight(.semibold))
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday)
                    .accessibilityLabel("Next day")
                Spacer()
                Text(Store.format(dayRecords.reduce(0) { $0 + $1.duration(now: store.now) }, seconds: false))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)

            if dayRecords.isEmpty {
                Text("No records").foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(dayRecords) { r in dayRow(r) }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    private func dayRow(_ r: Record) -> some View {
        HStack(spacing: 8) {
            Text(store.clock(r.t1) + "–" + (r.isRunning ? "now" : store.clock(r.t2)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(r.ds.isEmpty ? "(no description)" : r.ds).lineLimit(1)
            Spacer()
            Text(Store.format(r.duration(now: store.now), seconds: false)).monospacedDigit().foregroundStyle(.secondary)
            if !r.isRunning {
                Button { Task { await store.start(r.ds) } } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Resume \(r.ds)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { editing = r }
        .contextMenu {
            Button("Edit…") { editing = r }
            Button("Resume") { Task { await store.start(r.ds) } }
            if r.isRunning { Button("Stop") { Task { await store.stop(r) } } }
            Divider()
            Button("Delete", role: .destructive) { Task { await store.delete(r) } }
        }
    }

    private func move(_ days: Int) {
        day = Calendar.current.date(byAdding: .day, value: days, to: day)!
    }

    private func loadDay() async {
        let t1 = Int(day.timeIntervalSince1970)
        let t2 = Int(Calendar.current.date(byAdding: .day, value: 1, to: day)!.timeIntervalSince1970)
        do {
            // Records that started this day, newest first.
            dayRecords = try await store.api.records(from: t1, to: t2)
                .filter { !$0.isDeleted && $0.t1 >= t1 && $0.t1 < t2 }
                .sorted { $0.t1 > $1.t1 }
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func runningCard(_ r: Record) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Tracking", systemImage: "circle.fill")
                .font(.caption.weight(.semibold)).textCase(.uppercase)
                .foregroundStyle(.red)
            HStack(spacing: 14) {
                Text("Since **\(store.clock(r.t1))** local")
                if store.showsWorkZone {
                    Text("**\(store.clock(r.t1, work: true))** \(store.workZoneName) · work")
                }
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text(Store.format(r.duration(now: store.now)))
                .font(.system(size: 44, weight: .light)).monospacedDigit()
            Text(r.ds.isEmpty ? "(no description)" : r.ds).font(.headline).lineLimit(2)
            HStack(spacing: 8) {
                Button { Task { await store.stop(r) } } label: {
                    Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                Button { editing = r } label: { Image(systemName: "pencil") }
                    .controlSize(.large)
                    .accessibilityLabel("Edit current record")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Not tracking").font(.caption.weight(.semibold)).textCase(.uppercase).foregroundStyle(.secondary)
                Spacer()
                Text("**\(store.clock(store.now))** local")
                if store.showsWorkZone { Text("**\(store.clock(store.now, work: true))** \(store.workZoneName)") }
            }
            .font(.callout).monospacedDigit()
            taskField("What are you working on? #tag", icon: nil)
            Button(action: startDraft) {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func taskField(_ prompt: String, icon: String?) -> some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
            TextField(prompt, text: $draft)
                .textFieldStyle(.plain)
                .onSubmit(startDraft)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func startDraft() {
        let ds = draft
        draft = ""
        Task { await store.start(ds) }
    }
}

struct RecordRow: View {
    let record: Record
    let now: Int

    var body: some View {
        HStack {
            Text(Self.time(record.t1) + "–" + (record.isRunning ? "now" : Self.time(record.t2)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(record.ds.isEmpty ? "(no description)" : record.ds).lineLimit(1)
            Spacer()
            Text(Store.format(record.duration(now: now), seconds: false)).monospacedDigit()
        }
        .font(.callout)
    }

    static func time(_ t: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(t))
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "E HH:mm"
        return f.string(from: d)
    }
}

struct EditRecordView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var record: Record
    @State private var start = Date()
    @State private var end = Date()
    @State private var running = false

    var body: some View {
        Form {
            TextField("Description", text: $record.ds)
            DatePicker("Start", selection: $start)
            Toggle("Running", isOn: $running)
            if !running { DatePicker("End", selection: $end) }
        }
        .padding()
        .frame(width: 360)
        .onAppear {
            start = Date(timeIntervalSince1970: TimeInterval(record.t1))
            end = Date(timeIntervalSince1970: TimeInterval(record.t2))
            running = record.isRunning
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    record.t1 = Int(start.timeIntervalSince1970)
                    record.t2 = running ? record.t1 : max(Int(end.timeIntervalSince1970), record.t1 + 1)
                    let r = record
                    Task { await store.update(r) }
                    dismiss()
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Account") {
                if store.token.isEmpty {
                    TextField("Server", text: $url, prompt: Text("https://timetagger.example.com"))
                    TextField("Username", text: $username)
                        .textContentType(.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit(signIn)
                    HStack {
                        if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
                        Spacer()
                        Button("Sign In", action: signIn)
                            .keyboardShortcut(.defaultAction)
                            .disabled(busy || url.isEmpty || username.isEmpty || password.isEmpty)
                    }
                } else {
                    LabeledContent("Server", value: store.serverURL)
                    LabeledContent("Signed in as", value: store.username.isEmpty ? "—" : store.username)
                    HStack {
                        Spacer()
                        Button("Sign Out") { store.signOut() }
                    }
                }
            }
            Section("Time") {
                Picker("Work time zone", selection: $store.workTimeZoneID) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Show work time next to local time", isOn: $store.showWorkTime)
                Toggle("Pause the running task while the Mac sleeps", isOn: $store.pauseOnSleep)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { url = store.serverURL; username = store.username }
    }

    private func signIn() {
        busy = true
        status = ""
        Task {
            do {
                try await store.signIn(url: url, username: username, password: password)
                password = ""
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }
}

struct ReportView: View {
    @EnvironmentObject var store: Store
    @State private var options = ReportOptions()
    @State private var rows: [ReportRow] = []
    @State private var copied = false
    @State private var loading = false

    private var builder: ReportBuilder {
        ReportBuilder(options: options, timeZone: options.workZone ? store.workTimeZone : .current)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Form {
                Picker("Period", selection: $options.period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Tags", text: $options.tags, prompt: Text("#work"))
                Picker("Grouping", selection: $options.grouping) {
                    ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Group by period", selection: $options.groupPeriod) {
                    ForEach(GroupPeriod.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Time zone", selection: $options.workZone) {
                    Text("Work · \(store.workTimeZoneID)").tag(true)
                    Text("Local").tag(false)
                }
                Picker("Duration", selection: $options.duration) {
                    ForEach(DurationFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Show records", isOn: $options.showRecords)
                Toggle("Exclude tags", isOn: $options.excludeTags)
                Toggle("Hide secondary tags", isOn: $options.hideSecondaryTags)
            }
            .formStyle(.grouped)
            .frame(width: 280)

            VStack(alignment: .leading, spacing: 0) {
                Text("Click any cell to edit it before copying. Edits only change the copied table, not your records.")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 2) {
                        GridRow {
                            ForEach(builder.columns, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                            Color.clear.frame(width: 20, height: 1)
                        }
                        ForEach($rows) { $row in
                            GridRow {
                                ForEach(row.cells.indices, id: \.self) { i in
                                    TextField("", text: $row.cells[i])
                                        .textFieldStyle(.plain)
                                        .fontWeight(row.isHeader ? .semibold : .regular)
                                        .frame(minWidth: i == row.cells.count - 1 ? 240 : 70)
                                }
                                Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove row")
                            }
                            .padding(.vertical, 3)
                            .background(row.isHeader ? Color.secondary.opacity(0.08) : .clear)
                        }
                    }
                    .monospacedDigit()
                    .padding(10)
                    Button("+ Add row") {
                        rows.append(ReportRow(isHeader: false, cells: Array(repeating: "", count: builder.columns.count)))
                    }
                    .buttonStyle(.link)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(.background)
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItem {
                Button("Reset edits") { Task { await generate() } }
            }
            ToolbarItem {
                Button {
                    ReportBuilder.copy(columns: builder.columns, rows: rows)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy table", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Report")
        .task(id: options) { await generate() }
    }

    private func generate() async {
        loading = true
        defer { loading = false }
        // The period's days follow the report's time zone (the work zone by default).
        let (t1, t2) = options.period.range(in: builder.timeZone)
        do {
            let recs = try await store.api.records(from: t1, to: t2).filter { !$0.isDeleted }
            rows = builder.rows(recs, from: t1, to: t2)
        } catch {
            store.error = error.localizedDescription
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @State private var from = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))!
    @State private var to = Date()
    @State private var search = ""
    @State private var records: [Record] = []
    @State private var editing: Record?

    private struct Day: Identifiable {
        let id: Date
        let records: [Record]
    }

    private var days: [Day] {
        let q = search.lowercased()
        let shown = records.filter { q.isEmpty || $0.ds.lowercased().contains(q) }
        let groups = Dictionary(grouping: shown) { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.t1))) }
        return groups.keys.sorted(by: >).map { Day(id: $0, records: groups[$0]!.sorted { $0.t1 > $1.t1 }) }
    }

    var body: some View {
        List {
            ForEach(days) { day in
                Section {
                    ForEach(day.records) { r in
                        row(r)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { editing = r }
                            .contextMenu {
                                Button("Edit…") { editing = r }
                                Button("Resume") { Task { await store.start(r.ds) } }
                                if r.isRunning { Button("Stop") { Task { await store.stop(r) } } }
                                Divider()
                                Button("Delete", role: .destructive) { Task { await store.delete(r) } }
                            }
                    }
                } header: {
                    HStack {
                        Text(day.id, format: .dateTime.weekday(.wide).day().month(.wide))
                        Spacer()
                        Text(Store.format(day.records.reduce(0) { $0 + $1.duration(now: store.now) }, seconds: false))
                            .monospacedDigit()
                    }
                }
            }
        }
        .overlay {
            if days.isEmpty { Text("No records").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "Search description or #tag")
        .toolbar {
            ToolbarItemGroup {
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, displayedComponents: .date)
                Button {
                    let t = Int(Date().timeIntervalSince1970)
                    editing = Record(key: Record.newKey(), rev: 0, t1: t - 3600, t2: t, ds: "", deleted: 0)
                } label: { Label("Add record", systemImage: "plus") }
            }
        }
        .navigationTitle("History")
        .frame(minWidth: 620, minHeight: 480)
        .sheet(item: $editing) { r in
            EditRecordView(record: r).environmentObject(store)
        }
        .task(id: "\(from)-\(to)-\(store.revision)") { await load() }
    }

    private func row(_ r: Record) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.clock(r.t1) + "–" + (r.isRunning ? "now" : store.clock(r.t2)))
                if store.showsWorkZone {
                    Text(store.clock(r.t1, work: true) + "–" + (r.isRunning ? "now" : store.clock(r.t2, work: true)) + " " + store.workZoneName)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .frame(width: 150, alignment: .leading)
            Text(r.ds.isEmpty ? "(no description)" : r.ds).lineLimit(2)
            Spacer()
            if r.isRunning { Image(systemName: "circle.fill").foregroundStyle(.red).font(.caption2) }
            Text(Store.format(r.duration(now: store.now), seconds: false)).monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        let cal = Calendar.current
        let t1 = Int(cal.startOfDay(for: from).timeIntervalSince1970)
        let t2 = Int(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!.timeIntervalSince1970)
        do {
            records = try await store.api.records(from: t1, to: t2).filter { !$0.isDeleted }
        } catch {
            store.error = error.localizedDescription
        }
    }
}
