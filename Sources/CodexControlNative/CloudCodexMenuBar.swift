import AppKit
import SwiftUI

struct CloudCodexMenuBarIcon: View {
    let isRunning: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: statusImage)
            .renderingMode(.original)
            .accessibilityLabel(isRunning ? "CloudCodex · 有任务正在执行" : "CloudCodex · 空闲")
    }

    private var statusImage: NSImage {
        let foreground: NSColor = colorScheme == .dark ? .white : .black
        let symbol = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [foreground]))
        // Render as a non-template image so macOS preserves the purple dot.
        // Reserve the same width in both states to keep adjacent icons steady.
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { rect in
            symbol?.draw(in: NSRect(x: 0, y: 2, width: 18, height: 14))
            if isRunning {
                NSColor.systemPurple.setFill()
                NSBezierPath(ovalIn: NSRect(x: 22, y: 6.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct CloudCodexMenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开 CloudCodex", action: showMainWindow)
        Divider()
        if model.menuBarTasks.isEmpty {
            Text("暂无正在执行的任务")
        } else {
            Text("正在执行 · \(model.menuBarTasks.count) 个任务")
            ForEach(model.menuBarTasks) { task in
                Menu {
                    Button("打开会话") {
                        model.selectThread(task.id)
                        showMainWindow()
                    }
                    Button(model.menuBarStoppingThreadIDs.contains(task.id) ? "正在停止…" : "停止任务") {
                        Task { await model.stopMenuBarTask(task.id) }
                    }
                    .disabled(model.menuBarStoppingThreadIDs.contains(task.id))
                } label: {
                    Label(task.title, systemImage: "circle.dotted.circle")
                }
            }
        }
        if let error = model.errorMessage {
            Divider()
            Text(error)
        }
        Divider()
        Button("退出 CloudCodex") { NSApplication.shared.terminate(nil) }
    }

    private func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: {
            $0.identifier == CloudCodexMainWindowRegistration.identifier
        }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "cloudcodex-main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// Mark only product windows, so menu actions never bring About or a panel
/// forward in place of the conversation window.
struct CloudCodexMainWindowRegistration: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("CloudCodex.MainWindow")

    func makeNSView(context: Context) -> NSView { WindowMarker() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowMarker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.identifier = CloudCodexMainWindowRegistration.identifier
        }
    }
}
