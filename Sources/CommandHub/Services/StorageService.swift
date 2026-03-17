import Foundation

final class StorageService {
    static let shared = StorageService()

    private(set) var commands: [CommandItem] = []
    private let maxCapacity = 200

    func save(command: String, context: CommandContext) {
        if let first = commands.first, first.command == command {
            return
        }

        let item = CommandItem(
            id: UUID(),
            command: command,
            context: context,
            createdAt: Date()
        )

        commands.insert(item, at: 0)

        if commands.count > maxCapacity {
            commands.removeLast(commands.count - maxCapacity)
        }
    }
}
