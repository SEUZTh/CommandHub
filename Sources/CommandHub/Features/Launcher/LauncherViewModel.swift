import Foundation
import SwiftUI

final class LauncherViewModel: ObservableObject {
    typealias Executor = (@escaping () -> Void) -> Void

    @Published var query = ""
    @Published var results: [SearchResultItem] = []
    @Published var selection: String?
    @Published var scope: SearchScope = .all
    @Published private(set) var contextStatusText = "Current: Unknown, no web context"
    @Published private(set) var isCurrentEnvOnlyAvailable = false

    private static let defaultSearchQueue = DispatchQueue(
        label: "commandhub.launcher.search",
        qos: .userInitiated
    )

    private let storageService: CommandStoring
    private let searchService: CommandSearching
    private let clipboardService: ClipboardWriting
    private let contextResolver: ContextResolving
    private let searchExecutor: Executor
    private let resultExecutor: Executor

    private var searchGeneration = 0
    private var currentContext: CommandContext?

    init(
        storageService: CommandStoring = StorageService.shared,
        searchService: CommandSearching = SearchService.shared,
        clipboardService: ClipboardWriting = ClipboardService.shared,
        contextResolver: ContextResolving = ContextResolver.shared,
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
        self.contextResolver = contextResolver
        self.searchExecutor = searchExecutor
        self.resultExecutor = resultExecutor
    }

    func activate() {
        query = ""
        selection = nil
        scope = .all
        refreshContext()
        search()
    }

    func setScope(_ newScope: SearchScope) {
        let effectiveScope = newScope == .currentEnvOnly && !isCurrentEnvOnlyAvailable ? .all : newScope
        guard scope != effectiveScope else { return }

        scope = effectiveScope
        search()
    }

    func search() {
        let currentQuery = query
        let currentScope = effectiveSearchScope
        let context = currentContext

        searchGeneration += 1
        let generation = searchGeneration

        searchExecutor { [weak self] in
            guard let self else { return }

            let items = self.searchService.search(
                query: currentQuery,
                currentContext: context,
                scope: currentScope
            )

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

        let item: SearchResultItem
        if let selection, let match = results.first(where: { $0.id == selection }) {
            item = match
        } else {
            item = results[0]
            self.selection = item.id
        }

        select(item)
    }

    func select(_ item: SearchResultItem) {
        selection = item.id
        clipboardService.copyToClipboard(item.command.command)
        storageService.markUsed(
            commandID: item.command.id,
            matchedContextID: item.matchedContext?.id,
            fallbackContext: currentContext
        )
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

    private var effectiveSearchScope: SearchScope {
        isCurrentEnvOnlyAvailable ? scope : .all
    }

    private func refreshContext() {
        let resolution = contextResolver.resolve()
        currentContext = resolution.context
        contextStatusText = resolution.statusText
        isCurrentEnvOnlyAvailable = resolution.canFilterToCurrentEnv

        if !isCurrentEnvOnlyAvailable && scope == .currentEnvOnly {
            scope = .all
        }
    }

    private func updateSelectionIfNeeded() {
        if let selection, results.contains(where: { $0.id == selection }) {
            return
        }
        selection = results.first?.id
    }
}
