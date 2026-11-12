import ServiceManagement
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @State private var draftTags = ""
    @State private var editing: Record?
    @StateObject private var feed = DayFeed()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                banners
                if let r = store.running.first {
                    runningCard(r)
                    taskField("Switch to…", icon: "arrow.right")
                } else {
                    idleCard
                }
                Divider()
                TagTotals()
                Spacer(minLength: 0)
                footer
            }
            .padding(16)
            .frame(width: 320)

            Divider()

            daySection
                .padding(.vertical, 8)
                .frame(width: 340)
        }
        .frame(height: 480)
        .sheet(item: $editing) { r in
            EditRecordView(record: r).environmentObject(store)
        }
        // Reload whenever the store has refreshed (a write here or anywhere else).
        .task(id: store.lately.hashValue) { await load { try await feed.reload(store.api) } }
    }

    @ViewBuilder private var banners: some View {
        if let err = store.error {
            Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        if let u = store.undoable {
            HStack {
                Text(u.label).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button("Undo") { Task { await store.undo() } }
                    .keyboardShortcut("z", modifiers: .command)
            }
            .font(.callout)
        }
        if let u = store.update {
            Link("TimeTaggerBar \(u.version) is available", destination: u.url).font(.callout)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Store.format(store.todayTotal, seconds: false)).font(.headline).monospacedDigit()
                Text(store.showsWorkZone ? "Worked today, \(store.workZoneName)" : "Worked today")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Refresh") { Task { await store.refresh() } }
                Divider()
                Button("Quit TimeTaggerBar") { NSApp.terminate(nil) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .help("More")
                .accessibilityLabel("More")
        }
    }

    /// Today first, older days below, loading further back as the end scrolls into view.
    /// Within a day, rows run strictly by time; back-to-back sessions of one task fold into one row.
    private var daySection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(feed.days()) { day in
                    Section {
                        ForEach(TaskGroup.group(day.records)) { g in
                            TaskGroupRow(group: g, editing: $editing)
                        }
                    } header: {
                        HStack {
                            Text(Calendar.current.isDateInToday(day.id) ? "Today" : day.id.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            Spacer()
                            Text(Store.format(day.records.reduce(0) { $0 + $1.duration(now: store.now) }, seconds: false))
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(.bar)
                    }
                }
                if !feed.reachedEnd {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
                        .onAppear { Task { await load { try await feed.loadMore(store.api) } } }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// The one rich moment of the popover: the clock that is running.
    private func runningCard(_ r: Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 6, height: 6).accessibilityLabel("Running")
                Text("Since \(store.clock(r.t1))")
                if store.showsWorkZone {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(store.clock(r.t1, work: true)) \(store.workZoneName)")
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Text(Store.format(r.duration(now: store.now)))
                .font(.system(size: 40, weight: .light, design: .rounded)).monospacedDigit()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button { editing = r } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        if !r.extraTags.isEmpty { TagLine(tags: r.extraTags).font(.callout) }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut("e", modifiers: .command)
                .help("Edit (⌘E)")
                Spacer(minLength: 8)
                Button { Task { await store.stop(r) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Not tracking")
                Spacer()
                Text(store.clock(store.now))
                if store.showsWorkZone {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(store.clock(store.now, work: true)) \(store.workZoneName)")
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            taskField("What are you working on?", icon: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func taskField(_ prompt: String, icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                TextField(prompt, text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit(startDraft)
                Divider().frame(height: 18)
                Image(systemName: "number").foregroundStyle(.secondary)
                TextField("tags", text: $draftTags)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .onSubmit(startDraft)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            TagSuggestions(text: $draftTags, tags: store.tags)
        }
    }

    private func startDraft() {
        let ds = draft
        let tags = Record.parseTags(draftTags)
        draft = ""
        draftTags = ""
        Task { await store.start(ds, tags: tags) }
    }

    private func load(_ op: () async throws -> Void) async {
        do { try await op() } catch { store.error = error.localizedDescription }
    }
}

/// Signed-in devices and API keys for scripts, each revocable on its own.
struct AccessSection: View {
    @EnvironmentObject var store: Store
    @State private var sessions: [API.SignedInSession] = []
    @State private var keys: [API.ApiKey] = []
    @State private var newKeyName = ""
    /// A just-created key, shown until the window closes: the server never shows it again.
    @State private var created: API.ApiKey?
    @State private var problem = ""

    var body: some View {
        Section("Signed-in devices") {
            ForEach(sessions) { s in
                LabeledContent(s.userAgent ?? "Unknown device") {
                    HStack {
                        Text(s.lastRefreshedAt, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                        Button("Sign Out") { run { try await store.api.endSession(s.id) } }
                    }
                }
            }
        }
        Section("API keys") {
            ForEach(keys) { k in
                LabeledContent(k.name) {
                    HStack {
                        Text("\(k.prefix)…").font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button("Revoke") { run { try await store.api.revokeApiKey(k.id) } }
                    }
                }
            }
            if let key = created?.key {
                HStack {
                    Text(key).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(key, forType: .string)
                    }
                }
                Text("Copy it now: it won't be shown again.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("New key name", text: $newKeyName, prompt: Text("e.g. merge cron"))
                Button("Create") {
                    let name = newKeyName
                    run {
                        created = try await store.api.createApiKey(name: name)
                        newKeyName = ""
                    }
                }
            }
            if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(.red) }
        }
        .task { await load() }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op(); problem = "" } catch { problem = error.localizedDescription }
            await load()
        }
    }

    private func load() async {
        do {
            sessions = try await store.api.sessions()
            keys = try await store.api.apiKeys()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// "Open SM-1061" for every ticket tag on the record, when a ticket URL is set.
struct TicketLinks: View {
    @EnvironmentObject var store: Store
    let record: Record

    var body: some View {
        ForEach(record.tags.compactMap { t in store.ticketLink(t).map { (t, $0) } }, id: \.0) { tag, url in
            Link("Open \(tag.uppercased())", destination: url)
        }
    }
}

/// The record's tags as quiet "#a #b" text.
struct TagLine: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            Text(tags.map { "#" + $0 }.joined(separator: " ")).lineLimit(1).foregroundStyle(.secondary)
        }
    }
}

/// Tags that complete the word being typed at the end of a tags field; clicking one fills it in.
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

    /// The tag being typed at the end of the text, without '#', or nil when there is none yet.
    static func partial(_ text: String) -> String? {
        guard let last = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "," }).last else { return nil }
        let p = last.drop(while: { $0 == "#" }).lowercased()
        return p.isEmpty ? nil : p
    }

    static func matches(for text: String, in tags: [String]) -> [String] {
        guard let p = partial(text) else { return [] }
        let taken = Set(Record.parseTags(text))
        return Array(tags.filter { $0.hasPrefix(p) && $0 != p && !taken.contains($0) }.prefix(5))
    }

    static func complete(_ text: String, with tag: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words[words.count - 1] = tag
        return words.joined(separator: " ") + " "
    }
}

struct EditRecordView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var record: Record
    @State private var start = Date()
    @State private var end = Date()
    @State private var running = false
    @State private var tagText = ""

    var body: some View {
        Form {
            TextField("Description", text: $record.ds)
            TextField("Tags", text: $tagText, prompt: Text("core-12 call"))
            TagSuggestions(text: $tagText, tags: store.tags)
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
            tagText = record.tags.joined(separator: " ")
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    record.t1 = Int(start.timeIntervalSince1970)
                    record.t2 = running ? record.t1 : max(Int(end.timeIntervalSince1970), record.t1 + 1)
                    record.tags = Record.parseTags(tagText)
                    let r = record
                    Task { await store.update(r) }
                    dismiss()
                }
            }
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case account = "Account", general = "General", reminders = "Reminders", about = "About"

    var id: Self { self }
    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape"
        case .reminders: return "bell"
        case .about: return "info.circle"
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
    @State private var section: SettingsSection? = .account

    var body: some View {
        // A sidebar of sections, the way System Settings goes.
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            detail
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 400, idealHeight: 440)
        .onAppear { url = store.serverURL; username = store.username }
        .task(id: store.serverURL) { store.serverVersion = (try? await store.api.version()) ?? "unreachable" }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .account {
        case .account:
            pane {
                Section("Account") {
                    if !store.signedIn {
                        TextField("Server", text: $url, prompt: Text("https://timetagger.example.com"))
                        TextField("Username", text: $username)
                            .textContentType(.username)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .onSubmit(signIn)
                        HStack {
                            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Button("Sign In", action: signIn)
                                .keyboardShortcut(.defaultAction)
                                .disabled(busy || url.isEmpty || username.isEmpty || password.isEmpty)
                        }
                    } else {
                        LabeledContent("Server", value: store.serverURL)
                        LabeledContent("Signed in as", value: store.username.isEmpty ? "—" : store.username)
                        HStack {
                            Spacer()
                            Button("Sign Out") { Task { await store.signOut() } }
                        }
                    }
                }
                if store.signedIn { AccessSection() }
            }
        case .general:
            pane {
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
                Section("Tickets") {
                    TextField("Ticket URL", text: $store.ticketURL, prompt: Text("https://company.atlassian.net/browse/{key}"))
                    Text("A tag like #sm-1061 links to this URL with {key} = SM-1061.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .reminders:
            pane {
                Section("Reminders") {
                    Toggle("Remind me when nothing is tracked", isOn: $store.remindIdle)
                    if store.remindIdle {
                        Stepper("Working hours from \(store.workStartHour):00", value: $store.workStartHour, in: 0...23)
                        Stepper("to \(store.workEndHour):00, weekdays", value: $store.workEndHour, in: 1...24)
                    }
                }
            }
        case .about:
            pane {
                Section("About") {
                    LabeledContent("TimeTaggerBar", value: Store.appVersion)
                    LabeledContent("Server", value: store.serverVersion)
                    if let u = store.update {
                        Link("Version \(u.version) is available", destination: u.url)
                    } else {
                        HStack {
                            Button("Check for Updates") { Task { await store.checkForUpdate() } }
                            Text(store.updateStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func pane(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }.formStyle(.grouped)
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

extension Record {
    /// What to call the record: its description, else its ticket tag, else its tags.
    var title: String {
        if !ds.trimmingCharacters(in: .whitespaces).isEmpty { return ds }
        if let t = ticketTag { return t.uppercased() }
        if !tags.isEmpty { return tags.map { "#" + $0 }.joined(separator: " ") }
        return "Untitled"
    }

    /// The first tag that looks like a ticket key, e.g. sm-1114.
    var ticketTag: String? {
        tags.first(where: Record.isTicket)
    }

    static func isTicket(_ tag: String) -> Bool {
        tag.range(of: #"^[a-z][a-z0-9]*-\d+$"#, options: .regularExpression) != nil
    }

    /// Tags not already shown as the title.
    var extraTags: [String] {
        if !ds.trimmingCharacters(in: .whitespaces).isEmpty { return tags }
        if let t = ticketTag { return tags.filter { $0 != t } }
        return []
    }
}

/// Back-to-back sessions of one task (same description and tags) within a day, newest first.
struct TaskGroup: Identifiable {
    let records: [Record]
    var id: String { records[0].id }
    var first: Record { records[0] }
    var isRunning: Bool { records.contains { $0.isRunning } }
    func total(now: Int) -> Int { records.reduce(0) { $0 + $1.duration(now: now) } }

    /// Strictly chronological: only back-to-back sessions of the same task fold together,
    /// so a task picked up again later in the day shows up again at that time.
    static func group(_ records: [Record]) -> [TaskGroup] {
        let key = { (r: Record) in r.ds.lowercased() + "|" + r.tags.sorted().joined(separator: ",") }
        var runs: [[Record]] = []
        for r in records {
            if let last = runs.last?.last, key(last) == key(r) { runs[runs.count - 1].append(r) } else { runs.append([r]) }
        }
        return runs.map { TaskGroup(records: $0) }
    }
}

/// One task in the day list. Several sessions fold into one row that opens to show them.
struct TaskGroupRow: View {
    @EnvironmentObject var store: Store
    let group: TaskGroup
    @Binding var editing: Record?
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if group.records.count > 1 {
                    Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(open ? "Collapse" : "Expand")
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                SessionRow(record: group.first, title: group.first.title,
                           detail: group.records.count > 1 ? "\(group.records.count) sessions" : store.range(group.first),
                           duration: group.total(now: store.now), running: group.isRunning,
                           editing: $editing) {
                    if group.records.count > 1 { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } else { editing = group.first }
                }
            }
            if open {
                ForEach(group.records) { r in
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 12, height: 1)
                        SessionRow(record: r, title: store.range(r), detail: nil,
                                   duration: r.duration(now: store.now), running: r.isRunning,
                                   editing: $editing, secondary: true) { editing = r }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

/// A row with a title, quiet detail and duration; resume appears on hover.
struct SessionRow: View {
    @EnvironmentObject var store: Store
    let record: Record
    let title: String
    let detail: String?
    let duration: Int
    let running: Bool
    @Binding var editing: Record?
    var secondary = false
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if running { Circle().fill(.red).frame(width: 6, height: 6).accessibilityLabel("Running") }
            Text(title)
                .foregroundStyle(secondary ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .monospacedDigit()
                .lineLimit(1)
            if let detail {
                Text(detail).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
            if !secondary && !record.extraTags.isEmpty {
                TagLine(tags: record.extraTags).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if hover && !record.isRunning {
                Button { Task { await store.start(record.ds, tags: record.tags) } } label: {
                    Image(systemName: "play.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Resume")
                .accessibilityLabel("Resume \(record.title)")
            }
            Text(Store.format(duration, seconds: false))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: tap)
        .contextMenu {
            Button("Edit…") { editing = record }
            Button("Resume") { Task { await store.start(record.ds, tags: record.tags) } }
            if record.isRunning { Button("Stop") { Task { await store.stop(record) } } }
            TicketLinks(record: record)
            Divider()
            Button("Delete", role: .destructive) { Task { await store.delete(record) } }
        }
    }
}

/// Today's time per tag, biggest first, as a ranked list with thin bars. Tapping a row starts that tag.
struct TagTotals: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let totals = store.totalsByTag
        let top = totals.first?.1 ?? 1
        VStack(alignment: .leading, spacing: 8) {
            Text("By tag today").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if totals.isEmpty {
                Text("Nothing tracked yet").font(.callout).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(totals, id: \.0) { tag, secs in
                            let current = store.running.contains { $0.tags.contains(tag) }
                            Button { Task { await store.start(tag: tag) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(Record.isTicket(tag) ? tag.uppercased() : "#" + tag)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(Store.format(secs, seconds: false)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                GeometryReader { g in
                                    Capsule().fill(Color.primary.opacity(0.08))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(Color.accentColor.opacity(tag == totals.first?.0 ? 0.9 : 0.45))
                                                .frame(width: max(4, g.size.width * CGFloat(secs) / CGFloat(top)))
                                        }
                                }
                                .frame(height: 4)
                            }
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(current || tag == "untagged")
                            .help(current ? "Running" : "Start \(Record.isTicket(tag) ? tag.uppercased() : "#" + tag)")
                            .accessibilityLabel("Start \(tag)")
                        }
                    }
                }
            }
        }
    }
}
