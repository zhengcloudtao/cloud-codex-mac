import SwiftUI

@main
struct CloudCodexApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("CloudCodex") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .task { await model.start() }
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") { model.showingNewThread = true }
                    .keyboardShortcut("n")
            }
            CommandMenu("会话") {
                Button("刷新") { Task { await model.refreshThreads() } }
                    .keyboardShortcut("r")
            }
        }
    }
}
