import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceService.shared.acquire() else {
            NSApp.terminate(nil)
            return
        }

        ClipboardService.shared.startListening()
        HotkeyService.shared.register()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SingleInstanceService.shared.release()
    }
}
