import Foundation

protocol CommandSearching {
    func search(query: String) -> [CommandItem]
}

enum CommandAliasMatcher {
    private static let aliasesByPrefix: [(prefix: String, aliases: Set<String>)] = [
        ("git checkout", ["gco"]),
        ("git commit", ["gcm"]),
        ("git status", ["gst"]),
        ("kubectl", ["kctl"]),
        ("docker ps", ["dps"])
    ]

    static func matches(query: String, command: String) -> Bool {
        let normalizedQuery = query.lowercased()
        let normalizedCommand = command.lowercased()

        guard !normalizedQuery.isEmpty else { return false }

        return aliasesByPrefix.contains { entry in
            normalizedCommand.hasPrefix(entry.prefix) && entry.aliases.contains(normalizedQuery)
        }
    }
}

struct FuzzyMatcher {
    static func matchScore(query: String, target: String) -> Double {
        let normalizedQuery = query.lowercased()
        let normalizedTarget = target.lowercased()

        guard !normalizedTarget.isEmpty else { return 0 }
        if normalizedQuery.isEmpty { return 1 }
        if CommandAliasMatcher.matches(query: normalizedQuery, command: normalizedTarget) {
            return 1
        }

        var matchedCount = 0
        var targetIndex = normalizedTarget.startIndex

        for character in normalizedQuery {
            guard let foundIndex = normalizedTarget[targetIndex...].firstIndex(of: character) else {
                return 0
            }

            matchedCount += 1
            targetIndex = normalizedTarget.index(after: foundIndex)
        }

        return Double(matchedCount) / Double(normalizedTarget.count)
    }
}

enum CommandScorer {
    private static let recencyWindow: TimeInterval = 7 * 24 * 60 * 60

    static func score(
        item: CommandItem,
        query: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Double {
        let matchScore = FuzzyMatcher.matchScore(query: query, target: item.command)
        guard matchScore > 0 else { return 0 }

        let usageScore = min(1, log1p(Double(item.usageCount)) / 5)
        let recencyScore = self.recencyScore(for: item, now: now)

        return (matchScore * 0.4) + (usageScore * 0.4) + (recencyScore * 0.2)
    }

    static func recencyScore(
        for item: CommandItem,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Double {
        guard let lastUsedAt = item.lastUsedAt else { return 0 }

        let diff = max(0, now - lastUsedAt)
        return max(0, 1 - (diff / recencyWindow))
    }
}

final class SearchService: CommandSearching {
    static let shared = SearchService()

    private let storageService: CommandStoring
    private let candidateLimit: Int
    private let nowProvider: () -> TimeInterval

    init(
        storageService: CommandStoring = StorageService.shared,
        candidateLimit: Int = 200,
        nowProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.storageService = storageService
        self.candidateLimit = candidateLimit
        self.nowProvider = nowProvider
    }

    func search(query: String) -> [CommandItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = storageService.fetchCandidates(query: normalizedQuery, limit: candidateLimit)
        return Self.sort(items, query: normalizedQuery, now: nowProvider())
    }

    static func sort(
        _ items: [CommandItem],
        query: String,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [CommandItem] {
        items
            .map { ($0, CommandScorer.score(item: $0, query: query, now: now)) }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                if lhs.0.usageCount != rhs.0.usageCount {
                    return lhs.0.usageCount > rhs.0.usageCount
                }
                let lhsLastUsedAt = lhs.0.lastUsedAt ?? .leastNormalMagnitude
                let rhsLastUsedAt = rhs.0.lastUsedAt ?? .leastNormalMagnitude
                if lhsLastUsedAt != rhsLastUsedAt {
                    return lhsLastUsedAt > rhsLastUsedAt
                }
                if lhs.0.createdAt != rhs.0.createdAt {
                    return lhs.0.createdAt > rhs.0.createdAt
                }
                return lhs.0.command.localizedStandardCompare(rhs.0.command) == .orderedAscending
            }
            .map(\.0)
    }
}
