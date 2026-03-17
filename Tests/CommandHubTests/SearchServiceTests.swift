import XCTest
import SQLite3
@testable import CommandHub

final class SearchServiceTests: XCTestCase {
    func testSearchMatchesSubsequenceAbbreviations() {
        let storage = makeStorageHarness().storage
        storage.save(command: "kubectl")
        storage.save(command: "git checkout")

        let searchService = SearchService(storageService: storage)

        let kubectlResults = searchService.search(query: "kctl")
        let gitResults = searchService.search(query: "gco")

        XCTAssertEqual(kubectlResults.first?.command, "kubectl")
        XCTAssertEqual(gitResults.first?.command, "git checkout")
    }

    func testEmptyQueryReturnsOnlyCandidateLimit() {
        let storage = makeStorageHarness().storage
        (0..<250).forEach { storage.save(command: "command-\($0)") }

        let searchService = SearchService(storageService: storage, candidateLimit: 200)
        let results = searchService.search(query: "")

        XCTAssertEqual(results.count, 200)
    }

    func testNonEmptyQueryReturnsOnlyCandidateLimit() {
        let storage = makeStorageHarness().storage
        (0..<250).forEach { storage.save(command: "git checkout branch-\($0)") }

        let searchService = SearchService(storageService: storage, candidateLimit: 200)
        let results = searchService.search(query: "gco")

        XCTAssertEqual(results.count, 200)
    }

    func testSearchMatchesRequestedAbbreviationsAgainstFullCommands() {
        let storage = makeStorageHarness().storage
        storage.save(command: "kubectl get pods")
        storage.save(command: "git checkout -b feature/test")
        storage.save(command: "git commit -m \"fix bug\"")
        storage.save(command: "git status")
        storage.save(command: "docker ps")
        storage.save(command: "git push origin main")

        let searchService = SearchService(storageService: storage)

        XCTAssertEqual(searchService.search(query: "kctl").first?.command, "kubectl get pods")
        XCTAssertEqual(searchService.search(query: "gco").first?.command, "git checkout -b feature/test")
        XCTAssertEqual(searchService.search(query: "gcm").first?.command, "git commit -m \"fix bug\"")
        XCTAssertEqual(searchService.search(query: "gst").first?.command, "git status")
        XCTAssertEqual(searchService.search(query: "dps").first?.command, "docker ps")
    }

    func testEmptyQueryRanksCommandsByUsageCount() throws {
        let harness = makeStorageHarness()
        let storage = harness.storage
        storage.save(command: "git status")
        storage.save(command: "kubectl get pods")
        storage.save(command: "docker ps")

        let gitStatus = try XCTUnwrap(item(command: "git status", in: storage))
        let kubectl = try XCTUnwrap(item(command: "kubectl get pods", in: storage))
        let docker = try XCTUnwrap(item(command: "docker ps", in: storage))

        (0..<10).forEach { _ in storage.markUsed(id: gitStatus.id) }
        (0..<3).forEach { _ in storage.markUsed(id: kubectl.id) }
        storage.markUsed(id: docker.id)

        let searchService = SearchService(storageService: storage)
        let results = searchService.search(query: "")

        XCTAssertEqual(
            Array(results.prefix(3)).map(\.command),
            ["git status", "kubectl get pods", "docker ps"]
        )
    }

    func testMoreRecentCommandRanksAheadOfOlderCommandWhenUsageMatches() {
        let harness = makeStorageHarness()
        let storage = harness.storage
        let now = Date().timeIntervalSince1970

        storage.save(command: "git status")
        storage.save(command: "kubectl get pods")

        updateStats(
            command: "git status",
            usageCount: 1,
            lastUsedAt: now - (8 * 24 * 60 * 60),
            createdAt: now - 1_000,
            using: harness.databaseManager
        )
        updateStats(
            command: "kubectl get pods",
            usageCount: 1,
            lastUsedAt: now,
            createdAt: now - 500,
            using: harness.databaseManager
        )

        let searchService = SearchService(
            storageService: storage,
            nowProvider: { now }
        )
        let results = searchService.search(query: "")

        XCTAssertEqual(Array(results.prefix(2)).map(\.command), ["kubectl get pods", "git status"])
    }

    func testLargeDatasetSearchRespectsCandidateLimitWithFiveHundredCommands() {
        let storage = makeStorageHarness().storage
        (1...500).forEach { storage.save(command: "git test-\($0)") }

        let searchService = SearchService(storageService: storage, candidateLimit: 200)
        let results = searchService.search(query: "gt")

        XCTAssertEqual(results.count, 200)
        XCTAssertTrue(results.contains(where: { $0.command == "git test-1" }))
    }

    func testStrongRecentMatchCanBeatHighUsageWeakMatch() {
        let now = Date().timeIntervalSince1970

        let strongRecentMatch = CommandItem(
            id: "recent",
            command: "kubectl",
            usageCount: 0,
            lastUsedAt: now,
            createdAt: now
        )
        let weakHistoricMatch = CommandItem(
            id: "historic",
            command: "kubernetes context list",
            usageCount: 10_000,
            lastUsedAt: nil,
            createdAt: now - 10_000
        )

        let sorted = SearchService.sort(
            [weakHistoricMatch, strongRecentMatch],
            query: "kubectl",
            now: now
        )

        XCTAssertEqual(sorted.first?.id, strongRecentMatch.id)
    }

    func testRecencyScoreExpiresAfterSevenDays() {
        let now = Date().timeIntervalSince1970
        let item = CommandItem(
            id: "stale",
            command: "git status",
            usageCount: 0,
            lastUsedAt: now - (8 * 24 * 60 * 60),
            createdAt: now - 100
        )

        XCTAssertEqual(CommandScorer.recencyScore(for: item, now: now), 0, accuracy: 0.0001)
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

    private func item(command: String, in storage: StorageService) -> CommandItem? {
        storage.fetchCandidates(query: "", limit: 20).first(where: { $0.command == command })
    }

    private func updateStats(
        command: String,
        usageCount: Int,
        lastUsedAt: TimeInterval?,
        createdAt: TimeInterval,
        using databaseManager: DatabaseManager
    ) {
        databaseManager.withConnection { db in
            let sql = """
            UPDATE commands
            SET usage_count = ?, last_used_at = ?, created_at = ?
            WHERE command = ?;
            """

            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int(statement, 1, Int32(usageCount))
            if let lastUsedAt {
                sqlite3_bind_int64(statement, 2, Int64(lastUsedAt))
            } else {
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_int64(statement, 3, Int64(createdAt))
            sqlite3_bind_text(statement, 4, (command as NSString).utf8String, -1, sqliteTransientDestructor)

            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        }
    }
}
