import AppKit
import Combine
import SwiftUI

@main
struct TimeTaggerBarApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var controller

    var body: some Scene {
        Settings {
            SettingsView().environmentObject(controller.store)
        }
    }
}

/// The menu bar item and its popover. Dragging the popover away tears it off into a
/// normal window that stays on screen; closing that window brings the popover back.
@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuView().environmentObject(store))

        updateItem()
        // The store publishes every second while a timer runs; the bar follows it.
        watch = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateItem() }
    }

    private func updateItem() {
        guard let button = item?.button else { return }
        button.image = NSImage(systemSymbolName: store.running.isEmpty ? "clock" : "clock.fill", accessibilityDescription: "TimeTaggerBar")
        button.title = " " + store.menuTitle
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        // The task's name lives in the tooltip, not in the bar.
        button.toolTip = store.menuTooltip
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Lets AppKit turn the popover into a standalone window when it is dragged off.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }
}

/// Opens the Settings scene; works from AppKit-hosted views where `openWindow` isn't available.
@MainActor
func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    } else {
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}
