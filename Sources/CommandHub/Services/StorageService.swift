import Foundation
import SQLite3

protocol CommandStoring {
    func save(command: String, context: CommandContext?)
    func fetchCandidates(query: String, limit: Int) -> [CommandItem]
    func markUsed(id: String)
    func delete(id: String)
}

final class StorageService: CommandStoring {
    static let shared = StorageService()

    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager = .shared) {
        self.databaseManager = databaseManager
    }

    func save(command: String, context: CommandContext? = nil) {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else { return }

        databaseManager.withConnection { db in
            guard !exists(command: normalizedCommand, in: db) else { return }

            let sql = """
            INSERT INTO commands (id, command, usage_count, last_used_at, created_at, source)
            VALUES (?, ?, 0, NULL, ?, ?);
            """

            guard let statement = prepareStatement(sql, in: db) else { return }
            defer { sqlite3_finalize(statement) }

            bindText(UUID().uuidString, to: statement, at: 1)
            bindText(normalizedCommand, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, Int64(Date().timeIntervalSince1970))

            if let source = sourceValue(from: context) {
                bindText(source, to: statement, at: 4)
            } else {
                sqlite3_bind_null(statement, 4)
            }

            guard sqlite3_step(statement) == SQLITE_DONE else {
                assertionFailure("Failed to insert command: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
        }
    }

    func fetchCandidates(query: String, limit: Int = 200) -> [CommandItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateLimit = max(1, limit)

        return databaseManager.withConnection { db in
            let sql: String
            let bindsPattern = !normalizedQuery.isEmpty

            if bindsPattern {
                sql = """
                SELECT id, command, usage_count, last_used_at, created_at
                FROM commands
                WHERE LOWER(command) LIKE ? ESCAPE '\\'
                ORDER BY usage_count DESC, last_used_at DESC, created_at DESC
                LIMIT ?;
                """
            } else {
                sql = """
                SELECT id, command, usage_count, last_used_at, created_at
                FROM commands
                ORDER BY usage_count DESC, last_used_at DESC, created_at DESC
                LIMIT ?;
                """
            }

            guard let statement = prepareStatement(sql, in: db) else { return [] }
            defer { sqlite3_finalize(statement) }

            var bindIndex: Int32 = 1
            if bindsPattern {
                bindText(subsequenceLikePattern(for: normalizedQuery), to: statement, at: bindIndex)
                bindIndex += 1
            }
            sqlite3_bind_int(statement, bindIndex, Int32(candidateLimit))

            var items: [CommandItem] = []

            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idPointer = sqlite3_column_text(statement, 0),
                      let commandPointer = sqlite3_column_text(statement, 1) else {
                    continue
                }

                let lastUsedAt: TimeInterval?
                if sqlite3_column_type(statement, 3) == SQLITE_NULL {
                    lastUsedAt = nil
                } else {
                    lastUsedAt = TimeInterval(sqlite3_column_int64(statement, 3))
                }

                items.append(
                    CommandItem(
                        id: String(cString: idPointer),
                        command: String(cString: commandPointer),
                        usageCount: Int(sqlite3_column_int(statement, 2)),
                        lastUsedAt: lastUsedAt,
                        createdAt: TimeInterval(sqlite3_column_int64(statement, 4))
                    )
                )
            }

            return items
        }
    }

    func markUsed(id: String) {
        databaseManager.withConnection { db in
            let sql = """
            UPDATE commands
            SET usage_count = usage_count + 1,
                last_used_at = ?
            WHERE id = ?;
            """

            guard let statement = prepareStatement(sql, in: db) else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970))
            bindText(id, to: statement, at: 2)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                assertionFailure("Failed to update usage: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
        }
    }

    func delete(id: String) {
        databaseManager.withConnection { db in
            let sql = "DELETE FROM commands WHERE id = ?;"
            guard let statement = prepareStatement(sql, in: db) else { return }
            defer { sqlite3_finalize(statement) }

            bindText(id, to: statement, at: 1)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                assertionFailure("Failed to delete command: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
        }
    }

    private func exists(command: String, in db: OpaquePointer) -> Bool {
        let sql = "SELECT 1 FROM commands WHERE command = ? LIMIT 1;"
        guard let statement = prepareStatement(sql, in: db) else { return false }
        defer { sqlite3_finalize(statement) }

        bindText(command, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func prepareStatement(_ sql: String, in db: OpaquePointer) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            assertionFailure("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return statement
    }

    private func bindText(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, (text as NSString).utf8String, -1, sqliteTransientDestructor)
    }

    private func subsequenceLikePattern(for query: String) -> String {
        let escaped = query.lowercased().map { character -> String in
            switch character {
            case "%", "_", "\\":
                return "\\\(character)"
            default:
                return String(character)
            }
        }

        return "%\(escaped.joined(separator: "%"))%"
    }

    private func sourceValue(from context: CommandContext?) -> String? {
        guard let url = context?.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }

        return url
    }
}
