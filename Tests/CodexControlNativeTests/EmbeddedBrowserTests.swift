import XCTest
import AppKit
@testable import CloudCodex

@MainActor
final class EmbeddedBrowserTests: XCTestCase {
    func testBrowserVisibilityIsScopedToTheConversationAndManualClosePersists() {
        let browser = EmbeddedBrowser()
        XCTAssertFalse(browser.isVisible(for: "unused"))

        browser.show(threadID: "used")
        XCTAssertTrue(browser.isVisible(for: "used"))
        XCTAssertFalse(browser.isVisible(for: "unused"), "A browser used by one conversation must not open in another")

        browser.hide(threadID: "used")
        XCTAssertFalse(browser.isVisible(for: "used"), "Switching conversations must not undo a manual close")
        browser.toggle(threadID: "used")
        XCTAssertTrue(browser.isVisible(for: "used"), "The toolbar can still open the browser explicitly")
    }

    func testLiveAppServerToolRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_BROWSER_MODEL_TEST"] == "1" else { throw XCTSkip("Opt-in live model test") }
        let client = AppServerClient()
        let browser = EmbeddedBrowser()
        try await client.start()
        let thread = try await client.createThread(cwd: NSTemporaryDirectory(), model: nil, permissions: nil)
        let tab = try browser.create(threadID: thread.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = tab.webView; window.orderFront(nil)
        defer { window.close() }
        tab.webView.loadHTMLString("<html><body><input aria-label='Name'><button onclick=\"document.querySelector('p').textContent='Hello '+document.querySelector('input').value\">Greet</button><p>Ready</p></body></html>", baseURL: nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        var actions: [String] = []
        var completed = false
        client.onServerRequest = { id, method, params in
            guard method == "item/tool/call" else { return }
            Task { @MainActor in
                guard params["tool"] as? String == BrowserTool.name, let args = params["arguments"] as? [String: Any], params["threadId"] as? String == thread.id else {
                    try? client.respond(to: id, result: BrowserTool.result("Unsupported test tool", success: false)); return
                }
                actions.append(args["action"] as? String ?? "")
                let result = await browser.execute(threadID: thread.id, arguments: args)
                try? client.respond(to: id, result: result)
            }
        }
        client.onEvent = { method, params in
            if method == "turn/completed", params["threadId"] as? String == thread.id { completed = true }
        }
        let turnID = try await client.startTurn(threadID: thread.id,
            text: "This is a local browser integration test. Use ONLY cloudcodex_browser. Tab \(tab.id) already contains a synthetic test form. Read it, fill Name with CloudCodex, click Greet, read and verify Hello CloudCodex, then take a screenshot and finish. Do not use external browsers, shell or other tools.",
            attachments: [], model: nil, effort: nil, permissions: nil, serviceTierForTurn: nil)
        let deadline = Date().addingTimeInterval(120)
        while !completed && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        if !completed, let turnID { try? await client.interruptTurn(threadID: thread.id, turnID: turnID) }
        XCTAssertTrue(completed, "Live model timed out")
        XCTAssertTrue(actions.contains("fill")); XCTAssertTrue(actions.contains("click")); XCTAssertTrue(actions.contains("screenshot"))
        let final = try await tab.read()
        XCTAssertTrue(final.contains("Hello CloudCodex"))
    }

    func testURLPolicy() throws {
        XCTAssertEqual(try BrowserTool.url("http://localhost:8080/test").host, "localhost")
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.com", "data:text/html,test"] {
            XCTAssertThrowsError(try BrowserTool.url(value))
        }
    }

    func testWebKitInteractionAndIsolation() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_BROWSER_TEST"] == "1" else { throw XCTSkip("Opt-in WebKit integration test") }
        let browser = EmbeddedBrowser()
        let tab = try browser.create(threadID: "test-a")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.webView
        window.orderFront(nil)
        defer { window.close() }
        tab.webView.loadHTMLString("<html><body><input aria-label='Name'><button onclick=\"document.querySelector('p').textContent='Hello '+document.querySelector('input').value\">Greet</button><p>Ready</p></body></html>", baseURL: nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        let snapshot = try await tab.read()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
        let elements = try XCTUnwrap(json["elements"] as? [[String: Any]])
        let input = try XCTUnwrap(elements.first { $0["tag"] as? String == "input" }?["id"] as? String)
        let filled = await browser.execute(threadID: "test-a", arguments: ["action": "fill", "tabId": tab.id, "element": input, "text": "CloudCodex"])
        XCTAssertEqual(filled["success"] as? Bool, true)
        let newSnapshot = try await tab.read()
        let next = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(newSnapshot.utf8)) as? [String: Any])
        let button = try XCTUnwrap((next["elements"] as? [[String: Any]])?.first { $0["tag"] as? String == "button" }?["id"] as? String)
        let clicked = await browser.execute(threadID: "test-a", arguments: ["action": "click", "tabId": tab.id, "element": button])
        XCTAssertEqual(clicked["success"] as? Bool, true)
        let final = try await tab.read()
        XCTAssertTrue(final.contains("Hello CloudCodex"))
        let rejected = await browser.execute(threadID: "test-b", arguments: ["action": "read", "tabId": tab.id])
        XCTAssertEqual(rejected["success"] as? Bool, false)
        let stale = await browser.execute(threadID: "test-a", arguments: ["action": "click", "tabId": tab.id, "element": button])
        XCTAssertEqual(stale["success"] as? Bool, false)
        let screenshot = await browser.execute(threadID: "test-a", arguments: ["action": "screenshot", "tabId": tab.id])
        XCTAssertEqual(screenshot["success"] as? Bool, true)
    }
}
