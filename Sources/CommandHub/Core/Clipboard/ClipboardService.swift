import AppKit

final class ClipboardService {
    static let shared = ClipboardService()

    private var changeCount = NSPasteboard.general.changeCount
    private var timer: Timer?

    func startListening() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount

        if let text = pasteboard.string(forType: .string) {
            handleClipboardText(text)
        }
    }

    private func handleClipboardText(_ text: String) {
        let commands = CommandParser.parse(text)
        let context = ContextResolver.resolve()

        commands.forEach {
            StorageService.shared.save(command: $0, context: context)
        }
    }
}
