import XCTest
@testable import CommandHub

final class StorageServiceTests: XCTestCase {
    func testSaveDeduplicatesExactCommands() {
        let storage = makeStorageService()

        storage.save(command: "git status")
        storage.save(command: "git status")

        let items = storage.fetchCandidates(query: "", limit: 10)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.command, "git status")
    }

    func testRepeatedParsedCommandsPersistOnlyOnce() {
        let storage = makeStorageService()
        let input = """
        git status
        git status
        git status
        """

        CommandParser.parse(input).forEach { storage.save(command: $0) }

        let items = storage.fetchCandidates(query: "", limit: 10)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.command, "git status")
    }

    func testMarkUsedUpdatesUsageCountAndLastUsedAt() throws {
        let storage = makeStorageService()

        storage.save(command: "git status")
        let item = try XCTUnwrap(storage.fetchCandidates(query: "", limit: 10).first)

        storage.markUsed(id: item.id)

        let updated = try XCTUnwrap(storage.fetchCandidates(query: "", limit: 10).first)
        XCTAssertEqual(updated.usageCount, 1)
        XCTAssertNotNil(updated.lastUsedAt)
    }

    func testDeleteRemovesCommand() throws {
        let storage = makeStorageService()

        storage.save(command: "git status")
        let item = try XCTUnwrap(storage.fetchCandidates(query: "", limit: 10).first)

        storage.delete(id: item.id)

        XCTAssertTrue(storage.fetchCandidates(query: "", limit: 10).isEmpty)
    }

    func testPersistenceSurvivesServiceRecreation() {
        let databaseURL = makeDatabaseURL()
        defer { cleanupDatabase(at: databaseURL) }

        let firstStorage = StorageService(
            databaseManager: DatabaseManager(
                databaseURL: databaseURL,
                queueLabel: "commandhub.tests.db.\(UUID().uuidString)"
            )
        )
        firstStorage.save(command: "git status")

        let secondStorage = StorageService(
            databaseManager: DatabaseManager(
                databaseURL: databaseURL,
                queueLabel: "commandhub.tests.db.\(UUID().uuidString)"
            )
        )

        let items = secondStorage.fetchCandidates(query: "", limit: 10)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.command, "git status")
    }

    func testStoragePersistsLongAndSpecialCharacterCommands() {
        let storage = makeStorageService()
        let commands = [
            "kubectl get pods -n default --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'",
            "echo $PATH",
            "echo `date`",
            "echo \"$(whoami)\"",
            "grep \"error\" log.txt"
        ]

        commands.forEach { storage.save(command: $0) }

        let storedCommands = storage.fetchCandidates(query: "", limit: 20).map(\.command)

        XCTAssertEqual(Set(storedCommands), Set(commands))
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
}
