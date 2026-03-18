import Foundation

enum CommandCategoryResolver {
    static let orderedCategories = [
        "Git",
        "Docker",
        "Kubernetes",
        "Node",
        "Remote",
        "General"
    ]

    static func resolveCategory(for command: String) -> String {
        let tokens = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !tokens.isEmpty else {
            return "General"
        }

        let executable: String
        if tokens.first?.lowercased() == "sudo", tokens.count > 1 {
            executable = tokens[1].lowercased()
        } else {
            executable = tokens[0].lowercased()
        }

        switch executable {
        case "git":
            return "Git"
        case "docker":
            return "Docker"
        case "kubectl":
            return "Kubernetes"
        case "npm", "yarn", "pnpm":
            return "Node"
        case "ssh", "scp":
            return "Remote"
        default:
            return "General"
        }
    }
}
