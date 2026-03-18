import Foundation

protocol CommandSearching {
    func search(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        filters: SearchFilters,
        sessionBaseline: SearchSessionBaseline?
    ) -> [SearchResultItem]
}

extension CommandSearching {
    func search(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        sessionBaseline: SearchSessionBaseline?
    ) -> [SearchResultItem] {
        search(
            query: query,
            currentContext: currentContext,
            scope: scope,
            filters: .default,
            sessionBaseline: sessionBaseline
        )
    }

    func search(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        filters: SearchFilters = .default
    ) -> [SearchResultItem] {
        search(
            query: query,
            currentContext: currentContext,
            scope: scope,
            filters: filters,
            sessionBaseline: nil
        )
    }

    func search(query: String) -> [SearchResultItem] {
        search(
            query: query,
            currentContext: nil,
            scope: .all,
            filters: .default,
            sessionBaseline: nil
        )
    }
}

struct SearchSessionBaseline: Equatable {
    struct UsageSnapshot: Equatable {
        let usageCount: Int
        let lastUsedAt: TimeInterval?
    }

    struct ContextKey: Hashable {
        let commandID: String
        let contextKey: String
    }

    enum ContextSnapshot: Equatable {
        case missing
        case existing(UsageSnapshot)
    }

    private(set) var commandSnapshots: [String: UsageSnapshot] = [:]
    private(set) var contextSnapshots: [ContextKey: ContextSnapshot] = [:]

    var isEmpty: Bool {
        commandSnapshots.isEmpty && contextSnapshots.isEmpty
    }

    var touchedCommandCount: Int {
        commandSnapshots.count
    }

    mutating func recordSelection(_ item: SearchResultItem, currentContext: CommandContext?) {
        if commandSnapshots[item.command.id] == nil {
            commandSnapshots[item.command.id] = UsageSnapshot(
                usageCount: item.command.usageCount,
                lastUsedAt: item.command.lastUsedAt
            )
        }

        guard let contextKey = currentContext?.contextKey else { return }

        let compositeKey = ContextKey(
            commandID: item.command.id,
            contextKey: contextKey
        )
        guard contextSnapshots[compositeKey] == nil else { return }

        if let existingContext = item.command.contexts.first(where: { $0.contextKey == contextKey }) {
            contextSnapshots[compositeKey] = .existing(
                UsageSnapshot(
                    usageCount: existingContext.usageCount,
                    lastUsedAt: existingContext.lastUsedAt
                )
            )
        } else {
            contextSnapshots[compositeKey] = .missing
        }
    }

    func apply(to item: CommandItem) -> CommandItem {
        let adjustedContexts = item.contexts.compactMap { context -> CommandContextStat? in
            let compositeKey = ContextKey(
                commandID: item.id,
                contextKey: context.contextKey
            )

            switch contextSnapshots[compositeKey] {
            case let .existing(snapshot):
                return CommandContextStat(
                    id: context.id,
                    contextKey: context.contextKey,
                    domain: context.domain,
                    url: context.url,
                    env: context.env,
                    sourceApp: context.sourceApp,
                    captureCount: context.captureCount,
                    usageCount: snapshot.usageCount,
                    lastSeenAt: context.lastSeenAt,
                    lastUsedAt: snapshot.lastUsedAt,
                    createdAt: context.createdAt
                )
            case .missing:
                return nil
            case .none:
                return context
            }
        }

        let commandSnapshot = commandSnapshots[item.id]

        return CommandItem(
            id: item.id,
            command: item.command,
            category: item.category,
            isFavorite: item.isFavorite,
            alias: item.alias,
            note: item.note,
            workspaceID: item.workspaceID,
            usageCount: commandSnapshot?.usageCount ?? item.usageCount,
            lastUsedAt: commandSnapshot?.lastUsedAt ?? item.lastUsedAt,
            createdAt: item.createdAt,
            contexts: adjustedContexts
        )
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
        let commandMatch = FuzzyMatcher.matchScore(query: query, target: item.command)
        let aliasMatch = item.alias.map { FuzzyMatcher.matchScore(query: query, target: $0) } ?? 0
        let noteMatch = item.note.map { FuzzyMatcher.matchScore(query: query, target: $0) } ?? 0
        let textMatch = max(commandMatch, aliasMatch, noteMatch * 0.35)
        guard textMatch > 0 else { return nil }

        let globalUsage = usageScore(item.usageCount)
        let globalRecency = recencyScore(lastUsedAt: item.lastUsedAt, now: now)
        let match = matchedContext(for: item, currentContext: currentContext, now: now)
        let contextAffinity = match.map { affinity(for: $0, currentContext: currentContext) } ?? 0
        let contextBehavior = match.map { behaviorScore(for: $0, now: now) } ?? 0
        let favoriteBonus = item.isFavorite ? 1.0 : 0.0

        let score =
            (textMatch * 0.35) +
            (globalUsage * 0.15) +
            (globalRecency * 0.10) +
            (contextAffinity * 0.20) +
            (contextBehavior * 0.10) +
            (favoriteBonus * 0.10)

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

        let currentEnvKey = CommandContext.normalizeEnvKey(currentContext.env)
        let itemEnvKey = CommandContext.normalizeEnvKey(context.env)

        if let currentEnvKey,
           let itemEnvKey,
           currentEnvKey != itemEnvKey {
            return 0
        }

        if let currentEnvKey,
           let itemEnvKey,
           currentEnvKey == itemEnvKey {
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
        scope: SearchScope,
        filters: SearchFilters,
        sessionBaseline: SearchSessionBaseline? = nil
    ) -> [SearchResultItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeBaseline = sessionBaseline?.isEmpty == false ? sessionBaseline : nil
        let effectiveLimit = candidateLimit + (activeBaseline?.touchedCommandCount ?? 0)
        let items = storageService.fetchCandidates(
            query: normalizedQuery,
            currentContext: currentContext,
            scope: scope,
            filters: filters,
            limit: effectiveLimit
        )

        let results = Self.sort(
            items,
            query: normalizedQuery,
            currentContext: currentContext,
            now: nowProvider(),
            sessionBaseline: activeBaseline
        )

        guard scope == .currentEnvOnly else {
            return Array(results.prefix(candidateLimit))
        }

        return Array(
            results
                .filter { Self.matchesCurrentEnvScope(result: $0, currentContext: currentContext) }
                .prefix(candidateLimit)
        )
    }

    static func sort(
        _ items: [CommandItem],
        query: String,
        currentContext: CommandContext?,
        now: TimeInterval = Date().timeIntervalSince1970,
        sessionBaseline: SearchSessionBaseline? = nil
    ) -> [SearchResultItem] {
        items
            .compactMap { item in
                let adjustedItem = sessionBaseline?.apply(to: item) ?? item
                return CommandScorer.score(
                    item: adjustedItem,
                    query: query,
                    currentContext: currentContext,
                    now: now
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.command.isFavorite != rhs.command.isFavorite {
                    return lhs.command.isFavorite && !rhs.command.isFavorite
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

        if let currentEnvKey = CommandContext.normalizeEnvKey(currentContext.env) {
            return result.command.contexts.contains {
                CommandContext.normalizeEnvKey($0.env) == currentEnvKey
            }
        }

        return false
    }
}
