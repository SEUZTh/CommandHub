import Foundation

struct CommandItem: Identifiable, Hashable {
    let id: UUID
    let command: String
    let context: CommandContext
    let createdAt: Date
}
