import Foundation

struct SearchFilters: Equatable, Hashable {
    let favoritesOnly: Bool
    let category: String?
    let workspaceID: String?

    static let `default` = SearchFilters(
        favoritesOnly: false,
        category: nil,
        workspaceID: nil
    )

    var isDefault: Bool {
        self == .default
    }

    func clearingAll() -> SearchFilters {
        .default
    }
}
