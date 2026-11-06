import AppKit
import SwiftUI
import Quartz

struct LocalFilePreviewTarget: Identifiable {
    let url: URL
    var id: String { url.path }
    var isMarkdown: Bool { ["md", "markdown"].contains(url.pathExtension.lowercased()) }

    static func resolve(_ url: URL, cwd: String?) -> Self? {
        guard url.scheme == nil || url.isFileURL else { return nil }
        guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        // Source citations may end in :line or :line:column; those are not filenames.
        let path = url.path.replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return Self(url: URL(fileURLWithPath: path)) }
        guard let cwd else { return nil }
        return Self(url: URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(path).standardizedFileURL)
    }

    static func readText(_ url: URL) throws -> String? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 2 * 1024 * 1024
        let data = try handle.read(upToCount: limit) ?? Data()
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text + ((values.fileSize ?? 0) > limit ? "\n\n—— 文件较大，仅预览前 2 MB ——" : "")
    }
}

@MainActor
final class LocalFilePreviewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(_ target: LocalFilePreviewTarget) {
        let previewWindow: NSWindow
        if let window {
            previewWindow = window
        } else {
            previewWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            previewWindow.isReleasedWhenClosed = false
            previewWindow.delegate = self
            window = previewWindow
            previewWindow.center()
        }
        previewWindow.title = target.url.lastPathComponent
        let size = previewWindow.frame.size
        previewWindow.contentViewController = NSHostingController(
            rootView: LocalFilePreviewView(target: target, close: { [weak previewWindow] in
                previewWindow?.performClose(nil)
            }).id(target.id)
        )
        previewWindow.contentMinSize = NSSize(width: 720, height: 520)
        previewWindow.setFrame(NSRect(origin: previewWindow.frame.origin, size: size), display: true)
        previewWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Release Quick Look and stop media playback when the preview closes.
        window?.contentViewController = nil
        window = nil
    }
}

private struct LocalFilePreviewView: View {
    let target: LocalFilePreviewTarget
    let close: () -> Void
    @State private var text: String?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(target.url.lastPathComponent, systemImage: "doc.text").font(.headline)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([target.url]) }
                Button("关闭") { close() }.keyboardShortcut(.cancelAction)
            }
            Text(target.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("无法预览文件", systemImage: "doc.badge.ellipsis", description: Text(error))
            } else if let text {
                if target.isMarkdown {
                    ScrollView(.vertical, showsIndicators: true) {
                        MarkdownMessageView(markdown: text)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(20)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                SystemFilePreview(url: target.url)
            }
            Text("只读预览，不会执行脚本或修改文件").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 960, minHeight: 520, idealHeight: 700)
        .task(id: target.id) {
            let url = target.url
            let result = await Task.detached { Result { try LocalFilePreviewTarget.readText(url) } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): text = value
            case .failure(let failure): error = failure.localizedDescription
            }
            loading = false
        }
    }
}

private struct SystemFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        // SwiftUI owns teardown, including replacement while the window remains open.
        // Disable Quick Look's automatic window-close path to avoid closing twice.
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
