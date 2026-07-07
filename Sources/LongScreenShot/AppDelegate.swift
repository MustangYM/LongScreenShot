import AppKit
import Carbon
import CoreGraphics
import ServiceManagement

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
    }

    private func configureStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        if let button = statusItem.button {
            let image = NSImage(named: "StatusBarIcon")
                ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "LongScreenShot")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: L10n.tr("menu.capture"), action: #selector(startCapture), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("menu.longCapture"), action: #selector(startLongCapture), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: L10n.tr("menu.closePins"), action: #selector(closePins), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
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
        settingsController?.showWindow(nil)
        settingsController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
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
            "menu.closePins": "关闭所有图钉",
            "menu.settings": "设置…",
            "menu.quit": "退出 LongScreenShot",
            "permission.title": "需要屏幕录制权限",
            "permission.message": "请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 LongScreenShot，然后重新启动应用。",
            "permission.openSettings": "打开系统设置",
            "common.cancel": "取消",
            "common.copy": "复制",
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
            "menu.closePins": "Close All Pins",
            "menu.settings": "Settings…",
            "menu.quit": "Quit LongScreenShot",
            "permission.title": "Screen Recording Permission Required",
            "permission.message": "Allow LongScreenShot in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app.",
            "permission.openSettings": "Open System Settings",
            "common.cancel": "Cancel",
            "common.copy": "Copy",
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
            "menu.closePins": "すべてのピンを閉じる",
            "menu.settings": "設定…",
            "menu.quit": "LongScreenShot を終了",
            "permission.title": "画面収録の権限が必要です",
            "permission.message": "システム設定 → プライバシーとセキュリティ → 画面とシステムオーディオ収録で LongScreenShot を許可してから、アプリを再起動してください。",
            "permission.openSettings": "システム設定を開く",
            "common.cancel": "キャンセル",
            "common.copy": "コピー",
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
            "menu.closePins": "모든 핀 닫기",
            "menu.settings": "설정…",
            "menu.quit": "LongScreenShot 종료",
            "permission.title": "화면 기록 권한 필요",
            "permission.message": "시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 LongScreenShot을 허용한 뒤 앱을 다시 시작하세요.",
            "permission.openSettings": "시스템 설정 열기",
            "common.cancel": "취소",
            "common.copy": "복사",
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
            "menu.closePins": "Fermer toutes les épingles",
            "menu.settings": "Réglages…",
            "menu.quit": "Quitter LongScreenShot",
            "permission.title": "Autorisation d’enregistrement d’écran requise",
            "permission.message": "Autorisez LongScreenShot dans Réglages Système → Confidentialité et sécurité → Enregistrement de l’écran et de l’audio système, puis redémarrez l’app.",
            "permission.openSettings": "Ouvrir Réglages Système",
            "common.cancel": "Annuler",
            "common.copy": "Copier",
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
            "menu.closePins": "Alle Pins schließen",
            "menu.settings": "Einstellungen…",
            "menu.quit": "LongScreenShot beenden",
            "permission.title": "Berechtigung für Bildschirmaufnahme erforderlich",
            "permission.message": "Erlaube LongScreenShot in Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- und Systemaudioaufnahme und starte die App anschließend neu.",
            "permission.openSettings": "Systemeinstellungen öffnen",
            "common.cancel": "Abbrechen",
            "common.copy": "Kopieren",
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
            "menu.closePins": "Cerrar todos los pines",
            "menu.settings": "Ajustes…",
            "menu.quit": "Salir de LongScreenShot",
            "permission.title": "Se requiere permiso de grabación de pantalla",
            "permission.message": "Permite LongScreenShot en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema, y reinicia la app.",
            "permission.openSettings": "Abrir Ajustes del Sistema",
            "common.cancel": "Cancelar",
            "common.copy": "Copiar",
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
