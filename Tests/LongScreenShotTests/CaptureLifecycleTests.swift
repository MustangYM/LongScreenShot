import AppKit
import XCTest
@testable import LongScreenShot

final class CaptureLifecycleTests: XCTestCase {
    func testLongCaptureReturnAndKeypadEnterUseUnmodifiedKeysOnly() throws {
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(LongCaptureKeyboard.isConfirm(try key(36)))
        XCTAssertTrue(LongCaptureKeyboard.isConfirm(try key(76, flags: .numericPad)))
        for modifiers: NSEvent.ModifierFlags in [.command, .shift, .option, .control] {
            XCTAssertFalse(LongCaptureKeyboard.isConfirm(try key(36, flags: modifiers)))
        }
        XCTAssertFalse(LongCaptureKeyboard.isConfirm(try key(53)))
    }

    func testForeignMenuCannotPresentOverlayBeforeActivation() {
        var session = CaptureSessionLifecycle()
        XCTAssertTrue(session.begin())
        XCTAssertFalse(session.present(applicationIsActive: false))
        XCTAssertFalse(session.present(applicationIsActive: false))
        XCTAssertTrue(session.present(applicationIsActive: true))
        XCTAssertFalse(session.present(applicationIsActive: true))
    }

    func testStatusMenuTrackingPreventsPresentationEvenWhenAppIsActive() {
        var session = CaptureSessionLifecycle()
        XCTAssertTrue(session.begin())
        XCTAssertFalse(session.present(applicationIsActive: true, menuIsTracking: true))
        XCTAssertTrue(session.present(applicationIsActive: true, menuIsTracking: false))
    }

    func testVisibleTrackingMenusAreDetectedWithoutTreatingMenuBarAsMenu() {
        let menu: [String: Any] = [kCGWindowLayer as String: NSNumber(value: CGWindowLevelForKey(.popUpMenuWindow)),
                                   kCGWindowAlpha as String: NSNumber(value: 1)]
        let menuBar: [String: Any] = [kCGWindowLayer as String: NSNumber(value: CGWindowLevelForKey(.mainMenuWindow)),
                                      kCGWindowAlpha as String: NSNumber(value: 1)]
        var hiddenMenu = menu
        hiddenMenu[kCGWindowAlpha as String] = NSNumber(value: 0)
        XCTAssertTrue(WindowDetector.hasTrackingMenu(in: [menuBar, menu]))
        XCTAssertFalse(WindowDetector.hasTrackingMenu(in: [menuBar, hiddenMenu]))
    }

    func testActivationTimeoutCannotBeUndoneByLateActivation() {
        var session = CaptureSessionLifecycle()
        XCTAssertTrue(session.begin())
        XCTAssertFalse(session.present(applicationIsActive: false))
        XCTAssertTrue(session.finish())
        XCTAssertFalse(session.present(applicationIsActive: true))
        XCTAssertFalse(session.begin())
    }

    func testRepeatedStartAndRepeatedCancelAreIdempotent() {
        var session = CaptureSessionLifecycle()
        XCTAssertTrue(session.begin())
        XCTAssertFalse(session.begin())
        XCTAssertTrue(session.finish())
        XCTAssertFalse(session.finish())
    }

    func testCancelBeforeDelayedStartDoesNotCaptureOrReopen() {
        var captures = 0, finishes = 0
        let coordinator = CaptureCoordinator(initialLongMode: false, snapshotProvider: {
            captures += 1
            return []
        })
        coordinator.onFinish = { finishes += 1 }
        coordinator.cancel()
        coordinator.start()
        coordinator.cancel()
        XCTAssertEqual(captures, 0)
        XCTAssertEqual(finishes, 1)
    }

    func testFailedCaptureFinishesOnceWithoutInstallingOverlays() {
        var captures = 0, finishes = 0
        let coordinator = CaptureCoordinator(initialLongMode: false, snapshotProvider: {
            captures += 1
            return []
        })
        coordinator.onFinish = { finishes += 1 }
        coordinator.start()
        coordinator.start()
        coordinator.cancel()
        XCTAssertEqual(captures, 1)
        XCTAssertEqual(finishes, 1)
    }

    func testOwnMenuIsDismissedOnlyAfterItsPixelsAreCaptured() {
        var events: [String] = []
        let coordinator = CaptureCoordinator(initialLongMode: false, snapshotProvider: {
            events.append("snapshot")
            return []
        })
        coordinator.onFinish = { events.append("finish") }
        coordinator.start(afterSnapshot: { events.append("dismiss-menu") })
        XCTAssertEqual(events, ["snapshot", "dismiss-menu", "finish"])
        coordinator.start(afterSnapshot: { events.append("unexpected-dismiss") })
        XCTAssertEqual(events, ["snapshot", "dismiss-menu", "finish"])
    }

    func testCancelledPendingCaptureDoesNotDismissAnOpenMenu() {
        var didDismiss = false
        let coordinator = CaptureCoordinator(initialLongMode: false, snapshotProvider: { [] })
        coordinator.cancel()
        coordinator.start(afterSnapshot: { didDismiss = true })
        XCTAssertFalse(didDismiss)
    }

    func testOverlayLevelsDoNotUseScreenSaverTier() {
        XCTAssertGreaterThan(CaptureWindowLevels.overlay.rawValue, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertGreaterThan(CaptureWindowLevels.toolbar.rawValue, CaptureWindowLevels.overlay.rawValue)
        XCTAssertLessThan(CaptureWindowLevels.toolbar.rawValue, NSWindow.Level.screenSaver.rawValue)
    }
}
