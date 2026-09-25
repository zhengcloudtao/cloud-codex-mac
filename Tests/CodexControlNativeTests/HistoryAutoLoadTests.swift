import CoreGraphics
import XCTest
@testable import CloudCodex

final class HistoryAutoLoadTests: XCTestCase {
    func testTriggerLoadsWhenItEntersFromTopOrPreloadBand() {
        XCTAssertTrue(HistoryAutoLoad.triggerIsVisible(CGRect(x: 0, y: -20, width: 180, height: 28)))
        XCTAssertTrue(HistoryAutoLoad.triggerIsVisible(CGRect(x: 0, y: 60, width: 180, height: 28)))
    }

    func testTriggerIgnoresContentStillAboveOrFarBelowViewport() {
        XCTAssertFalse(HistoryAutoLoad.triggerIsVisible(CGRect(x: 0, y: -40, width: 180, height: 20)))
        XCTAssertFalse(HistoryAutoLoad.triggerIsVisible(CGRect(x: 0, y: 81, width: 180, height: 28)))
        XCTAssertFalse(HistoryAutoLoad.triggerIsVisible(nil))
    }
}
