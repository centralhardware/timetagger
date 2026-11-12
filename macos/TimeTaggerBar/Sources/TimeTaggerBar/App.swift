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
final class StatusBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static private(set) weak var shared: StatusBarController?
    let store = Store()
    /// The torn-off window, while there is one.
    private var window: NSWindow?
    /// When the popover last closed. A click on the icon first closes a transient popover
    /// (it counts as a click outside) and then fires the action; this keeps it from reopening.
    private var closedAt = Date.distantPast
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var watch: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
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
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(closedAt) < 0.3 {
            return
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
    }

    /// Tears the popover off into a window that looks the same (popover material, rounded,
    /// no title bar) and keeps following the mouse: the drag that started in the popover
    /// carries on moving the new window. SwiftUI content swallows the drag AppKit's own
    /// detaching needs, so the view asks for this when a drag begins.
    func popOut(dragging: Bool = false) {
        guard window == nil else { return }
        let frame = popover.contentViewController?.view.window?.frame ?? .zero
        popover.performClose(nil)

        let host = NSHostingView(rootView: MenuView().environmentObject(store))
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor), host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor), host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = blur
        w.setFrame(frame, display: true)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        // Hand the ongoing mouse drag to the new window so it detaches under the cursor.
        if dragging, let event = NSApp.currentEvent, event.type == .leftMouseDragged || event.type == .leftMouseDown {
            w.performDrag(with: event)
        }
    }

    /// Closing the torn-off window brings back the usual popover on the next click.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
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
