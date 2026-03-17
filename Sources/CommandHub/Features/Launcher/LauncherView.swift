import SwiftUI

struct LauncherView: View {
    @StateObject private var vm = LauncherViewModel()
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands...", text: $vm.query)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .padding()
                .focused($isSearchFocused)
                .onSubmit {
                    vm.copySelectedOrFirst()
                }

            List(selection: $vm.selection) {
                ForEach(vm.filteredCommands) { item in
                    Text(item.command)
                        .tag(item.id)
                        .onTapGesture {
                            vm.selection = item.id
                            vm.copy(item)
                        }
                }
            }
        }
        .frame(width: 500, height: 400)
        .onAppear {
            isSearchFocused = true
            vm.selection = vm.filteredCommands.first?.id
        }
        .onMoveCommand { direction in
            vm.moveSelection(direction)
        }
        .onExitCommand {
            LauncherWindow.shared.close()
        }
    }
}
