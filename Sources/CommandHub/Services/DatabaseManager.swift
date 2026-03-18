import Foundation
import SQLite3

let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager {
    static let shared = DatabaseManager()

    let databaseURL: URL

    private let queue: DispatchQueue
    private var db: OpaquePointer?

    init(
        databaseURL: URL = DatabaseManager.defaultDatabaseURL(),
        queueLabel: String = "commandhub.db.queue"
    ) {
        self.databaseURL = databaseURL
        self.queue = DispatchQueue(label: queueLabel)

        openDatabase()
        createSchema()
    }

    deinit {
        closeDatabase()
    }

    @discardableResult
    func withConnection<T>(_ work: (OpaquePointer) -> T) -> T {
        queue.sync {
            guard let db else {
                fatalError("CommandHub database is not available.")
            }

            return work(db)
        }
    }

    private func openDatabase() {
        let directoryURL = databaseURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            fatalError("Failed to create database directory: \(error.localizedDescription)")
        }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databaseURL.path, &connection, flags, nil) == SQLITE_OK,
              let connection else {
            let message = connection.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(connection)
            fatalError("Failed to open database: \(message)")
        }

        sqlite3_busy_timeout(connection, 5_000)
        db = connection
    }

    private func closeDatabase() {
        queue.sync {
            guard let db else { return }
            sqlite3_close(db)
            self.db = nil
        }
    }

    private func createSchema() {
        withConnection { db in
            createTables(on: db)
            migrateSchema(on: db)
            createIndices(on: db)
            backfillMissingCategories(on: db)
        }
    }

    private func createTables(on db: OpaquePointer) {
        execute(
            """
            CREATE TABLE IF NOT EXISTS commands (
                id TEXT PRIMARY KEY,
                command TEXT NOT NULL UNIQUE,
                category TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                alias TEXT,
                note TEXT,
                workspace_id TEXT,
                usage_count INTEGER DEFAULT 0,
                last_used_at INTEGER,
                created_at INTEGER NOT NULL
            );
            """,
            on: db
        )

        execute(
            """
            CREATE TABLE IF NOT EXISTS command_contexts (
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
            on: db
        )

        execute(
            """
            CREATE TABLE IF NOT EXISTS workspaces (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL
            );
            """,
            on: db
        )
    }

    private func migrateSchema(on db: OpaquePointer) {
        guard tableExists("commands", on: db) else { return }

        ensureColumnExists(
            table: "commands",
            name: "category",
            definition: "TEXT",
            on: db
        )
        ensureColumnExists(
            table: "commands",
            name: "is_favorite",
            definition: "INTEGER NOT NULL DEFAULT 0",
            on: db
        )
        ensureColumnExists(
            table: "commands",
            name: "alias",
            definition: "TEXT",
            on: db
        )
        ensureColumnExists(
            table: "commands",
            name: "note",
            definition: "TEXT",
            on: db
        )
        ensureColumnExists(
            table: "commands",
            name: "workspace_id",
            definition: "TEXT",
            on: db
        )
    }

    private func createIndices(on db: OpaquePointer) {
        execute(
            "CREATE INDEX IF NOT EXISTS idx_command ON commands(command);",
            on: db
        )

        execute(
            "CREATE INDEX IF NOT EXISTS idx_commands_category ON commands(category);",
            on: db
        )

        execute(
            "CREATE INDEX IF NOT EXISTS idx_commands_favorite ON commands(is_favorite);",
            on: db
        )

        execute(
            "CREATE INDEX IF NOT EXISTS idx_commands_workspace_id ON commands(workspace_id);",
            on: db
        )

        execute(
            "CREATE INDEX IF NOT EXISTS idx_command_contexts_command_id ON command_contexts(command_id);",
            on: db
        )

        execute(
            "CREATE INDEX IF NOT EXISTS idx_command_contexts_env_domain ON command_contexts(env, domain, last_used_at);",
            on: db
        )

        execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_command_contexts_command_key ON command_contexts(command_id, context_key);",
            on: db
        )
    }

    private func ensureColumnExists(
        table: String,
        name: String,
        definition: String,
        on db: OpaquePointer
    ) {
        let columns = columnNames(in: table, on: db)
        guard !columns.contains(name) else { return }

        execute(
            "ALTER TABLE \(table) ADD COLUMN \(name) \(definition);",
            on: db
        )
    }

    private func backfillMissingCategories(on db: OpaquePointer) {
        let columns = columnNames(in: "commands", on: db)
        guard columns.contains("category") else { return }

        let sql = """
        SELECT id, command
        FROM commands
        WHERE category IS NULL;
        """

        guard let statement = prepareStatement(sql, on: db) else { return }
        defer { sqlite3_finalize(statement) }

        var commandRows: [(id: String, command: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let commandPointer = sqlite3_column_text(statement, 1) else {
                continue
            }

            commandRows.append((
                id: String(cString: idPointer),
                command: String(cString: commandPointer)
            ))
        }

        guard !commandRows.isEmpty else { return }

        let updateSQL = "UPDATE commands SET category = ? WHERE id = ?;"
        guard let updateStatement = prepareStatement(updateSQL, on: db) else { return }
        defer { sqlite3_finalize(updateStatement) }

        for row in commandRows {
            sqlite3_reset(updateStatement)
            sqlite3_clear_bindings(updateStatement)

            let category = CommandCategoryResolver.resolveCategory(for: row.command)
            sqlite3_bind_text(
                updateStatement,
                1,
                (category as NSString).utf8String,
                -1,
                sqliteTransientDestructor
            )
            sqlite3_bind_text(
                updateStatement,
                2,
                (row.id as NSString).utf8String,
                -1,
                sqliteTransientDestructor
            )

            guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                assertionFailure("Failed to backfill categories: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
        }
    }

    private func tableExists(_ table: String, on db: OpaquePointer) -> Bool {
        let sql = """
        SELECT 1
        FROM sqlite_master
        WHERE type = 'table' AND name = ?
        LIMIT 1;
        """

        guard let statement = prepareStatement(sql, on: db) else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (table as NSString).utf8String, -1, sqliteTransientDestructor)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columnNames(in table: String, on db: OpaquePointer) -> Set<String> {
        guard tableExists(table, on: db) else { return [] }

        let sql = "PRAGMA table_info(\(table));"
        guard let statement = prepareStatement(sql, on: db) else { return [] }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let namePointer = sqlite3_column_text(statement, 1) else {
                continue
            }

            names.insert(String(cString: namePointer))
        }

        return names
    }

    private func prepareStatement(_ sql: String, on db: OpaquePointer) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            assertionFailure("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return statement
    }

    private func execute(
        _ sql: String,
        on db: OpaquePointer,
        ignoringErrorsContaining expectedMessage: String? = nil
    ) {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result != SQLITE_OK else { return }

        let message = String(cString: sqlite3_errmsg(db))
        if let expectedMessage, message.contains(expectedMessage) {
            return
        }

        assertionFailure("SQLite error: \(message)")
    }

    private static func defaultDatabaseURL() -> URL {
        let baseURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser

        return baseURL
            .appendingPathComponent("CommandHub", isDirectory: true)
            .appendingPathComponent("commandhub.sqlite", isDirectory: false)
    }
}
