import XCTest
@testable import CommandHub

final class LauncherViewModelTests: XCTestCase {
    func testActivateResetsQueryLoadsResultsAndSelectsFirstItem() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()

        let expectedItems = [
            CommandItem(id: "1", command: "git status", usageCount: 0, lastUsedAt: nil, createdAt: 1),
            CommandItem(id: "2", command: "git checkout", usageCount: 0, lastUsedAt: nil, createdAt: 2)
        ]
        search.handler = { query in
            XCTAssertEqual(query, "")
            return expectedItems
        }

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )
        viewModel.query = "old"

        viewModel.activate()

        XCTAssertEqual(viewModel.query, "")
        XCTAssertEqual(viewModel.results, expectedItems)
        XCTAssertEqual(viewModel.selection, expectedItems.first?.id)
    }

    func testCopySelectedOrFirstCopiesMarksUsedAndRefreshesResults() {
        let storage = StorageServiceSpy()
        let clipboard = ClipboardSpy()
        let search = SearchServiceSpy()

        let item = CommandItem(
            id: "selected",
            command: "git status",
            usageCount: 0,
            lastUsedAt: nil,
            createdAt: 1
        )
        search.handler = { _ in [item] }

        let viewModel = LauncherViewModel(
            storageService: storage,
            searchService: search,
            clipboardService: clipboard,
            searchExecutor: { $0() },
            resultExecutor: { $0() }
        )
        viewModel.query = "git"
        viewModel.results = [item]
        viewModel.selection = item.id

        viewModel.copySelectedOrFirst()

        XCTAssertEqual(clipboard.copiedTexts, [item.command])
        XCTAssertEqual(storage.markedUsedIDs, [item.id])
        XCTAssertEqual(search.receivedQueries.suffix(1), ["git"])
    }
}

private final class StorageServiceSpy: CommandStoring {
    private(set) var markedUsedIDs: [String] = []

    func save(command: String, context: CommandContext?) {}

    func fetchCandidates(query: String, limit: Int) -> [CommandItem] {
        []
    }

    func markUsed(id: String) {
        markedUsedIDs.append(id)
    }

    func delete(id: String) {}
}

private final class SearchServiceSpy: CommandSearching {
    var handler: (String) -> [CommandItem] = { _ in [] }
    private(set) var receivedQueries: [String] = []

    func search(query: String) -> [CommandItem] {
        receivedQueries.append(query)
        return handler(query)
    }
}

private final class ClipboardSpy: ClipboardWriting {
    private(set) var copiedTexts: [String] = []

    func copyToClipboard(_ text: String) {
        copiedTexts.append(text)
    }
}
