import Foundation

enum SearchScope: String, CaseIterable, Hashable, Identifiable {
    case all
    case currentEnvOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .currentEnvOnly:
            return "Current Env Only"
        }
    }
}
