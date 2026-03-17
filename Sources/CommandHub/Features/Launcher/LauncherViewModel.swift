import Foundation
import SwiftUI

final class LauncherViewModel: ObservableObject {
    typealias Executor = (@escaping () -> Void) -> Void

    @Published var query = ""
    @Published var results: [CommandItem] = []
    @Published var selection: String?

    private static let defaultSearchQueue = DispatchQueue(
        label: "commandhub.launcher.search",
        qos: .userInitiated
    )

    private let storageService: CommandStoring
    private let searchService: CommandSearching
    private let clipboardService: ClipboardWriting
    private let searchExecutor: Executor
    private let resultExecutor: Executor

    private var searchGeneration = 0

    init(
        storageService: CommandStoring = StorageService.shared,
        searchService: CommandSearching = SearchService.shared,
        clipboardService: ClipboardWriting = ClipboardService.shared,
        searchExecutor: @escaping Executor = { work in
            defaultSearchQueue.async(execute: work)
        },
        resultExecutor: @escaping Executor = { work in
            DispatchQueue.main.async(execute: work)
        }
    ) {
        self.storageService = storageService
        self.searchService = searchService
        self.clipboardService = clipboardService
        self.searchExecutor = searchExecutor
        self.resultExecutor = resultExecutor
    }

    func activate() {
        query = ""
        selection = nil
        search()
    }

    func search() {
        let currentQuery = query
        searchGeneration += 1
        let generation = searchGeneration

        searchExecutor { [weak self] in
            guard let self else { return }

            let items = self.searchService.search(query: currentQuery)

            self.resultExecutor { [weak self] in
                guard let self else { return }
                guard generation == self.searchGeneration, currentQuery == self.query else { return }

                self.results = items
                self.updateSelectionIfNeeded()
            }
        }
    }

    func copySelectedOrFirst() {
        guard !results.isEmpty else { return }

        let item: CommandItem
        if let selection, let match = results.first(where: { $0.id == selection }) {
            item = match
        } else {
            item = results[0]
            self.selection = item.id
        }

        select(item)
    }

    func select(_ item: CommandItem) {
        selection = item.id
        clipboardService.copyToClipboard(item.command)
        storageService.markUsed(id: item.id)
        search()
    }

    func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }

        let currentIndex = results.firstIndex { $0.id == selection } ?? 0
        let nextIndex: Int

        switch direction {
        case .up:
            nextIndex = max(currentIndex - 1, 0)
        case .down:
            nextIndex = min(currentIndex + 1, results.count - 1)
        default:
            return
        }

        selection = results[nextIndex].id
    }

    private func updateSelectionIfNeeded() {
        if let selection, results.contains(where: { $0.id == selection }) {
            return
        }
        selection = results.first?.id
    }
}
