import AppKit
import XCTest
@testable import CommandHub

final class LauncherViewModelTests: XCTestCase {
    func testActivateResetsQueryLoadsResultsAndSelectsFirstItem() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()
        let contextResolver = ContextResolverSpy(
            resolution: ContextResolution(
                context: CommandContext(
                    url: "https://prod.example.com",
                    domain: "prod.example.com",
                    env: "prod",
                    sourceApp: "com.google.chrome"
                ),
                status: .webContext(domain: "prod.example.com", env: "prod")
            )
        )

        let expectedItems = [
            makeResult(id: "1", command: "git status"),
            makeResult(id: "2", command: "git checkout")
        ]
        storage.workspaces = [
            CommandWorkspace(id: "workspace-1", name: "Prod", createdAt: 1, commandCount: 2)
        ]
        search.handler = { query, currentContext, scope, filters, sessionBaseline in
            XCTAssertEqual(query, "")
            XCTAssertEqual(currentContext?.domain, "prod.example.com")
            XCTAssertEqual(scope, .all)
            XCTAssertEqual(filters, .default)
            XCTAssertNil(sessionBaseline)
            return expectedItems
        }

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            contextResolver: contextResolver,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )
        viewModel.query = "old"
        viewModel.scope = .currentEnvOnly

        viewModel.activate()

        XCTAssertEqual(viewModel.query, "")
        XCTAssertEqual(viewModel.scope, .all)
        XCTAssertEqual(viewModel.results, expectedItems)
        XCTAssertEqual(viewModel.selection, expectedItems.first?.id)
        XCTAssertEqual(viewModel.contextStatusText, "Current: prod.example.com (prod)")
        XCTAssertTrue(viewModel.isCurrentEnvOnlyAvailable)
        XCTAssertEqual(viewModel.workspaces, storage.workspaces)
    }

    func testCopySelectedOrFirstCopiesMarksMatchedContextWithoutRefreshingResults() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()
        let currentContext = CommandContext(
            url: "https://dev.example.com",
            domain: "dev.example.com",
            env: "dev",
            sourceApp: "com.google.chrome"
        )
        let contextResolver = ContextResolverSpy(
            resolution: ContextResolution(
                context: currentContext,
                status: .webContext(domain: "dev.example.com", env: "dev")
            )
        )

        let item = makeResult(
            id: "selected",
            command: "git status",
            matchedContext: CommandContextStat(
                id: "matched-context",
                contextKey: "com.google.chrome|dev.example.com|dev",
                domain: "dev.example.com",
                url: "https://dev.example.com",
                env: "dev",
                sourceApp: "com.google.chrome",
                captureCount: 1,
                usageCount: 1,
                lastSeenAt: 10,
                lastUsedAt: 10,
                createdAt: 1
            )
        )

        search.handler = { _, _, _, _, _ in [item] }

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            contextResolver: contextResolver,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )
        viewModel.activate()
        viewModel.query = "git"
        viewModel.results = [item]
        viewModel.selection = item.id
        let searchCountBeforeCopy = search.receivedQueries.count

        viewModel.copySelectedOrFirst()

        XCTAssertEqual(clipboard.copiedTexts, [item.command.command])
        XCTAssertEqual(storage.markUsedCalls.count, 1)
        XCTAssertEqual(storage.markUsedCalls.first?.commandID, item.command.id)
        XCTAssertEqual(storage.markUsedCalls.first?.matchedContextID, "matched-context")
        XCTAssertEqual(storage.markUsedCalls.first?.fallbackContext, currentContext)
        XCTAssertEqual(search.receivedQueries.count, searchCountBeforeCopy)
    }

    func testSetScopeFallsBackToAllWhenCurrentEnvOnlyIsUnavailable() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()
        let contextResolver = ContextResolverSpy(
            resolution: ContextResolution(
                context: CommandContext(sourceApp: "com.googlecode.iterm2"),
                status: .noWebContext(appName: "iTerm2")
            )
        )

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            contextResolver: contextResolver,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )

        viewModel.activate()
        viewModel.setScope(.currentEnvOnly)

        XCTAssertEqual(viewModel.scope, .all)
        XCTAssertFalse(viewModel.isCurrentEnvOnlyAvailable)
        XCTAssertEqual(viewModel.contextStatusText, "Current: iTerm2, no web context")
    }

    func testActivateUsesProvidedFrontmostApplicationForContextResolution() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()
        let contextResolver = ContextResolverSpy(
            resolution: ContextResolution(
                context: CommandContext(
                    url: "https://prod.example.com",
                    domain: "prod.example.com",
                    env: "prod",
                    sourceApp: "com.google.chrome"
                ),
                status: .webContext(domain: "prod.example.com", env: "prod")
            )
        )

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            contextResolver: contextResolver,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )

        viewModel.activate(frontmostApplication: NSRunningApplication.current)

        XCTAssertEqual(
            contextResolver.receivedFrontmostApplication?.bundleIdentifier,
            NSRunningApplication.current.bundleIdentifier
        )
        XCTAssertEqual(viewModel.contextStatusText, "Current: prod.example.com (prod)")
    }

    func testSearchUsesSessionBaselineUntilNextActivate() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()
        let currentContext = CommandContext(
            url: "https://dev.example.com",
            domain: "dev.example.com",
            env: "dev",
            sourceApp: "com.google.chrome"
        )
        let contextResolver = ContextResolverSpy(
            resolution: ContextResolution(
                context: currentContext,
                status: .webContext(domain: "dev.example.com", env: "dev")
            )
        )

        let item = makeResult(
            id: "selected",
            command: "git status",
            matchedContext: CommandContextStat(
                id: "matched-context",
                contextKey: "com.google.chrome|dev.example.com|dev",
                domain: "dev.example.com",
                url: "https://dev.example.com",
                env: "dev",
                sourceApp: "com.google.chrome",
                captureCount: 1,
                usageCount: 1,
                lastSeenAt: 10,
                lastUsedAt: 10,
                createdAt: 1
            )
        )

        search.handler = { _, _, _, _, _ in [item] }

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            contextResolver: contextResolver,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )

        viewModel.activate()
        viewModel.results = [item]
        viewModel.copySelectedOrFirst()
        viewModel.search()

        XCTAssertEqual(search.receivedQueries.last?.sessionBaseline?.touchedCommandCount, 1)

        viewModel.activate()

        XCTAssertNil(search.receivedQueries.last?.sessionBaseline)
    }

    func testCopyInvalidatesInFlightSearchResults() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()
        let contextResolver = ContextResolverSpy(
            resolution: ContextResolution(
                context: CommandContext(
                    url: "https://dev.example.com",
                    domain: "dev.example.com",
                    env: "dev",
                    sourceApp: "com.google.chrome"
                ),
                status: .webContext(domain: "dev.example.com", env: "dev")
            )
        )

        let originalFirst = makeResult(id: "1", command: "git alpha")
        let originalSecond = makeResult(id: "2", command: "git beta")
        let reordered = [originalSecond, originalFirst]

        search.handler = { _, _, _, _, _ in reordered }

        var queuedSearchWork: [() -> Void] = []
        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            contextResolver: contextResolver,
            searchExecutor: { queuedSearchWork.append($0) },
            resultExecutor: { $0() }
        )

        viewModel.activate()
        XCTAssertEqual(queuedSearchWork.count, 1)

        viewModel.results = [originalFirst, originalSecond]
        viewModel.selection = originalSecond.id

        viewModel.copySelectedOrFirst()
        queuedSearchWork.removeFirst()()

        XCTAssertEqual(viewModel.results, [originalFirst, originalSecond])
        XCTAssertEqual(viewModel.selection, originalSecond.id)
        XCTAssertEqual(clipboard.copiedTexts, [originalSecond.command.command])
    }

    func testSearchKeepsSelectionWhenSelectedItemStillExists() {
        let kept = makeResult(id: "keep", command: "git status")
        let moved = makeResult(id: "move", command: "git checkout")

        let search = SearchServiceSpy()
        search.handler = { _, _, _, _, _ in [moved, kept] }

        let updatedViewModel = LauncherViewModel(
            storageService: StorageServiceSpy(),
            searchService: search,
            clipboardService: ClipboardSpy(),
            contextResolver: ContextResolverSpy(
                resolution: ContextResolution(context: nil, status: .noWebContext(appName: "Unknown"))
            ),
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )
        updatedViewModel.results = [kept, moved]
        updatedViewModel.selection = kept.id

        updatedViewModel.search()

        XCTAssertEqual(updatedViewModel.selection, kept.id)
    }

    func testSearchFallsBackToAdjacentSelectionWhenSelectedItemDisappears() {
        let search = SearchServiceSpy()
        let first = makeResult(id: "1", command: "git alpha")
        let second = makeResult(id: "2", command: "git beta")
        let third = makeResult(id: "3", command: "git gamma")
        search.handler = { _, _, _, _, _ in [first, third] }

        let viewModel = LauncherViewModel(
            storageService: StorageServiceSpy(),
            searchService: search,
            clipboardService: ClipboardSpy(),
            contextResolver: ContextResolverSpy(
                resolution: ContextResolution(context: nil, status: .noWebContext(appName: "Unknown"))
            ),
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )
        viewModel.results = [first, second, third]
        viewModel.selection = second.id

        viewModel.search()

        XCTAssertEqual(viewModel.selection, third.id)
    }

    private func makeResult(
        id: String,
        command: String,
        matchedContext: CommandContextStat? = nil
    ) -> SearchResultItem {
        let commandItem = CommandItem(
            id: id,
            command: command,
            usageCount: 0,
            lastUsedAt: nil,
            createdAt: 1,
            contexts: matchedContext.map { [$0] } ?? []
        )

        return SearchResultItem(
            command: commandItem,
            matchedContext: matchedContext,
            displayContext: matchedContext,
            score: 1
        )
    }
}

private final class StorageServiceSpy: CommandStoring {
    struct MarkUsedCall: Equatable {
        let commandID: String
        let matchedContextID: String?
        let fallbackContext: CommandContext?
    }

    private(set) var markUsedCalls: [MarkUsedCall] = []
    var workspaces: [CommandWorkspace] = []

    func save(command: String, context: CommandContext?) {}

    func fetchCandidates(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        filters: SearchFilters,
        limit: Int
    ) -> [CommandItem] {
        []
    }

    func markUsed(commandID: String, matchedContextID: String?, fallbackContext: CommandContext?) {
        markUsedCalls.append(
            MarkUsedCall(
                commandID: commandID,
                matchedContextID: matchedContextID,
                fallbackContext: fallbackContext
            )
        )
    }

    func fetchWorkspaces() -> [CommandWorkspace] {
        workspaces
    }

    func delete(id: String) {}
}

private final class SearchServiceSpy: CommandSearching {
    var handler: (String, CommandContext?, SearchScope, SearchFilters, SearchSessionBaseline?) -> [SearchResultItem] = {
        _, _, _, _, _ in []
    }
    private(set) var receivedQueries: [(
        query: String,
        context: CommandContext?,
        scope: SearchScope,
        filters: SearchFilters,
        sessionBaseline: SearchSessionBaseline?
    )] = []

    func search(
        query: String,
        currentContext: CommandContext?,
        scope: SearchScope,
        filters: SearchFilters,
        sessionBaseline: SearchSessionBaseline?
    ) -> [SearchResultItem] {
        receivedQueries.append((query, currentContext, scope, filters, sessionBaseline))
        return handler(query, currentContext, scope, filters, sessionBaseline)
    }
}

private final class ClipboardSpy: ClipboardWriting {
    private(set) var copiedTexts: [String] = []

    func copyToClipboard(_ text: String) {
        copiedTexts.append(text)
    }
}

private final class ContextResolverSpy: ContextResolving {
    let resolution: ContextResolution
    private(set) var receivedFrontmostApplication: NSRunningApplication?

    init(resolution: ContextResolution) {
        self.resolution = resolution
    }

    func resolve() -> ContextResolution {
        resolution
    }

    func resolve(frontmostApplication: NSRunningApplication?) -> ContextResolution {
        receivedFrontmostApplication = frontmostApplication
        return resolution
    }
}
