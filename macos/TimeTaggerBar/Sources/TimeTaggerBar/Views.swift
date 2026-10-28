import SwiftUI

struct MenuView: View {
    @EnvironmentObject var store: Store
    @State private var draft = ""
    @State private var editing: Record?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = store.error {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            // Running timers
            ForEach(store.running) { r in
                HStack {
                    Image(systemName: "record.circle").foregroundStyle(.red)
                    Text(r.ds.isEmpty ? "(no description)" : r.ds).lineLimit(1)
                    Spacer()
                    Text(Store.format(r.duration(now: store.now))).monospacedDigit()
                    Button { Task { await store.stop(r) } } label: { Image(systemName: "stop.fill") }
                        .help("Stop")
                }
            }

            // Start a new record
            HStack {
                TextField("What are you doing? #tag", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startDraft)
                Button(action: startDraft) { Image(systemName: "play.fill") }
                    .help("Start (stops the running record)")
            }
            if !store.recent.isEmpty {
                Menu("Resume recent…") {
                    ForEach(store.recent, id: \.self) { ds in
                        Button(ds) { Task { await store.start(ds) } }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Divider()

            // Period summary
            Picker("", selection: $store.period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: store.period) { _ in Task { await store.refresh() } }

            HStack {
                Text("Total").bold()
                Spacer()
                Text(Store.format(store.total, seconds: false)).bold().monospacedDigit()
            }
            ForEach(store.totalsByTag, id: \.0) { tag, secs in
                HStack {
                    Text("#" + tag).foregroundStyle(.secondary)
                    Spacer()
                    Text(Store.format(secs, seconds: false)).monospacedDigit()
                }
                .font(.callout)
            }

            Divider()

            // Records list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(store.records) { r in
                        RecordRow(record: r, now: store.now)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = r }
                            .contextMenu {
                                Button("Edit…") { editing = r }
                                Button("Resume") { Task { await store.start(r.ds) } }
                                if r.isRunning { Button("Stop") { Task { await store.stop(r) } } }
                                Button("Delete", role: .destructive) { Task { await store.delete(r) } }
                            }
                    }
                }
            }
            .frame(maxHeight: 260)

            Divider()

            HStack {
                Button("Add record…") {
                    let t = Int(Date().timeIntervalSince1970)
                    editing = Record(key: Record.newKey(), mt: t, t1: t - 3600, t2: t, ds: "", deleted: 0)
                }
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                Spacer()
                Button("Web app") {
                    if let url = URL(string: store.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/app/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit")
            }
        }
        .padding(12)
        .frame(width: 380)
        .sheet(item: $editing) { r in
            EditRecordView(record: r).environmentObject(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(store).padding()
        }
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
            running = record.isRunning && store.records.contains(record)
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
    @State private var token = ""
    @State private var status = ""

    var body: some View {
        Form {
            TextField("Server URL", text: $url, prompt: Text("https://timetagger.example.com"))
            SecureField("API token", text: $token)
            Text("Get the API token in the web app: Account → API token.")
                .font(.caption).foregroundStyle(.secondary)
            if !status.isEmpty { Text(status).font(.caption) }
            HStack {
                Button("Test") {
                    Task {
                        do { status = "OK: " + (try await API(baseURL: url, token: token).version()) }
                        catch { status = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Save") {
                    Task { await store.saveSettings(url: url, token: token) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 400)
        .onAppear { url = store.serverURL; token = store.token }
    }
}
