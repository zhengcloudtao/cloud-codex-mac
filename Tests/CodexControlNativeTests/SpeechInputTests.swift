import XCTest
@testable import CloudCodex

@MainActor
final class SpeechInputTests: XCTestCase {
    func testTranscriptPreservesExistingFormatting() {
        XCTAssertEqual(SpeechInputController.appendingTranscript("你好。", to: "已有草稿\n\n"), "已有草稿\n\n你好。")
        XCTAssertEqual(SpeechInputController.appendingTranscript("你好。", to: "已有草稿"), "已有草稿\n你好。")
        XCTAssertEqual(SpeechInputController.appendingTranscript("", to: "  草稿  "), "  草稿  ")
        XCTAssertEqual(SpeechInputController.appendingTranscript("你好。", to: ""), "你好。")
    }

    func testPartialResultsReplaceOnlyDictationSuffix() {
        let prefix = "原有要求\n"
        let partial = SpeechInputController.appendingTranscript("优化", to: prefix)
        let final = SpeechInputController.appendingTranscript("优化语音输入。", to: prefix)
        XCTAssertEqual(partial, "原有要求\n优化")
        XCTAssertEqual(final, "原有要求\n优化语音输入。")
    }
}
