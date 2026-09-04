import Foundation
import XCTest
@testable import CloudCodex

final class AppServerDecoderTests: XCTestCase {
    func testLargeFragmentedJSONLineIsDecodedOnlyAfterNewlineArrives() throws {
        var decoder = JSONLineDecoder()
        let payload = String(repeating: "x", count: 512_000)
        let encoded = try XCTUnwrap(
            "{\"id\":42,\"result\":{\"payload\":\"\(payload)\"}}\n".data(using: .utf8)
        )

        var decoded: [[String: Any]] = []
        for offset in stride(from: 0, to: encoded.count, by: 257) {
            let end = min(offset + 257, encoded.count)
            decoded.append(contentsOf: decoder.consume(encoded.subdata(in: offset..<end)))
        }

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?["id"] as? Int, 42)
        let result = try XCTUnwrap(decoded.first?["result"] as? [String: Any])
        XCTAssertEqual((result["payload"] as? String)?.count, payload.count)
    }

    func testMultipleAndPartialLinesPreserveOrder() {
        var decoder = JSONLineDecoder()

        XCTAssertTrue(decoder.consume(Data("{\"id\":1}\n{\"id\"".utf8)).map { $0["id"] as? Int } == [1])
        XCTAssertTrue(decoder.consume(Data(":2}\n\n{\"id\":3}\n".utf8)).map { $0["id"] as? Int } == [2, 3])
    }
}
