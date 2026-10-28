import SwiftUI

@main
struct TimeTaggerBarApp: App {
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            Image(systemName: store.running.isEmpty ? "clock" : "clock.fill")
            if !store.running.isEmpty { Text(store.menuTitle) }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(store)
        }
    }
}
