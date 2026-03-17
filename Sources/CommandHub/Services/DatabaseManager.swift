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
            execute(
                """
                CREATE TABLE IF NOT EXISTS commands (
                    id TEXT PRIMARY KEY,
                    command TEXT NOT NULL,
                    usage_count INTEGER DEFAULT 0,
                    last_used_at INTEGER,
                    created_at INTEGER NOT NULL,
                    source TEXT
                );
                """,
                on: db
            )

            // Keep pre-release databases compatible if they were created without the reserved column.
            execute(
                "ALTER TABLE commands ADD COLUMN source TEXT;",
                on: db,
                ignoringErrorsContaining: "duplicate column name: source"
            )

            execute(
                "CREATE INDEX IF NOT EXISTS idx_command ON commands(command);",
                on: db
            )
        }
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
