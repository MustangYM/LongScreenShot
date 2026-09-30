import AppKit
import XCTest
@testable import LongScreenShot

final class StatusPopoverTests: XCTestCase {
    func testCommandsAndSeparatorsRetainTheirActionsWithoutMenuTracking() {
        let menu = NSMenu()
        menu.addItem(withTitle: "截图", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置", action: nil, keyEquivalent: ",")
        let content = StatusPopoverContent(menu: menu)
        let stack = content.view as! NSStackView
        let buttons = stack.arrangedSubviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.map(\.title), ["截图", "设置"])
        XCTAssertEqual(stack.arrangedSubviews.count, 3)
        XCTAssertEqual(buttons[1].keyEquivalent, ",")
        XCTAssertGreaterThan(content.preferredContentSize.height, 50)
        var selected: NSMenuItem?
        content.onSelect = { selected = $0 }
        buttons[1].performClick(nil)
        XCTAssertTrue(selected === menu.items[2])
        buttons[0].performClick(nil)
        XCTAssertTrue(selected === menu.items[0])
    }

    func testEscapeRequestsPopoverDismissal() {
        let content = StatusPopoverContent(menu: NSMenu())
        var cancelled = false
        content.onCancel = { cancelled = true }
        content.cancelOperation(nil)
        XCTAssertTrue(cancelled)
    }
}
