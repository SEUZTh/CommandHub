import Foundation
import SwiftUI

final class LauncherViewModel: ObservableObject {
    @Published var query = "" {
        didSet { updateSelectionIfNeeded() }
    }
    @Published var selection: UUID?

    var commands: [CommandItem] {
        StorageService.shared.commands
    }

    var filteredCommands: [CommandItem] {
        if query.isEmpty { return commands }
        return commands.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }

    func copySelectedOrFirst() {
        let items = filteredCommands
        if items.isEmpty { return }

        let item: CommandItem
        if let selection, let match = items.first(where: { $0.id == selection }) {
            item = match
        } else {
            item = items[0]
            self.selection = item.id
        }

        copy(item)
    }

    func copy(_ item: CommandItem) {
        ClipboardService.shared.copyToClipboard(item.command)
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        let items = filteredCommands
        guard !items.isEmpty else { return }

        let currentIndex = items.firstIndex { $0.id == selection } ?? 0
        let nextIndex: Int

        switch direction {
        case .up:
            nextIndex = max(currentIndex - 1, 0)
        case .down:
            nextIndex = min(currentIndex + 1, items.count - 1)
        default:
            return
        }

        selection = items[nextIndex].id
    }

    private func updateSelectionIfNeeded() {
        let items = filteredCommands
        if let selection, items.contains(where: { $0.id == selection }) {
            return
        }
        selection = items.first?.id
    }
}
