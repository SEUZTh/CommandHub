import Foundation

final class CommandParser {
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
        return true
    }
}
