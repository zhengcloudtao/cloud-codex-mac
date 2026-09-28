import SwiftUI

@main
struct CloudCodexApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updateController = CloudCodexUpdateController()
    @StateObject private var sparkleUpdater = CloudCodexSparkleUpdater()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("CloudCodex") {
            ContentView()
                .environmentObject(model)
                // CloudCodex is a three-column application.  Keeping enough
                // room for every column prevents a selected long conversation
                // from forcing the workspace column into a compressed layout.
                .frame(minWidth: 1_140, minHeight: 640)
                .task { await model.start() }
                .task { await updateController.check() }
                .sheet(item: $updateController.notice) { notice in
                    CloudCodexUpdateSheet(notice: notice) {
                        sparkleUpdater.checkForUpdates()
                    }
                }
        }
        .defaultSize(width: 1220, height: 780)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 CloudCodex") { openWindow(id: "about-cloudcodex") }
                Divider()
                Button("检查更新…") {
                    sparkleUpdater.checkForUpdates()
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("新建会话", action: model.prepareNewThread)
                    .keyboardShortcut("n")
            }
            CommandMenu("会话") {
                Button("刷新") { Task { await model.refreshThreads() } }
                    .keyboardShortcut("r")
            }
        }
        Window("关于 CloudCodex", id: "about-cloudcodex") {
            AboutCloudCodexView()
        }
        .defaultSize(width: 620, height: 700)
        .windowResizability(.contentMinSize)
    }
}
