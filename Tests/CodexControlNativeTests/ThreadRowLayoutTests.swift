import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

final class ThreadRowLayoutTests: XCTestCase {
    private func thread(_ id: String, preview: String, running: Bool = false) -> CodexThread {
        CodexThread(json: ["id": id, "cwd": "/workspace/school", "name": id == "1" ? "shenzhen-polytechnic-3d-cocos 建筑细节优化" : "修复首页文案不换行",
                           "preview": preview, "model": "gpt-6-astra", "updatedAt": Date().timeIntervalSince1970,
                           "status": running ? "active" : "idle"])!
    }

    @MainActor
    func testRowHeightRemainsStableAcrossWidthsSelectionAndPreviewUpdates() {
        for width in [240.0, 300.0, 400.0] {
            for preview in ["", "简短摘要", String(repeating: "很长的摘要包含换行\n", count: 200)] {
                for selected in [true, false] {
                    let view = NSHostingView(rootView: ThreadRow(thread: thread("1", preview: preview, running: selected), isSelected: selected).frame(width: width))
                    XCTAssertEqual(view.fittingSize.height, 96, accuracy: 0.5)
                    XCTAssertEqual(view.fittingSize.width, width, accuracy: 0.5)
                }
            }
        }
    }

    @MainActor
    func testOptionalNativeListPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["CLOUDCODEX_THREAD_PREVIEW_DIR"] else { return }
        let rows = [thread("1", preview: "继续优化香蜜湖校区的建筑细节，参考 GIS 地图，检查并完善建筑物外观。", running: true),
                    thread("2", preview: "mp-szpu 的首页这句话确保不要换行显示"),
                    thread("3", preview: "检查报名流程和页面信息展示，保留现有功能。")]
        let preview = VStack(alignment: .leading, spacing: 0) {
            Text("school").font(.headline).padding(12)
            List {
                ForEach(rows) { row in
                    ThreadRow(thread: row, isSelected: row.id == "1")
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            }.listStyle(.inset)
        }.frame(width: 340, height: 370).preferredColorScheme(.dark)
        let view = NSHostingView(rootView: preview)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 370), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 370)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("thread-list-preview.png"))
        window.contentView = nil
    }
}
