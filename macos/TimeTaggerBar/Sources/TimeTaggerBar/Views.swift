import ServiceManagement
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @State private var editing: Record?
    @StateObject private var feed = DayFeed()

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
                    Text("App \(Store.appVersion)")
                    Text("Server \(store.serverVersion)")
                    Divider()
                    Button("Settings…") {
                        openWindow(id: "settings")
                        NSApp.activate(ignoringOtherApps: true)
                    }
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
        // Reload whenever the store has refreshed (a write here or anywhere else).
        .task(id: store.lately.hashValue) { await load { try await feed.reload(store.api) } }
    }

    /// Today first, older days below, loading further back as the end scrolls into view.
    private var daySection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(feed.days()) { day in
                    Section {
                        ForEach(day.records) { r in dayRow(r) }
                    } header: {
                        HStack {
                            Text(Calendar.current.isDateInToday(day.id) ? "Today" : day.id.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(Store.format(day.records.reduce(0) { $0 + $1.duration(now: store.now) }, seconds: false))
                                .font(.caption).monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.regularMaterial)
                    }
                }
                if !feed.reachedEnd {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
                        .onAppear { Task { await load { try await feed.loadMore(store.api) } } }
                }
            }
        }
        .frame(height: 300)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                TextField(prompt, text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit(startDraft)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            TagSuggestions(text: $draft, tags: store.tags)
        }
    }

    private func startDraft() {
        let ds = draft
        draft = ""
        Task { await store.start(ds) }
    }

    private func load(_ op: () async throws -> Void) async {
        do { try await op() } catch { store.error = error.localizedDescription }
    }
}

/// Tags that complete the #word being typed at the end of `text`; clicking one fills it in.
struct TagSuggestions: View {
    @Binding var text: String
    let tags: [String]

    var body: some View {
        let matches = Self.matches(for: text, in: tags)
        if !matches.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { tag in
                        Button("#" + tag) { text = Self.complete(text, with: tag) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    /// The partial tag at the end of the text, without '#', or nil when the last word isn't one.
    static func partial(_ text: String) -> String? {
        guard let last = text.split(separator: " ", omittingEmptySubsequences: false).last, last.hasPrefix("#") else { return nil }
        return last.dropFirst().lowercased()
    }

    static func matches(for text: String, in tags: [String]) -> [String] {
        guard let p = partial(text) else { return [] }
        return Array(tags.filter { $0.hasPrefix(p) && $0 != p }.prefix(5))
    }

    static func complete(_ text: String, with tag: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words[words.count - 1] = "#" + tag
        return words.joined(separator: " ") + " "
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
            TagSuggestions(text: $record.ds, tags: store.tags)
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
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError = ""
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
            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { on in setOpenAtLogin(on) }
                if !loginError.isEmpty { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("About") {
                LabeledContent("TimeTaggerBar", value: Store.appVersion)
                LabeledContent("Server", value: store.serverVersion)
            }
        }
        .formStyle(.grouped)
        // Sized to its content: everything shows at once, no scrolling.
        .scrollDisabled(true)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { url = store.serverURL; username = store.username }
        .task(id: store.serverURL) { store.serverVersion = (try? await store.api.version()) ?? "unreachable" }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch {
            loginError = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
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
    @State private var search = ""
    @State private var editing: Record?
    @StateObject private var feed = DayFeed()

    var body: some View {
        let days = feed.days(matching: search)
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
            // Scrolling to the end reaches further back.
            if !feed.reachedEnd {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    .onAppear { Task { await load { try await feed.loadMore(store.api) } } }
            }
        }
        .overlay {
            if days.isEmpty && feed.reachedEnd { Text("No records").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "Search description or #tag")
        .toolbar {
            ToolbarItemGroup {
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
        .task(id: store.lately.hashValue) { await load { try await feed.reload(store.api) } }
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

    private func load(_ op: () async throws -> Void) async {
        do { try await op() } catch { store.error = error.localizedDescription }
    }
}
