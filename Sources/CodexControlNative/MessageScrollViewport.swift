import AppKit
import SwiftUI

/// This cache is not published: scrolling and unrelated toolbar refreshes must
/// not regroup every tool event in a long conversation.
final class ConversationTimelineCache {
    private var messages: [ChatMessage] = []
    private var cachedEntries: [ConversationTimelineEntry] = []
    private(set) var rebuildCount = 0

    func entries(from messages: [ChatMessage]) -> [ConversationTimelineEntry] {
        guard self.messages != messages else { return cachedEntries }
        self.messages = messages
        cachedEntries = ConversationTimeline.entries(from: messages)
        rebuildCount += 1
        return cachedEntries
    }
}

/// Native geometry stays out of SwiftUI's per-frame preference/layout cycle.
/// Only entering the history preload band requests a display-state change.
final class MessageScrollViewportController: ObservableObject {
    let timeline = ConversationTimelineCache()
    var pendingAnchor: (String, UnitPoint)?
    var onHistoryRequested: (() -> Void)?
    var onLatestChanged: ((Bool) -> Void)?
    private weak var scrollView: NSScrollView?
    private weak var anchorView: MessageHistoryProbeView?
    private weak var triggerView: MessageHistoryProbeView?
    private var triggerWasVisible = false
    private var requestScheduled = false
    private var lastReportedLatest: Bool?
    private var observations: [NSObjectProtocol] = []

    deinit {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(_ scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else { return }
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        triggerWasVisible = false
        lastReportedLatest = nil
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        observations.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in self?.reportHistoryPosition() })
        if let document = scrollView.documentView {
            document.postsFrameChangedNotifications = true
            observations.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: document, queue: .main
            ) { [weak self] _ in self?.reportHistoryPosition() })
        }
    }

    func register(_ view: MessageHistoryProbeView) {
        switch view.role {
        case .anchor: anchorView = view
        case .trigger:
            guard triggerView !== view else { return }
            triggerView = view
            DispatchQueue.main.async { [weak self] in self?.reportHistoryPosition() }
        }
    }

    func unregister(_ view: MessageHistoryProbeView) {
        if anchorView === view { anchorView = nil }
        if triggerView === view {
            triggerView = nil
            triggerWasVisible = false
        }
    }

    func viewportFrame(of view: NSView) -> CGRect? {
        guard let clip = scrollView?.contentView,
              view.window != nil, view.window === clip.window,
              view.isDescendant(of: clip) else { return nil }
        let rect = view.convert(view.bounds, to: clip)
        return Self.topLeadingFrame(rect, in: clip.bounds, isFlipped: clip.isFlipped)
    }

    static func topLeadingFrame(_ rect: CGRect, in viewport: CGRect, isFlipped: Bool) -> CGRect {
        CGRect(x: rect.minX - viewport.minX,
               y: isFlipped ? rect.minY - viewport.minY : viewport.maxY - rect.maxY,
               width: rect.width, height: rect.height)
    }

    func reportHistoryPosition() {
        if let scrollView, let document = scrollView.documentView {
            let visible = scrollView.documentVisibleRect
            let remaining = document.isFlipped
                ? document.bounds.maxY - visible.maxY
                : visible.minY - document.bounds.minY
            let latest = remaining <= 28
            if latest != lastReportedLatest {
                lastReportedLatest = latest
                DispatchQueue.main.async { [weak self] in self?.onLatestChanged?(latest) }
            }
        }
        let visible = triggerView.flatMap { viewportFrame(of: $0) }
            .map { HistoryAutoLoad.triggerIsVisible($0) } ?? false
        guard visible != triggerWasVisible else { return }
        triggerWasVisible = visible
        guard visible, !requestScheduled else { return }
        requestScheduled = true
        // AppKit may report bounds during a SwiftUI layout pass. Schedule only
        // this boundary event, never each scrolling frame, after that pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.requestScheduled = false
            guard self.triggerWasVisible else { return }
            self.onHistoryRequested?()
        }
    }

    func prependAlignment(for id: String?) -> UnitPoint {
        guard let id, let anchorView, anchorView.role == .anchor(id),
              let frame = viewportFrame(of: anchorView), let scrollView else {
            return .topLeading
        }
        let available = scrollView.contentView.bounds.height - frame.height
        guard abs(available) > 0.5 else { return .topLeading }
        return UnitPoint(x: 0, y: frame.minY / available)
    }
}

struct MessageHistoryProbe: NSViewRepresentable {
    let controller: MessageScrollViewportController
    let role: MessageHistoryProbeView.Role

    func makeNSView(context: Context) -> MessageHistoryProbeView {
        let view = MessageHistoryProbeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MessageHistoryProbeView, context: Context) {
        view.controller = controller
        view.role = role
        controller.register(view)
    }

    static func dismantleNSView(_ view: MessageHistoryProbeView, coordinator: ()) {
        view.controller?.unregister(view)
    }
}

final class MessageHistoryProbeView: NSView {
    enum Role: Equatable {
        case anchor(String)
        case trigger
    }
    weak var controller: MessageScrollViewportController?
    var role: Role = .trigger

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            controller?.register(self)
        } else {
            controller?.unregister(self)
        }
    }

    override func layout() {
        super.layout()
        if window != nil { controller?.register(self) }
    }

    // The probe only measures; it must not intercept text selection or clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
