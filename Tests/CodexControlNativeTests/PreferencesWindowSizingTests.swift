import AppKit
import XCTest
@testable import CloudCodex

final class PreferencesWindowSizingTests: XCTestCase {
    @MainActor
    func testResizePersistsAndReopeningRestoresContentSize() throws {
        let suite = "PreferencesWindow-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 720),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        let first = window()
        let coordinator = PreferencesWindowSizing.Coordinator(defaults: defaults)
        coordinator.attach(to: first)
        XCTAssertTrue(first.styleMask.contains(.resizable))
        XCTAssertEqual(first.contentMinSize, PreferencesWindowSizing.minimum)
        first.setContentSize(NSSize(width: 850, height: 620))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: first)
        XCTAssertEqual(defaults.double(forKey: PreferencesWindowSizing.widthKey), 850)
        XCTAssertEqual(defaults.double(forKey: PreferencesWindowSizing.heightKey), 620)
        coordinator.detach()
        first.close()

        let second = window()
        defer { coordinator.detach(); second.close() }
        coordinator.attach(to: second)
        let available = (second.screen ?? NSScreen.main).map {
            NSSize(width: $0.visibleFrame.width - 40, height: $0.visibleFrame.height - 80)
        } ?? PreferencesWindowSizing.initial
        XCTAssertEqual(second.contentView?.bounds.size,
                       PreferencesWindowSizing.restoredSize(defaults: defaults, available: available))
    }

    func testMissingInvalidAndOversizedDimensionsAreBounded() throws {
        let suite = "PreferencesWindowBounds-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let available = NSSize(width: 1200, height: 900)
        XCTAssertEqual(PreferencesWindowSizing.restoredSize(defaults: defaults, available: available),
                       PreferencesWindowSizing.initial)
        defaults.set(-10, forKey: PreferencesWindowSizing.widthKey)
        defaults.set(5000, forKey: PreferencesWindowSizing.heightKey)
        XCTAssertEqual(PreferencesWindowSizing.restoredSize(defaults: defaults, available: available),
                       NSSize(width: 760, height: 900))
        defaults.set(100, forKey: PreferencesWindowSizing.widthKey)
        XCTAssertEqual(PreferencesWindowSizing.restoredSize(defaults: defaults, available: available).width, 640)
    }
}
