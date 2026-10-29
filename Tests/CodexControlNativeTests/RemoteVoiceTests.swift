import XCTest
@testable import CloudCodex

final class RemoteVoiceTests: XCTestCase {
    func recording() -> Data {
        var bytes = [UInt8](repeating: 0, count: 3244)
        func text(_ offset: Int, _ text: String) { bytes.replaceSubrange(offset..<(offset+text.utf8.count), with: text.utf8) }
        func u16(_ offset: Int, _ value: Int) { bytes[offset] = UInt8(value & 255); bytes[offset+1] = UInt8((value >> 8) & 255) }
        func u32(_ offset: Int, _ value: Int) { u16(offset, value); u16(offset+2,value >> 16) }
        text(0,"RIFF");u32(4,3236);text(8,"WAVEfmt ");u32(16,16);u16(20,1);u16(22,1)
        u32(24,16000);u32(28,32000);u16(32,2);u16(34,16);text(36,"data");u32(40,3200)
        return Data(bytes)
    }
    func testRecordingContractRejectsCorruptionAndOversize() {
        let valid = recording()
        XCTAssertTrue(RemoteVoiceTranscriber.isSupportedRecording(valid))
        for offset in [0,4,8,16,20,22,24,28,32,34,36,40] {
            var broken = valid; broken[offset] ^= 1
            XCTAssertFalse(RemoteVoiceTranscriber.isSupportedRecording(broken), "offset \(offset)")
        }
        XCTAssertFalse(RemoteVoiceTranscriber.isSupportedRecording(valid.dropLast()))
        XCTAssertFalse(RemoteVoiceTranscriber.isSupportedRecording(Data(repeating: 0, count: 960045)))
    }
    func testHardwareControlCodeCarriesSeparateTokens() throws {
        let code = WatchConnectionCode(version: 2, server: "https://relay.example.invalid", deviceId: "fixture", token: String(repeating: "r", count: 43), expiresAt: 2_000_000_000, controlToken: String(repeating: "c",count:43))
        let decoded = try JSONDecoder().decode(WatchConnectionCode.self, from: JSONEncoder().encode(code))
        XCTAssertEqual(decoded.version,2)
        XCTAssertNotEqual(decoded.token,decoded.controlToken)
    }
}
