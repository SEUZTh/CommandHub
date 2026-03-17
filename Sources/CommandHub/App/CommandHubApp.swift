import SwiftUI

@main
struct CommandHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("Settings")
                .frame(width: 300, height: 200)
        }
    }
}
