import XCTest
@testable import CloudCodex

final class AppearancePreferenceTests: XCTestCase {
    func testEveryAppearanceOptionHasAPersistableIdentityAndTitle() {
        XCTAssertEqual(AppearancePreference.allCases.map(\.rawValue), ["system", "light", "dark"])
        XCTAssertEqual(AppearancePreference.system.title, "跟随系统")
        XCTAssertEqual(AppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(AppearancePreference.dark.colorScheme, .dark)
        XCTAssertNil(AppearancePreference.system.colorScheme)
    }

    func testBackgroundScopesDescribeRangeAndRecommendedDimensions() {
        XCTAssertEqual(BackgroundScope.allCases.map(\.rawValue), ["entireWindow", "conversation"])
        XCTAssertEqual(BackgroundScope.entireWindow.title, "整个窗口")
        XCTAssertEqual(BackgroundScope.entireWindow.recommendedSize, "2560 × 1600 px（16:10）")
        XCTAssertEqual(BackgroundScope.conversation.title, "仅会话区域")
        XCTAssertEqual(BackgroundScope.conversation.recommendedSize, "1600 × 2000 px（4:5）")
    }

    func testBackgroundCropValuesStayInsideSupportedRanges() {
        XCTAssertEqual(BackgroundPreference.clampedOpacity(-1), 0.05)
        XCTAssertEqual(BackgroundPreference.clampedOpacity(2), 0.85)
        XCTAssertEqual(BackgroundPreference.clampedZoom(0.2), 1)
        XCTAssertEqual(BackgroundPreference.clampedZoom(8), 3)
        XCTAssertEqual(BackgroundPreference.clampedOffset(-4), -1)
        XCTAssertEqual(BackgroundPreference.clampedOffset(4), 1)
    }

    func testCropOffsetsNeverExposeAnEmptyEdge() {
        let wideImage = BackgroundCropGeometry.maximumOffset(
            imageSize: CGSize(width: 2_000, height: 1_000),
            containerSize: CGSize(width: 400, height: 400),
            zoom: 1
        )
        XCTAssertEqual(wideImage.width, 200, accuracy: 0.001)
        XCTAssertEqual(wideImage.height, 0, accuracy: 0.001)

        let zoomedSquare = BackgroundCropGeometry.maximumOffset(
            imageSize: CGSize(width: 1_000, height: 1_000),
            containerSize: CGSize(width: 400, height: 400),
            zoom: 2
        )
        XCTAssertEqual(zoomedSquare.width, 200, accuracy: 0.001)
        XCTAssertEqual(zoomedSquare.height, 200, accuracy: 0.001)
    }
}
