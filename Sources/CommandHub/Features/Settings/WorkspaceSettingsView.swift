import SwiftUI

struct WorkspaceSettingsView: View {
    @State private var workspaces: [CommandWorkspace] = []
    @State private var draftNames: [String: String] = [:]
    @State private var newWorkspaceName = ""
    @State private var errorMessage: String?

    private let storageService: CommandStoring

    init(storageService: CommandStoring = StorageService.shared) {
        self.storageService = storageService
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspaces")
                    .font(.title2.weight(.semibold))
                Text("Manage reusable project and system buckets for command assignment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("New workspace name", text: $newWorkspaceName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        createWorkspace()
                    }

                Button("Add") {
                    createWorkspace()
                }
                .keyboardShortcut(.defaultAction)
            }

            if workspaces.isEmpty {
                Text("No workspaces yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(workspaces) { workspace in
                        HStack(spacing: 12) {
                            TextField(
                                "Workspace name",
                                text: Binding(
                                    get: { draftNames[workspace.id] ?? workspace.name },
                                    set: { draftNames[workspace.id] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)

                            Text("\(workspace.commandCount) commands")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 100, alignment: .leading)

                            Button("Save") {
                                renameWorkspace(workspace)
                            }
                            .disabled((draftNames[workspace.id] ?? workspace.name) == workspace.name)

                            Button("Delete", role: .destructive) {
                                storageService.deleteWorkspace(id: workspace.id)
                                reload()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
        .onAppear {
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .workspacesDidChange)) { _ in
            reload()
        }
        .alert(
            "Workspace Error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reload() {
        workspaces = storageService.fetchWorkspaces()
        draftNames = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.name) })
    }

    private func createWorkspace() {
        do {
            _ = try storageService.createWorkspace(name: newWorkspaceName)
            newWorkspaceName = ""
            reload()
        } catch WorkspaceStoreError.emptyName {
            errorMessage = "Workspace name cannot be empty."
        } catch WorkspaceStoreError.duplicateName {
            errorMessage = "Workspace name already exists."
        } catch {
            errorMessage = "Failed to create workspace."
        }
    }

    private func renameWorkspace(_ workspace: CommandWorkspace) {
        do {
            try storageService.renameWorkspace(
                id: workspace.id,
                name: draftNames[workspace.id] ?? workspace.name
            )
            reload()
        } catch WorkspaceStoreError.emptyName {
            errorMessage = "Workspace name cannot be empty."
        } catch WorkspaceStoreError.duplicateName {
            errorMessage = "Workspace name already exists."
            draftNames[workspace.id] = workspace.name
        } catch {
            errorMessage = "Failed to rename workspace."
            draftNames[workspace.id] = workspace.name
        }
    }
}
