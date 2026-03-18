import AppKit
import SwiftUI

struct LauncherView: View {
    private enum FocusedField: Hashable {
        case search
        case alias
        case note
    }

    @StateObject private var vm = LauncherViewModel()
    @FocusState private var focusedField: FocusedField?
    @State private var aliasDraft = ""
    @State private var noteDraft = ""
    @State private var lastFocusedField: FocusedField?

    var body: some View {
        GeometryReader { proxy in
            let useVerticalLayout = proxy.size.width < 860

            VStack(spacing: 0) {
                header

                Divider()

                if useVerticalLayout {
                    VStack(spacing: 0) {
                        resultsList
                        Divider()
                        detailPane
                    }
                } else {
                    HStack(spacing: 0) {
                        resultsList
                            .frame(minWidth: 0, maxWidth: .infinity)
                        Divider()
                        detailPane
                            .frame(width: 320)
                    }
                }
            }
            .frame(minWidth: 760, minHeight: 520)
        }
        .onAppear {
            syncEditorDrafts()
            focusSearchField()
        }
        .onChange(of: vm.selection) { _ in
            syncEditorDrafts()
        }
        .onChange(of: focusedField) { newValue in
            commitIfNeeded(leaving: lastFocusedField, next: newValue)
            lastFocusedField = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherActivated)) { notification in
            vm.activate(frontmostApplication: notification.object as? NSRunningApplication)
            syncEditorDrafts()
            focusSearchField()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherFocusSearchRequested)) { _ in
            focusSearchField()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherFocusAliasRequested)) { _ in
            commitActiveEditors()
            syncEditorDrafts()
            focusedField = .alias
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherToggleFavoriteRequested)) { _ in
            commitActiveEditors()
            vm.toggleFavoriteForSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherCopyAndCloseRequested)) { _ in
            commitActiveEditors()
            if vm.copySelectedOrFirst() != nil {
                LauncherWindow.shared.close()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherDeleteRequested)) { _ in
            commitActiveEditors()
            vm.requestDeleteSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspacesDidChange)) { _ in
            vm.reloadWorkspaces()
        }
        .onMoveCommand { direction in
            vm.moveSelection(direction)
        }
        .onExitCommand {
            LauncherWindow.shared.close()
        }
        .alert(
            "Delete Command?",
            isPresented: Binding(
                get: { vm.pendingDeleteItem != nil },
                set: { isPresented in
                    if !isPresented {
                        vm.cancelDeleteSelection()
                    }
                }
            ),
            presenting: vm.pendingDeleteItem
        ) { _ in
            Button("Delete", role: .destructive) {
                vm.confirmDeleteSelection()
            }
            Button("Cancel", role: .cancel) {
                vm.cancelDeleteSelection()
            }
        } message: { item in
            Text(item.command.command)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            TextField("Search commands...", text: $vm.query)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.top, .horizontal])
                .focused($focusedField, equals: .search)
                .onSubmit {
                    commitActiveEditors()
                    _ = vm.copySelectedOrFirst()
                }
                .onChange(of: vm.query) { _ in
                    vm.search()
                }

            HStack(spacing: 12) {
                Text(vm.contextStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Picker(
                    "Scope",
                    selection: Binding(
                        get: { vm.scope },
                        set: { vm.setScope($0) }
                    )
                ) {
                    ForEach(SearchScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(!vm.isCurrentEnvOnlyAvailable)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            filterBar
                .padding(.horizontal)
                .padding(.bottom, 10)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Button("All") {
                vm.resetSecondaryFilters()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(vm.activeFilters.isDefault ? .primary : .secondary)

            FilterChipButton(
                title: "Favorites",
                isSelected: vm.favoritesOnly
            ) {
                vm.setFavoritesOnly(!vm.favoritesOnly)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CommandCategoryResolver.orderedCategories, id: \.self) { category in
                        FilterChipButton(
                            title: category,
                            isSelected: vm.selectedCategory == category
                        ) {
                            vm.setSelectedCategory(vm.selectedCategory == category ? nil : category)
                        }
                    }
                }
            }

            workspaceMenu
        }
    }

    private var workspaceMenu: some View {
        Menu {
            Button("Any Workspace") {
                vm.setSelectedWorkspaceID(nil)
            }

            Divider()

            ForEach(vm.workspaces) { workspace in
                Button {
                    vm.setSelectedWorkspaceID(workspace.id)
                } label: {
                    if vm.selectedWorkspaceID == workspace.id {
                        Label(workspace.name, systemImage: "checkmark")
                    } else {
                        Text(workspace.name)
                    }
                }
            }
        } label: {
            Label(
                vm.workspaces.first(where: { $0.id == vm.selectedWorkspaceID })?.name ?? "Workspace",
                systemImage: "folder"
            )
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.12))
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(vm.workspaces.isEmpty)
    }

    private var resultsList: some View {
        List(selection: $vm.selection) {
            ForEach(vm.results) { item in
                LauncherResultRow(item: item)
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        commitActiveEditors()
                        vm.select(item)
                    }
            }
        }
        .listStyle(.plain)
    }

    private var detailPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item = vm.selectedResult {
                    detailHeader(for: item)
                    detailMetadata(for: item)
                    detailStats(for: item)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Command Selected")
                            .font(.headline)
                        Text("Select a command to inspect details and edit its metadata.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                }
            }
            .padding()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func detailHeader(for item: SearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(
                "Favorite",
                isOn: Binding(
                    get: { item.command.isFavorite },
                    set: { _ in
                        vm.toggleFavoriteForSelection()
                    }
                )
            )
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                Text("Alias")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Add an alias", text: $aliasDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .alias)
                    .onSubmit {
                        commitAliasIfNeeded()
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(item.command.command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.08))
                    )
            }
        }
    }

    private func detailMetadata(for item: SearchResultItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Note")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $noteDraft)
                    .font(.system(.body))
                    .focused($focusedField, equals: .note)
                    .frame(minHeight: 120)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(
                    "Workspace",
                    selection: Binding(
                        get: { item.command.workspaceID ?? "" },
                        set: { workspaceID in
                            vm.assignWorkspaceToSelection(workspaceID.isEmpty ? nil : workspaceID)
                        }
                    )
                ) {
                    Text("None").tag("")
                    ForEach(vm.workspaces) { workspace in
                        Text(workspace.name).tag(workspace.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ContextChip(text: item.command.category)
            }
        }
    }

    private func detailStats(for item: SearchResultItem) -> some View {
        let topContext = item.matchedContext ?? item.displayContext

        return VStack(alignment: .leading, spacing: 12) {
            if let topContext {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top Context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let env = topContext.env {
                            ContextChip(text: env)
                        }
                        if let domain = topContext.domain {
                            ContextChip(text: domain)
                        }
                        if let sourceApp = topContext.sourceAppDisplayName {
                            ContextChip(text: sourceApp)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(item.command.usageCount) uses")
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Last Used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatTimestamp(item.command.lastUsedAt))
                    .font(.body)
            }
        }
    }

    private func focusSearchField() {
        focusedField = .search
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func syncEditorDrafts() {
        aliasDraft = vm.selectedResult?.command.alias ?? ""
        noteDraft = vm.selectedResult?.command.note ?? ""
    }

    private func commitIfNeeded(leaving previous: FocusedField?, next: FocusedField?) {
        if previous == .alias, next != .alias {
            commitAliasIfNeeded()
        }
        if previous == .note, next != .note {
            commitNoteIfNeeded()
        }
    }

    private func commitActiveEditors() {
        commitAliasIfNeeded()
        commitNoteIfNeeded()
    }

    private func commitAliasIfNeeded() {
        guard let currentAlias = vm.selectedResult?.command.alias else {
            if !aliasDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                vm.updateAliasForSelection(aliasDraft)
            }
            return
        }

        if normalizeDraft(aliasDraft) != currentAlias {
            vm.updateAliasForSelection(aliasDraft)
        }
    }

    private func commitNoteIfNeeded() {
        let currentNote = vm.selectedResult?.command.note
        if normalizeDraft(noteDraft) != currentNote {
            vm.updateNoteForSelection(noteDraft)
        }
    }

    private func normalizeDraft(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func formatTimestamp(_ timestamp: TimeInterval?) -> String {
        guard let timestamp else { return "Never" }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: Date())
    }
}

private struct LauncherResultRow: View {
    let item: SearchResultItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.command.alias ?? item.command.command)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.command.command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        ContextChip(text: item.command.category)

                        if let context = item.displayContext {
                            if let env = context.env {
                                ContextChip(text: env)
                            }
                            if let domain = context.domain {
                                ContextChip(text: domain)
                            }
                            if let sourceApp = context.sourceAppDisplayName {
                                ContextChip(text: sourceApp)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if item.command.isFavorite {
                    Text("★")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                Text("\(item.command.usageCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ContextChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.gray.opacity(0.12))
            )
    }
}

private struct FilterChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.gray.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}
