import Foundation

struct CommandContextStat: Identifiable, Hashable {
    let id: String
    let contextKey: String
    let domain: String?
    let url: String?
    let env: String?
    let sourceApp: String?
    let captureCount: Int
    let usageCount: Int
    let lastSeenAt: TimeInterval?
    let lastUsedAt: TimeInterval?
    let createdAt: TimeInterval

    var sourceAppDisplayName: String? {
        guard let sourceApp else { return nil }

        switch sourceApp {
        case "com.google.chrome":
            return "Chrome"
        case "com.apple.safari":
            return "Safari"
        case "com.googlecode.iterm2":
            return "iTerm2"
        case "com.microsoft.vscode":
            return "VS Code"
        case "com.todesktop.230313mzl4w4u92":
            return "Cursor"
        case "com.apple.finder":
            return "Finder"
        default:
            if sourceApp.contains("."),
               let suffix = sourceApp.split(separator: ".").last {
                let value = String(suffix)
                if value.lowercased() == "code" {
                    return "Code"
                }
                return value
                    .replacingOccurrences(of: "-", with: " ")
                    .capitalized
            }

            return sourceApp.capitalized
        }
    }
}
