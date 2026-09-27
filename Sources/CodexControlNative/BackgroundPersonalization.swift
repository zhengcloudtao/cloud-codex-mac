import AppKit
import SwiftUI

enum BackgroundScope: String, CaseIterable, Identifiable {
    case entireWindow
    case conversation

    static let storageKey = "CloudCodex.backgroundScope.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .entireWindow: "整个窗口"
        case .conversation: "仅会话区域"
        }
    }

    var symbolName: String {
        switch self {
        case .entireWindow: "macwindow"
        case .conversation: "rectangle.righthalf.inset.filled"
        }
    }

    var recommendedSize: String {
        switch self {
        case .entireWindow: "2560 × 1600 px（16:10）"
        case .conversation: "1600 × 2000 px（4:5）"
        }
    }

    var recommendationDetail: String {
        switch self {
        case .entireWindow:
            "适合横向壁纸；重要主体建议放在画面中央，避免被侧栏和工具栏遮挡。"
        case .conversation:
            "适合偏竖构图；会话栏宽度会随窗口变化，请为四周预留可裁切空间。"
        }
    }
}

enum BackgroundPreference {
    static let imagePathKey = "CloudCodex.backgroundImagePath.v1"
    static let opacityKey = "CloudCodex.backgroundOpacity.v1"
    static let zoomKey = "CloudCodex.backgroundZoom.v1"
    static let offsetXKey = "CloudCodex.backgroundOffsetX.v1"
    static let offsetYKey = "CloudCodex.backgroundOffsetY.v1"

    static let defaultOpacity = 0.28
    static let defaultZoom = 1.0

    static func clampedOpacity(_ value: Double) -> Double { min(0.85, max(0.05, value)) }
    static func clampedZoom(_ value: Double) -> Double { min(3, max(1, value)) }
    static func clampedOffset(_ value: Double) -> Double { min(1, max(-1, value)) }
}

enum BackgroundCropGeometry {
    static func maximumOffset(
        imageSize: CGSize,
        containerSize: CGSize,
        zoom: Double
    ) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let fillScale = max(
            containerSize.width / imageSize.width,
            containerSize.height / imageSize.height
        )
        let appliedZoom = CGFloat(BackgroundPreference.clampedZoom(zoom))
        let renderedWidth = imageSize.width * fillScale * appliedZoom
        let renderedHeight = imageSize.height * fillScale * appliedZoom
        return CGSize(
            width: max(0, (renderedWidth - containerSize.width) / 2),
            height: max(0, (renderedHeight - containerSize.height) / 2)
        )
    }
}

enum BackgroundImageStore {
    static func importImage(from source: URL, fileManager: FileManager = .default) throws -> String {
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("CloudCodex", isDirectory: true)
            .appendingPathComponent("Personalization", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("background.png")
        try png.write(to: destination, options: .atomic)
        return destination.path
    }
}

struct PersonalBackgroundImage: View {
    let path: String
    let opacity: Double
    let zoom: Double
    let offsetX: Double
    let offsetY: Double

    var body: some View {
        GeometryReader { geometry in
            if let image = NSImage(contentsOfFile: path) {
                let maximumOffset = BackgroundCropGeometry.maximumOffset(
                    imageSize: image.size,
                    containerSize: geometry.size,
                    zoom: zoom
                )
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(BackgroundPreference.clampedZoom(zoom))
                    .offset(
                        x: BackgroundPreference.clampedOffset(offsetX) * maximumOffset.width,
                        y: BackgroundPreference.clampedOffset(offsetY) * maximumOffset.height
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .opacity(BackgroundPreference.clampedOpacity(opacity))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct BackgroundCropPreview: View {
    let path: String
    let scope: BackgroundScope
    @Binding var zoom: Double
    @Binding var offsetX: Double
    @Binding var offsetY: Double

    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.16)
                if let image = NSImage(contentsOfFile: path) {
                    let maximumOffset = BackgroundCropGeometry.maximumOffset(
                        imageSize: image.size,
                        containerSize: geometry.size,
                        zoom: zoom
                    )
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(BackgroundPreference.clampedZoom(zoom))
                        .offset(
                            x: offsetX * maximumOffset.width,
                            y: offsetY * maximumOffset.height
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    ContentUnavailableView("背景图片不可用", systemImage: "photo.badge.exclamationmark")
                }

                RoundedRectangle(cornerRadius: 12)
                    .stroke(.white.opacity(0.72), lineWidth: 1)
                Image(systemName: "plus")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStart ?? CGPoint(x: offsetX, y: offsetY)
                        if dragStart == nil { dragStart = start }
                        offsetX = BackgroundPreference.clampedOffset(
                            start.x + value.translation.width / max(1, cropMaximumOffset(for: geometry.size).width)
                        )
                        offsetY = BackgroundPreference.clampedOffset(
                            start.y + value.translation.height / max(1, cropMaximumOffset(for: geometry.size).height)
                        )
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .aspectRatio(scope == .entireWindow ? 16 / 10 : 4 / 5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("背景裁切预览")
        .accessibilityHint("拖动图片调整裁切位置")
    }

    private func cropMaximumOffset(for containerSize: CGSize) -> CGSize {
        guard let image = NSImage(contentsOfFile: path) else { return .zero }
        return BackgroundCropGeometry.maximumOffset(
            imageSize: image.size,
            containerSize: containerSize,
            zoom: zoom
        )
    }
}
