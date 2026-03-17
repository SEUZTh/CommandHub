import XCTest
@testable import CommandHub

final class SearchServiceTests: XCTestCase {
    func testSearchMatchesSubsequenceAbbreviations() {
        let storage = makeStorageHarness().storage
        storage.save(command: "kubectl")
        storage.save(command: "git checkout")

        let searchService = SearchService(storageService: storage)

        let kubectlResults = searchService.search(query: "kctl")
        let gitResults = searchService.search(query: "gco")

        XCTAssertEqual(kubectlResults.first?.command.command, "kubectl")
        XCTAssertEqual(gitResults.first?.command.command, "git checkout")
    }

    func testEmptyQueryReturnsOnlyCandidateLimit() {
        let storage = makeStorageHarness().storage
        (0..<250).forEach { storage.save(command: "command-\($0)") }

        let searchService = SearchService(storageService: storage, candidateLimit: 200)
        let results = searchService.search(query: "")

        XCTAssertEqual(results.count, 200)
    }

    func testDomainExactMatchRanksAheadOfEnvOnlyMatch() {
        let now = Date().timeIntervalSince1970
        let currentContext = CommandContext(
            url: "https://prod.cluster-a.example.com",
            domain: "prod.cluster-a.example.com",
            env: "prod",
            sourceApp: "com.google.chrome"
        )

        let exactDomain = makeItem(
            id: "domain",
            command: "kubectl get pods",
            usageCount: 2,
            lastUsedAt: now - 60,
            createdAt: now - 1_000,
            contexts: [
                makeContextStat(
                    id: "domain-context",
                    domain: "prod.cluster-a.example.com",
                    env: "prod",
                    usageCount: 1,
                    lastUsedAt: now - 120,
                    createdAt: now - 1_000
                )
            ]
        )
        let envOnly = makeItem(
            id: "env",
            command: "kubectl get pods --all-namespaces",
            usageCount: 2,
            lastUsedAt: now - 60,
            createdAt: now - 900,
            contexts: [
                makeContextStat(
                    id: "env-context",
                    domain: "prod.cluster-b.example.com",
                    env: "prod",
                    usageCount: 1,
                    lastUsedAt: now - 120,
                    createdAt: now - 900
                )
            ]
        )

        let sorted = SearchService.sort(
            [envOnly, exactDomain],
            query: "kubectl",
            currentContext: currentContext,
            now: now
        )

        XCTAssertEqual(sorted.first?.command.id, "domain")
        XCTAssertEqual(sorted.first?.matchedContext?.id, "domain-context")
    }

    func testCurrentEnvOnlyFiltersByDomainBeforeEnv() {
        let harness = makeStorageHarness()
        let storage = harness.storage
        storage.save(command: "kubectl get pods", context: makeStoredContext(url: "https://prod.a.example.com/pods"))
        storage.save(command: "kubectl describe svc", context: makeStoredContext(url: "https://prod.b.example.com/svc"))
        storage.save(command: "kubectl config current-context", context: makeStoredContext(url: "https://dev.example.com/context"))

        let currentContext = CommandContext(
            url: "https://prod.a.example.com/dashboard",
            domain: "prod.a.example.com",
            env: "prod",
            sourceApp: "com.google.chrome"
        )

        let searchService = SearchService(storageService: storage)
        let results = searchService.search(
            query: "kubectl",
            currentContext: currentContext,
            scope: .currentEnvOnly
        )

        XCTAssertEqual(results.map { $0.command.command }, ["kubectl get pods"])
    }

    func testNoCurrentContextUsesMostUsefulDisplayContext() throws {
        let now = Date().timeIntervalSince1970
        let item = makeItem(
            id: "command",
            command: "kubectl get pods",
            usageCount: 0,
            lastUsedAt: nil,
            createdAt: now,
            contexts: [
                makeContextStat(
                    id: "older-used",
                    domain: "prod.example.com",
                    env: "prod",
                    usageCount: 3,
                    lastUsedAt: now - 3_600,
                    lastSeenAt: now - 7_200,
                    createdAt: now - 10_000
                ),
                makeContextStat(
                    id: "best",
                    domain: "dev.example.com",
                    env: "dev",
                    usageCount: 3,
                    lastUsedAt: now - 60,
                    lastSeenAt: now - 120,
                    createdAt: now - 5_000
                )
            ]
        )

        let result = try XCTUnwrap(
            SearchService.sort([item], query: "kubectl", currentContext: nil, now: now).first
        )

        XCTAssertEqual(result.displayContext?.id, "best")
        XCTAssertNil(result.matchedContext)
    }

    func testStrongRecentMatchCanBeatHighUsageWeakMatch() {
        let now = Date().timeIntervalSince1970

        let strongRecentMatch = makeItem(
            id: "recent",
            command: "kubectl",
            usageCount: 0,
            lastUsedAt: now,
            createdAt: now,
            contexts: []
        )
        let weakHistoricMatch = makeItem(
            id: "historic",
            command: "kubernetes context list",
            usageCount: 10_000,
            lastUsedAt: nil,
            createdAt: now - 10_000,
            contexts: []
        )

        let sorted = SearchService.sort(
            [weakHistoricMatch, strongRecentMatch],
            query: "kubectl",
            currentContext: nil,
            now: now
        )

        XCTAssertEqual(sorted.first?.id, strongRecentMatch.id)
    }

    func testRecencyScoreExpiresAfterSevenDays() {
        let now = Date().timeIntervalSince1970
        XCTAssertEqual(
            CommandScorer.recencyScore(lastUsedAt: now - (8 * 24 * 60 * 60), now: now),
            0,
            accuracy: 0.0001
        )
    }

    private func makeStorageHarness() -> (storage: StorageService, databaseManager: DatabaseManager) {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("commandhub.sqlite", isDirectory: false)
        let databaseManager = DatabaseManager(
            databaseURL: databaseURL,
            queueLabel: "commandhub.tests.db.\(UUID().uuidString)"
        )

        addTeardownBlock {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }

        return (
            storage: StorageService(databaseManager: databaseManager),
            databaseManager: databaseManager
        )
    }

    private func makeItem(
        id: String,
        command: String,
        usageCount: Int,
        lastUsedAt: TimeInterval?,
        createdAt: TimeInterval,
        contexts: [CommandContextStat]
    ) -> CommandItem {
        CommandItem(
            id: id,
            command: command,
            usageCount: usageCount,
            lastUsedAt: lastUsedAt,
            createdAt: createdAt,
            contexts: contexts
        )
    }

    private func makeContextStat(
        id: String,
        domain: String?,
        env: String?,
        usageCount: Int,
        lastUsedAt: TimeInterval?,
        lastSeenAt: TimeInterval? = nil,
        createdAt: TimeInterval
    ) -> CommandContextStat {
        CommandContextStat(
            id: id,
            contextKey: "\(domain ?? "")|\(env ?? "")",
            domain: domain,
            url: domain.map { "https://\($0)" },
            env: env,
            sourceApp: "com.google.chrome",
            captureCount: 1,
            usageCount: usageCount,
            lastSeenAt: lastSeenAt,
            lastUsedAt: lastUsedAt,
            createdAt: createdAt
        )
    }

    private func makeStoredContext(url: String) -> CommandContext {
        CommandContext(
            url: url,
            env: ContextResolver.resolveEnv(from: url),
            sourceApp: "com.google.chrome"
        )
    }
}
