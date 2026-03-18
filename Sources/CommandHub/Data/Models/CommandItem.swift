import Foundation

struct CommandItem: Identifiable, Hashable {
    let id: String
    let command: String
    let category: String
    let isFavorite: Bool
    let alias: String?
    let note: String?
    let workspaceID: String?
    let usageCount: Int
    let lastUsedAt: TimeInterval?
    let createdAt: TimeInterval
    let contexts: [CommandContextStat]

    init(
        id: String,
        command: String,
        category: String = "General",
        isFavorite: Bool = false,
        alias: String? = nil,
        note: String? = nil,
        workspaceID: String? = nil,
        usageCount: Int,
        lastUsedAt: TimeInterval?,
        createdAt: TimeInterval,
        contexts: [CommandContextStat]
    ) {
        self.id = id
        self.command = command
        self.category = category
        self.isFavorite = isFavorite
        self.alias = alias
        self.note = note
        self.workspaceID = workspaceID
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.contexts = contexts
    }
}
