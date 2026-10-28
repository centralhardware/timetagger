import SwiftUI

@main
struct TimeTaggerBarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            Image(systemName: store.running.isEmpty ? "clock" : "clock.fill")
            Text(store.menuTitle).monospacedDigit()
        }
        .menuBarExtraStyle(.window)

        Window("History", id: "history") {
            HistoryView().environmentObject(store)
        }

        Window("Report", id: "report") {
            ReportView().environmentObject(store)
        }

        // A window of its own rather than a sheet in the menu, which is too short to show it whole.
        Window("Settings", id: "settings") {
            SettingsView().environmentObject(store)
        }
        .windowResizability(.contentSize)
    }
}
