import AppKit
import SwiftUI

final class LauncherWindow {
    static let shared = LauncherWindow()

    private var window: NSWindow?

    func toggle() {
        if window == nil {
            let view = LauncherView()
            let window = NSWindow(
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
        }
    }

    func close() {
        window?.orderOut(nil)
    }
}
