import AppKit
import SwiftUI

/// Applies only to the preferences sheet's native window, never the main window.
struct PreferencesWindowSizing: NSViewRepresentable {
    static let minimum = NSSize(width: 640, height: 480)
    static let initial = NSSize(width: 760, height: 720)
    static let widthKey = "cloudcodex.preferences.windowWidth"
    static let heightKey = "cloudcodex.preferences.windowHeight"

    var defaults: UserDefaults = .standard

    static func restoredSize(defaults: UserDefaults, available: NSSize) -> NSSize {
        func dimension(_ key: String, initial: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
            let saved = defaults.double(forKey: key)
            let value = saved.isFinite && saved > 0 ? CGFloat(saved) : initial
            return min(max(value, minimum), max(minimum, maximum))
        }
        return NSSize(width: dimension(widthKey, initial: initial.width, minimum: minimum.width, maximum: available.width),
                      height: dimension(heightKey, initial: initial.height, minimum: minimum.height, maximum: available.height))
    }

    func makeNSView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WindowProbe, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(defaults: defaults) }

    static func dismantleNSView(_ nsView: WindowProbe, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class WindowProbe: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { coordinator?.detach(); return }
            // Wait until SwiftUI has attached and sized the hosting window.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.coordinator?.attach(to: window)
            }
        }
    }

    final class Coordinator {
        let defaults: UserDefaults
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?

        init(defaults: UserDefaults) { self.defaults = defaults }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            window.styleMask.insert(.resizable)
            window.contentMinSize = Self.minimumSize
            let screen = window.screen ?? NSScreen.main
            let available = screen.map { NSSize(width: $0.visibleFrame.width - 40, height: $0.visibleFrame.height - 80) }
                ?? PreferencesWindowSizing.initial
            window.setContentSize(PreferencesWindowSizing.restoredSize(defaults: defaults, available: available))
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                object: window, queue: .main) { [weak self] _ in self?.save() }
        }

        private static var minimumSize: NSSize { PreferencesWindowSizing.minimum }

        func save() {
            guard let size = window?.contentView?.bounds.size,
                  size.width.isFinite, size.height.isFinite,
                  size.width >= PreferencesWindowSizing.minimum.width,
                  size.height >= PreferencesWindowSizing.minimum.height else { return }
            defaults.set(Double(size.width), forKey: PreferencesWindowSizing.widthKey)
            defaults.set(Double(size.height), forKey: PreferencesWindowSizing.heightKey)
        }

        func detach() {
            save()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = nil
            window = nil
        }

        deinit {
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        }
    }
}
