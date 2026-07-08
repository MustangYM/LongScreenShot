import AppKit
import Carbon
import CoreGraphics
import ServiceManagement

private enum StatusBarIconFactory {
    static func image() -> NSImage {
        if let custom = NSImage(named: "StatusBarIcon"), !custom.representations.isEmpty {
            let image = (custom.copy() as? NSImage) ?? custom
            image.size = NSSize(width: 18, height: 18)

            // 关键：不要让系统当模板图标自动染色
            image.isTemplate = false

            return image
        }

        return generatedWhiteIcon()
    }

    private static func whiteMaskImage(from source: NSImage) -> NSImage {
        let pointSize = NSSize(width: 18, height: 18)
        let pixelSize = 42
        guard let sourceRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let outputRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return generatedWhiteIcon() }

        sourceRep.size = pointSize
        outputRep.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sourceRep)
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: pointSize).fill()
        source.draw(
            in: NSRect(origin: .zero, size: pointSize).insetBy(dx: 1, dy: 1),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        var paintedPixels = 0
        for y in 0..<pixelSize {
            for x in 0..<pixelSize {
                guard let color = sourceRep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = color.alphaComponent
                guard alpha > 0.04 else { continue }
                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                let saturation = max(red, green, blue) - min(red, green, blue)
                // 只保留图标线条：深色像素直接保留；有明显色彩但不接近白色的像素也保留。
                // 这样即使源图不小心带了浅色/棋盘格背景，也不会被染成一整块白方形。
                guard luminance < 0.76 || (saturation > 0.16 && luminance < 0.88) else { continue }
                outputRep.setColor(NSColor.white.withAlphaComponent(min(1, max(0.12, alpha))), atX: x, y: y)
                paintedPixels += 1
            }
        }
        guard paintedPixels > 8 else { return generatedWhiteIcon() }
        let image = NSImage(size: pointSize)
        image.addRepresentation(outputRep)
        image.isTemplate = false
        return image
    }

    private static func generatedWhiteIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { rect in
            func makeCorners(in rect: NSRect, offset: CGFloat = 0) -> NSBezierPath {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                let inset: CGFloat = 2.6
                let corner: CGFloat = 4.7
                path.move(to: CGPoint(x: rect.minX + inset + corner, y: rect.maxY - inset + offset))
                path.line(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset + offset))
                path.line(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset - corner + offset))
                path.move(to: CGPoint(x: rect.maxX - inset - corner, y: rect.maxY - inset + offset))
                path.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset + offset))
                path.line(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset - corner + offset))
                path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset + corner + offset))
                path.line(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset + offset))
                path.line(to: CGPoint(x: rect.minX + inset + corner, y: rect.minY + inset + offset))
                path.move(to: CGPoint(x: rect.maxX - inset - corner, y: rect.minY + inset + offset))
                path.line(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset + offset))
                path.line(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset + corner + offset))
                return path
            }

            func makeArrow(in rect: NSRect, offset: CGFloat = 0) -> NSBezierPath {
                let path = NSBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: CGPoint(x: rect.midX, y: rect.maxY - 5.4 + offset))
                path.line(to: CGPoint(x: rect.midX, y: rect.minY + 5.8 + offset))
                path.move(to: CGPoint(x: rect.midX - 3.3, y: rect.minY + 8.6 + offset))
                path.line(to: CGPoint(x: rect.midX, y: rect.minY + 5.4 + offset))
                path.line(to: CGPoint(x: rect.midX + 3.3, y: rect.minY + 8.6 + offset))
                return path
            }

            NSColor.black.withAlphaComponent(0.34).setStroke()
            let shadowCorners = makeCorners(in: rect, offset: -0.45)
            shadowCorners.lineWidth = 3.0
            shadowCorners.stroke()
            let shadowArrow = makeArrow(in: rect, offset: -0.45)
            shadowArrow.lineWidth = 3.0
            shadowArrow.stroke()

            NSColor.white.setStroke()
            let corners = makeCorners(in: rect)
            corners.lineWidth = 2.0
            corners.stroke()
            let arrow = makeArrow(in: rect)
            arrow.lineWidth = 2.0
            arrow.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private var captureCoordinator: CaptureCoordinator?
    private var settingsController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        registerHotKey()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registerHotKey),
            name: .hotKeyDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appLanguageDidChange),
            name: .appLanguageDidChange,
            object: nil
        )
        UpdateChecker.shared.checkAutomaticallyIfNeeded()
    }

    private func refreshStatusItemIcon() {
        guard let button = statusItem?.button else { return }

        button.title = ""
        button.toolTip = "LongScreenShot"
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        // 强制原图显示时，不要再给 template tint
        button.contentTintColor = nil

        let image = StatusBarIconFactory.image()
        image.isTemplate = false
        button.image = image
    }

    private func configureStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        statusItem.length = 28
        refreshStatusItemIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refreshStatusItemIcon()
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L10n.tr("menu.capture"), action: #selector(startCapture), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("menu.longCapture"), action: #selector(startLongCapture), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("menu.history"), action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L10n.tr("menu.closePins"), action: #selector(closePins), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L10n.tr("menu.checkUpdates"), action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("menu.settings"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L10n.tr("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.items.first?.keyEquivalent = ""
        menu.items.first?.keyEquivalentModifierMask = []
        menu.items.first?.title = "\(L10n.tr("menu.capture"))    \(HotKeyConfiguration.current.displayString)"
    }

    @objc private func registerHotKey() {
        hotKey = nil
        hotKey = GlobalHotKey(configuration: .current) { [weak self] in
            self?.beginCapture(longMode: false)
        }
    }

    @objc private func appLanguageDidChange() {
        configureStatusItem()
        settingsController?.refreshLanguage()
    }

    @objc private func startCapture() { beginCapture(longMode: false) }
    @objc private func startLongCapture() { beginCapture(longMode: true) }
    @objc private func checkForUpdates() { UpdateChecker.shared.checkForUpdates(userInitiated: true) }
    @objc private func showHistory() { CaptureHistoryWindowController.shared.showAtPointer() }

    private func beginCapture(longMode: Bool) {
        guard captureCoordinator == nil else { return }
        guard ScreenCaptureAuthorization.ensureAuthorized() else {
            showPermissionAlert()
            return
        }
        settingsController?.window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            let coordinator = CaptureCoordinator(initialLongMode: longMode)
            self.captureCoordinator = coordinator
            coordinator.onFinish = { [weak self] in self?.captureCoordinator = nil }
            coordinator.start()
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("permission.title")
        alert.informativeText = L10n.tr("permission.message")
        alert.addButton(withTitle: L10n.tr("permission.openSettings"))
        alert.addButton(withTitle: L10n.tr("common.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCaptureAuthorization.openSystemSettings()
        }
    }

    @objc private func closePins() { PinWindowController.closeAll() }

    @objc private func showSettings() {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.presentFromStatusMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

enum ScreenCaptureAuthorization {
    static func ensureAuthorized() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

extension Notification.Name {
    static let hotKeyDidChange = Notification.Name("LongScreenShot.hotKeyDidChange")
    static let appLanguageDidChange = Notification.Name("LongScreenShot.appLanguageDidChange")
}

enum AppLanguage: String, CaseIterable {
    case system
    case zhHans
    case en
    case ja
    case ko
    case fr
    case de
    case es

    static let defaultsKey = "appLanguage"

    static var current: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let language = AppLanguage(rawValue: raw) else { return .system }
            return language
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: nil)
        }
    }

    var displayName: String {
        switch self {
        case .system: return L10n.tr("language.system")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        }
    }

    var code: String {
        switch self {
        case .system:
            return Self.systemResolved.code
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .es: return "es"
        }
    }

    private static var systemResolved: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return .zhHans }
        if preferred.hasPrefix("ja") { return .ja }
        if preferred.hasPrefix("ko") { return .ko }
        if preferred.hasPrefix("fr") { return .fr }
        if preferred.hasPrefix("de") { return .de }
        if preferred.hasPrefix("es") { return .es }
        return .en
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return UserDefaults.standard.bool(forKey: "launchAtLoginFallback")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } else {
            UserDefaults.standard.set(enabled, forKey: "launchAtLoginFallback")
        }
    }
}

enum L10n {
    static func tr(_ key: String) -> String {
        let language = AppLanguage.current.code
        return table[language]?[key]
            ?? table[String(language.prefix(2))]?[key]
            ?? table["en"]?[key]
            ?? table["zh-Hans"]?[key]
            ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), arguments: arguments)
    }

    private static let table: [String: [String: String]] = [
        "zh-Hans": [
            "language.system": "跟随系统",
            "menu.capture": "框选截图",
            "menu.longCapture": "长截图",
            "menu.history": "历史截图",
            "menu.closePins": "关闭所有图钉",
            "menu.settings": "设置…",
            "menu.checkUpdates": "检查更新…",
            "menu.quit": "退出 LongScreenShot",
            "permission.title": "需要屏幕录制权限",
            "permission.message": "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 LongScreenShot，然后重新启动应用。",
            "permission.openSettings": "打开系统设置",
            "common.cancel": "取消",
            "common.ok": "确定",
            "common.copy": "复制",
            "common.later": "稍后",
            "settings.title": "LongScreenShot 设置",
            "settings.general": "通用",
            "settings.about": "关于",
            "settings.language": "语言",
            "settings.launchAtLogin": "开机自动启动 LongScreenShot",
            "settings.hotkey": "框选截图快捷键",
            "settings.hotkeyHint": "点击快捷键框，然后按下包含 ⌘ / ⌥ / ⌃ 的组合键；按 Esc 取消，Delete 恢复默认。",
            "settings.translationProvider": "翻译引擎",
            "settings.translationHint": "默认使用百度翻译；翻译时会优先在 App 内显示左右双栏结果，如果网页接口不可用则自动打开对应翻译网页。",
            "settings.screenRecordingGranted": "● 屏幕录制：已授权",
            "settings.screenRecordingDenied": "● 屏幕录制：未授权",
            "settings.restoreDefault": "恢复默认",
            "settings.recordHotKey": "请按快捷键…",
            "settings.launchFailed": "无法修改开机启动设置",
            "settings.version": "版本 %@ (%@)",
            "settings.developer": "开发者",
            "settings.projectHomepage": "免费开源主页",
            "settings.contact": "联系开发者",
            "settings.privacyNote": "本应用在本机完成截图、标注和 OCR；翻译会按你选择的引擎发送识别文本。",
            "settings.autoCheckUpdates": "自动检查更新并提醒",
            "settings.checkUpdates": "检查更新…",
            "settings.updateHint": "自动检查会访问 GitHub Releases；发现新版本时会提醒你打开下载页，不会在后台悄悄替换应用。",
            "settings.quickCopyOnConfirm": "双击或按回车时直接复制截图",
            "settings.history": "历史截图",
            "settings.saveHistory": "保存历史截图",
            "settings.historyLimit": "最多保留",
            "settings.historyLocation": "保存位置",
            "settings.choose": "选择…",
            "settings.historyHint": "最多保留 1～200 张；超过数量后会自动删除最旧的截图。历史窗口可从菜单栏打开。",
            "update.checking": "正在检查更新…",
            "update.availableTitle": "发现新版本",
            "update.availableMessage": "%@ 已发布；当前版本是 %@。",
            "update.openRelease": "打开下载页",
            "update.noUpdateTitle": "已是最新版本",
            "update.noUpdateMessage": "当前版本 %@ 已是最新。",
            "update.failedTitle": "无法检查更新",
            "update.failedMessage": "GitHub Releases 暂时不可用，请稍后再试。",
            "history.title": "历史截图",
            "history.empty": "还没有历史截图",
            "history.delete": "删除",
            "history.deleted": "已移除截图",
            "history.showInFinder": "在 Finder 中显示",
            "history.justNow": "刚刚",
            "history.minutesAgo": "%d 分钟前",
            "history.hoursAgo": "%d 小时前",
            "history.oneDayAgo": "一天前",
            "feedback.copied": "已复制到剪贴板",
            "feedback.undone": "已撤销上一步",
            "feedback.noUndo": "没有可撤销的操作",
            "provider.baidu": "百度翻译",
            "provider.google": "谷歌翻译",
            "toolbar.rectangle": "矩形",
            "toolbar.ellipse": "圆圈",
            "toolbar.arrow": "箭头",
            "toolbar.text": "文字",
            "toolbar.pen": "画笔",
            "toolbar.longCapture": "长截图（滚动页面）",
            "toolbar.mosaic": "马赛克样式与程度",
            "toolbar.pin": "图钉",
            "toolbar.translate": "翻译",
            "toolbar.undo": "撤销",
            "toolbar.redo": "重做",
            "toolbar.cancel": "退出",
            "toolbar.confirmCopy": "确定并复制",
            "toolbar.save": "保存",
            "toolbar.finishLongCapture": "完成长截图并复制",
            "ocr.noText": "未识别到文字",
            "ocr.title": "OCR 识别结果",
            "translation.windowTitle": "翻译结果（%@）",
            "translation.title": "翻译结果",
            "translation.subtitle": "左侧为 OCR 原文，右侧为翻译内容",
            "translation.copySource": "复制原文",
            "translation.copyTranslated": "复制译文",
            "translation.openWeb": "网页打开",
            "translation.source": "原文",
            "translation.translated": "译文",
            "translation.empty": "未翻译到内容",
            "long.finishing": "正在完成拼接…",
            "long.scrollHint": "请手动向下滚动并稍作停顿",
            "long.scrollInSelection": "请在选区内手动向下滚动",
            "long.frames": "已采集 %d 帧",
            "long.manualMessage": "手动滚动页面 · 在右侧预览中完成",
            "long.minimapTitle": "长截图实时全图",
            "text.placeholder": "输入文字，回车确认，Esc 取消",
            "style.text": "文字",
            "style.stroke": "线条",
            "style.mosaic": "马赛克",
            "style.pixel": "像素",
            "style.blur": "模糊",
            "color.red": "红色",
            "color.orange": "橙色",
            "color.yellow": "黄色",
            "color.green": "绿色",
            "color.blue": "蓝色",
            "color.white": "白色",
            "color.black": "黑色"
        ],
        "en": [
            "language.system": "Follow System",
            "menu.capture": "Area Capture",
            "menu.longCapture": "Scrolling Capture",
            "menu.history": "Screenshot History",
            "menu.closePins": "Close All Pins",
            "menu.settings": "Settings…",
            "menu.checkUpdates": "Check for Updates…",
            "menu.quit": "Quit LongScreenShot",
            "permission.title": "Screen Recording Permission Required",
            "permission.message": "Allow LongScreenShot in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app.",
            "permission.openSettings": "Open System Settings",
            "common.cancel": "Cancel",
            "common.ok": "OK",
            "common.copy": "Copy",
            "common.later": "Later",
            "settings.title": "LongScreenShot Settings",
            "settings.general": "General",
            "settings.about": "About",
            "settings.language": "Language",
            "settings.launchAtLogin": "Launch LongScreenShot at login",
            "settings.hotkey": "Area capture hotkey",
            "settings.hotkeyHint": "Click the field and press a shortcut containing ⌘ / ⌥ / ⌃. Esc cancels; Delete restores default.",
            "settings.translationProvider": "Translation engine",
            "settings.translationHint": "Baidu is the default. Translation first appears in a two-column in-app window; if the web endpoint fails, the matching translation page opens.",
            "settings.screenRecordingGranted": "● Screen Recording: Granted",
            "settings.screenRecordingDenied": "● Screen Recording: Not Granted",
            "settings.restoreDefault": "Restore Default",
            "settings.recordHotKey": "Press shortcut…",
            "settings.launchFailed": "Could not update launch-at-login",
            "settings.version": "Version %@ (%@)",
            "settings.developer": "Developer",
            "settings.projectHomepage": "Free open-source project",
            "settings.contact": "Contact",
            "settings.privacyNote": "Screenshots, annotation and OCR run locally. Translation sends recognized text to the selected engine.",
            "settings.autoCheckUpdates": "Automatically check for updates",
            "settings.checkUpdates": "Check for Updates…",
            "settings.updateHint": "The app checks GitHub Releases and prompts you when a new version is available. It will not replace the app silently in the background.",
            "settings.quickCopyOnConfirm": "Double-click or press Return to copy",
            "settings.history": "History",
            "settings.saveHistory": "Save screenshot history",
            "settings.historyLimit": "Keep up to",
            "settings.historyLocation": "Save location",
            "settings.choose": "Choose…",
            "settings.historyHint": "Keep 1–200 screenshots. Older items are removed automatically. Open history from the menu bar.",
            "update.checking": "Checking for updates…",
            "update.availableTitle": "A New Version Is Available",
            "update.availableMessage": "%@ is available. Current version: %@.",
            "update.openRelease": "Open Download Page",
            "update.noUpdateTitle": "You’re Up to Date",
            "update.noUpdateMessage": "Version %@ is the latest version.",
            "update.failedTitle": "Could Not Check for Updates",
            "update.failedMessage": "GitHub Releases is temporarily unavailable. Please try again later.",
            "history.title": "Screenshot History",
            "history.empty": "No screenshots yet",
            "history.delete": "Delete",
            "history.deleted": "Screenshot Removed",
            "history.showInFinder": "Show in Finder",
            "history.justNow": "just now",
            "history.minutesAgo": "%d min ago",
            "history.hoursAgo": "%d hr ago",
            "history.oneDayAgo": "1 day ago",
            "feedback.copied": "Copied to Clipboard",
            "feedback.undone": "Last Action Undone",
            "feedback.noUndo": "Nothing to Undo",
            "provider.baidu": "Baidu Translate",
            "provider.google": "Google Translate",
            "toolbar.rectangle": "Rectangle",
            "toolbar.ellipse": "Ellipse",
            "toolbar.arrow": "Arrow",
            "toolbar.text": "Text",
            "toolbar.pen": "Pen",
            "toolbar.longCapture": "Scrolling capture",
            "toolbar.mosaic": "Mosaic style and intensity",
            "toolbar.pin": "Pin",
            "toolbar.translate": "Translate",
            "toolbar.undo": "Undo",
            "toolbar.redo": "Redo",
            "toolbar.cancel": "Exit",
            "toolbar.confirmCopy": "Confirm and copy",
            "toolbar.save": "Save",
            "toolbar.finishLongCapture": "Finish scrolling capture and copy",
            "ocr.noText": "No text recognized",
            "ocr.title": "OCR Result",
            "translation.windowTitle": "Translation Result (%@)",
            "translation.title": "Translation Result",
            "translation.subtitle": "OCR source on the left, translation on the right",
            "translation.copySource": "Copy Source",
            "translation.copyTranslated": "Copy Translation",
            "translation.openWeb": "Open Web",
            "translation.source": "Source",
            "translation.translated": "Translation",
            "translation.empty": "No translation",
            "long.finishing": "Finishing stitch…",
            "long.scrollHint": "Scroll down manually and pause briefly",
            "long.scrollInSelection": "Scroll down inside the selected area",
            "long.frames": "Captured %d frames",
            "long.manualMessage": "Manual scrolling · finish from the right preview",
            "long.minimapTitle": "Live full preview",
            "text.placeholder": "Type text, Enter to confirm, Esc to cancel",
            "style.text": "Text",
            "style.stroke": "Stroke",
            "style.mosaic": "Mosaic",
            "style.pixel": "Pixel",
            "style.blur": "Blur",
            "color.red": "Red",
            "color.orange": "Orange",
            "color.yellow": "Yellow",
            "color.green": "Green",
            "color.blue": "Blue",
            "color.white": "White",
            "color.black": "Black"
        ],
        "ja": [
            "language.system": "システムに合わせる",
            "menu.capture": "範囲スクリーンショット",
            "menu.longCapture": "スクロールキャプチャ",
            "menu.history": "履歴",
            "menu.closePins": "すべてのピンを閉じる",
            "menu.settings": "設定…",
            "menu.checkUpdates": "アップデートを確認…",
            "menu.quit": "LongScreenShot を終了",
            "permission.title": "画面収録の権限が必要です",
            "permission.message": "システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ収録で LongScreenShot を許可してから、アプリを再起動してください。",
            "permission.openSettings": "システム設定を開く",
            "common.cancel": "キャンセル",
            "common.ok": "OK",
            "common.copy": "コピー",
            "common.later": "あとで",
            "settings.title": "LongScreenShot 設定",
            "settings.general": "一般",
            "settings.about": "このアプリについて",
            "settings.language": "言語",
            "settings.launchAtLogin": "ログイン時に LongScreenShot を起動",
            "settings.hotkey": "範囲キャプチャのショートカット",
            "settings.hotkeyHint": "入力欄をクリックし、⌘ / ⌥ / ⌃ を含むショートカットを押してください。Esc でキャンセル、Delete で既定に戻します。",
            "settings.translationProvider": "翻訳エンジン",
            "settings.translationHint": "既定は百度翻訳です。翻訳結果はまずアプリ内の左右 2 カラムで表示し、Web インターフェイスが使えない場合は対応する翻訳ページを開きます。",
            "settings.screenRecordingGranted": "● 画面収録：許可済み",
            "settings.screenRecordingDenied": "● 画面収録：未許可",
            "settings.restoreDefault": "既定に戻す",
            "settings.recordHotKey": "ショートカットを入力…",
            "settings.launchFailed": "ログイン時起動の設定を変更できません",
            "settings.version": "バージョン %@ (%@)",
            "settings.developer": "開発者",
            "settings.projectHomepage": "無料オープンソースのプロジェクト",
            "settings.contact": "開発者に連絡",
            "settings.privacyNote": "スクリーンショット、注釈、OCR はこの Mac 上で処理されます。翻訳では認識したテキストを選択したエンジンへ送信します。",
            "settings.autoCheckUpdates": "アップデートを自動確認して通知",
            "settings.checkUpdates": "アップデートを確認…",
            "settings.updateHint": "GitHub Releases を確認し、新しいバージョンがある場合はダウンロードページを開くよう通知します。バックグラウンドでアプリを勝手に置き換えることはありません。",
            "settings.quickCopyOnConfirm": "ダブルクリックまたは Return でコピー",
            "settings.history": "履歴",
            "settings.saveHistory": "スクリーンショット履歴を保存",
            "settings.historyLimit": "最大保存数",
            "settings.historyLocation": "保存場所",
            "settings.choose": "選択…",
            "settings.historyHint": "1〜200 枚まで保存できます。古い項目は自動的に削除されます。履歴はメニューバーから開けます。",
            "update.checking": "アップデートを確認中…",
            "update.availableTitle": "新しいバージョンがあります",
            "update.availableMessage": "%@ が利用可能です。現在のバージョン：%@。",
            "update.openRelease": "ダウンロードページを開く",
            "update.noUpdateTitle": "最新バージョンです",
            "update.noUpdateMessage": "現在のバージョン %@ は最新です。",
            "update.failedTitle": "アップデートを確認できません",
            "update.failedMessage": "GitHub Releases を一時的に利用できません。あとでもう一度お試しください。",
            "history.title": "スクリーンショット履歴",
            "history.empty": "履歴はまだありません",
            "history.delete": "削除",
            "history.deleted": "スクリーンショットを削除しました",
            "history.showInFinder": "Finder に表示",
            "history.justNow": "たった今",
            "history.minutesAgo": "%d 分前",
            "history.hoursAgo": "%d 時間前",
            "history.oneDayAgo": "1日前",
            "feedback.copied": "クリップボードにコピーしました",
            "feedback.undone": "直前の操作を取り消しました",
            "feedback.noUndo": "取り消せる操作はありません",
            "provider.baidu": "百度翻訳",
            "provider.google": "Google 翻訳",
            "toolbar.rectangle": "四角形",
            "toolbar.ellipse": "円",
            "toolbar.arrow": "矢印",
            "toolbar.text": "テキスト",
            "toolbar.pen": "ペン",
            "toolbar.longCapture": "長いスクロールキャプチャ",
            "toolbar.mosaic": "モザイクの種類と強さ",
            "toolbar.pin": "ピン留め",
            "toolbar.translate": "翻訳",
            "toolbar.undo": "取り消す",
            "toolbar.redo": "やり直す",
            "toolbar.cancel": "終了",
            "toolbar.confirmCopy": "確定してコピー",
            "toolbar.save": "保存",
            "toolbar.finishLongCapture": "スクロールキャプチャを完了してコピー",
            "ocr.noText": "文字を認識できませんでした",
            "ocr.title": "OCR 結果",
            "translation.windowTitle": "翻訳結果（%@）",
            "translation.title": "翻訳結果",
            "translation.subtitle": "左が OCR 原文、右が翻訳結果です",
            "translation.copySource": "原文をコピー",
            "translation.copyTranslated": "訳文をコピー",
            "translation.openWeb": "Web で開く",
            "translation.source": "原文",
            "translation.translated": "翻訳",
            "translation.empty": "翻訳結果がありません",
            "long.finishing": "結合を完了中…",
            "long.scrollHint": "手動で下へスクロールし、少し停止してください",
            "long.scrollInSelection": "選択範囲内で下へスクロールしてください",
            "long.frames": "%d フレーム取得済み",
            "long.manualMessage": "手動スクロール · 右側プレビューで完了します",
            "long.minimapTitle": "長いスクリーンショットのリアルタイム全体表示",
            "text.placeholder": "テキストを入力。Enter で確定、Esc でキャンセル",
            "style.text": "テキスト",
            "style.stroke": "線",
            "style.mosaic": "モザイク",
            "style.pixel": "ピクセル",
            "style.blur": "ぼかし",
            "color.red": "赤",
            "color.orange": "オレンジ",
            "color.yellow": "黄",
            "color.green": "緑",
            "color.blue": "青",
            "color.white": "白",
            "color.black": "黒"
        ],
        "ko": [
            "language.system": "시스템 설정 사용",
            "menu.capture": "영역 캡처",
            "menu.longCapture": "스크롤 캡처",
            "menu.history": "스크린샷 기록",
            "menu.closePins": "모든 핀 닫기",
            "menu.settings": "설정…",
            "menu.checkUpdates": "업데이트 확인…",
            "menu.quit": "LongScreenShot 종료",
            "permission.title": "화면 기록 권한 필요",
            "permission.message": "시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 LongScreenShot을 허용한 뒤 앱을 다시 시작하세요.",
            "permission.openSettings": "시스템 설정 열기",
            "common.cancel": "취소",
            "common.ok": "확인",
            "common.copy": "복사",
            "common.later": "나중에",
            "settings.title": "LongScreenShot 설정",
            "settings.general": "일반",
            "settings.about": "정보",
            "settings.language": "언어",
            "settings.launchAtLogin": "로그인 시 LongScreenShot 실행",
            "settings.hotkey": "영역 캡처 단축키",
            "settings.hotkeyHint": "입력 칸을 클릭한 뒤 ⌘ / ⌥ / ⌃ 이 포함된 단축키를 누르세요. Esc는 취소, Delete는 기본값 복원입니다.",
            "settings.translationProvider": "번역 엔진",
            "settings.translationHint": "기본값은 바이두 번역입니다. 번역 결과는 먼저 앱 안의 좌우 2열 창에 표시되며, 웹 인터페이스를 사용할 수 없으면 해당 번역 페이지를 엽니다.",
            "settings.screenRecordingGranted": "● 화면 기록: 허용됨",
            "settings.screenRecordingDenied": "● 화면 기록: 허용되지 않음",
            "settings.restoreDefault": "기본값 복원",
            "settings.recordHotKey": "단축키 입력…",
            "settings.launchFailed": "로그인 시 실행 설정을 변경할 수 없습니다",
            "settings.version": "버전 %@ (%@)",
            "settings.developer": "개발자",
            "settings.projectHomepage": "무료 오픈소스 프로젝트",
            "settings.contact": "개발자 연락처",
            "settings.privacyNote": "스크린샷, 주석, OCR은 이 Mac에서 처리됩니다. 번역은 인식된 텍스트를 선택한 엔진으로 전송합니다.",
            "settings.autoCheckUpdates": "업데이트 자동 확인 및 알림",
            "settings.checkUpdates": "업데이트 확인…",
            "settings.updateHint": "GitHub Releases를 확인하고 새 버전이 있으면 다운로드 페이지를 열도록 알려줍니다. 백그라운드에서 앱을 자동으로 교체하지 않습니다.",
            "settings.quickCopyOnConfirm": "두 번 클릭 또는 Return으로 복사",
            "settings.history": "기록",
            "settings.saveHistory": "스크린샷 기록 저장",
            "settings.historyLimit": "최대 보관",
            "settings.historyLocation": "저장 위치",
            "settings.choose": "선택…",
            "settings.historyHint": "1~200장을 보관합니다. 오래된 항목은 자동으로 삭제됩니다. 기록은 메뉴 막대에서 열 수 있습니다.",
            "update.checking": "업데이트 확인 중…",
            "update.availableTitle": "새 버전이 있습니다",
            "update.availableMessage": "%@ 버전을 사용할 수 있습니다. 현재 버전: %@.",
            "update.openRelease": "다운로드 페이지 열기",
            "update.noUpdateTitle": "최신 버전입니다",
            "update.noUpdateMessage": "현재 버전 %@이 최신입니다.",
            "update.failedTitle": "업데이트를 확인할 수 없습니다",
            "update.failedMessage": "GitHub Releases를 일시적으로 사용할 수 없습니다. 나중에 다시 시도하세요.",
            "history.title": "스크린샷 기록",
            "history.empty": "아직 기록이 없습니다",
            "history.delete": "삭제",
            "history.deleted": "스크린샷을 제거했습니다",
            "history.showInFinder": "Finder에서 보기",
            "history.justNow": "방금",
            "history.minutesAgo": "%d분 전",
            "history.hoursAgo": "%d시간 전",
            "history.oneDayAgo": "하루 전",
            "feedback.copied": "클립보드에 복사됨",
            "feedback.undone": "마지막 작업을 취소했습니다",
            "feedback.noUndo": "취소할 작업이 없습니다",
            "provider.baidu": "바이두 번역",
            "provider.google": "구글 번역",
            "toolbar.rectangle": "사각형",
            "toolbar.ellipse": "원",
            "toolbar.arrow": "화살표",
            "toolbar.text": "텍스트",
            "toolbar.pen": "펜",
            "toolbar.longCapture": "긴 스크롤 캡처",
            "toolbar.mosaic": "모자이크 스타일과 강도",
            "toolbar.pin": "핀",
            "toolbar.translate": "번역",
            "toolbar.undo": "실행 취소",
            "toolbar.redo": "다시 실행",
            "toolbar.cancel": "나가기",
            "toolbar.confirmCopy": "확인하고 복사",
            "toolbar.save": "저장",
            "toolbar.finishLongCapture": "스크롤 캡처 완료 후 복사",
            "ocr.noText": "인식된 텍스트 없음",
            "ocr.title": "OCR 결과",
            "translation.windowTitle": "번역 결과(%@)",
            "translation.title": "번역 결과",
            "translation.subtitle": "왼쪽은 OCR 원문, 오른쪽은 번역문입니다",
            "translation.copySource": "원문 복사",
            "translation.copyTranslated": "번역문 복사",
            "translation.openWeb": "웹에서 열기",
            "translation.source": "원문",
            "translation.translated": "번역",
            "translation.empty": "번역 결과 없음",
            "long.finishing": "이어붙이는 중…",
            "long.scrollHint": "수동으로 아래로 스크롤하고 잠시 멈춰 주세요",
            "long.scrollInSelection": "선택 영역 안에서 아래로 스크롤하세요",
            "long.frames": "%d 프레임 캡처됨",
            "long.manualMessage": "수동 스크롤 · 오른쪽 미리보기에서 완료",
            "long.minimapTitle": "긴 스크린샷 실시간 전체 보기",
            "text.placeholder": "텍스트 입력, Enter로 확인, Esc로 취소",
            "style.text": "텍스트",
            "style.stroke": "선",
            "style.mosaic": "모자이크",
            "style.pixel": "픽셀",
            "style.blur": "흐림",
            "color.red": "빨강",
            "color.orange": "주황",
            "color.yellow": "노랑",
            "color.green": "초록",
            "color.blue": "파랑",
            "color.white": "흰색",
            "color.black": "검정"
        ],
        "fr": [
            "language.system": "Suivre le système",
            "menu.capture": "Capture de zone",
            "menu.longCapture": "Capture défilante",
            "menu.history": "Historique",
            "menu.closePins": "Fermer toutes les épingles",
            "menu.settings": "Réglages…",
            "menu.checkUpdates": "Rechercher des mises à jour…",
            "menu.quit": "Quitter LongScreenShot",
            "permission.title": "Autorisation d’enregistrement d’écran requise",
            "permission.message": "Autorisez LongScreenShot dans Réglages Système → Confidentialité et sécurité → Enregistrement de l’écran et de l’audio système, puis redémarrez l’app.",
            "permission.openSettings": "Ouvrir Réglages Système",
            "common.cancel": "Annuler",
            "common.ok": "OK",
            "common.copy": "Copier",
            "common.later": "Plus tard",
            "settings.title": "Réglages LongScreenShot",
            "settings.general": "Général",
            "settings.about": "À propos",
            "settings.language": "Langue",
            "settings.launchAtLogin": "Lancer LongScreenShot à l’ouverture de session",
            "settings.hotkey": "Raccourci de capture de zone",
            "settings.hotkeyHint": "Cliquez dans le champ puis appuyez sur un raccourci contenant ⌘ / ⌥ / ⌃. Esc annule ; Delete restaure la valeur par défaut.",
            "settings.translationProvider": "Moteur de traduction",
            "settings.translationHint": "Baidu est utilisé par défaut. La traduction s’affiche d’abord dans une fenêtre intégrée à deux colonnes ; si l’interface web échoue, la page de traduction correspondante s’ouvre.",
            "settings.screenRecordingGranted": "● Enregistrement d’écran : autorisé",
            "settings.screenRecordingDenied": "● Enregistrement d’écran : non autorisé",
            "settings.restoreDefault": "Restaurer",
            "settings.recordHotKey": "Appuyez sur le raccourci…",
            "settings.launchFailed": "Impossible de modifier le lancement à l’ouverture de session",
            "settings.version": "Version %@ (%@)",
            "settings.developer": "Développeur",
            "settings.projectHomepage": "Projet libre et gratuit",
            "settings.contact": "Contacter le développeur",
            "settings.privacyNote": "Les captures, annotations et l’OCR s’exécutent localement. La traduction envoie le texte reconnu au moteur choisi.",
            "settings.autoCheckUpdates": "Rechercher automatiquement les mises à jour",
            "settings.checkUpdates": "Rechercher…",
            "settings.updateHint": "L’app consulte GitHub Releases et vous prévient lorsqu’une nouvelle version est disponible. Elle ne remplace pas l’app en arrière-plan sans action de votre part.",
            "settings.quickCopyOnConfirm": "Double-clic ou Retour pour copier",
            "settings.history": "Historique",
            "settings.saveHistory": "Enregistrer l’historique",
            "settings.historyLimit": "Conserver",
            "settings.historyLocation": "Emplacement",
            "settings.choose": "Choisir…",
            "settings.historyHint": "Conserve 1 à 200 captures. Les plus anciennes sont supprimées automatiquement. L’historique s’ouvre depuis la barre des menus.",
            "update.checking": "Recherche de mises à jour…",
            "update.availableTitle": "Nouvelle version disponible",
            "update.availableMessage": "%@ est disponible. Version actuelle : %@.",
            "update.openRelease": "Ouvrir la page de téléchargement",
            "update.noUpdateTitle": "Vous êtes à jour",
            "update.noUpdateMessage": "La version %@ est la dernière version.",
            "update.failedTitle": "Impossible de rechercher les mises à jour",
            "update.failedMessage": "GitHub Releases est temporairement indisponible. Réessayez plus tard.",
            "history.title": "Historique des captures",
            "history.empty": "Aucune capture pour le moment",
            "history.delete": "Supprimer",
            "history.deleted": "Capture supprimée",
            "history.showInFinder": "Afficher dans le Finder",
            "history.justNow": "à l’instant",
            "history.minutesAgo": "il y a %d min",
            "history.hoursAgo": "il y a %d h",
            "history.oneDayAgo": "il y a 1 jour",
            "feedback.copied": "Copié dans le presse-papiers",
            "feedback.undone": "Dernière action annulée",
            "feedback.noUndo": "Rien à annuler",
            "provider.baidu": "Baidu Traduction",
            "provider.google": "Google Traduction",
            "toolbar.rectangle": "Rectangle",
            "toolbar.ellipse": "Cercle",
            "toolbar.arrow": "Flèche",
            "toolbar.text": "Texte",
            "toolbar.pen": "Stylo",
            "toolbar.longCapture": "Capture longue défilante",
            "toolbar.mosaic": "Style et intensité du mosaïque",
            "toolbar.pin": "Épingler",
            "toolbar.translate": "Traduire",
            "toolbar.undo": "Annuler",
            "toolbar.redo": "Rétablir",
            "toolbar.cancel": "Quitter",
            "toolbar.confirmCopy": "Valider et copier",
            "toolbar.save": "Enregistrer",
            "toolbar.finishLongCapture": "Terminer la capture défilante et copier",
            "ocr.noText": "Aucun texte reconnu",
            "ocr.title": "Résultat OCR",
            "translation.windowTitle": "Résultat de traduction (%@)",
            "translation.title": "Résultat de traduction",
            "translation.subtitle": "Texte OCR à gauche, traduction à droite",
            "translation.copySource": "Copier la source",
            "translation.copyTranslated": "Copier la traduction",
            "translation.openWeb": "Ouvrir le web",
            "translation.source": "Source",
            "translation.translated": "Traduction",
            "translation.empty": "Aucune traduction",
            "long.finishing": "Finalisation de l’assemblage…",
            "long.scrollHint": "Faites défiler manuellement vers le bas et marquez une courte pause",
            "long.scrollInSelection": "Faites défiler vers le bas dans la zone sélectionnée",
            "long.frames": "%d images capturées",
            "long.manualMessage": "Défilement manuel · terminez depuis l’aperçu à droite",
            "long.minimapTitle": "Aperçu complet en direct",
            "text.placeholder": "Saisissez du texte, Entrée pour valider, Esc pour annuler",
            "style.text": "Texte",
            "style.stroke": "Trait",
            "style.mosaic": "Mosaïque",
            "style.pixel": "Pixel",
            "style.blur": "Flou",
            "color.red": "Rouge",
            "color.orange": "Orange",
            "color.yellow": "Jaune",
            "color.green": "Vert",
            "color.blue": "Bleu",
            "color.white": "Blanc",
            "color.black": "Noir"
        ],
        "de": [
            "language.system": "Systemsprache",
            "menu.capture": "Bereich aufnehmen",
            "menu.longCapture": "Scroll-Aufnahme",
            "menu.history": "Verlauf",
            "menu.closePins": "Alle Pins schließen",
            "menu.settings": "Einstellungen…",
            "menu.checkUpdates": "Nach Updates suchen…",
            "menu.quit": "LongScreenShot beenden",
            "permission.title": "Berechtigung für Bildschirmaufnahme erforderlich",
            "permission.message": "Erlaube LongScreenShot in Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- und Systemaudioaufnahme und starte die App anschließend neu.",
            "permission.openSettings": "Systemeinstellungen öffnen",
            "common.cancel": "Abbrechen",
            "common.ok": "OK",
            "common.copy": "Kopieren",
            "common.later": "Später",
            "settings.title": "LongScreenShot Einstellungen",
            "settings.general": "Allgemein",
            "settings.about": "Über",
            "settings.language": "Sprache",
            "settings.launchAtLogin": "LongScreenShot beim Anmelden starten",
            "settings.hotkey": "Kurzbefehl für Bereichsaufnahme",
            "settings.hotkeyHint": "Klicke in das Feld und drücke einen Kurzbefehl mit ⌘ / ⌥ / ⌃. Esc bricht ab; Delete stellt den Standard wieder her.",
            "settings.translationProvider": "Übersetzungsdienst",
            "settings.translationHint": "Baidu ist die Voreinstellung. Übersetzungen erscheinen zuerst in einem zweispaltigen App-Fenster; falls die Web-Schnittstelle fehlschlägt, wird die passende Übersetzungsseite geöffnet.",
            "settings.screenRecordingGranted": "● Bildschirmaufnahme: erlaubt",
            "settings.screenRecordingDenied": "● Bildschirmaufnahme: nicht erlaubt",
            "settings.restoreDefault": "Standard wiederherstellen",
            "settings.recordHotKey": "Kurzbefehl drücken…",
            "settings.launchFailed": "Anmeldeobjekt konnte nicht geändert werden",
            "settings.version": "Version %@ (%@)",
            "settings.developer": "Entwickler",
            "settings.projectHomepage": "Kostenloses Open-Source-Projekt",
            "settings.contact": "Entwickler kontaktieren",
            "settings.privacyNote": "Screenshots, Markierungen und OCR laufen lokal. Für Übersetzungen wird erkannter Text an den gewählten Dienst gesendet.",
            "settings.autoCheckUpdates": "Automatisch nach Updates suchen",
            "settings.checkUpdates": "Nach Updates suchen…",
            "settings.updateHint": "Die App prüft GitHub Releases und informiert dich bei einer neuen Version. Sie ersetzt die App nicht heimlich im Hintergrund.",
            "settings.quickCopyOnConfirm": "Doppelklick oder Return kopiert",
            "settings.history": "Verlauf",
            "settings.saveHistory": "Screenshot-Verlauf speichern",
            "settings.historyLimit": "Maximal behalten",
            "settings.historyLocation": "Speicherort",
            "settings.choose": "Wählen…",
            "settings.historyHint": "Speichert 1–200 Screenshots. Ältere Einträge werden automatisch entfernt. Der Verlauf ist über die Menüleiste erreichbar.",
            "update.checking": "Suche nach Updates…",
            "update.availableTitle": "Neue Version verfügbar",
            "update.availableMessage": "%@ ist verfügbar. Aktuelle Version: %@.",
            "update.openRelease": "Downloadseite öffnen",
            "update.noUpdateTitle": "Du bist auf dem neuesten Stand",
            "update.noUpdateMessage": "Version %@ ist die neueste Version.",
            "update.failedTitle": "Updates konnten nicht geprüft werden",
            "update.failedMessage": "GitHub Releases ist vorübergehend nicht verfügbar. Bitte später erneut versuchen.",
            "history.title": "Screenshot-Verlauf",
            "history.empty": "Noch keine Screenshots",
            "history.delete": "Löschen",
            "history.deleted": "Screenshot entfernt",
            "history.showInFinder": "Im Finder anzeigen",
            "history.justNow": "gerade eben",
            "history.minutesAgo": "vor %d Min.",
            "history.hoursAgo": "vor %d Std.",
            "history.oneDayAgo": "vor 1 Tag",
            "feedback.copied": "In die Zwischenablage kopiert",
            "feedback.undone": "Letzte Aktion rückgängig gemacht",
            "feedback.noUndo": "Nichts zum Rückgängigmachen",
            "provider.baidu": "Baidu Übersetzer",
            "provider.google": "Google Übersetzer",
            "toolbar.rectangle": "Rechteck",
            "toolbar.ellipse": "Kreis",
            "toolbar.arrow": "Pfeil",
            "toolbar.text": "Text",
            "toolbar.pen": "Stift",
            "toolbar.longCapture": "Lange Scroll-Aufnahme",
            "toolbar.mosaic": "Mosaikstil und Stärke",
            "toolbar.pin": "Anheften",
            "toolbar.translate": "Übersetzen",
            "toolbar.undo": "Rückgängig",
            "toolbar.redo": "Wiederholen",
            "toolbar.cancel": "Beenden",
            "toolbar.confirmCopy": "Bestätigen und kopieren",
            "toolbar.save": "Speichern",
            "toolbar.finishLongCapture": "Scroll-Aufnahme beenden und kopieren",
            "ocr.noText": "Kein Text erkannt",
            "ocr.title": "OCR-Ergebnis",
            "translation.windowTitle": "Übersetzungsergebnis (%@)",
            "translation.title": "Übersetzungsergebnis",
            "translation.subtitle": "OCR-Original links, Übersetzung rechts",
            "translation.copySource": "Original kopieren",
            "translation.copyTranslated": "Übersetzung kopieren",
            "translation.openWeb": "Im Web öffnen",
            "translation.source": "Original",
            "translation.translated": "Übersetzung",
            "translation.empty": "Keine Übersetzung",
            "long.finishing": "Zusammenfügen wird abgeschlossen…",
            "long.scrollHint": "Bitte manuell nach unten scrollen und kurz pausieren",
            "long.scrollInSelection": "Bitte im ausgewählten Bereich nach unten scrollen",
            "long.frames": "%d Bilder erfasst",
            "long.manualMessage": "Manuelles Scrollen · rechts in der Vorschau abschließen",
            "long.minimapTitle": "Live-Gesamtvorschau",
            "text.placeholder": "Text eingeben, Enter bestätigt, Esc bricht ab",
            "style.text": "Text",
            "style.stroke": "Linie",
            "style.mosaic": "Mosaik",
            "style.pixel": "Pixel",
            "style.blur": "Unschärfe",
            "color.red": "Rot",
            "color.orange": "Orange",
            "color.yellow": "Gelb",
            "color.green": "Grün",
            "color.blue": "Blau",
            "color.white": "Weiß",
            "color.black": "Schwarz"
        ],
        "es": [
            "language.system": "Seguir sistema",
            "menu.capture": "Captura de área",
            "menu.longCapture": "Captura con desplazamiento",
            "menu.history": "Historial",
            "menu.closePins": "Cerrar todos los pines",
            "menu.settings": "Ajustes…",
            "menu.checkUpdates": "Buscar actualizaciones…",
            "menu.quit": "Salir de LongScreenShot",
            "permission.title": "Se requiere permiso de grabación de pantalla",
            "permission.message": "Permite LongScreenShot en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema, y reinicia la app.",
            "permission.openSettings": "Abrir Ajustes del Sistema",
            "common.cancel": "Cancelar",
            "common.ok": "Aceptar",
            "common.copy": "Copiar",
            "common.later": "Más tarde",
            "settings.title": "Ajustes de LongScreenShot",
            "settings.general": "General",
            "settings.about": "Acerca de",
            "settings.language": "Idioma",
            "settings.launchAtLogin": "Abrir LongScreenShot al iniciar sesión",
            "settings.hotkey": "Atajo de captura de área",
            "settings.hotkeyHint": "Haz clic en el campo y pulsa un atajo que incluya ⌘ / ⌥ / ⌃. Esc cancela; Delete restaura el valor predeterminado.",
            "settings.translationProvider": "Motor de traducción",
            "settings.translationHint": "Baidu es el valor predeterminado. La traducción aparece primero en una ventana de dos columnas dentro de la app; si falla la interfaz web, se abre la página de traducción correspondiente.",
            "settings.screenRecordingGranted": "● Grabación de pantalla: permitida",
            "settings.screenRecordingDenied": "● Grabación de pantalla: no permitida",
            "settings.restoreDefault": "Restaurar",
            "settings.recordHotKey": "Pulsa el atajo…",
            "settings.launchFailed": "No se pudo cambiar el inicio de sesión",
            "settings.version": "Versión %@ (%@)",
            "settings.developer": "Desarrollador",
            "settings.projectHomepage": "Proyecto gratuito y de código abierto",
            "settings.contact": "Contactar al desarrollador",
            "settings.privacyNote": "Las capturas, anotaciones y OCR se procesan localmente. La traducción envía el texto reconocido al motor elegido.",
            "settings.autoCheckUpdates": "Buscar actualizaciones automáticamente",
            "settings.checkUpdates": "Buscar actualizaciones…",
            "settings.updateHint": "La app consulta GitHub Releases y te avisa cuando hay una nueva versión. No reemplaza la app en segundo plano sin que lo decidas.",
            "settings.quickCopyOnConfirm": "Doble clic o Return para copiar",
            "settings.history": "Historial",
            "settings.saveHistory": "Guardar historial de capturas",
            "settings.historyLimit": "Conservar hasta",
            "settings.historyLocation": "Ubicación",
            "settings.choose": "Elegir…",
            "settings.historyHint": "Conserva entre 1 y 200 capturas. Las más antiguas se eliminan automáticamente. El historial se abre desde la barra de menús.",
            "update.checking": "Buscando actualizaciones…",
            "update.availableTitle": "Hay una nueva versión disponible",
            "update.availableMessage": "%@ está disponible. Versión actual: %@.",
            "update.openRelease": "Abrir página de descarga",
            "update.noUpdateTitle": "Ya tienes la última versión",
            "update.noUpdateMessage": "La versión %@ es la más reciente.",
            "update.failedTitle": "No se pudieron buscar actualizaciones",
            "update.failedMessage": "GitHub Releases no está disponible temporalmente. Inténtalo de nuevo más tarde.",
            "history.title": "Historial de capturas",
            "history.empty": "Todavía no hay capturas",
            "history.delete": "Eliminar",
            "history.deleted": "Captura eliminada",
            "history.showInFinder": "Mostrar en Finder",
            "history.justNow": "ahora mismo",
            "history.minutesAgo": "hace %d min",
            "history.hoursAgo": "hace %d h",
            "history.oneDayAgo": "hace 1 día",
            "feedback.copied": "Copiado al portapapeles",
            "feedback.undone": "Última acción deshecha",
            "feedback.noUndo": "Nada que deshacer",
            "provider.baidu": "Baidu Translate",
            "provider.google": "Google Translate",
            "toolbar.rectangle": "Rectángulo",
            "toolbar.ellipse": "Círculo",
            "toolbar.arrow": "Flecha",
            "toolbar.text": "Texto",
            "toolbar.pen": "Pincel",
            "toolbar.longCapture": "Captura larga con desplazamiento",
            "toolbar.mosaic": "Estilo e intensidad de mosaico",
            "toolbar.pin": "Fijar",
            "toolbar.translate": "Traducir",
            "toolbar.undo": "Deshacer",
            "toolbar.redo": "Rehacer",
            "toolbar.cancel": "Salir",
            "toolbar.confirmCopy": "Confirmar y copiar",
            "toolbar.save": "Guardar",
            "toolbar.finishLongCapture": "Terminar captura con desplazamiento y copiar",
            "ocr.noText": "No se reconoció texto",
            "ocr.title": "Resultado OCR",
            "translation.windowTitle": "Resultado de traducción (%@)",
            "translation.title": "Resultado de traducción",
            "translation.subtitle": "Texto OCR a la izquierda, traducción a la derecha",
            "translation.copySource": "Copiar original",
            "translation.copyTranslated": "Copiar traducción",
            "translation.openWeb": "Abrir web",
            "translation.source": "Original",
            "translation.translated": "Traducción",
            "translation.empty": "Sin traducción",
            "long.finishing": "Finalizando unión…",
            "long.scrollHint": "Desplázate manualmente hacia abajo y haz una breve pausa",
            "long.scrollInSelection": "Desplázate hacia abajo dentro del área seleccionada",
            "long.frames": "%d fotogramas capturados",
            "long.manualMessage": "Desplazamiento manual · termina desde la vista previa derecha",
            "long.minimapTitle": "Vista previa completa en directo",
            "text.placeholder": "Escribe texto, Enter para confirmar, Esc para cancelar",
            "style.text": "Texto",
            "style.stroke": "Trazo",
            "style.mosaic": "Mosaico",
            "style.pixel": "Píxel",
            "style.blur": "Desenfoque",
            "color.red": "Rojo",
            "color.orange": "Naranja",
            "color.yellow": "Amarillo",
            "color.green": "Verde",
            "color.blue": "Azul",
            "color.white": "Blanco",
            "color.black": "Negro"
        ]
    ]
}
