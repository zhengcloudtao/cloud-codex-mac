import XCTest
@testable import CloudCodex

final class RemoteCodexBotTests: XCTestCase {
    func testLegacyVoiceDraftRemainsDecodable() throws {
        let draft = try JSONDecoder().decode(RemoteVoiceDraft.self, from: Data(#"{"id":"legacy","workspace":"/fixture","threadId":""}"#.utf8))
        XCTAssertNil(draft.purpose)
        XCTAssertNil(draft.wakeWord)
    }
    @MainActor
    func testSystemSpeechProducesHardwareWAV() async throws {
        let audio = try await RemoteVoiceSpeaker().synthesize("Good evening. Your task is complete.")
        XCTAssertTrue(RemoteVoiceTranscriber.isSupportedRecording(audio))
    }
    @MainActor
    func testDefaultBritishVoiceIsRetainedAndFirst() {
        let source = "Tingting zh_CN # Hello\nDaniel en_GB # Hello\nDaniel (英语（英国）) en_GB # Duplicate\nUnknown en_US # Hello\n" + (0..<20).map { "Chinese\($0) zh_CN # Hello" }.joined(separator: "\n")
        let voices = RemoteSpeechVoiceCatalog.parse(source)
        XCTAssertEqual(RemoteSpeechVoiceCatalog.defaultVoiceID, "Daniel")
        XCTAssertEqual(voices.first?.id, "Daniel")
        XCTAssertEqual(voices.first?.language, "en_GB")
        XCTAssertEqual(voices.count, 16)
        XCTAssertEqual(voices[1].id, "Tingting")
        XCTAssertEqual(voices.filter { $0.id == "Daniel" }.count, 1)
        XCTAssertFalse(voices.contains { $0.id == "Unknown" })
    }
    @MainActor
    func testLocalizedBritishVoiceUsesStableAlias() {
        let voices = RemoteSpeechVoiceCatalog.parse("Daniel (英语（英国）) en_GB # Hello\nTingting (中文（中国大陆）) zh_CN # Hello")
        XCTAssertEqual(voices.map(\.id), ["Daniel", "Tingting"])
    }
    @MainActor
    func testUnknownVoiceIsRejected() async {
        do {
            _ = try await RemoteVoiceSpeaker().synthesize("Hello.", voiceID: "uninstalled-test-voice")
            XCTFail("Unknown voice accepted")
        } catch { }
    }
    @MainActor
    func testSpeechRejectsOversizedText() async {
        do {
            _ = try await RemoteVoiceSpeaker().synthesize(String(repeating: "字", count: 121))
            XCTFail("Oversized speech accepted")
        } catch { }
    }
}
