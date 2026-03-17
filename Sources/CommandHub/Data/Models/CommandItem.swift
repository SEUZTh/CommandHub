import Foundation

struct CommandItem: Identifiable, Hashable {
    let id: String
    let command: String
    let usageCount: Int
    let lastUsedAt: TimeInterval?
    let createdAt: TimeInterval
}
