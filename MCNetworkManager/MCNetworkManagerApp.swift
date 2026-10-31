import SwiftUI

@main
struct MCNetworkManagerApp: App {
    @State private var app = AppModel()
    @State private var monitor = MonitorModel()
    @State private var runner = ProvisionRunner()
    @State private var workspace = TerminalWorkspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(app)
                .environment(monitor)
                .environment(runner)
                .environment(workspace)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await app.syncNow() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(app.session == nil)
            }
        }
    }
}
