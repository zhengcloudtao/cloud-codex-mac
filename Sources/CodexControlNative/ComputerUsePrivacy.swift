import AppKit
import SwiftUI

/// Keep the curtain between tool calls in the same turn, including background chats.
struct ComputerUsePrivacyState: Equatable {
    static let defaultsKey = "cloudcodex.computerUse.hideApplicationContent.v1"
    private(set) var turns: [String: String] = [:]
    var isActive: Bool { !turns.isEmpty }

    mutating func begin(threadID: String, turnID: String?) { turns[threadID] = turnID ?? "" }
    mutating func end(threadID: String, turnID: String? = nil) {
        if let turnID, let current = turns[threadID], !current.isEmpty, current != turnID { return }
        turns.removeValue(forKey: threadID)
    }
    mutating func reset() { turns.removeAll() }
}

struct ComputerUseCoveredWindow: Equatable {
    let id: Int
    let frame: CGRect

    static func visibleWindows(_ descriptions: [[String: Any]], processID: pid_t,
                               desktopTop: CGFloat) -> [Self] {
        descriptions.compactMap { info in
            guard info[kCGWindowOwnerPID as String] as? Int == Int(processID),
                  info[kCGWindowLayer as String] as? Int == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            // CG coordinates start at the primary display's top left; AppKit
            // coordinates start at its bottom left, also on secondary displays.
            return Self(id: id, frame: CGRect(x: rect.minX, y: desktopTop - rect.maxY,
                                              width: rect.width, height: rect.height))
        }
    }
}

/// A local viewing preference, not a screenshot redaction or access-control boundary.
@MainActor
final class ComputerUsePrivacyController {
    private var panels: [Int: NSPanel] = [:]
    private var timer: Timer?
    private var statusItem: NSStatusItem?
    private var isActive = false
    var revealContent: (() -> Void)?

    func setActive(_ active: Bool) {
        guard active else { stop(); return }
        isActive = true
        guard timer == nil else { refresh(); return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "电脑控制内容遮盖")
        item.button?.toolTip = "电脑控制期间正在遮盖前台软件；点击恢复显示"
        item.button?.target = self
        item.button?.action = #selector(reveal)
        statusItem = item
        refresh()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func reveal() { revealContent?() }

    private func refresh() {
        // A timer callback may already be queued when the user reveals content.
        guard isActive else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              let top = NSScreen.screens.first?.frame.maxY,
              let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                           kCGNullWindowID) as? [[String: Any]] else {
            removePanels()
            return
        }
        let windows = ComputerUseCoveredWindow.visibleWindows(descriptions, processID: app.processIdentifier,
                                                               desktopTop: top)
        let visibleIDs = Set(windows.map(\.id))
        for id in Array(panels.keys) where !visibleIDs.contains(id) { panels.removeValue(forKey: id)?.close() }
        for window in windows {
            let panel: NSPanel
            if let existing = panels[window.id] { panel = existing } else {
                panel = Self.makePanel()
                panels[window.id] = panel
            }
            if panel.frame != window.frame { panel.setFrame(window.frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = false
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        // Best effort for legacy capture only. ScreenCaptureKit display captures
        // may include the curtain; do not claim this flag excludes it.
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: ComputerUsePrivacyCurtain())
        return panel
    }

    private func removePanels() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
    private func stop() {
        isActive = false
        timer?.invalidate()
        timer = nil
        removePanels()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }
    deinit {
        timer?.invalidate()
        let remainingPanels = Array(panels.values)
        let remainingItem = statusItem
        Task { @MainActor in
            remainingPanels.forEach { $0.close() }
            if let remainingItem { NSStatusBar.system.removeStatusItem(remainingItem) }
        }
    }
}

private struct ComputerUsePrivacyCurtain: View {
    var body: some View {
        ZStack {
            Color(nsColor: NSColor(calibratedWhite: 0.08, alpha: 1))
            VStack(spacing: 10) {
                Image(systemName: "eye.slash.fill").font(.system(size: 28))
                Text("Computer Use 正在操作").font(.headline)
                Text("软件内容已遮盖")
                Text("点击菜单栏的遮盖图标可恢复显示")
                    .font(.caption).foregroundStyle(.white.opacity(0.65))
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .accessibilityHidden(true)
    }
}
