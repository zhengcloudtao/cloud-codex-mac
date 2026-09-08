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
}
