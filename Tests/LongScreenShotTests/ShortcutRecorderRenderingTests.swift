import AppKit
import XCTest
@testable import LongScreenShot

final class ShortcutRecorderRenderingTests: XCTestCase {
    func testAllShortcutRowsRenderWhileScrollingInBothAppearances() throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 160))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 640))
        scroll.documentView = document
        let rows = CaptureCommand.allCases.enumerated().map { index, command in
            let row = ToolShortcutRecorderView(command: command)
            row.frame = NSRect(x: 10, y: index * 40, width: 240, height: 32)
            document.addSubview(row)
            XCTAssertEqual(row.displayLabel.stringValue, ToolShortcutStore.configuration(for: command).displayString)
            return row
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            scroll.appearance = NSAppearance(named: appearance)
            for offset in stride(from: 0, through: 480, by: 40) {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                for row in rows {
                    row.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                    row.cacheDisplay(in: row.bounds, to: bitmap)
                    XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                }
            }
        }
    }

    func testRecordingErrorAndCancelUpdateNativeLabel() throws {
        let row = ToolShortcutRecorderView(command: .cancel)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 32)
        let normal = row.displayLabel.stringValue
        row.recording = true
        XCTAssertEqual(row.displayLabel.stringValue, L10n.tr("settings.recordHotKey"))
        row.validationMessage = "快捷键冲突：⌘⇧Z / Shortcut already in use"
        XCTAssertEqual(row.displayLabel.stringValue, row.validationMessage)
        row.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        row.keyDown(with: escape)
        XCTAssertEqual(row.displayLabel.stringValue, normal)
        XCTAssertFalse(row.recording)
        XCTAssertNil(row.validationMessage)
    }

    func testGlobalShortcutChangesRefreshLabelAndLabelDoesNotInterceptClicks() {
        let row = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        row.configuration = .defaultValue
        XCTAssertEqual(row.displayLabel.stringValue, HotKeyConfiguration.defaultValue.displayString)
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.hitTest(NSPoint(x: 120, y: 16)) === row)
    }
}
