import XCTest
@testable import CloudCodex

final class HistoryPrependGeometryTests: XCTestCase {
    func testWindowAnchorMovingUpScrollsFlippedDocumentBackBySamePixels() {
        XCTAssertEqual(
            HistoryPrependGeometry.windowAnchorLockedOrigin(
                currentOrigin: 900,
                anchorDisplacement: 98,
                documentIsFlipped: true
            ),
            802
        )
    }

    func testNonFlippedDocumentMovesOriginForwardTowardEarlierContent() {
        XCTAssertEqual(
            HistoryPrependGeometry.windowAnchorLockedOrigin(
                currentOrigin: 900,
                anchorDisplacement: 98,
                documentIsFlipped: false
            ),
            998
        )
    }

    func testFlippedDocumentMovesOriginByInsertedHeight() {
        XCTAssertEqual(
            HistoryPrependGeometry.lockedOrigin(
                baselineOrigin: 420,
                baselineDocumentHeight: 1_000,
                currentDocumentHeight: 1_360,
                documentIsFlipped: true
            ),
            780
        )
    }

    func testNonFlippedDocumentMovesOriginInOppositeDirection() {
        XCTAssertEqual(
            HistoryPrependGeometry.lockedOrigin(
                baselineOrigin: 420,
                baselineDocumentHeight: 1_000,
                currentDocumentHeight: 1_360,
                documentIsFlipped: false
            ),
            60
        )
    }

    func testOriginDoesNotMoveBeforeLayoutAddsHeight() {
        XCTAssertEqual(
            HistoryPrependGeometry.lockedOrigin(
                baselineOrigin: 420,
                baselineDocumentHeight: 1_000,
                currentDocumentHeight: 1_000,
                documentIsFlipped: true
            ),
            420
        )
    }
}
