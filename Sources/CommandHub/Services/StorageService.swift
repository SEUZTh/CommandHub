import Foundation
import SQLite3

protocol CommandStoring {
    func save(command: String, context: CommandContext?)
    func fetchCandidates(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        limit: Int
    ) -> [CommandItem]
    func markUsed(commandID: String, matchedContextID: String?, fallbackContext: CommandContext?)
    func delete(id: String)
}

extension CommandStoring {
    func fetchCandidates(query: String, limit: Int = 200) -> [CommandItem] {
        fetchCandidates(query: query, currentContext: nil, scope: .all, limit: limit)
    }

    func markUsed(id: String) {
        markUsed(commandID: id, matchedContextID: nil, fallbackContext: nil)
    }
}

final class StorageService: CommandStoring {
    static let shared = StorageService()

    private struct PersistedContext {
        let contextKey: String
        let domain: String?
        let url: String?
        let env: String?
        let sourceApp: String?
    }

    private enum ContextFilter {
        case domain(String)
        case env(String)
    }

    private let databaseManager: DatabaseManager

    init(databaseManager: DatabaseManager = .shared) {
        self.databaseManager = databaseManager
    }

    func save(command: String, context: CommandContext? = nil) {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else { return }

        databaseManager.withConnection { db in
            let now = Int64(Date().timeIntervalSince1970)
            let commandID = fetchOrInsertCommandID(command: normalizedCommand, now: now, in: db)

            guard let persistedContext = persistedContext(from: context) else { return }
            upsertCapturedContext(
                commandID: commandID,
                context: persistedContext,
                now: now,
                in: db
            )
        }
    }

    func fetchCandidates(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        limit: Int = 200
    ) -> [CommandItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateLimit = max(1, limit)

        return databaseManager.withConnection { db in
            let ids: [String]
            let filter = contextFilter(from: currentContext)

            switch scope {
            case .all:
                if let filter {
                    let contextIDs = fetchContextCandidateIDs(
                        query: normalizedQuery,
                        filter: filter,
                        limit: min(100, candidateLimit),
                        in: db
                    )
                    let globalIDs = fetchGlobalCandidateIDs(
                        query: normalizedQuery,
                        limit: candidateLimit,
                        in: db
                    )
                    ids = mergeCandidateIDs(
                        prioritized: contextIDs,
                        fallback: globalIDs,
                        limit: candidateLimit
                    )
                } else {
                    ids = fetchGlobalCandidateIDs(
                        query: normalizedQuery,
                        limit: candidateLimit,
                        in: db
                    )
                }
            case .currentEnvOnly:
                guard let filter else { return [] }
                let contextIDs = fetchContextCandidateIDs(
                    query: normalizedQuery,
                    filter: filter,
                    limit: candidateLimit,
                    in: db
                )
                let globalIDs = fetchGlobalCandidateIDs(
                    query: normalizedQuery,
                    limit: candidateLimit,
                    in: db
                )
                ids = mergeCandidateIDs(
                    prioritized: contextIDs,
                    fallback: globalIDs,
                    limit: candidateLimit
                )
            }

            return fetchCommandItems(ids: ids, in: db)
        }
    }

    func markUsed(
        commandID: String,
        matchedContextID: String?,
        fallbackContext: CommandContext?
    ) {
        databaseManager.withConnection { db in
            let now = Int64(Date().timeIntervalSince1970)
            incrementCommandUsage(commandID: commandID, now: now, in: db)

            if let matchedContextID {
                incrementExistingContextUsage(contextID: matchedContextID, now: now, in: db)
                return
            }

            guard let persistedContext = persistedContext(from: fallbackContext) else { return }
            upsertUsageContext(commandID: commandID, context: persistedContext, now: now, in: db)
        }
    }

    func delete(id: String) {
        databaseManager.withConnection { db in
            executeDelete(
                sql: "DELETE FROM command_contexts WHERE command_id = ?;",
                value: id,
                in: db
            )
            executeDelete(
                sql: "DELETE FROM commands WHERE id = ?;",
                value: id,
                in: db
            )
        }
    }

    private func fetchOrInsertCommandID(command: String, now: Int64, in db: OpaquePointer) -> String {
        if let existingID = fetchCommandID(command: command, in: db) {
            return existingID
        }

        let id = UUID().uuidString
        let sql = """
        INSERT INTO commands (id, command, usage_count, last_used_at, created_at)
        VALUES (?, ?, 0, NULL, ?);
        """

        guard let statement = prepareStatement(sql, in: db) else {
            return id
        }
        defer { sqlite3_finalize(statement) }

        bindText(id, to: statement, at: 1)
        bindText(command, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, now)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            assertionFailure("Failed to insert command: \(String(cString: sqlite3_errmsg(db)))")
            return id
        }

        return id
    }

    private func fetchCommandID(command: String, in db: OpaquePointer) -> String? {
        let sql = "SELECT id FROM commands WHERE command = ? LIMIT 1;"
        guard let statement = prepareStatement(sql, in: db) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindText(command, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let idPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: idPointer)
    }

    private func incrementCommandUsage(commandID: String, now: Int64, in db: OpaquePointer) {
        let sql = """
        UPDATE commands
        SET usage_count = usage_count + 1,
            last_used_at = ?
        WHERE id = ?;
        """

        guard let statement = prepareStatement(sql, in: db) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, now)
        bindText(commandID, to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            assertionFailure("Failed to update usage: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func incrementExistingContextUsage(contextID: String, now: Int64, in db: OpaquePointer) {
        let sql = """
        UPDATE command_contexts
        SET usage_count = usage_count + 1,
            last_used_at = ?
        WHERE id = ?;
        """

        guard let statement = prepareStatement(sql, in: db) else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, now)
        bindText(contextID, to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            assertionFailure("Failed to update context usage: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func upsertCapturedContext(
        commandID: String,
        context: PersistedContext,
        now: Int64,
        in db: OpaquePointer
    ) {
        if let existingID = fetchContextID(commandID: commandID, contextKey: context.contextKey, in: db) {
            let sql = """
            UPDATE command_contexts
            SET capture_count = capture_count + 1,
                last_seen_at = ?,
                url = ?,
                domain = ?,
                env = ?,
                source_app = ?
            WHERE id = ?;
            """

            guard let statement = prepareStatement(sql, in: db) else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, now)
            bindOptionalText(context.url, to: statement, at: 2)
            bindOptionalText(context.domain, to: statement, at: 3)
            bindOptionalText(context.env, to: statement, at: 4)
            bindOptionalText(context.sourceApp, to: statement, at: 5)
            bindText(existingID, to: statement, at: 6)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                assertionFailure("Failed to update captured context: \(String(cString: sqlite3_errmsg(db)))")
                return
            }

            return
        }

        insertContext(
            id: UUID().uuidString,
            commandID: commandID,
            context: context,
            captureCount: 1,
            usageCount: 0,
            lastSeenAt: now,
            lastUsedAt: nil,
            createdAt: now,
            in: db
        )
    }

    private func upsertUsageContext(
        commandID: String,
        context: PersistedContext,
        now: Int64,
        in db: OpaquePointer
    ) {
        if let existingID = fetchContextID(commandID: commandID, contextKey: context.contextKey, in: db) {
            let sql = """
            UPDATE command_contexts
            SET usage_count = usage_count + 1,
                last_used_at = ?,
                url = COALESCE(?, url),
                domain = COALESCE(?, domain),
                env = COALESCE(?, env),
                source_app = COALESCE(?, source_app)
            WHERE id = ?;
            """

            guard let statement = prepareStatement(sql, in: db) else { return }
            defer { sqlite3_finalize(statement) }

            sqlite3_bind_int64(statement, 1, now)
            bindOptionalText(context.url, to: statement, at: 2)
            bindOptionalText(context.domain, to: statement, at: 3)
            bindOptionalText(context.env, to: statement, at: 4)
            bindOptionalText(context.sourceApp, to: statement, at: 5)
            bindText(existingID, to: statement, at: 6)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                assertionFailure("Failed to upsert used context: \(String(cString: sqlite3_errmsg(db)))")
                return
            }

            return
        }

        insertContext(
            id: UUID().uuidString,
            commandID: commandID,
            context: context,
            captureCount: 0,
            usageCount: 1,
            lastSeenAt: nil,
            lastUsedAt: now,
            createdAt: now,
            in: db
        )
    }

    private func insertContext(
        id: String,
        commandID: String,
        context: PersistedContext,
        captureCount: Int,
        usageCount: Int,
        lastSeenAt: Int64?,
        lastUsedAt: Int64?,
        createdAt: Int64,
        in db: OpaquePointer
    ) {
        let sql = """
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
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        guard let statement = prepareStatement(sql, in: db) else { return }
        defer { sqlite3_finalize(statement) }

        bindText(id, to: statement, at: 1)
        bindText(commandID, to: statement, at: 2)
        bindText(context.contextKey, to: statement, at: 3)
        bindOptionalText(context.domain, to: statement, at: 4)
        bindOptionalText(context.url, to: statement, at: 5)
        bindOptionalText(context.env, to: statement, at: 6)
        bindOptionalText(context.sourceApp, to: statement, at: 7)
        sqlite3_bind_int(statement, 8, Int32(captureCount))
        sqlite3_bind_int(statement, 9, Int32(usageCount))
        bindOptionalInt64(lastSeenAt, to: statement, at: 10)
        bindOptionalInt64(lastUsedAt, to: statement, at: 11)
        sqlite3_bind_int64(statement, 12, createdAt)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            assertionFailure("Failed to insert context: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func fetchContextID(commandID: String, contextKey: String, in db: OpaquePointer) -> String? {
        let sql = """
        SELECT id
        FROM command_contexts
        WHERE command_id = ? AND context_key = ?
        LIMIT 1;
        """

        guard let statement = prepareStatement(sql, in: db) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindText(commandID, to: statement, at: 1)
        bindText(contextKey, to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let idPointer = sqlite3_column_text(statement, 0) else {
            return nil
        }

        return String(cString: idPointer)
    }

    private func fetchGlobalCandidateIDs(
        query: String,
        limit: Int,
        in db: OpaquePointer
    ) -> [String] {
        let bindsPattern = !query.isEmpty
        let sql: String

        if bindsPattern {
            sql = """
            SELECT id
            FROM commands
            WHERE LOWER(command) LIKE ? ESCAPE '\\'
            ORDER BY usage_count DESC, last_used_at DESC, created_at DESC
            LIMIT ?;
            """
        } else {
            sql = """
            SELECT id
            FROM commands
            ORDER BY usage_count DESC, last_used_at DESC, created_at DESC
            LIMIT ?;
            """
        }

        guard let statement = prepareStatement(sql, in: db) else { return [] }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if bindsPattern {
            bindText(subsequenceLikePattern(for: query), to: statement, at: bindIndex)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        return fetchIDRows(from: statement)
    }

    private func fetchContextCandidateIDs(
        query: String,
        filter: ContextFilter,
        limit: Int,
        in db: OpaquePointer
    ) -> [String] {
        let bindsPattern = !query.isEmpty
        let filterClause: String

        switch filter {
        case .domain:
            filterClause = "cc.domain = ?"
        case .env:
            filterClause = "LOWER(cc.env) = ?"
        }

        let sql = """
        SELECT c.id
        FROM commands c
        JOIN command_contexts cc ON cc.command_id = c.id
        WHERE \(bindsPattern ? "LOWER(c.command) LIKE ? ESCAPE '\\\\' AND " : "")\(filterClause)
        GROUP BY c.id
        ORDER BY
            MAX(cc.usage_count) DESC,
            MAX(COALESCE(cc.last_used_at, 0)) DESC,
            MAX(COALESCE(cc.last_seen_at, 0)) DESC,
            c.usage_count DESC,
            COALESCE(c.last_used_at, 0) DESC,
            c.created_at DESC
        LIMIT ?;
        """

        guard let statement = prepareStatement(sql, in: db) else { return [] }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if bindsPattern {
            bindText(subsequenceLikePattern(for: query), to: statement, at: bindIndex)
            bindIndex += 1
        }

        switch filter {
        case let .domain(domain):
            bindText(domain, to: statement, at: bindIndex)
        case let .env(env):
            bindText(env, to: statement, at: bindIndex)
        }

        sqlite3_bind_int(statement, bindIndex + 1, Int32(limit))
        return fetchIDRows(from: statement)
    }

    private func fetchIDRows(from statement: OpaquePointer?) -> [String] {
        var ids: [String] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0) else {
                continue
            }

            ids.append(String(cString: idPointer))
        }

        return ids
    }

    private func mergeCandidateIDs(prioritized: [String], fallback: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for id in prioritized where seen.insert(id).inserted {
            merged.append(id)
            if merged.count == limit { return merged }
        }

        for id in fallback where seen.insert(id).inserted {
            merged.append(id)
            if merged.count == limit { return merged }
        }

        return merged
    }

    private func fetchCommandItems(ids: [String], in db: OpaquePointer) -> [CommandItem] {
        guard !ids.isEmpty else { return [] }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")

        let commandsSQL = """
        SELECT id, command, usage_count, last_used_at, created_at
        FROM commands
        WHERE id IN (\(placeholders));
        """

        guard let commandsStatement = prepareStatement(commandsSQL, in: db) else { return [] }
        defer { sqlite3_finalize(commandsStatement) }

        bindTexts(ids, to: commandsStatement)

        struct CommandRow {
            let id: String
            let command: String
            let usageCount: Int
            let lastUsedAt: TimeInterval?
            let createdAt: TimeInterval
        }

        var commandRowsByID: [String: CommandRow] = [:]
        while sqlite3_step(commandsStatement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(commandsStatement, 0),
                  let commandPointer = sqlite3_column_text(commandsStatement, 1) else {
                continue
            }

            let id = String(cString: idPointer)
            commandRowsByID[id] = CommandRow(
                id: id,
                command: String(cString: commandPointer),
                usageCount: Int(sqlite3_column_int(commandsStatement, 2)),
                lastUsedAt: readNullableTime(at: 3, from: commandsStatement),
                createdAt: TimeInterval(sqlite3_column_int64(commandsStatement, 4))
            )
        }

        let contextsSQL = """
        SELECT
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
        FROM command_contexts
        WHERE command_id IN (\(placeholders))
        ORDER BY usage_count DESC, last_used_at DESC, last_seen_at DESC, created_at DESC;
        """

        guard let contextsStatement = prepareStatement(contextsSQL, in: db) else {
            return ids.compactMap { commandID in
                guard let row = commandRowsByID[commandID] else { return nil }
                return CommandItem(
                    id: row.id,
                    command: row.command,
                    usageCount: row.usageCount,
                    lastUsedAt: row.lastUsedAt,
                    createdAt: row.createdAt,
                    contexts: []
                )
            }
        }
        defer { sqlite3_finalize(contextsStatement) }

        bindTexts(ids, to: contextsStatement)

        var contextsByCommandID: [String: [CommandContextStat]] = [:]
        while sqlite3_step(contextsStatement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(contextsStatement, 0),
                  let commandIDPointer = sqlite3_column_text(contextsStatement, 1),
                  let contextKeyPointer = sqlite3_column_text(contextsStatement, 2) else {
                continue
            }

            let commandID = String(cString: commandIDPointer)
            let stat = CommandContextStat(
                id: String(cString: idPointer),
                contextKey: String(cString: contextKeyPointer),
                domain: readNullableText(at: 3, from: contextsStatement),
                url: readNullableText(at: 4, from: contextsStatement),
                env: readNullableText(at: 5, from: contextsStatement),
                sourceApp: readNullableText(at: 6, from: contextsStatement),
                captureCount: Int(sqlite3_column_int(contextsStatement, 7)),
                usageCount: Int(sqlite3_column_int(contextsStatement, 8)),
                lastSeenAt: readNullableTime(at: 9, from: contextsStatement),
                lastUsedAt: readNullableTime(at: 10, from: contextsStatement),
                createdAt: TimeInterval(sqlite3_column_int64(contextsStatement, 11))
            )

            contextsByCommandID[commandID, default: []].append(stat)
        }

        return ids.compactMap { commandID in
            guard let row = commandRowsByID[commandID] else { return nil }

            return CommandItem(
                id: row.id,
                command: row.command,
                usageCount: row.usageCount,
                lastUsedAt: row.lastUsedAt,
                createdAt: row.createdAt,
                contexts: contextsByCommandID[commandID] ?? []
            )
        }
    }

    private func executeDelete(sql: String, value: String, in db: OpaquePointer) {
        guard let statement = prepareStatement(sql, in: db) else { return }
        defer { sqlite3_finalize(statement) }

        bindText(value, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            assertionFailure("Failed to delete row: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
    }

    private func prepareStatement(_ sql: String, in db: OpaquePointer) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            assertionFailure("Failed to prepare statement: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        return statement
    }

    private func bindTexts(_ texts: [String], to statement: OpaquePointer?) {
        for (index, text) in texts.enumerated() {
            bindText(text, to: statement, at: Int32(index + 1))
        }
    }

    private func bindText(_ text: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, (text as NSString).utf8String, -1, sqliteTransientDestructor)
    }

    private func bindOptionalText(_ text: String?, to statement: OpaquePointer?, at index: Int32) {
        guard let text else {
            sqlite3_bind_null(statement, index)
            return
        }

        bindText(text, to: statement, at: index)
    }

    private func bindOptionalInt64(_ value: Int64?, to statement: OpaquePointer?, at index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }

        sqlite3_bind_int64(statement, index, value)
    }

    private func readNullableText(at index: Int32, from statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }

        return String(cString: pointer)
    }

    private func readNullableTime(at index: Int32, from statement: OpaquePointer?) -> TimeInterval? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }

        return TimeInterval(sqlite3_column_int64(statement, index))
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

    private func contextFilter(from context: CommandContext?) -> ContextFilter? {
        if let domain = context?.domain {
            return .domain(domain)
        }

        if let env = context?.env {
            guard let normalizedEnv = CommandContext.normalizeEnvKey(env) else {
                return nil
            }
            return .env(normalizedEnv)
        }

        return nil
    }

    private func persistedContext(from context: CommandContext?) -> PersistedContext? {
        guard let context else { return nil }
        guard let contextKey = context.contextKey else { return nil }

        return PersistedContext(
            contextKey: contextKey,
            domain: CommandContext.normalizeDomain(context.domain) ?? CommandContext.normalizeDomain(from: context.url),
            url: CommandContext.normalizeURL(context.url),
            env: CommandContext.normalizeEnv(context.env),
            sourceApp: CommandContext.normalizeSourceAppKey(context.sourceApp)
        )
    }
}
