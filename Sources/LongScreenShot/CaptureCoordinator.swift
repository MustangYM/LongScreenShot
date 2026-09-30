import AppKit
import CoreGraphics
import Carbon

struct ScreenSnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage

    var pointSize: CGSize { screen.frame.size }

    func pixelRect(for viewRect: CGRect) -> CGRect? {
        let sx = CGFloat(image.width) / pointSize.width
        let sy = CGFloat(image.height) / pointSize.height
        let pixelRect = CGRect(
            x: viewRect.minX * sx,
            y: (pointSize.height - viewRect.maxY) * sy,
            width: viewRect.width * sx,
            height: viewRect.height * sy
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0 else { return nil }
        return pixelRect
    }

    func crop(viewRect: CGRect) -> CGImage? {
        guard let pixelRect = pixelRect(for: viewRect) else { return nil }
        return image.cropping(to: pixelRect)
    }
}

struct WindowCandidate {
    let rect: CGRect
    let label: String
}

enum WindowDetector {
    static func hasTrackingMenu(in windows: [[String: Any]]) -> Bool {
        windows.contains { info in
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) && alpha > 0.01
        }
    }

    static func candidates(in snapshot: ScreenSnapshot) -> [WindowCandidate] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let displayBounds = CGDisplayBounds(snapshot.displayID)
        return windowList.compactMap { info in
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
            let owner = info[kCGWindowOwnerName as String] as? String ?? "窗口"
            guard layer == 0, alpha > 0.01,
                  owner != "LongScreenShot", owner != "Dock", owner != "Window Server",
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var globalRect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(dictionary, &globalRect) else { return nil }
            let visible = globalRect.intersection(displayBounds)
            guard !visible.isNull, visible.width >= 60, visible.height >= 40,
                  visible.width * visible.height >= globalRect.width * globalRect.height * 0.35 else { return nil }

            let localRect = CGRect(
                x: visible.minX - displayBounds.minX,
                y: displayBounds.maxY - visible.maxY,
                width: visible.width,
                height: visible.height
            ).integral
            let title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = title?.isEmpty == false ? "\(owner) — \(title!)" : owner
            return WindowCandidate(rect: localRect, label: label)
        }
    }
}

/// One session owns one set of overlays, including while activation is pending.
struct CaptureSessionLifecycle {
    private enum Phase { case idle, waitingForActivation, presented, finished }
    private var phase = Phase.idle
    var isFinished: Bool { phase == .finished }

    mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .waitingForActivation
        return true
    }

    mutating func present(applicationIsActive: Bool, menuIsTracking: Bool = false) -> Bool {
        guard phase == .waitingForActivation, applicationIsActive, !menuIsTracking else { return false }
        phase = .presented
        return true
    }

    mutating func finish() -> Bool {
        guard phase != .finished else { return false }
        phase = .finished
        return true
    }
}

final class CaptureCoordinator: NSObject {
    var onFinish: (() -> Void)?
    private var overlayControllers: [OverlayWindowController] = []
    private let initialLongMode: Bool
    private var lifecycle = CaptureSessionLifecycle()
    private var escapeHotKey: GlobalHotKey?
    private var emergencyHotKey: GlobalHotKey?
    private var keyMonitor: Any?
    private var activationObservers: [NSObjectProtocol] = []
    private var activationTimeout: Timer?
    private let snapshotProvider: (() -> [ScreenSnapshot])?

    init(initialLongMode: Bool, snapshotProvider: (() -> [ScreenSnapshot])? = nil) {
        self.initialLongMode = initialLongMode
        self.snapshotProvider = snapshotProvider
    }

    deinit { closeOverlays() }

    func cancel() { finish() }

    func start(afterSnapshot: (() -> Void)? = nil) {
        guard lifecycle.begin() else { return }
        // Preserve the OPEN menu in the captured pixels before requesting focus.
        let snapshots = snapshotProvider?() ?? NSScreen.screens.compactMap { capture(screen: $0) }
        // Only dismiss an app-owned menu once its visible pixels have been retained.
        // Foreign menus still use the activation/readiness checks below.
        afterSnapshot?()
        guard !snapshots.isEmpty else {
            finish(); return
        }

        overlayControllers = snapshots.map { snapshot in
            let controller = OverlayWindowController(snapshot: snapshot, startsInLongMode: initialLongMode)
            controller.onCancel = { [weak self] in self?.finish() }
            controller.onComplete = { [weak self] image, action, screen, anchorRect in
                self?.handle(image: image, action: action, sourceScreen: screen, toastAnchorRect: anchorRect)
            }
            return controller
        }
        installExitRoutes()
        // A foreign menu may keep its tracking grab even after activate() is called.
        // Do not put an input-blocking overlay on screen until activation succeeds.
        activationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in self?.presentIfActive() })
        activationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            guard let self, !self.overlayControllers.contains(where: { $0.allowsInactiveCapture }) else { return }
            self.cancel()
        })
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let timeout = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline { self.cancel() }
            else { self.presentIfActive() }
        }
        activationTimeout = timeout
        for mode: RunLoop.Mode in [.default, .eventTracking, .modalPanel] {
            RunLoop.main.add(timeout, forMode: mode)
        }
        NSApp.activate(ignoringOtherApps: true)
        presentIfActive()
    }

    private func presentIfActive() {
        guard NSApp.isActive else { return }
        // Status-item menus can hold a tracking grab without changing the active
        // application. Wait for those real menu windows to disappear as well.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]],
              lifecycle.present(applicationIsActive: true,
                                menuIsTracking: WindowDetector.hasTrackingMenu(in: windows)) else { return }
        activationTimeout?.invalidate()
        activationTimeout = nil
        overlayControllers.forEach { $0.show() }
    }

    private func installExitRoutes() {
        // Register once per session, not once per display. This still works while
        // the long-capture overlay is inactive and forwards mouse input underneath.
        escapeHotKey = GlobalHotKey(configuration: HotKeyConfiguration(
            keyCode: UInt32(kVK_Escape), carbonModifiers: 0
        )) { [weak self] in self?.cancel() }
        emergencyHotKey = GlobalHotKey(configuration: HotKeyConfiguration(
            keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(cmdKey | shiftKey)
        )) { [weak self] in self?.cancel() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) {
                self?.cancel()
                // Never intercept the operating system's Force Quit shortcut.
                return modifiers == [.command, .option] ? event : nil
            }
            if event.keyCode == UInt16(kVK_ANSI_Q), modifiers == .command {
                self?.cancel()
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    private func screenUnderPointer() -> NSScreen? {
        if let point = CGEvent(source: nil)?.location {
            var displayCount: UInt32 = 0
            var displays = [CGDirectDisplayID](repeating: 0, count: 16)
            if CGGetDisplaysWithPoint(point, UInt32(displays.count), &displays, &displayCount) == .success,
               let displayID = displays.prefix(Int(displayCount)).first,
               let screen = NSScreen.screens.first(where: { Self.displayID(for: $0) == displayID }) {
                return screen
            }
        }
        let appKitPoint = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(appKitPoint) }) ?? NSScreen.main
    }

    private func capture(screen: NSScreen) -> ScreenSnapshot? {
        guard let displayID = Self.displayID(for: screen),
              let image = CGDisplayCreateImage(displayID) else { return nil }
        return ScreenSnapshot(screen: screen, displayID: displayID, image: image)
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }

    private func handle(
        image: CGImage,
        action: CaptureCompletionAction,
        sourceScreen: NSScreen,
        toastAnchorRect: CGRect?
    ) {
        guard !lifecycle.isFinished else { return }
        CaptureHistoryManager.shared.record(image)
        switch action {
        case .copy:
            ImageExporter.copyToPasteboard(image)
            FeedbackToast.show(L10n.tr("feedback.copied"), screen: sourceScreen, anchorRect: toastAnchorRect)
            finish()
        case .save:
            closeOverlays()
            ImageExporter.showSavePanel(for: image, preferredScreen: sourceScreen) { [weak self] in self?.finish() }
        case .pin:
            PinWindowController.pin(image: image)
            finish()
        case .ocr:
            closeOverlays()
            OCRService.recognize(image: image) { [weak self] text in
                if !text.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                OCRResultWindowController.show(image: image, text: text)
                self?.finish()
            }
        case .translate:
            closeOverlays()
            OCRService.recognize(image: image) { [weak self] text in
                self?.translate(image: image, text: text)
            }
        }
    }

    private func translate(image: CGImage, text: String) {
        guard !text.isEmpty else { finish(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let provider = TranslationProvider.current
        closeOverlays()

        TranslationService.translate(text, provider: provider) { [weak self] result in
            switch result {
            case let .success(translated):
                TranslationResultWindowController.show(
                    sourceText: text,
                    translatedText: translated,
                    provider: provider
                )
            case .failure:
                if let url = provider.browserURL(for: text) {
                    NSWorkspace.shared.open(url)
                }
            }
            self?.finish()
        }
    }

    private func closeOverlays() {
        activationTimeout?.invalidate()
        activationTimeout = nil
        activationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        activationObservers.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        escapeHotKey = nil
        emergencyHotKey = nil
        // First release EVERY display, then perform potentially expensive cleanup.
        let controllers = overlayControllers
        overlayControllers.removeAll()
        controllers.forEach { $0.releaseInput() }
        controllers.forEach { $0.close() }
    }

    private func finish() {
        guard lifecycle.finish() else { return }
        closeOverlays()
        let callback = onFinish
        onFinish = nil
        callback?()
    }

}

enum CaptureCompletionAction {
    case copy, save, pin, ocr, translate
}

enum TranslationProvider: String, CaseIterable {
    case baidu
    case google

    static let defaultsKey = "translationProvider"

    static var current: TranslationProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let provider = TranslationProvider(rawValue: raw) else { return .baidu }
            return provider
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .baidu: return L10n.tr("provider.baidu")
        case .google: return L10n.tr("provider.google")
        }
    }

    func browserURL(for text: String) -> URL? {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch self {
        case .baidu:
            return URL(string: "https://fanyi.baidu.com/#auto/zh/\(encoded)")
        case .google:
            return URL(string: "https://translate.google.com/?sl=auto&tl=zh-CN&text=\(encoded)&op=translate")
        }
    }
}

enum TranslationService {
    enum TranslationError: Error {
        case emptyText
        case invalidURL
        case invalidResponse
        case noTranslation
    }

    static func translate(
        _ text: String,
        provider: TranslationProvider,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(.failure(TranslationError.emptyText)) }
            return
        }
        switch provider {
        case .baidu:
            translateWithBaidu(trimmed, completion: completion)
        case .google:
            translateWithGoogle(trimmed, completion: completion)
        }
    }

    private static func translateWithBaidu(
        _ text: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "https://fanyi.baidu.com/transapi") else {
            DispatchQueue.main.async { completion(.failure(TranslationError.invalidURL)) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("https://fanyi.baidu.com", forHTTPHeaderField: "Referer")
        request.setValue("LongScreenShot/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = formEncoded([
            "from": "auto",
            "to": "zh",
            "query": text,
            "source": "txt"
        ]).data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                complete(.failure(error), completion)
                return
            }
            guard let data,
                  let translated = parseBaidu(data: data),
                  !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                complete(.failure(TranslationError.noTranslation), completion)
                return
            }
            complete(.success(translated), completion)
        }.resume()
    }

    private static func translateWithGoogle(
        _ text: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single") else {
            DispatchQueue.main.async { completion(.failure(TranslationError.invalidURL)) }
            return
        }
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "zh-CN"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components.url else {
            DispatchQueue.main.async { completion(.failure(TranslationError.invalidURL)) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("LongScreenShot/1.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                complete(.failure(error), completion)
                return
            }
            guard let data,
                  let translated = parseGoogle(data: data),
                  !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                complete(.failure(TranslationError.noTranslation), completion)
                return
            }
            complete(.success(translated), completion)
        }.resume()
    }

    private static func parseBaidu(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let dictionary = object as? [String: Any] else { return nil }
        if let items = dictionary["data"] as? [[String: Any]] {
            let lines = items.compactMap { $0["dst"] as? String }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        if let result = dictionary["trans_result"] as? [String: Any],
           let items = result["data"] as? [[String: Any]] {
            let lines = items.compactMap { $0["dst"] as? String }
            if !lines.isEmpty { return lines.joined(separator: "\n") }
        }
        return nil
    }

    private static func parseGoogle(data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [Any],
              let sentences = root.first as? [Any] else { return nil }
        let lines = sentences.compactMap { item -> String? in
            guard let segment = item as? [Any], let translated = segment.first as? String else { return nil }
            return translated
        }
        return lines.isEmpty ? nil : lines.joined()
    }

    private static func formEncoded(_ values: [String: String]) -> String {
        values
            .map { key, value in
                "\(escape(key))=\(escape(value))"
            }
            .joined(separator: "&")
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func complete(
        _ result: Result<String, Error>,
        _ completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.main.async { completion(result) }
    }
}
