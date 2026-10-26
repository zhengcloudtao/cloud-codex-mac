import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

@MainActor
final class AssistantReplyPanelLayoutTests: XCTestCase {
    func testShortPanelHugsContentAndLongPanelKeepsScrolling() throws {
        for width: CGFloat in [600, 1200] {
            for long in [false, true] {
                let question = AssistantReplyChoices.Question(id: "layout", turnID: nil,
                    prompt: long ? String(repeating: "较长的问题需要换行显示。", count: 60) : "你指的是哪处不一样？",
                    options: ["会话内容、数量或排列顺序不一致", "执行中 / 空闲状态不一致", "页面样式不一致"])
                let host = NSHostingView(rootView: VStack(spacing: 0) {
                    AssistantReplyQuestionPanel(question: question, isSubmitting: false, error: nil,
                                                submit: { _ in }, dismiss: {})
                    Spacer(minLength: 0)
                })
                let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: width, height: 700),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                for _ in 0..<8 {
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
                }
                func scroll(in view: NSView) -> NSScrollView? {
                    if let view = view as? NSScrollView { return view }
                    return view.subviews.compactMap { scroll(in: $0) }.first
                }
                let viewport = try XCTUnwrap(scroll(in: host))
                let document = try XCTUnwrap(viewport.documentView)
                XCTAssertLessThanOrEqual(viewport.bounds.height, 331)
                if long {
                    XCTAssertGreaterThan(document.bounds.height, viewport.contentView.bounds.height)
                } else {
                    XCTAssertLessThan(viewport.bounds.height, 310)
                    XCTAssertLessThanOrEqual(abs(viewport.contentView.bounds.height - document.bounds.height), 2,
                                             "Short content should not leave a tall empty area below the buttons")
                }
            }
        }
    }
}
