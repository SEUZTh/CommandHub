import Foundation

struct CommandWorkspace: Identifiable, Hashable {
    let id: String
    let name: String
    let createdAt: TimeInterval
    let commandCount: Int
}
