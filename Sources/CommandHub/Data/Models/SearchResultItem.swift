import Foundation

struct SearchResultItem: Identifiable, Hashable {
    let command: CommandItem
    let matchedContext: CommandContextStat?
    let displayContext: CommandContextStat?
    let score: Double

    var id: String {
        command.id
    }
}
