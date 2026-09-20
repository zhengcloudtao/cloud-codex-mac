import XCTest
@testable import CloudCodex

final class RemotePairingQRCodeTests: XCTestCase {
    func testPairingPayloadOnlyAcceptsEightDigitServerCredential() throws {
        XCTAssertEqual(
            RemotePairingQRCode.payload(code: "12345678"),
            "cloudcodex://pair?v=1&code=12345678"
        )
        XCTAssertNil(RemotePairingQRCode.payload(code: "1234567"))
        XCTAssertNil(RemotePairingQRCode.payload(code: "1234567x"))
    }

    func testPairingPayloadRendersQRCode() throws {
        let payload = try XCTUnwrap(RemotePairingQRCode.payload(code: "87654321"))
        let image = try XCTUnwrap(RemotePairingQRCode.image(payload: payload))
        XCTAssertGreaterThan(image.size.width, 100)
        XCTAssertEqual(image.size.width, image.size.height)
    }

    func testPairingExpirationSupportsServerISO8601Formats() {
        XCTAssertNotNil(RemotePairingQRCode.expirationDate("2026-09-19T21:00:00+08:00"))
        XCTAssertNotNil(RemotePairingQRCode.expirationDate("2026-09-19T13:00:00.123Z"))
        XCTAssertNil(RemotePairingQRCode.expirationDate(nil))
    }
}
