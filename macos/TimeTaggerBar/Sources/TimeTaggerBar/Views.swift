import ServiceManagement
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: Store
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var switching = false
    /// Past days opened to their full log; today is always open.
    @State private var expandedDays: Set<Date> = []
    @State private var editing: Record?
    @StateObject private var feed = DayFeed()

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                banners
                if let r = store.running.first, editing?.id == r.id {
                    InlineEditor(record: r) { editing = nil }
                } else if let r = store.running.first {
                    runningCard(r)
                    if switching {
                        HStack(alignment: .top, spacing: 6) {
                            taskField("Switch to…", icon: "arrow.right")
                            Button { switching = false; draft = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.tertiary).frame(height: 28)
                                .keyboardShortcut(.cancelAction)
                                .help("Close (Esc)")
                        }
                    } else {
                        Button { switching = true; fieldFocused = true } label: {
                            Label("Switch to…", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .keyboardShortcut("n", modifiers: .command)
                        .help("Switch to another task (⌘N)")
                    }
                } else {
                    idleCard
                }
                RecentTasks()
                Divider()
                DayTimeline(editing: $editing)
                TagTotals()
                Spacer(minLength: 0)
                footer
            }
            .padding(16)
            .frame(width: 320)
            // Drag the left column away (like a Calendar popover) to keep it as a window.
            .gesture(DragGesture(minimumDistance: 12).onChanged { _ in
                StatusBarController.shared?.popOut(dragging: true)
            })

            Divider()

            daySection
                .padding(.vertical, 8)
                .frame(width: 340)
        }
        .frame(height: 480)
        // Opening the popover puts the cursor in the task field: type and press Return.
        .onAppear { if store.running.isEmpty { fieldFocused = true } }
        // Reload whenever the store has refreshed (a write here or anywhere else).
        .task(id: store.lately.hashValue) {
            feed.calendar = store.workCalendar
            await load { try await feed.reload(store.api) }
        }
        // A popover reopened later starts clean: no half-typed switch left open.
        .onDisappear { switching = false; draft = ""; editing = nil }
    }

    @ViewBuilder private var banners: some View {
        if let err = store.error {
            HStack(alignment: .top) {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Spacer(minLength: 4)
                Button { store.error = nil } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    .help("Dismiss").accessibilityLabel("Dismiss error")
            }
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
                    openSettings()
                }
                Button("Open as Window") { StatusBarController.shared?.popOut() }
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
            LazyVStack(alignment: .leading, spacing: 0) {
                if feed.reachedEnd && feed.records.isEmpty {
                    Text("No history yet. Start a task on the left and it shows up here.")
                        .font(.callout).foregroundStyle(.tertiary).padding(16)
                }
                ForEach(feed.days()) { day in
                    let detailed = store.workCalendar.isDateInToday(day.id) || expandedDays.contains(day.id)
                    Section {
                        if detailed {
                            let groups = TaskGroup.group(day.records)
                            ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                                TaskGroupRow(group: g, editing: $editing)
                                if i + 1 < groups.count { GapRow(newer: g, older: groups[i + 1]) }
                            }
                        } else {
                            // Past days fold to one stacked bar of tickets/tags with a short legend.
                            let totals = Self.tagTotals(day.records)
                            let sum = CGFloat(max(1, totals.reduce(0) { $0 + $1.1 }))
                            VStack(alignment: .leading, spacing: 4) {
                                GeometryReader { g in
                                    HStack(spacing: 1) {
                                        ForEach(totals, id: \.0) { key, secs in
                                            Rectangle().fill(Color.forKey(key == key.uppercased() ? key : "#" + key))
                                                .frame(width: max(2, g.size.width * CGFloat(secs) / sum - 1))
                                                .help("\(key) \(Store.format(secs, seconds: false))")
                                        }
                                    }
                                    .clipShape(Capsule())
                                }
                                .frame(height: 6)
                                HStack(spacing: 10) {
                                    ForEach(totals.prefix(4), id: \.0) { key, secs in
                                        HStack(spacing: 4) {
                                            Circle().fill(Color.forKey(key == key.uppercased() ? key : "#" + key)).frame(width: 6, height: 6)
                                            Text("\(key == "untagged" ? "Untagged" : key == key.uppercased() ? key : "#" + key) \(Store.format(secs, seconds: false))")
                                        }
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                            }
                            .padding(.leading, 28).padding(.trailing, 12).padding(.bottom, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { expandedDays.insert(day.id) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            if !store.workCalendar.isDateInToday(day.id) {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(detailed ? 90 : 0))
                            }
                            Text(store.workCalendar.isDateInToday(day.id) ? "Today" : day.id.formatted(Date.FormatStyle(timeZone: store.workTimeZone).weekday(.abbreviated).day().month(.abbreviated)))
                            Spacer()
                            Text(Store.format(day.records.reduce(0) { $0 + $1.duration(now: store.now) }, seconds: false))
                                .monospacedDigit()
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 10)
                        .frame(height: 34)
                        // No band of its own: a quiet label on the popover's own background.
                        .overlay(alignment: .top) { Divider().opacity(day.id == feed.days().first?.id ? 0 : 1) }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !store.workCalendar.isDateInToday(day.id) else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                if expandedDays.contains(day.id) { expandedDays.remove(day.id) } else { expandedDays.insert(day.id) }
                            }
                        }
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
    /// The running task first: ticket and description lead, the clock is supporting detail.
    private func runningCard(_ r: Record) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 6, height: 6).accessibilityLabel("Running")
                if let t = r.ticket {
                    Text(t).font(.caption.monospaced().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Text("Now").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            RunningText(record: r)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Store.format(r.duration(now: store.now)))
                    .font(.system(.title2, design: .rounded).weight(.light)).monospacedDigit()
                HStack(spacing: 4) {
                    Text("since")
                    RunningStart(record: r)
                    if store.showsWorkZone {
                        Text("· \(store.clock(r.t1, work: true)) \(store.workZoneName)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                Button { Task { await store.stop(r) } } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop (⌘.)")
            }
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

    /// One field for everything: "SM-1176 fix login #call 25m ago".
    private func taskField(_ prompt: String, icon: String?) -> some View {
        let parsed = QuickEntry.parse(draft)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).foregroundStyle(.secondary) }
                TextField(prompt, text: $draft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit(startDraft)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .help("Ticket keys and #words become tags; end with \u{201C}25m ago\u{201D} or \u{201C}at 14:30\u{201D} to backdate")
            HashSuggestions(text: $draft, tags: store.tags)
            // Shows how the line will be read before Return, so nothing is a surprise.
            if !parsed.isEmpty && (!parsed.tags.isEmpty || parsed.start != nil) {
                HStack(spacing: 6) {
                    if let t = parsed.start { Text("from \(store.clock(t))") }
                    if !parsed.tags.isEmpty { TagLine(tags: parsed.tags) }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    /// Return in an empty field does nothing rather than log a blank "Untitled" record.
    private func startDraft() {
        let e = QuickEntry.parse(draft)
        guard !e.isEmpty else { return }
        draft = ""
        switching = false
        Task { await store.start(e.ds, ticket: e.ticket, tags: e.tags, at: e.start) }
    }

    /// A day's time per tag, biggest first; a record with several tags counts toward each.
    static func tagTotals(_ records: [Record]) -> [(String, Int)] {
        // Tickets (upper case) first, then tags; a record counts toward its ticket and each tag.
        var tickets: [String: Int] = [:], tags: [String: Int] = [:]
        for r in records {
            if let t = r.ticket { tickets[t, default: 0] += r.duration() }
            for t in r.tags { tags[t, default: 0] += r.duration() }
            if r.ticket == nil && r.tags.isEmpty { tags["untagged", default: 0] += r.duration() }
        }
        return tickets.sorted { $0.value > $1.value } + tags.sorted { $0.value > $1.value }
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
        if let t = record.ticket, let url = store.ticketLink(t.lowercased()) {
            Link("Open \(t)", destination: url)
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

/// Edits a record in place, in the popover's own style: no sheet, Return saves, Esc cancels.
struct InlineEditor: View {
    @EnvironmentObject var store: Store
    let original: Record
    let close: () -> Void
    @State private var ticket: String
    @State private var text: String
    @State private var start: Date
    @State private var end: Date
    @State private var running: Bool
    @State private var lastStart: Date

    init(record: Record, close: @escaping () -> Void) {
        original = record
        self.close = close
        let s = Date(timeIntervalSince1970: TimeInterval(record.t1))
        _ticket = State(initialValue: record.ticket ?? "")
        _text = State(initialValue: ([record.ds] + record.tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " "))
        _start = State(initialValue: s)
        _end = State(initialValue: record.isRunning ? Date() : Date(timeIntervalSince1970: TimeInterval(record.t2)))
        _running = State(initialValue: record.isRunning)
        _lastStart = State(initialValue: s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Ticket and text are separate fields, as they are on the server.
            HStack(spacing: 6) {
                field {
                    TextField("Ticket", text: $ticket, prompt: Text("SM-1234")).textFieldStyle(.plain).onSubmit(save)
                        .font(.callout.monospaced())
                }
                .frame(width: 110)
                field { TextField("What was done #tags", text: $text).textFieldStyle(.plain).onSubmit(save) }
            }
            HashSuggestions(text: $text, tags: store.tags)
            HStack(spacing: 8) {
                TimeRow(label: "Start", time: $start, showsDate: true)
                Spacer()
                if canRun { Toggle("Running", isOn: $running).toggleStyle(.checkbox) }
            }
            if !running {
                TimeRow(label: "End", time: $end, showsDate: !Calendar.current.isDate(end, inSameDayAs: start))
            }
            HStack {
                if invalid {
                    Text("End must be after start").foregroundStyle(.red)
                } else if !running {
                    Text(Store.format(Int(end.timeIntervalSince(start)), seconds: false)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(invalid)
            }
            .font(.caption)
            .controlSize(.small)
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Moving the day carries the end along, so the duration is kept.
        .onChange(of: start) { new in
            if !Calendar.current.isDate(new, inSameDayAs: lastStart) { end = end.addingTimeInterval(new.timeIntervalSince(lastStart)) }
            lastStart = new
        }
    }

    private func field<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8, content: content)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Only the newest record (nothing logged after it) can be set running again.
    private var canRun: Bool {
        original.isRunning || !(store.lately + store.records).contains { !$0.isDeleted && $0.key != original.key && $0.t1 > original.t1 }
    }

    /// A finished record whose end isn't after its start can't be saved, nor a ticket that isn't a key.
    private var invalid: Bool {
        let t = ticket.trimmingCharacters(in: .whitespaces).lowercased()
        return (!running && end <= start) || (!t.isEmpty && !Record.isTicket(t))
    }

    private func save() {
        guard !invalid else { return }
        var r = original
        let e = QuickEntry.parse(text)
        let typed = ticket.trimmingCharacters(in: .whitespaces).uppercased()
        r.ds = e.ds
        r.ticket = typed.isEmpty ? e.ticket : typed
        r.tags = e.tags
        r.t1 = Int(start.timeIntervalSince1970)
        r.t2 = running ? r.t1 : Int(end.timeIntervalSince1970)
        close()
        Task { await store.update(r) }
    }
}

/// An hh:mm field with quick nudges: −5 / +5 minutes and Now.
struct TimeRow: View {
    let label: String
    @Binding var time: Date
    var showsDate = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            TimePicker(time: $time, showsDate: showsDate)
        }
    }
}

/// A time as a button, like Calendar's event times: click it for a calendar and a clock face.
struct TimePicker: View {
    @Binding var time: Date
    var latest: Date? = nil
    var showsDate = false
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if showsDate {
                    Text(time, format: .dateTime.day().month(.abbreviated).hour().minute())
                } else {
                    Text(time, format: .dateTime.hour().minute())
                }
            }
            .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            HStack(alignment: .top, spacing: 12) {
                DatePicker("", selection: clamped, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden()
                VStack(spacing: 8) {
                    DatePicker("", selection: clamped, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.graphical).labelsHidden()
                    DatePicker("", selection: clamped, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.stepperField).labelsHidden().fixedSize()
                }
            }
            .padding(12)
        }
    }

    /// Keeps the time at or before `latest` (a running record can't start in the future).
    private var clamped: Binding<Date> {
        Binding(get: { time }, set: { new in time = latest.map { min(new, $0) } ?? new })
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
    /// What to call the record: its description, else its ticket, else its tags.
    var title: String {
        if !ds.trimmingCharacters(in: .whitespaces).isEmpty { return ds }
        if let t = ticket { return t }
        if !tags.isEmpty { return tags.map { "#" + $0 }.joined(separator: " ") }
        return "Untitled"
    }

    /// A key like sm-1114 (lower case, as typed in tags or text).
    static func isTicket(_ tag: String) -> Bool {
        tag.range(of: #"^[a-z][a-z0-9]*-\d+$"#, options: .regularExpression) != nil
    }

    /// Same task = same description, ticket and tags.
    var taskKey: String {
        ds.lowercased() + "|" + (ticket ?? "") + "|" + tags.sorted().joined(separator: ",")
    }

    /// Tags shown after the title.
    var extraTags: [String] { tags }

    /// The ticket shown before the title, unless the title already is the ticket.
    /// Always a badge, so a ticket-only row lines up with the rest instead of standing out.
    var ticketBadge: String? { ticket }

    /// The row's text next to the badge: the description, else the tags, else nothing.
    var rowText: String {
        if !ds.trimmingCharacters(in: .whitespaces).isEmpty { return ds }
        if ticket != nil { return tags.map { "#" + $0 }.joined(separator: " ") }
        return title
    }
}

/// Back-to-back sessions of one task (same description and tags) within a day, newest first.
struct TaskGroup: Identifiable {
    let records: [Record]
    var id: String { records[0].id }
    var first: Record { records[0] }
    var isRunning: Bool { records.contains { $0.isRunning } }
    func total(now: Int) -> Int { records.reduce(0) { $0 + $1.duration(now: now) } }

    /// Every record is its own row. Only sessions of the same task that run straight into
    /// each other (a minute or less apart) are kept together, as a mergeable block.
    static func group(_ records: [Record]) -> [TaskGroup] {
        var runs: [[Record]] = []
        for r in records {   // newest first
            if let newer = runs.last?.last, newer.taskKey == r.taskKey, !r.isRunning, newer.t1 - r.t2 <= 60, newer.t1 >= r.t2 - 60 {
                runs[runs.count - 1].append(r)
            } else {
                runs.append([r])
            }
        }
        return runs.map { TaskGroup(records: $0) }
    }
}

/// One row per record. Back-to-back sessions of one task sit in a shared block with a Merge button.
struct TaskGroupRow: View {
    @EnvironmentObject var store: Store
    let group: TaskGroup
    @Binding var editing: Record?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(group.records) { r in
                SessionRow(record: r, title: r.rowText, detail: store.range(r),
                           duration: r.duration(now: store.now), running: r.isRunning,
                           editing: $editing) { editing = editing?.id == r.id ? nil : r }
            }
            if group.records.count > 1 {
                HStack {
                    Text("\(group.records.count) back-to-back sessions · \(Store.format(group.total(now: store.now), seconds: false))")
                    Spacer()
                    Button("Merge") { Task { await store.merge(group.records) } }
                        .buttonStyle(.borderless)
                        .help("Join them into one record")
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .padding(.horizontal, 8).frame(height: 22)
            }
        }
        .background {
            if group.records.count > 1 {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05))
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
    /// False for a folded group's header, whose sessions each show their own editor.
    var editsInline = true
    let tap: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            row
            // A running record is edited in the left column, where its clock is.
            if editsInline, let e = editing, e.id == record.id, !record.isRunning {
                InlineEditor(record: record) { editing = nil }
                    .padding(.bottom, 8)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(record.taskColor).frame(width: 3, height: 16)
            if running { Circle().fill(.red).frame(width: 6, height: 6).accessibilityLabel("Running") }
            if !secondary, let t = record.ticketBadge {
                Text(t).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Text(title)
                .foregroundStyle(secondary ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
                .monospacedDigit()
                .lineLimit(1)
            if let detail {
                // The time range gives way first, so the description stays readable.
                Text(detail).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1).layoutPriority(-1)
            }
            if !secondary && !record.extraTags.isEmpty && !record.ds.trimmingCharacters(in: .whitespaces).isEmpty {
                TagLine(tags: record.extraTags).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if !record.isRunning && !secondary {
                Button { Task { await store.resume(record) } } label: {
                    Image(systemName: "play.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(hover ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.quaternary)
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
            Button("Edit") { editing = record }
            Button("Resume") { Task { await store.resume(record) } }
            if record.isRunning { Button("Stop") { Task { await store.stop(record) } } }
            TicketLinks(record: record)
            Divider()
            Button("Delete", role: .destructive) { Task { await store.delete(record) } }
        }
    }
}

/// Today's time by ticket and by tag. Both lists show when they fit; otherwise a switch picks one.
/// Tapping a row starts that ticket or tag.
struct TagTotals: View {
    @EnvironmentObject var store: Store
    @AppStorage("totalsMode") private var mode = 0   // 0 tickets, 1 tags

    var body: some View {
        let tickets = store.totalsByTicket, tags = store.totalsByTag.filter { $0.0 != "untagged" || store.totalsByTicket.isEmpty }
        if tickets.isEmpty && tags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Today").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("Nothing tracked yet").font(.callout).foregroundStyle(.tertiary)
            }
        } else {
            ViewThatFits(in: .vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    if !tickets.isEmpty { list("By ticket today", tickets, ticket: true) }
                    if !tags.isEmpty { list("By tag today", tags, ticket: false) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $mode) {
                        Text("Tickets").tag(0)
                        Text("Tags").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                    ScrollView {
                        if mode == 0 { rows(tickets, ticket: true) } else { rows(tags, ticket: false) }
                    }
                }
            }
        }
    }

    private func list(_ title: String, _ totals: [(String, Int)], ticket: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            rows(totals, ticket: ticket)
        }
    }

    private func rows(_ totals: [(String, Int)], ticket: Bool) -> some View {
        let top = totals.first?.1 ?? 1
        return VStack(spacing: 8) {
            ForEach(totals, id: \.0) { key, secs in
                let current = store.running.contains { ticket ? $0.ticket == key : $0.tags.contains(key) }
                let label = ticket ? key : key == "untagged" ? "Untagged" : "#" + key
                Button { Task { if ticket { await store.start(ticket: key) } else { await store.start(tag: key) } } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if current { Circle().fill(.red).frame(width: 6, height: 6).accessibilityLabel("Running") }
                            Text(label).lineLimit(1)
                            Spacer()
                            Text(Store.format(secs, seconds: false)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        GeometryReader { g in
                            Capsule().fill(Color.primary.opacity(0.08))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color.forKey(ticket ? key : "#" + key))
                                        .frame(width: max(4, g.size.width * CGFloat(secs) / CGFloat(top)))
                                }
                        }
                        .frame(height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Not .disabled: that greys the row out and hides its bar.
                .allowsHitTesting(!current && key != "untagged")
                .help(current ? "Running" : "Start \(label)")
            }
        }
    }
}

/// Between two rows: an untracked gap (Fill) or an overlap (Trim), both fixed by moving the earlier end.
struct GapRow: View {
    @EnvironmentObject var store: Store
    let newer: TaskGroup
    let older: TaskGroup

    var body: some View {
        let earlier = older.first          // newest session of the older row
        let laterStart = newer.records.last!.t1
        let delta = laterStart - earlier.t2
        if !earlier.isRunning, delta >= 5 * 60 || delta <= -60, delta < 4 * 3600 {
            HStack(spacing: 6) {
                Rectangle().fill(delta > 0 ? Color.secondary.opacity(0.3) : Color.orange.opacity(0.6)).frame(width: 2, height: 14)
                Text(delta > 0 ? "\(Store.format(delta, seconds: false)) untracked" : "\(Store.format(-delta, seconds: false)) overlap")
                Spacer()
                Button(delta > 0 ? "Fill" : "Trim") { Task { await store.setEnd(earlier, to: laterStart) } }
                    .buttonStyle(.borderless)
                    .help(delta > 0 ? "Extend \u{201C}\(earlier.title)\u{201D} to \(store.clock(laterStart))" : "End \u{201C}\(earlier.title)\u{201D} at \(store.clock(laterStart))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .padding(.leading, 30).padding(.trailing, 12)
            .frame(height: 20)
        }
    }
}

/// The last three tasks as chips: one click (or ⌘1–3) resumes one.
struct RecentTasks: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let recent = store.recentTasks
        if !recent.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { i, r in
                    Button { Task { await store.resume(r) } } label: {
                        Label(r.title, systemImage: "play.fill").lineLimit(1)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    .help("Resume (⌘\(i + 1))")
                }
            }
        }
    }
}

/// Today as one bar from the first start to now; each record is a segment, click one to edit it.
struct DayTimeline: View {
    @EnvironmentObject var store: Store
    @Binding var editing: Record?
    /// The segment whose editor is open, shown right at the segment rather than down in the history.
    @State private var selected: String?

    var body: some View {
        let start = Int(store.workCalendar.startOfDay(for: Date()).timeIntervalSince1970)
        let recs = store.lately.filter { !$0.isDeleted && ($0.isRunning ? store.now : $0.t2) > start }
        if let first = recs.map({ max($0.t1, start) }).min() {
            let span = CGFloat(max(store.now - first, 60))
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        ForEach(recs) { r in
                            let a = CGFloat(max(r.t1, first) - first), b = CGFloat((r.isRunning ? store.now : r.t2) - first)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(r.taskColor)
                                .overlay(r.isRunning ? RoundedRectangle(cornerRadius: 2).stroke(Color.red, lineWidth: 1) : nil)
                                // A 1 pt gap keeps back-to-back segments apart.
                                .frame(width: max(2, (b - a) / span * g.size.width - 1))
                                .offset(x: a / span * g.size.width)
                                .help("\(r.title) \(store.range(r))")
                                .onTapGesture { selected = selected == r.id ? nil : r.id }
                                .popover(isPresented: Binding(get: { selected == r.id }, set: { if !$0 { selected = nil } }),
                                         arrowEdge: .bottom) {
                                    InlineEditor(record: r) { selected = nil }
                                        .environmentObject(store)
                                        .frame(width: 340)
                                        .padding(8)
                                }
                        }
                    }
                }
                .frame(height: 10)
                HStack {
                    Text(store.clock(first)); Spacer(); Text(store.clock(store.now))
                }
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}

/// Suggests tags for a "#par" being typed at the end of the task field.
struct HashSuggestions: View {
    @Binding var text: String
    let tags: [String]

    var body: some View {
        let last = text.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        if last.hasPrefix("#"), last.count > 1 {
            let p = last.dropFirst().lowercased()
            let matches = Array(tags.filter { $0.hasPrefix(p) && $0 != p }.prefix(5))
            if !matches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(matches, id: \.self) { tag in
                            Button("#" + tag) {
                                text = String(text.dropLast(last.count)) + "#" + tag + " "
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

/// The running record's start as an always-visible hh:mm field; a change saves itself after a short pause.
struct RunningStart: View {
    @EnvironmentObject var store: Store
    let record: Record
    @State private var start = Date()

    var body: some View {
        TimePicker(time: $start, latest: Date())
            .help("Change the start time")
            .onAppear { start = Date(timeIntervalSince1970: TimeInterval(record.t1)) }
            .onChange(of: record.t1) { t in start = Date(timeIntervalSince1970: TimeInterval(t)) }
            // Debounced so clicking through the picker saves once, at the end.
            .task(id: start) {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                let t = Int(start.timeIntervalSince1970)
                guard t != record.t1, t < Int(Date().timeIntervalSince1970) else { return }
                var r = record
                r.t1 = t
                r.t2 = t
                await store.update(r)
            }
    }
}

extension Record {
    /// Description with "#tag" text at the end, without the ticket.
    var textWithTags: String {
        ([ds] + tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Description with tags at the end as plain "#tag" text: the one-field form used for editing.
    var editText: String {
        ([ticket ?? "", ds] + tags.map { "#" + $0 }).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The record's colour: its ticket's, else its task's, so a ticket looks the same in the
    /// timeline, the history and the totals.
    var taskColor: Color { Color.forKey(ticket ?? taskKey) }
}

/// The running task's text as an always-editable field; Return saves.
struct RunningText: View {
    @EnvironmentObject var store: Store
    let record: Record
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("What are you working on? #tags", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit(save)
                .onAppear { text = record.textWithTags }
                .onChange(of: record.textWithTags) { t in if !focused { text = t } }
                .onChange(of: focused) { f in if !f { save() } }
                .help("Edit the running task; Return saves")
            if focused { HashSuggestions(text: $text, tags: store.tags) }
        }
    }

    private func save() {
        let e = QuickEntry.parse(text)
        // The ticket sits in the badge above; typing a key here replaces it.
        let ticket = e.ticket ?? record.ticket
        guard !e.ds.isEmpty || !e.tags.isEmpty || ticket != nil,
              e.ds != record.ds || ticket != record.ticket || e.tags != record.tags else { return }
        var r = record
        r.ds = e.ds
        r.ticket = ticket
        r.tags = e.tags
        Task { await store.update(r) }
    }
}

extension Color {
    /// A stable colour for a ticket, "#tag" or task key.
    static func forKey(_ key: String) -> Color {
        var h: UInt32 = 2166136261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.85)
    }
}
