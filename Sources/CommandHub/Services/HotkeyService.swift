import AppKit
import HotKey

final class HotkeyService {
    static let shared = HotkeyService()

    private var hotKey: HotKey?

    func register() {
        hotKey = HotKey(key: .v, modifiers: [.command, .shift])
        hotKey?.keyDownHandler = { [weak self] in
            _ = self
            LauncherWindow.shared.toggle()
        }
    }
}
