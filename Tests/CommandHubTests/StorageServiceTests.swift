import XCTest
@testable import CommandHub

final class StorageServiceTests: XCTestCase {
    func testSaveKeepsSingleCommandAndCreatesMultipleContexts() throws {
        let storage = makeStorageService()

        storage.save(command: "kubectl get pods", context: makeContext(url: "https://prod.example.com/pods"))
        storage.save(command: "kubectl get pods", context: makeContext(url: "https://dev.example.com/pods"))

        let item = try XCTUnwrap(fetchSingleCommand(from: storage))
        XCTAssertEqual(item.command, "kubectl get pods")
        XCTAssertEqual(item.contexts.count, 2)
        XCTAssertEqual(Set(item.contexts.compactMap(\.env)), ["prod", "dev"])
    }

    func testRepeatedCaptureUpdatesCaptureStatsOnlyForSameContext() throws {
        let storage = makeStorageService()

        storage.save(command: "kubectl get pods", context: makeContext(url: "https://prod.example.com/a"))
        storage.save(command: "kubectl get pods", context: makeContext(url: "https://prod.example.com/b"))

        let item = try XCTUnwrap(fetchSingleCommand(from: storage))
        let context = try XCTUnwrap(item.contexts.first)

        XCTAssertEqual(item.contexts.count, 1)
        XCTAssertEqual(context.captureCount, 2)
        XCTAssertEqual(context.usageCount, 0)
        XCTAssertNil(context.lastUsedAt)
        XCTAssertNotNil(context.lastSeenAt)
        XCTAssertEqual(context.url, "https://prod.example.com/b")
    }

    func testMarkUsedPrefersMatchedContextIDOverFallbackContext() throws {
        let storage = makeStorageService()

        storage.save(command: "kubectl get pods", context: makeContext(url: "https://prod.example.com/pods"))
        storage.save(command: "kubectl get pods", context: makeContext(url: "https://dev.example.com/pods"))

        let initialItem = try XCTUnwrap(fetchSingleCommand(from: storage))
        let prodContext = try XCTUnwrap(initialItem.contexts.first(where: { $0.env == "prod" }))

        storage.markUsed(
            commandID: initialItem.id,
            matchedContextID: prodContext.id,
            fallbackContext: makeContext(url: "https://dev.example.com/other")
        )

        let updatedItem = try XCTUnwrap(fetchSingleCommand(from: storage))
        let updatedProdContext = try XCTUnwrap(updatedItem.contexts.first(where: { $0.env == "prod" }))
        let updatedDevContext = try XCTUnwrap(updatedItem.contexts.first(where: { $0.env == "dev" }))

        XCTAssertEqual(updatedItem.usageCount, 1)
        XCTAssertEqual(updatedProdContext.usageCount, 1)
        XCTAssertNotNil(updatedProdContext.lastUsedAt)
        XCTAssertEqual(updatedDevContext.usageCount, 0)
    }

    func testMarkUsedFallbackUpsertsUsageOnlyContext() throws {
        let storage = makeStorageService()

        storage.save(command: "git status")
        let item = try XCTUnwrap(fetchSingleCommand(from: storage))

        storage.markUsed(
            commandID: item.id,
            matchedContextID: nil,
            fallbackContext: makeContext(url: "https://prod.example.com/status")
        )

        let updatedItem = try XCTUnwrap(fetchSingleCommand(from: storage))
        let context = try XCTUnwrap(updatedItem.contexts.first)

        XCTAssertEqual(updatedItem.usageCount, 1)
        XCTAssertEqual(context.captureCount, 0)
        XCTAssertEqual(context.usageCount, 1)
        XCTAssertNil(context.lastSeenAt)
        XCTAssertNotNil(context.lastUsedAt)
    }

    func testDeleteRemovesCommandAndContexts() throws {
        let storage = makeStorageService()

        storage.save(command: "git status", context: makeContext(url: "https://prod.example.com/status"))
        let item = try XCTUnwrap(fetchSingleCommand(from: storage))

        storage.delete(id: item.id)

        let results = storage.fetchCandidates(query: "", currentContext: nil, scope: .all, limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    private func fetchSingleCommand(from storage: StorageService) -> CommandItem? {
        storage.fetchCandidates(query: "", currentContext: nil, scope: .all, limit: 10).first
    }

    private func makeStorageService() -> StorageService {
        let databaseURL = makeDatabaseURL()
        addTeardownBlock {
            self.cleanupDatabase(at: databaseURL)
        }

        return StorageService(
            databaseManager: DatabaseManager(
                databaseURL: databaseURL,
                queueLabel: "commandhub.tests.db.\(UUID().uuidString)"
            )
        )
    }

    private func makeDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("commandhub.sqlite", isDirectory: false)
    }

    private func cleanupDatabase(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func makeContext(url: String) -> CommandContext {
        CommandContext(
            url: url,
            env: ContextResolver.resolveEnv(from: url),
            sourceApp: "com.google.chrome"
        )
    }
}
