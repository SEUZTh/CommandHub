import AppKit
import SwiftUI

extension Notification.Name {
    static let launcherActivated = Notification.Name("launcherActivated")
    static let launcherFocusSearchRequested = Notification.Name("launcherFocusSearchRequested")
    static let launcherFocusAliasRequested = Notification.Name("launcherFocusAliasRequested")
    static let launcherToggleFavoriteRequested = Notification.Name("launcherToggleFavoriteRequested")
    static let launcherCopyAndCloseRequested = Notification.Name("launcherCopyAndCloseRequested")
    static let launcherDeleteRequested = Notification.Name("launcherDeleteRequested")
}

private final class LauncherSearchWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isEditingText = firstResponder is NSTextView
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            NotificationCenter.default.post(name: .launcherFocusSearchRequested, object: nil)
            return true
        }

        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "e" {
            NotificationCenter.default.post(name: .launcherFocusAliasRequested, object: nil)
            return true
        }

        if modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            NotificationCenter.default.post(name: .launcherToggleFavoriteRequested, object: nil)
            return true
        }

        if modifiers == [.command],
           event.keyCode == 36 {
            NotificationCenter.default.post(name: .launcherCopyAndCloseRequested, object: nil)
            return true
        }

        if (event.keyCode == 51 || (modifiers == [.command] && event.keyCode == 51)),
           !isEditingText {
            NotificationCenter.default.post(name: .launcherDeleteRequested, object: nil)
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
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.minSize = NSSize(width: 760, height: 520)
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            self.window = window
        }

        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            let previousFrontmostApplication = NSWorkspace.shared.frontmostApplication
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .launcherActivated,
                    object: previousFrontmostApplication
                )
            }
        }
    }

    func close() {
        window?.orderOut(nil)
    }
}
