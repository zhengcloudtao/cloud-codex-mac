import SwiftUI

@main
struct CloudCodexApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("CloudCodex") {
            ContentView()
                .environmentObject(model)
                // CloudCodex is a three-column application.  Keeping enough
                // room for every column prevents a selected long conversation
                // from forcing the workspace column into a compressed layout.
                .frame(minWidth: 1_140, minHeight: 640)
                .task { await model.start() }
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话", action: model.prepareNewThread)
                    .keyboardShortcut("n")
            }
            CommandMenu("会话") {
                Button("刷新") { Task { await model.refreshThreads() } }
                    .keyboardShortcut("r")
            }
        }
    }
}
