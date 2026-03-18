import XCTest
import SQLite3
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

    func testSaveAssignsRuleBasedCategory() throws {
        let storage = makeStorageService()

        storage.save(command: "sudo docker ps")

        let item = try XCTUnwrap(fetchSingleCommand(from: storage))
        XCTAssertEqual(item.category, "Docker")
    }

    func testMetadataUpdatesNormalizeBlankToNilAndToggleFavorite() throws {
        let storage = makeStorageService()

        storage.save(command: "kubectl get pods")
        let initial = try XCTUnwrap(fetchSingleCommand(from: storage))

        storage.updateAlias(commandID: initial.id, alias: "  Pods  ")
        storage.updateNote(commandID: initial.id, note: "   ")
        storage.toggleFavorite(commandID: initial.id)

        let updated = try XCTUnwrap(fetchSingleCommand(from: storage))
        XCTAssertEqual(updated.alias, "Pods")
        XCTAssertNil(updated.note)
        XCTAssertTrue(updated.isFavorite)
    }

    func testWorkspaceLifecycleTrimsNameRejectsDuplicatesAndClearsAssignmentsOnDelete() throws {
        let storage = makeStorageService()
        storage.save(command: "git status")
        let command = try XCTUnwrap(fetchSingleCommand(from: storage))

        let workspace = try storage.createWorkspace(name: "  Project A  ")
        XCTAssertEqual(workspace.name, "Project A")

        XCTAssertThrowsError(try storage.createWorkspace(name: "Project A")) { error in
            XCTAssertEqual(error as? WorkspaceStoreError, .duplicateName)
        }

        storage.assignWorkspace(commandID: command.id, workspaceID: workspace.id)
        let assigned = try XCTUnwrap(fetchSingleCommand(from: storage))
        XCTAssertEqual(assigned.workspaceID, workspace.id)

        try storage.renameWorkspace(id: workspace.id, name: "  Project B ")
        XCTAssertEqual(storage.fetchWorkspaces().first?.name, "Project B")

        storage.deleteWorkspace(id: workspace.id)
        let cleared = try XCTUnwrap(fetchSingleCommand(from: storage))
        XCTAssertNil(cleared.workspaceID)
        XCTAssertTrue(storage.fetchWorkspaces().isEmpty)
    }

    func testMigrationAddsV14ColumnsAndBackfillsCategoryWithoutLosingData() throws {
        let databaseURL = makeDatabaseURL()
        addTeardownBlock {
            self.cleanupDatabase(at: databaseURL)
        }

        try createLegacyDatabase(at: databaseURL)

        let databaseManager = DatabaseManager(
            databaseURL: databaseURL,
            queueLabel: "commandhub.tests.db.\(UUID().uuidString)"
        )
        let storage = StorageService(databaseManager: databaseManager)

        let item = try XCTUnwrap(
            storage.fetchCandidates(query: "", currentContext: nil, scope: .all, limit: 10).first
        )
        XCTAssertEqual(item.command, "git status")
        XCTAssertEqual(item.category, "Git")
        XCTAssertEqual(item.contexts.first?.env, "prod")

        databaseManager.withConnection { db in
            XCTAssertTrue(columnNames(in: "commands", db: db).contains("category"))
            XCTAssertTrue(columnNames(in: "commands", db: db).contains("is_favorite"))
            XCTAssertTrue(columnNames(in: "commands", db: db).contains("alias"))
            XCTAssertTrue(columnNames(in: "commands", db: db).contains("note"))
            XCTAssertTrue(columnNames(in: "commands", db: db).contains("workspace_id"))
            XCTAssertTrue(tableExists("workspaces", db: db))
        }
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

    private func createLegacyDatabase(at url: URL) throws {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        XCTAssertEqual(result, SQLITE_OK)
        guard let db else { return }
        defer { sqlite3_close(db) }

        let statements = [
            """
            CREATE TABLE commands (
                id TEXT PRIMARY KEY,
                command TEXT NOT NULL UNIQUE,
                usage_count INTEGER DEFAULT 0,
                last_used_at INTEGER,
                created_at INTEGER NOT NULL
            );
            """,
            """
            CREATE TABLE command_contexts (
                id TEXT PRIMARY KEY,
                command_id TEXT NOT NULL,
                context_key TEXT NOT NULL,
                domain TEXT,
                url TEXT,
                env TEXT,
                source_app TEXT,
                capture_count INTEGER NOT NULL DEFAULT 0,
                usage_count INTEGER NOT NULL DEFAULT 0,
                last_seen_at INTEGER,
                last_used_at INTEGER,
                created_at INTEGER NOT NULL
            );
            """,
            """
            INSERT INTO commands (id, command, usage_count, last_used_at, created_at)
            VALUES ('cmd-1', 'git status', 2, 10, 1);
            """,
            """
            INSERT INTO command_contexts (
                id,
                command_id,
                context_key,
                domain,
                url,
                env,
                source_app,
                capture_count,
                usage_count,
                last_seen_at,
                last_used_at,
                created_at
            )
            VALUES (
                'ctx-1',
                'cmd-1',
                'com.google.chrome|prod.example.com|prod',
                'prod.example.com',
                'https://prod.example.com',
                'prod',
                'com.google.chrome',
                1,
                1,
                10,
                10,
                1
            );
            """
        ]

        for sql in statements {
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }
    }

    private func columnNames(in table: String, db: OpaquePointer) -> Set<String> {
        var names = Set<String>()
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: pointer))
            }
        }

        return names
    }

    private func tableExists(_ table: String, db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = """
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1;
        """
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (table as NSString).utf8String, -1, sqliteTransientDestructor)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
