import AppKit
import SwiftUI

extension Notification.Name {
    static let launcherActivated = Notification.Name("launcherActivated")
    static let launcherFocusSearchRequested = Notification.Name("launcherFocusSearchRequested")
}

private final class LauncherSearchWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown,
           modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            NotificationCenter.default.post(name: .launcherFocusSearchRequested, object: nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

final class LauncherWindow {
    static let shared = LauncherWindow()

    private var window: NSWindow?

    func toggle() {
        if window == nil {
            let view = LauncherView()
            let window = LauncherSearchWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            self.window = window
        }

        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .launcherActivated, object: nil)
            }
        }
    }

    func close() {
        window?.orderOut(nil)
    }
}
