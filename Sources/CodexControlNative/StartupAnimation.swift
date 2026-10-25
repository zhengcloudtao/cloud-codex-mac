import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum StartupAnimationPreference {
    static let enabledKey = "CloudCodex.startupAnimation.enabled.v1"
    static let pathKey = "CloudCodex.startupAnimation.path.v1"
    static let durationKey = "CloudCodex.startupAnimation.duration.v1"
    static func duration(_ value: Double) -> Double { value.isFinite ? min(10, max(1, value)) : 3 }
}

enum StartupAnimationStore {
    enum ImportError: LocalizedError {
        case invalid
        var errorDescription: String? { "请选择有效的多帧 GIF：最大 20 MB、600 帧，每帧不超过 2048 × 2048 像素。" }
    }
    static func validatedData(from url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw ImportError.invalid }
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier else { throw ImportError.invalid }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= 600 else { throw ImportError.invalid }
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 2048, height <= 2048 else { throw ImportError.invalid }
        }
        return data
    }
    static func importAnimation(from source: URL, directory: URL? = nil) throws -> String {
        let data = try validatedData(from: source)
        let base: URL
        if let directory { base = directory } else {
            base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
                .appendingPathComponent("CloudCodex/Personalization", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent("startup.gif")
        try data.write(to: destination, options: .atomic)
        return destination.path
    }
}

@MainActor
final class StartupAnimationSession: ObservableObject {
    private var claimed = false
    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

struct StartupAnimationHost<Content: View>: View {
    let session: StartupAnimationSession
    @ViewBuilder var content: () -> Content
    @State private var showing = false
    @State private var path = ""
    @State private var duration = 3.0
    var body: some View {
        content().disabled(showing).accessibilityHidden(showing)
            .background {
                if showing {
                    StartupWindowOverlay(path: path, duration: duration) { showing = false }
                }
            }
            .onAppear {
                guard session.claim(), UserDefaults.standard.bool(forKey: StartupAnimationPreference.enabledKey) else { return }
                path = UserDefaults.standard.string(forKey: StartupAnimationPreference.pathKey) ?? ""
                duration = StartupAnimationPreference.duration(
                    UserDefaults.standard.object(forKey: StartupAnimationPreference.durationKey) as? Double ?? 3)
                showing = true
            }
    }
}

/// Install above the native content and titlebar so the entire window is covered.
private struct StartupWindowOverlay: NSViewRepresentable {
    let path: String
    let duration: Double
    let dismiss: () -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.player = StartupAnimationPlayer(path: path, duration: duration, dismiss: dismiss)
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {}
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.removeOverlay() }

    final class Probe: NSView {
        var player: StartupAnimationPlayer?
        private var overlay: NSHostingView<StartupAnimationPlayer>?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeOverlay()
            guard let frameView = window?.contentView?.superview, let player else { return }
            let host = NSHostingView(rootView: player)
            host.sizingOptions = []
            host.frame = frameView.bounds
            host.autoresizingMask = [.width, .height]
            frameView.addSubview(host, positioned: .above, relativeTo: nil)
            overlay = host
        }
        func removeOverlay() {
            overlay?.removeFromSuperview()
            overlay = nil
        }
    }
}

enum StartupAnimationLayout {
    static func fittedSize(image: CGSize, container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return container }
        let scale = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    static func filledSize(image: CGSize, container: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return container }
        let scale = max(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

private struct AnimatedStartupImage: NSViewRepresentable {
    let image: NSImage
    let animates: Bool
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = image
        view.animates = animates
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) { view.animates = animates }
    static func dismantleNSView(_ view: NSImageView, coordinator: ()) {
        view.animates = false
        view.image = nil
    }
}

struct StartupAnimationPlayer: View {
    let path: String
    let duration: Double
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var appeared = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: .windowBackgroundColor)
            if let image {
                GeometryReader { geometry in
                    let backgroundSize = StartupAnimationLayout.filledSize(image: image.size, container: geometry.size)
                    let foregroundSize = StartupAnimationLayout.fittedSize(image: image.size, container: geometry.size)
                    ZStack {
                        // Only the ambient background is cropped; the complete GIF stays visible in front.
                        AnimatedStartupImage(image: image, animates: !reduceMotion)
                            .frame(width: backgroundSize.width, height: backgroundSize.height)
                            .scaleEffect(1.12)
                            .blur(radius: 32, opaque: true)
                            .accessibilityHidden(true)
                        AnimatedStartupImage(image: image, animates: !reduceMotion)
                            .frame(width: foregroundSize.width, height: foregroundSize.height)
                    }
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .clipped()
                .accessibilityLabel("自定义启动动画")
            } else {
                VStack(spacing: 22) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().scaledToFit().frame(width: 112, height: 112)
                        .scaleEffect(appeared ? 1 : 0.85).opacity(appeared ? 1 : 0)
                    Text("CloudCodex").font(.largeTitle.bold())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button("跳过", action: dismiss).keyboardShortcut(.cancelAction).padding(20)
        }
        .ignoresSafeArea()
        .task {
            if !path.isEmpty, let data = try? StartupAnimationStore.validatedData(from: URL(fileURLWithPath: path)) {
                image = NSImage(data: data)
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.7)) { appeared = true }
            do {
                try await Task.sleep(for: .seconds(StartupAnimationPreference.duration(duration)))
                dismiss()
            } catch { /* Dismissal cancels playback. */ }
        }
    }
}

struct StartupAnimationSettings: View {
    @AppStorage(StartupAnimationPreference.enabledKey) private var enabled = false
    @AppStorage(StartupAnimationPreference.pathKey) private var path = ""
    @AppStorage(StartupAnimationPreference.durationKey) private var duration = 3.0
    @State private var previewing = false
    @State private var error: String?
    var body: some View {
        GroupBox("启动动画") {
            VStack(alignment: .leading, spacing: 16) {
                Toggle("打开 CloudCodex 时播放启动动画", isOn: $enabled)
                Text("每次启动应用播放一次，重新打开窗口不会重复播放。设置自动保存，下次启动生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(path.isEmpty ? "当前动画：默认应用图标" : "当前动画：自定义 GIF")
                HStack {
                    Button("导入 GIF", action: chooseAnimation)
                    Button("恢复默认动画") { path = "" }.disabled(path.isEmpty)
                    Button("预览") { previewing = true }
                }
                Text("支持多帧 GIF，最大 20 MB、600 帧、2048 × 2048 像素。导入后保存在本机，移动原文件不会影响播放。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("显示时长")
                    Slider(value: $duration, in: 1...10, step: 0.5)
                    Text(String(format: "%.1f 秒", StartupAnimationPreference.duration(duration)))
                        .monospacedDigit().frame(width: 65)
                }
                Text("播放期间可点击“跳过”或按 Esc；系统开启“减少动态效果”时显示静态画面。文件不可用时使用默认动画。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.padding(12)
        }
        .sheet(isPresented: $previewing) {
            StartupAnimationPlayer(path: path, duration: duration) { previewing = false }
                .frame(width: 680, height: 500)
        }
    }
    private func chooseAnimation() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "导入动画"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            path = try StartupAnimationStore.importAnimation(from: url)
            enabled = true
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
