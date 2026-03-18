import AppKit
import Foundation
import SwiftUI

final class LauncherViewModel: ObservableObject {
    typealias Executor = (@escaping () -> Void) -> Void

    @Published var query = ""
    @Published var results: [SearchResultItem] = []
    @Published var selection: String?
    @Published var scope: SearchScope = .all
    @Published var favoritesOnly = false
    @Published var selectedCategory: String?
    @Published var selectedWorkspaceID: String?
    @Published private(set) var workspaces: [CommandWorkspace] = []
    @Published private(set) var contextStatusText = "Current: Unknown, no web context"
    @Published private(set) var isCurrentEnvOnlyAvailable = false
    @Published var pendingDeleteItem: SearchResultItem?

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
    private var sessionBaseline = SearchSessionBaseline()

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

    var selectedResult: SearchResultItem? {
        guard let selection else { return nil }
        return results.first(where: { $0.id == selection })
    }

    var selectedWorkspace: CommandWorkspace? {
        guard let workspaceID = selectedResult?.command.workspaceID else { return nil }
        return workspaces.first(where: { $0.id == workspaceID })
    }

    var activeFilters: SearchFilters {
        SearchFilters(
            favoritesOnly: favoritesOnly,
            category: selectedCategory,
            workspaceID: selectedWorkspaceID
        )
    }

    func activate(frontmostApplication: NSRunningApplication? = nil) {
        query = ""
        selection = nil
        scope = .all
        favoritesOnly = false
        selectedCategory = nil
        selectedWorkspaceID = nil
        pendingDeleteItem = nil
        sessionBaseline = SearchSessionBaseline()
        refreshContext(frontmostApplication: frontmostApplication)
        reloadWorkspaces()
        search()
    }

    func reloadWorkspaces() {
        workspaces = storageService.fetchWorkspaces()

        if let selectedWorkspaceID,
           !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            self.selectedWorkspaceID = nil
            search()
        }
    }

    func setScope(_ newScope: SearchScope) {
        let effectiveScope = newScope == .currentEnvOnly && !isCurrentEnvOnlyAvailable ? .all : newScope
        guard scope != effectiveScope else { return }

        scope = effectiveScope
        search()
    }

    func setFavoritesOnly(_ enabled: Bool) {
        guard favoritesOnly != enabled else { return }
        favoritesOnly = enabled
        search()
    }

    func setSelectedCategory(_ category: String?) {
        guard selectedCategory != category else { return }
        selectedCategory = category
        search()
    }

    func setSelectedWorkspaceID(_ workspaceID: String?) {
        guard selectedWorkspaceID != workspaceID else { return }
        selectedWorkspaceID = workspaceID
        search()
    }

    func resetSecondaryFilters() {
        guard !activeFilters.isDefault else { return }
        favoritesOnly = false
        selectedCategory = nil
        selectedWorkspaceID = nil
        search()
    }

    func search() {
        let currentQuery = query
        let currentScope = effectiveSearchScope
        let context = currentContext
        let filters = activeFilters
        let sessionBaseline = self.sessionBaseline.isEmpty ? nil : self.sessionBaseline
        let previousSelection = selection
        let previousIndex = previousSelection.flatMap { selectedID in
            results.firstIndex(where: { $0.id == selectedID })
        }

        searchGeneration += 1
        let generation = searchGeneration

        searchExecutor { [weak self] in
            guard let self else { return }

            let items = self.searchService.search(
                query: currentQuery,
                currentContext: context,
                scope: currentScope,
                filters: filters,
                sessionBaseline: sessionBaseline
            )

            self.resultExecutor { [weak self] in
                guard let self else { return }
                guard generation == self.searchGeneration, currentQuery == self.query else { return }

                self.results = items
                self.updateSelectionIfNeeded(
                    previousSelection: previousSelection,
                    previousIndex: previousIndex
                )
            }
        }
    }

    @discardableResult
    func copySelectedOrFirst() -> SearchResultItem? {
        guard !results.isEmpty else { return nil }

        let item: SearchResultItem
        if let selection, let match = results.first(where: { $0.id == selection }) {
            item = match
        } else {
            item = results[0]
            self.selection = item.id
        }

        searchGeneration += 1
        selection = item.id
        sessionBaseline.recordSelection(item, currentContext: currentContext)
        clipboardService.copyToClipboard(item.command.command)
        storageService.markUsed(
            commandID: item.command.id,
            matchedContextID: item.matchedContext?.id,
            fallbackContext: currentContext
        )

        return item
    }

    func select(_ item: SearchResultItem) {
        selection = item.id
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

    func toggleFavoriteForSelection() {
        guard let item = selectedResult else { return }
        storageService.toggleFavorite(commandID: item.command.id)
        search()
    }

    func updateAliasForSelection(_ alias: String?) {
        guard let item = selectedResult else { return }
        storageService.updateAlias(commandID: item.command.id, alias: alias)
        search()
    }

    func updateNoteForSelection(_ note: String?) {
        guard let item = selectedResult else { return }
        storageService.updateNote(commandID: item.command.id, note: note)
        search()
    }

    func assignWorkspaceToSelection(_ workspaceID: String?) {
        guard let item = selectedResult else { return }
        storageService.assignWorkspace(commandID: item.command.id, workspaceID: workspaceID)
        reloadWorkspaces()
        search()
    }

    func requestDeleteSelection() {
        pendingDeleteItem = selectedResult
    }

    func cancelDeleteSelection() {
        pendingDeleteItem = nil
    }

    func confirmDeleteSelection() {
        guard let item = pendingDeleteItem else { return }
        pendingDeleteItem = nil
        storageService.delete(id: item.command.id)
        reloadWorkspaces()
        search()
    }

    private var effectiveSearchScope: SearchScope {
        isCurrentEnvOnlyAvailable ? scope : .all
    }

    private func refreshContext(frontmostApplication: NSRunningApplication? = nil) {
        let resolution = contextResolver.resolve(frontmostApplication: frontmostApplication)
        currentContext = resolution.context
        contextStatusText = resolution.statusText
        isCurrentEnvOnlyAvailable = resolution.canFilterToCurrentEnv

        if !isCurrentEnvOnlyAvailable && scope == .currentEnvOnly {
            scope = .all
        }
    }

    private func updateSelectionIfNeeded(previousSelection: String?, previousIndex: Int?) {
        if let selection, results.contains(where: { $0.id == selection }) {
            return
        }

        if let previousSelection,
           results.contains(where: { $0.id == previousSelection }) {
            selection = previousSelection
            return
        }

        if let previousIndex, !results.isEmpty {
            let clampedIndex = min(previousIndex, results.count - 1)
            selection = results[clampedIndex].id
            return
        }

        selection = results.first?.id
    }
}
