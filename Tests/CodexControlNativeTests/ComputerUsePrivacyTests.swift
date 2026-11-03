import AppKit
import XCTest
@testable import CloudCodex

final class ComputerUsePrivacyTests: XCTestCase {
    func testOldTurnCompletionDoesNotRevealNewTurnOrOtherChat() {
        var state = ComputerUsePrivacyState()
        state.begin(threadID: "a", turnID: "old")
        state.begin(threadID: "a", turnID: "new")
        state.begin(threadID: "b", turnID: "other")
        state.end(threadID: "a", turnID: "old")
        XCTAssertEqual(state.turns["a"], "new")
        state.end(threadID: "a", turnID: "new")
        XCTAssertTrue(state.isActive)
        state.end(threadID: "b", turnID: "other")
        XCTAssertFalse(state.isActive)
    }

    func testUnknownTurnAndDisconnectCanBeCleanedUp() {
        var state = ComputerUsePrivacyState()
        state.begin(threadID: "a", turnID: nil)
        state.end(threadID: "a", turnID: "resolved")
        XCTAssertFalse(state.isActive)
        state.begin(threadID: "b", turnID: "running")
        state.reset()
        XCTAssertFalse(state.isActive)
    }

    func testWindowFilteringAndSecondaryDisplayCoordinates() {
        func info(_ id: Int, pid: Int = 7, layer: Int = 0, alpha: Double = 1,
                  rect: CGRect = CGRect(x: -900, y: -300, width: 800, height: 600)) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
             kCGWindowBounds as String: rect.dictionaryRepresentation]
        }
        let windows = ComputerUseCoveredWindow.visibleWindows([
            info(1), info(2, pid: 8), info(3, layer: 3), info(4, alpha: 0),
            info(5, rect: .zero), [:]
        ], processID: 7, desktopTop: 1080)
        XCTAssertEqual(windows, [ComputerUseCoveredWindow(id: 1,
            frame: CGRect(x: -900, y: 780, width: 800, height: 600))])
    }

    @MainActor
    func testCurtainDoesNotTakeInputOrActivateTarget() {
        let panel = ComputerUsePrivacyController.makePanel()
        defer { panel.close() }
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor?.alphaComponent, 1)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @MainActor
    func testPreferenceDefaultsOffAndPersistsBothChoices() {
        let suite = "computer-use-privacy.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        XCTAssertFalse(model.hidesComputerUseApplicationContent)
        model.setHidesComputerUseApplicationContent(true)
        XCTAssertTrue(AppModel(remoteDefaults: defaults).hidesComputerUseApplicationContent)
        model.setHidesComputerUseApplicationContent(false)
        XCTAssertFalse(AppModel(remoteDefaults: defaults).hidesComputerUseApplicationContent)
    }

    @MainActor
    func testBackgroundComputerUseStaysActiveBetweenCallsAndEndsOnDisconnect() {
        let suite = "computer-use-privacy.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.selectedThreadID = "visible"
        let params: [String: Any] = ["threadId": "background", "turnId": "turn",
            "item": ["id": "tool", "type": "mcpToolCall", "server": "cua_repl", "tool": "js"]]
        model.handleEvent("item/started", params)
        XCTAssertTrue(model.computerUsePrivacyState.isActive)
        model.handleEvent("item/completed", params)
        XCTAssertTrue(model.computerUsePrivacyState.isActive)
        model.handleEvent("error", ["threadId": "background", "turnId": "turn", "willRetry": true])
        XCTAssertTrue(model.computerUsePrivacyState.isActive)
        model.handleEvent("error", ["threadId": "background", "turnId": "turn",
            "error": ["message": "thread/items/list not supported"]])
        XCTAssertTrue(model.computerUsePrivacyState.isActive)
        model.handleClientDisconnect("test disconnect")
        XCTAssertFalse(model.computerUsePrivacyState.isActive)
    }

    @MainActor
    func testOrdinaryToolsDoNotCoverAndTerminalEventsReleaseBackgroundTurns() {
        let suite = "computer-use-privacy.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.handleEvent("item/started", ["threadId": "a", "turnId": "t",
            "item": ["id": "command", "type": "commandExecution", "command": "pwd"]])
        XCTAssertFalse(model.computerUsePrivacyState.isActive)
        model.handleEvent("item/started", ["threadId": "a", "turnId": "t",
            "item": ["id": "tool", "type": "dynamicToolCall", "namespace": "computer-use", "tool": "js"]])
        model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "old", "status": "completed"]])
        XCTAssertTrue(model.computerUsePrivacyState.isActive)
        model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "t", "status": "completed"]])
        XCTAssertFalse(model.computerUsePrivacyState.isActive)
    }
}
