import XCTest
import AppKit
import SwiftUI
@testable import CloudCodex

final class UsageLimitPresentationTests: XCTestCase {
    func testUsageLimitWithOrdinalDateAndOfficialLinks() throws {
        let text = "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again at Oct 25th, 2026 12:28 AM."
        let value = try XCTUnwrap(UsageLimitPresentation(text))
        XCTAssertEqual(value.recoveryTime, "2026年10月25日 00:28")
        XCTAssertTrue(value.showsUsageLink)
        XCTAssertTrue(value.showsPlanLink)
    }
    func testTimeOnlyRecoveryDoesNotInventDateOrTimezone() throws {
        XCTAssertEqual(try XCTUnwrap(UsageLimitPresentation("You've hit your usage limit. try again at 2:40 PM.")).recoveryTime, "14:40")
        XCTAssertEqual(try XCTUnwrap(UsageLimitPresentation("You've hit your usage limit. try again at 12:05 AM.")).recoveryTime, "00:05")
    }

    func testMissingOrMalformedTimeKeepsQuotaExplanation() throws {
        XCTAssertNil(try XCTUnwrap(UsageLimitPresentation("You've hit your usage limit.")).recoveryTime)
        XCTAssertNil(try XCTUnwrap(UsageLimitPresentation("You've hit your usage limit. try again at unknown")).recoveryTime)
        XCTAssertFalse(try XCTUnwrap(UsageLimitPresentation("You've hit your usage limit.")).showsUsageLink)
    }
    @MainActor func testOptionalQuotaNoticePreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["CLOUDCODEX_QUOTA_PREVIEW_DIR"] else {
            throw XCTSkip("Set CLOUDCODEX_QUOTA_PREVIEW_DIR to render the quota notice")
        }
        let raw = "You've hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again at 2:40 PM."
        let view = NSHostingView(rootView: UsageLimitDetailView(usageLimit: try XCTUnwrap(UsageLimitPresentation(raw)), originalError: raw)
            .padding(20).frame(width: 620).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
        view.frame = NSRect(x: 0, y: 0, width: 620, height: view.fittingSize.height)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("quota-notice.png"))
    }

    func testOtherErrorsAreNotReclassified() {
        XCTAssertNil(UsageLimitPresentation("Selected model is at capacity"))
        XCTAssertNil(UsageLimitPresentation("Network request failed"))
    }
}
