import Foundation

final class CommandParser {
    private static let wrapperCommands: Set<String> = [
        "sudo",
        "command",
        "env",
        "nohup",
        "time"
    ]

    private static let knownExecutables: Set<String> = [
        "adb",
        "ansible",
        "apt",
        "apt-get",
        "awk",
        "aws",
        "az",
        "bash",
        "brew",
        "bun",
        "cargo",
        "cat",
        "cd",
        "chmod",
        "chown",
        "code",
        "cp",
        "curl",
        "cut",
        "date",
        "df",
        "dig",
        "docker",
        "du",
        "echo",
        "env",
        "export",
        "fastlane",
        "find",
        "git",
        "gcloud",
        "go",
        "gradle",
        "grep",
        "head",
        "helm",
        "java",
        "javac",
        "journalctl",
        "jq",
        "kill",
        "kubectl",
        "kustomize",
        "less",
        "ln",
        "ls",
        "lsof",
        "make",
        "minikube",
        "mongosh",
        "more",
        "mv",
        "mvn",
        "mysql",
        "nano",
        "netstat",
        "node",
        "nohup",
        "npx",
        "nslookup",
        "npm",
        "nvim",
        "open",
        "ping",
        "pip",
        "pip3",
        "pnpm",
        "podman",
        "ps",
        "psql",
        "pwd",
        "python",
        "python3",
        "redis-cli",
        "rm",
        "rsync",
        "scp",
        "sed",
        "sh",
        "sort",
        "source",
        "sqlite3",
        "ssh",
        "systemctl",
        "tail",
        "tar",
        "terraform",
        "tmux",
        "top",
        "touch",
        "tr",
        "traceroute",
        "tee",
        "uniq",
        "unzip",
        "vi",
        "vim",
        "wc",
        "wget",
        "whoami",
        "xargs",
        "yarn",
        "zip",
        "zsh"
    ]

    private static let strongShellMarkers = [
        "&&",
        "||",
        "|",
        ";",
        "$(",
        "`",
        ">",
        "<"
    ]

    static func parse(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)

        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isCommand($0) }
    }

    private static func isCommand(_ line: String) -> Bool {
        if line.isEmpty { return false }
        if line.hasPrefix("#") { return false }
        if line.count < 2 { return false }

        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard let executable = executableInfo(in: tokens) else { return false }

        if isPathExecutable(executable.token) { return true }
        if knownExecutables.contains(executable.token.lowercased()) { return true }
        guard looksLikeExecutable(executable.token) else { return false }

        return hasStrongShellSyntax(line) || hasArgumentSignal(in: tokens, after: executable.index)
    }

    private static func executableInfo(in tokens: [Substring]) -> (index: Int, token: String)? {
        for (index, rawToken) in tokens.enumerated() {
            let token = String(rawToken)
            let normalizedToken = token.lowercased()

            if wrapperCommands.contains(normalizedToken) {
                continue
            }

            if isEnvironmentAssignment(token) {
                continue
            }

            return (index, token)
        }

        return nil
    }

    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let first = token.first, first.isLetter || first == "_" else {
            return false
        }

        return token.contains("=")
    }

    private static func isPathExecutable(_ token: String) -> Bool {
        token.hasPrefix("/") ||
        token.hasPrefix("./") ||
        token.hasPrefix("../") ||
        token.hasPrefix("~/")
    }

    private static func looksLikeExecutable(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        guard first.isLetter || first == "_" || first == "." || first == "/" || first == "~" else {
            return false
        }

        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-/+:@~")
        )

        return token.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private static func hasStrongShellSyntax(_ line: String) -> Bool {
        strongShellMarkers.contains { line.contains($0) }
    }

    private static func hasArgumentSignal(in tokens: [Substring], after executableIndex: Int) -> Bool {
        guard executableIndex + 1 < tokens.count else { return false }

        return tokens[(executableIndex + 1)...].contains { token in
            let text = String(token)

            return text.hasPrefix("-") ||
                text.contains("/") ||
                text.contains(".") ||
                text.contains(":") ||
                text.contains("$") ||
                text.contains("`") ||
                text.hasPrefix("\"") ||
                text.hasPrefix("'")
        }
    }
}
