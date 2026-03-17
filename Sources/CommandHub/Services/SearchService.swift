import Foundation

protocol CommandSearching {
    func search(query: String, currentContext: CommandContext?, scope: SearchScope) -> [SearchResultItem]
}

extension CommandSearching {
    func search(query: String) -> [SearchResultItem] {
        search(query: query, currentContext: nil, scope: .all)
    }
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
        currentContext: CommandContext?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> SearchResultItem? {
        let textMatch = FuzzyMatcher.matchScore(query: query, target: item.command)
        guard textMatch > 0 else { return nil }

        let globalUsage = usageScore(item.usageCount)
        let globalRecency = recencyScore(lastUsedAt: item.lastUsedAt, now: now)
        let match = matchedContext(for: item, currentContext: currentContext, now: now)
        let contextAffinity = match.map { affinity(for: $0, currentContext: currentContext) } ?? 0
        let contextBehavior = match.map { behaviorScore(for: $0, now: now) } ?? 0

        let score =
            (textMatch * 0.40) +
            (globalUsage * 0.20) +
            (globalRecency * 0.10) +
            (contextAffinity * 0.20) +
            (contextBehavior * 0.10)

        let displayContext: CommandContextStat?
        if currentContext == nil {
            displayContext = preferredDisplayContext(from: item.contexts)
        } else {
            displayContext = match
        }

        return SearchResultItem(
            command: item,
            matchedContext: match,
            displayContext: displayContext,
            score: score
        )
    }

    static func recencyScore(
        lastUsedAt: TimeInterval?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> Double {
        guard let lastUsedAt else { return 0 }

        let diff = max(0, now - lastUsedAt)
        return max(0, 1 - (diff / recencyWindow))
    }

    static func preferredDisplayContext(from contexts: [CommandContextStat]) -> CommandContextStat? {
        contexts.max { lhs, rhs in
            if lhs.usageCount != rhs.usageCount {
                return lhs.usageCount < rhs.usageCount
            }
            let lhsLastUsedAt = lhs.lastUsedAt ?? .leastNormalMagnitude
            let rhsLastUsedAt = rhs.lastUsedAt ?? .leastNormalMagnitude
            if lhsLastUsedAt != rhsLastUsedAt {
                return lhsLastUsedAt < rhsLastUsedAt
            }
            let lhsLastSeenAt = lhs.lastSeenAt ?? .leastNormalMagnitude
            let rhsLastSeenAt = rhs.lastSeenAt ?? .leastNormalMagnitude
            if lhsLastSeenAt != rhsLastSeenAt {
                return lhsLastSeenAt < rhsLastSeenAt
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func matchedContext(
        for item: CommandItem,
        currentContext: CommandContext?,
        now: TimeInterval
    ) -> CommandContextStat? {
        guard let currentContext else { return nil }

        let candidates = item.contexts.compactMap { context -> (CommandContextStat, Double, Double)? in
            let affinity = affinity(for: context, currentContext: currentContext)
            guard affinity > 0 else { return nil }

            let behavior = behaviorScore(for: context, now: now)
            let weightedContribution = (affinity * 0.20) + (behavior * 0.10)
            return (context, weightedContribution, behavior)
        }

        guard !candidates.isEmpty else { return nil }

        return candidates.max { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            if lhs.2 != rhs.2 {
                return lhs.2 < rhs.2
            }
            if lhs.0.usageCount != rhs.0.usageCount {
                return lhs.0.usageCount < rhs.0.usageCount
            }
            let lhsLastUsedAt = lhs.0.lastUsedAt ?? .leastNormalMagnitude
            let rhsLastUsedAt = rhs.0.lastUsedAt ?? .leastNormalMagnitude
            if lhsLastUsedAt != rhsLastUsedAt {
                return lhsLastUsedAt < rhsLastUsedAt
            }
            let lhsLastSeenAt = lhs.0.lastSeenAt ?? .leastNormalMagnitude
            let rhsLastSeenAt = rhs.0.lastSeenAt ?? .leastNormalMagnitude
            if lhsLastSeenAt != rhsLastSeenAt {
                return lhsLastSeenAt < rhsLastSeenAt
            }
            return lhs.0.createdAt < rhs.0.createdAt
        }?.0
    }

    private static func affinity(for context: CommandContextStat, currentContext: CommandContext?) -> Double {
        guard let currentContext else { return 0 }

        if let currentDomain = currentContext.domain,
           let itemDomain = context.domain,
           currentDomain == itemDomain {
            return 1.0
        }

        if let currentEnv = currentContext.env,
           let itemEnv = context.env,
           currentEnv != itemEnv {
            return 0
        }

        if let currentEnv = currentContext.env,
           let itemEnv = context.env,
           currentEnv == itemEnv {
            return 0.5
        }

        if let currentSourceApp = currentContext.normalizedSourceAppKey,
           let itemSourceApp = context.sourceApp,
           currentSourceApp == itemSourceApp {
            return 0.15
        }

        return 0
    }

    private static func behaviorScore(for context: CommandContextStat, now: TimeInterval) -> Double {
        let usage = usageScore(context.usageCount)
        let recency = recencyScore(lastUsedAt: context.lastUsedAt, now: now)
        return (usage * 0.60) + (recency * 0.40)
    }

    private static func usageScore(_ usageCount: Int) -> Double {
        min(1, log1p(Double(usageCount)) / 5)
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

    func search(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope
    ) -> [SearchResultItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = storageService.fetchCandidates(
            query: normalizedQuery,
            currentContext: currentContext,
            scope: scope,
            limit: candidateLimit
        )

        let results = Self.sort(
            items,
            query: normalizedQuery,
            currentContext: currentContext,
            now: nowProvider()
        )

        guard scope == .currentEnvOnly else {
            return results
        }

        return results.filter {
            Self.matchesCurrentEnvScope(result: $0, currentContext: currentContext)
        }
    }

    static func sort(
        _ items: [CommandItem],
        query: String,
        currentContext: CommandContext?,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> [SearchResultItem] {
        items
            .compactMap { CommandScorer.score(item: $0, query: query, currentContext: currentContext, now: now) }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.command.usageCount != rhs.command.usageCount {
                    return lhs.command.usageCount > rhs.command.usageCount
                }
                let lhsLastUsedAt = lhs.command.lastUsedAt ?? .leastNormalMagnitude
                let rhsLastUsedAt = rhs.command.lastUsedAt ?? .leastNormalMagnitude
                if lhsLastUsedAt != rhsLastUsedAt {
                    return lhsLastUsedAt > rhsLastUsedAt
                }
                if lhs.command.createdAt != rhs.command.createdAt {
                    return lhs.command.createdAt > rhs.command.createdAt
                }
                return lhs.command.command.localizedStandardCompare(rhs.command.command) == .orderedAscending
            }
    }

    private static func matchesCurrentEnvScope(
        result: SearchResultItem,
        currentContext: CommandContext?
    ) -> Bool {
        guard let currentContext else { return false }

        if let currentDomain = currentContext.domain {
            return result.command.contexts.contains { $0.domain == currentDomain }
        }

        if let currentEnv = currentContext.env {
            return result.command.contexts.contains { $0.env == currentEnv }
        }

        return false
    }
}
