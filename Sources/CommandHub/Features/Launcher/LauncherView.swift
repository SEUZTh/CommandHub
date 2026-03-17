import AppKit
import SwiftUI

struct LauncherView: View {
    @StateObject private var vm = LauncherViewModel()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands...", text: $vm.query)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding([.top, .horizontal])
                .focused($isSearchFocused)
                .onSubmit {
                    vm.copySelectedOrFirst()
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

            Divider()

            List(selection: $vm.selection) {
                ForEach(vm.results) { item in
                    LauncherResultRow(item: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.select(item)
                        }
                }
            }
            .listStyle(.plain)
        }
        .frame(width: 620, height: 460)
        .onAppear {
            focusSearchField()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherActivated)) { notification in
            vm.activate(frontmostApplication: notification.object as? NSRunningApplication)
            focusSearchField()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherFocusSearchRequested)) { _ in
            focusSearchField()
        }
        .onMoveCommand { direction in
            vm.moveSelection(direction)
        }
        .onExitCommand {
            LauncherWindow.shared.close()
        }
    }

    private func focusSearchField() {
        isSearchFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}

private struct LauncherResultRow: View {
    let item: SearchResultItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.command.command)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)

            if let context = item.displayContext {
                HStack(spacing: 6) {
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
