import AppKit
import QuartzCore
import CoreImage
import ImageIO
import Vision
import UniformTypeIdentifiers
import Accelerate

enum ImageEffects {
    private static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false
    ])
    private static let softwareCIContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true
    ])

    static func clearCaches() {
        ciContext.clearCaches()
        softwareCIContext.clearCaches()
    }

    static func mosaicPatch(
        from image: CGImage,
        pixelRectTopLeft rect: CGRect,
        style: MosaicStyle,
        intensity: CGFloat
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let target = rect.integral.intersection(imageBounds)
        guard target.width > 2, target.height > 2,
              let crop = image.cropping(to: target) else { return nil }
        switch style {
        case .pixel:
            return pixelated(crop, blockSize: max(4, Int(intensity)))
        case .blur:
            return gaussianBlurred(crop, radius: max(2, min(40, Int(intensity))))
        }
    }

    static func quickMosaicPreviewPatch(
        from image: CGImage,
        pixelRectTopLeft rect: CGRect,
        style: MosaicStyle,
        intensity: CGFloat,
        maximumDimension: Int = 260
    ) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let target = rect.integral.intersection(imageBounds)
        guard target.width > 2, target.height > 2,
              let crop = image.cropping(to: target) else { return nil }
        return downsampledObscuredPreview(
            crop,
            style: style,
            intensity: intensity,
            maximumDimension: maximumDimension
        )
    }

    private static func pixelated(_ image: CGImage, blockSize: Int) -> CGImage? {
        let block = min(max(2, blockSize), max(2, min(image.width, image.height)))
        let smallWidth = max(1, image.width / block)
        let smallHeight = max(1, image.height / block)
        guard let small = CGContext(
            data: nil,
            width: smallWidth,
            height: smallHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let output = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        small.interpolationQuality = .low
        small.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        guard let reduced = small.makeImage() else { return nil }
        output.interpolationQuality = .none
        output.draw(reduced, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return output.makeImage()
    }

    private static func downsampledObscuredPreview(
        _ image: CGImage,
        style: MosaicStyle,
        intensity: CGFloat,
        maximumDimension: Int
    ) -> CGImage? {
        let longest = max(image.width, image.height)
        let scale = min(1, CGFloat(max(48, maximumDimension)) / CGFloat(max(1, longest)))
        let previewWidth = max(1, Int(CGFloat(image.width) * scale))
        let previewHeight = max(1, Int(CGFloat(image.height) * scale))
        let block = max(2, Int(style == .pixel ? intensity : intensity * 1.35))
        let sampleWidth = max(1, previewWidth / block)
        let sampleHeight = max(1, previewHeight / block)
        guard let sample = CGContext(
            data: nil,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let output = CGContext(
            data: nil,
            width: previewWidth,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        sample.interpolationQuality = style == .pixel ? .low : .medium
        sample.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
        guard let reduced = sample.makeImage() else { return nil }
        output.interpolationQuality = style == .pixel ? .none : .high
        output.draw(reduced, in: CGRect(x: 0, y: 0, width: previewWidth, height: previewHeight))
        return output.makeImage()
    }

    private static func gaussianBlurred(_ image: CGImage, radius: Int) -> CGImage? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(NSNumber(value: radius), forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return ciContext.createCGImage(output, from: extent)
            ?? softwareCIContext.createCGImage(output, from: extent)
            ?? acceleratedBoxBlur(image, radius: radius)
    }

    private static func acceleratedBoxBlur(_ image: CGImage, radius: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var source = [UInt8](repeating: 0, count: bytesPerRow * height)
        var output = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let sourceContext = CGContext(
            data: &source,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        sourceContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let kernel = UInt32(max(3, min(81, radius * 2 + 1)) | 1)
        let error: vImage_Error = source.withUnsafeMutableBytes { sourceBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var sourceBuffer = vImage_Buffer(
                    data: sourceBytes.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var outputBuffer = vImage_Buffer(
                    data: outputBytes.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                return vImageBoxConvolve_ARGB8888(
                    &sourceBuffer,
                    &outputBuffer,
                    nil,
                    0,
                    0,
                    kernel,
                    kernel,
                    nil,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard error == kvImageNoError,
              let resultContext = CGContext(
                data: &output,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        return resultContext.makeImage()
    }
}

enum ImageExporter {
    static func copyToPasteboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    static func showSavePanel(
        for image: CGImage,
        preferredScreen: NSScreen? = nil,
        completion: @escaping () -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultFilename()
        if let preferredScreen {
            let visible = preferredScreen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK, let url = panel.url { writePNG(image, to: url) }
            completion()
        }
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        autoreleasepool {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private static func defaultFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "LongScreenShot \(formatter.string(from: Date())).png"
    }
}


enum CapturePreferences {
    private static let quickCopyKey = "quickCopyOnConfirm"

    static var quickCopyOnConfirm: Bool {
        get {
            if UserDefaults.standard.object(forKey: quickCopyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: quickCopyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: quickCopyKey) }
    }
}

struct CaptureHistoryItem: Equatable {
    let url: URL
    let date: Date
    let width: Int
    let height: Int
}

enum CaptureHistoryPreferences {
    private enum Keys {
        static let enabled = "captureHistoryEnabled"
        static let maximumCount = "captureHistoryMaximumCount"
        static let directoryPath = "captureHistoryDirectoryPath"
    }

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.enabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: Keys.enabled)
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    static var maximumCount: Int {
        get {
            let raw = UserDefaults.standard.integer(forKey: Keys.maximumCount)
            return raw == 0 ? 50 : max(1, min(200, raw))
        }
        set { UserDefaults.standard.set(max(1, min(200, newValue)), forKey: Keys.maximumCount) }
    }

    static var directoryURL: URL {
        if let path = UserDefaults.standard.string(forKey: Keys.directoryPath), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("LongScreenShot/History", isDirectory: true)
    }

    static func setDirectoryURL(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: Keys.directoryPath)
    }
}

final class CaptureHistoryManager {
    static let shared = CaptureHistoryManager()
    private let queue = DispatchQueue(label: "longscreenshot.capture.history", qos: .utility)
    private let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private init() {}

    func record(_ image: CGImage) {
        guard CaptureHistoryPreferences.isEnabled else { return }
        let directory = CaptureHistoryPreferences.directoryURL
        let maxCount = CaptureHistoryPreferences.maximumCount
        let width = image.width
        let height = image.height
        let date = Date()
        let filename = "\(filenameFormatter.string(from: date))_\(width)x\(height)_\(UUID().uuidString.prefix(8)).png"
        queue.async { [filenameFormatter] in
            autoreleasepool {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(filename)
                    ImageExporter.writePNG(image, to: url)
                    self.trim(in: directory, maximumCount: maxCount)
                } catch {
                    NSLog("LongScreenShot history save failed: \(error.localizedDescription)")
                }
            }
            _ = filenameFormatter
        }
    }

    /// 同步版本保留给旧调用方。注意：窗口展示不要直接调用它，避免主线程卡顿。
    func items() -> [CaptureHistoryItem] {
        Array(loadItems(in: CaptureHistoryPreferences.directoryURL).prefix(CaptureHistoryPreferences.maximumCount))
    }

    /// 历史窗口专用：放到后台队列扫描目录和读取轻量元数据，完成后回主线程。
    func asyncItems(completion: @escaping ([CaptureHistoryItem]) -> Void) {
        let directory = CaptureHistoryPreferences.directoryURL
        let displayLimit = CaptureHistoryPreferences.maximumCount
        queue.async {
            let result = autoreleasepool { Array(self.loadItems(in: directory).prefix(displayLimit)) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func delete(_ item: CaptureHistoryItem) {
        CaptureHistoryThumbnailCache.shared.remove(url: item.url)
        try? FileManager.default.removeItem(at: item.url)
    }

    private func loadItems(in directory: URL) -> [CaptureHistoryItem] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "png" }
            .compactMap(item(for:))
            .sorted { $0.date > $1.date }
    }

    private func trim(in directory: URL, maximumCount: Int) {
        let all = loadItems(in: directory)
        guard all.count > maximumCount else { return }
        for item in all.dropFirst(maximumCount) {
            CaptureHistoryThumbnailCache.shared.remove(url: item.url)
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    private func item(for url: URL) -> CaptureHistoryItem? {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast

        // 新版历史文件名里本来就带了 _宽x高_，优先解析文件名，避免为每张图创建 CGImageSource。
        // 只有旧文件名缺失尺寸时，才退回读取图片属性。
        let size = parseSize(from: url.lastPathComponent) ?? imagePixelSize(url: url) ?? .zero
        return CaptureHistoryItem(url: url, date: date, width: Int(size.width), height: Int(size.height))
    }

    private func imagePixelSize(url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func parseSize(from filename: String) -> CGSize? {
        guard let match = filename.range(of: #"_\d+x\d+_"#, options: .regularExpression) else { return nil }
        let token = filename[match].dropFirst().dropLast()
        let parts = token.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class FeedbackToast {
    private static var activePanels: [NSPanel] = []

    /// 显示反馈 Toast
    ///
    /// - Parameters:
    ///   - message: Toast 文案
    ///   - screen: 明确指定的目标屏幕。推荐从“截图开始时的屏幕”缓存后传入。
    ///   - anchorRect: 操作区域的全局屏幕坐标。注意：不是 view 内部坐标。
    static func show(_ message: String, screen: NSScreen? = nil, anchorRect: CGRect? = nil) {
        if Thread.isMainThread {
            showOnMain(message, screen: screen, anchorRect: anchorRect)
        } else {
            DispatchQueue.main.async {
                showOnMain(message, screen: screen, anchorRect: anchorRect)
            }
        }
    }

    private static func showOnMain(_ message: String, screen: NSScreen?, anchorRect: CGRect?) {
        let targetScreen =
            anchorRect.flatMap { screenContainingMost(of: $0) }
            ?? screen
            ?? screenContainingPoint(NSEvent.mouseLocation)
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let visible = targetScreen?.visibleFrame
            ?? targetScreen?.frame
            ?? NSRect(x: 0, y: 0, width: 900, height: 600)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let measured = (message as NSString).size(withAttributes: [.font: label.font as Any])
        let size = NSSize(width: max(176, measured.width + 46), height: 44)

        // 关键点：
        // Toast 永远放到目标屏幕 visibleFrame 的正中心。
        // 不再使用 anchorRect 的中心作为弹窗位置，否则选区靠边或跨屏时会偏。
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        container.layer?.borderWidth = 1
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: targetScreen
        )

        // 再 setFrame 一次，避免 NSPanel 初始化时被 AppKit 根据 screen/space 做隐式修正。
        panel.setFrame(frame, display: false)

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 8)
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.contentView = container

        // 不要加 .canJoinAllSpaces。
        // 多显示器 + 分屏/全屏 Space 下，它很容易导致 panel 被系统放到别的屏幕或别的 Space。
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        activePanels.append(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
                activePanels.removeAll { $0 === panel }
            }
        }
    }

    /// 找到和某个全局屏幕坐标 rect 重叠面积最大的屏幕。
    /// 比只判断 center 更稳，因为截图选区可能跨屏，也可能刚好贴着屏幕边缘。
    private static func screenContainingMost(of rect: CGRect) -> NSScreen? {
        guard !rect.isNull, !rect.isEmpty else { return nil }

        let best = NSScreen.screens
            .map { screen -> (screen: NSScreen, area: CGFloat) in
                let intersection = screen.frame.intersection(rect)
                return (screen, area(of: intersection))
            }
            .filter { $0.area > 0 }
            .max { lhs, rhs in
                lhs.area < rhs.area
            }

        if let best {
            return best.screen
        }

        return screenContainingPoint(CGPoint(x: rect.midX, y: rect.midY))
    }

    private static func screenContainingPoint(_ point: CGPoint) -> NSScreen? {
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return screen
        }

        // 如果 point 落在屏幕之间的空隙里，取最近的屏幕。
        return NSScreen.screens.min { lhs, rhs in
            distance(from: point, to: lhs.frame) < distance(from: point, to: rhs.frame)
        }
    }

    private static func area(of rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        return max(0, rect.width) * max(0, rect.height)
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }
}

private final class CaptureHistoryRootView: NSVisualEffectView {
    var onCopy: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopy?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class CaptureHistoryThumbnailCache {
    static let shared = CaptureHistoryThumbnailCache()

    private let cache = NSCache<NSString, CGImage>()
    private let workerQueue = DispatchQueue(label: "longscreenshot.capture.history.thumbnail.worker", qos: .userInitiated, attributes: .concurrent)
    private let stateQueue = DispatchQueue(label: "longscreenshot.capture.history.thumbnail.state")
    private var inFlight: [String: [(CGImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 320
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func thumbnail(for url: URL, maxPixelSize: Int, completion: @escaping (CGImage?) -> Void) {
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        stateQueue.async {
            if self.inFlight[key] != nil {
                self.inFlight[key]?.append(completion)
                return
            }

            self.inFlight[key] = [completion]
            self.workerQueue.async {
                let thumbnail = autoreleasepool {
                    Self.makeThumbnail(url: url, maxPixelSize: maxPixelSize)
                }

                if let thumbnail {
                    let cost = thumbnail.bytesPerRow * thumbnail.height
                    self.cache.setObject(thumbnail, forKey: key as NSString, cost: cost)
                }

                self.stateQueue.async {
                    let completions = self.inFlight.removeValue(forKey: key) ?? []
                    DispatchQueue.main.async {
                        completions.forEach { $0(thumbnail) }
                    }
                }
            }
        }
    }

    func remove(url: URL) {
        let key = cacheKey(url: url, maxPixelSize: 420)
        cache.removeObject(forKey: key as NSString)
    }

    private func cacheKey(url: URL, maxPixelSize: Int) -> String {
        "\(url.path)|\(maxPixelSize)"
    }

    private static func makeThumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary

        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }
}

final class CaptureHistoryWindowController: NSWindowController {
    static let shared = CaptureHistoryWindowController()

    private let rootView = CaptureHistoryRootView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let historyContentView = NSView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var selectedItem: CaptureHistoryItem?
    private var cardViews: [CaptureHistoryCardView] = []
    private var reloadGeneration: Int = 0
    private var boundsObserver: NSObjectProtocol?

    private init() {
        let screen = Self.screenUnderPointer() ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
        let width = min(980, max(560, visible.width * 0.78))
        let height: CGFloat = 360
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        super.init(window: panel)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
    }

    func showAtPointer() {
        positionAtPointerScreen()
        prepareForDisplay()
        presentWindow()
        reloadAsync()
    }

    private func presentWindow() {
        guard let window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(rootView)

        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self.rootView)
            self.loadVisibleThumbnails()
        }
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        rootView.material = .hudWindow
        rootView.blendingMode = .behindWindow
        rootView.state = .active
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 18
        rootView.layer?.masksToBounds = true
        rootView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rootView)
        rootView.onCopy = { [weak self] in self?.copySelectedItem() }

        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(titleLabel)

        historyContentView.frame = NSRect(x: 0, y: 0, width: 1, height: 252)
        historyContentView.autoresizesSubviews = false

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = historyContentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        rootView.addSubview(scrollView)

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.loadVisibleThumbnails()
        }

        emptyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: content.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 88),
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -14),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            emptyLabel.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: rootView.centerYAnchor)
        ])
    }

    private func prepareForDisplay() {
        titleLabel.stringValue = L10n.tr("history.title")
        window?.title = L10n.tr("history.title")

        // 如果已有旧列表，先直接显示旧列表，后台刷新；首次打开才显示 Loading。
        if cardViews.isEmpty {
            emptyLabel.stringValue = "Loading..."
            emptyLabel.isHidden = false
            scrollView.isHidden = true
        }
    }

    private func reloadAsync() {
        reloadGeneration += 1
        let generation = reloadGeneration
        CaptureHistoryManager.shared.asyncItems { [weak self] items in
            guard let self, generation == self.reloadGeneration else { return }
            self.render(items: items)
        }
    }

    private func render(items: [CaptureHistoryItem]) {
        titleLabel.stringValue = L10n.tr("history.title")
        window?.title = L10n.tr("history.title")
        emptyLabel.stringValue = L10n.tr("history.empty")

        historyContentView.subviews.forEach { $0.removeFromSuperview() }
        cardViews.removeAll()

        if let selectedItem, !items.contains(selectedItem) {
            self.selectedItem = items.first
        } else if selectedItem == nil {
            selectedItem = items.first
        }

        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty

        let cardWidth: CGFloat = 210
        let cardHeight: CGFloat = 252
        let spacing: CGFloat = 16
        let inset: CGFloat = 14
        let contentWidth = max(1, inset * 2 + CGFloat(items.count) * cardWidth + CGFloat(max(0, items.count - 1)) * spacing)
        historyContentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: cardHeight)

        for (index, item) in items.enumerated() {
            let card = CaptureHistoryCardView(
                item: item,
                onSelect: { [weak self] selected in self?.selectItem(selected) },
                onDelete: { [weak self] deleted in
                    guard let self else { return }
                    CaptureHistoryManager.shared.delete(deleted)
                    if self.selectedItem == deleted { self.selectedItem = nil }
                    FeedbackToast.show(L10n.tr("history.deleted"), screen: self.window?.screen, anchorRect: self.window?.frame)
                    self.reloadAsync()
                }
            )
            card.frame = NSRect(
                x: inset + CGFloat(index) * (cardWidth + spacing),
                y: 0,
                width: cardWidth,
                height: cardHeight
            )
            card.isSelected = item == selectedItem
            historyContentView.addSubview(card)
            cardViews.append(card)
        }

        DispatchQueue.main.async { [weak self] in
            self?.loadVisibleThumbnails()
        }
    }

    private func loadVisibleThumbnails() {
        guard !cardViews.isEmpty, !scrollView.isHidden else { return }
        let preloadRect = scrollView.contentView.bounds.insetBy(dx: -460, dy: -40)
        for card in cardViews where card.frame.intersects(preloadRect) {
            card.startThumbnailLoad()
        }
    }

    private func selectItem(_ item: CaptureHistoryItem) {
        selectedItem = item
        cardViews.forEach { $0.isSelected = $0.item == item }
        window?.makeFirstResponder(rootView)
    }

    private func copySelectedItem() {
        guard let item = selectedItem else {
            NSSound.beep()
            return
        }
        copyItemToPasteboard(item)
    }

    private func copyItemToPasteboard(_ item: CaptureHistoryItem) {
        let targetScreen = window?.screen
        let anchorRect = window?.frame
        DispatchQueue.global(qos: .userInitiated).async {
            let image = autoreleasepool {
                CGImageSourceCreateWithURL(item.url as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            DispatchQueue.main.async {
                guard let image else {
                    NSSound.beep()
                    return
                }
                ImageExporter.copyToPasteboard(image)
                FeedbackToast.show(L10n.tr("feedback.copied"), screen: targetScreen, anchorRect: anchorRect)
            }
        }
    }

    private func positionAtPointerScreen() {
        guard let window, let screen = Self.screenUnderPointer() ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(980, max(560, visible.width * 0.78))
        let height: CGFloat = 360
        window.setFrame(
            NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
            display: false
        )
    }

    private static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
    }
}

private final class CaptureHistoryCardView: NSView {
    let item: CaptureHistoryItem
    private let onSelect: (CaptureHistoryItem) -> Void
    private let onDelete: (CaptureHistoryItem) -> Void
    private let imageView = NSImageView()
    private var thumbnailRequested = false
    private var isDeleting = false

    var isSelected: Bool = false {
        didSet { updateSelectionAppearance(animated: oldValue != isSelected) }
    }

    init(
        item: CaptureHistoryItem,
        onSelect: @escaping (CaptureHistoryItem) -> Void,
        onDelete: @escaping (CaptureHistoryItem) -> Void
    ) {
        self.item = item
        self.onSelect = onSelect
        self.onDelete = onDelete
        super.init(frame: .zero)
        buildUI()
        updateSelectionAppearance(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func startThumbnailLoad() {
        guard !thumbnailRequested, !isDeleting else { return }
        thumbnailRequested = true
        let itemURL = item.url
        CaptureHistoryThumbnailCache.shared.thumbnail(for: itemURL, maxPixelSize: 420) { [weak self] thumbnail in
            guard let self, !self.isDeleting, self.item.url == itemURL, let thumbnail else { return }
            self.imageView.alphaValue = 0
            self.imageView.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.imageView.animator().alphaValue = 1
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isDeleting else { return }
        onSelect(item)
        if event.clickCount >= 2 {
            copyItemToPasteboard()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !isDeleting else { return }
        onSelect(item)
        let menu = NSMenu()
        let showItem = NSMenuItem(title: L10n.tr("history.showInFinder"), action: #selector(showInFinder), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func buildUI() {
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = false
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.84).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 0
        shadow?.shadowOffset = .zero
        shadow?.shadowColor = .clear

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 12
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        let info = NSTextField(labelWithString: "\(item.width) × \(item.height) · \(relativeTime(for: item.date))")
        info.font = .systemFont(ofSize: 12, weight: .medium)
        info.textColor = .secondaryLabelColor
        info.alignment = .center
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        addSubview(info)

        let deleteButton = NSButton(title: "×", target: self, action: #selector(deleteItem))
        deleteButton.toolTip = L10n.tr("history.delete")
        deleteButton.isBordered = false
        deleteButton.font = .systemFont(ofSize: 18, weight: .bold)
        deleteButton.contentTintColor = .white
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = 11
        deleteButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.52).cgColor
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: info.topAnchor, constant: -9),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            info.heightAnchor.constraint(equalToConstant: 18),
            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.widthAnchor.constraint(equalToConstant: 22),
            deleteButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @objc private func deleteItem() {
        guard !isDeleting else { return }
        isDeleting = true
        onSelect(item)
        explodeAndDelete { [weak self] in
            guard let self else { return }
            self.onDelete(self.item)
        }
    }

    @objc private func showInFinder() {
        guard !isDeleting else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    private func copyItemToPasteboard() {
        let targetScreen = window?.screen
        let anchorRect = window?.frame
        let itemURL = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            let image = autoreleasepool {
                CGImageSourceCreateWithURL(itemURL as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            DispatchQueue.main.async {
                guard let image else {
                    NSSound.beep()
                    return
                }
                ImageExporter.copyToPasteboard(image)
                FeedbackToast.show(L10n.tr("feedback.copied"), screen: targetScreen, anchorRect: anchorRect)
            }
        }
    }

    /// 高级删除动画：
    /// 1. 先把整张卡片截图成一张快照；
    /// 2. 把快照切成多个碎片；
    /// 3. 原卡片隐藏，碎片从原位置向外爆开、旋转、缩小并淡出；
    /// 4. 动画结束后再真正删除文件并刷新历史列表。
    private func explodeAndDelete(completion: @escaping () -> Void) {
        guard let container = superview,
              let snapshot = snapshotForExplosion(),
              bounds.width > 4,
              bounds.height > 4 else {
            fallbackDeleteAnimation(completion: completion)
            return
        }

        layoutSubtreeIfNeeded()
        container.wantsLayer = true
        guard let containerLayer = container.layer else {
            fallbackDeleteAnimation(completion: completion)
            return
        }

        let sourceFrame = frame
        let overlayLayer = CALayer()
        overlayLayer.frame = sourceFrame
        overlayLayer.masksToBounds = false
        overlayLayer.zPosition = 9999
        containerLayer.addSublayer(overlayLayer)

        addImpactFlash(to: overlayLayer)
        addShockwave(to: overlayLayer)
        addGlowBurst(to: overlayLayer)

        // 原卡片立刻隐藏，视觉上由碎片层接管。
        alphaValue = 0

        let columns = 7
        let rows = 6
        let pieceWidth = bounds.width / CGFloat(columns)
        let pieceHeight = bounds.height / CGFloat(rows)
        let pixelScaleX = CGFloat(snapshot.width) / max(1, bounds.width)
        let pixelScaleY = CGFloat(snapshot.height) / max(1, bounds.height)

        var maxAnimationTime: TimeInterval = 0.0

        for row in 0..<rows {
            for column in 0..<columns {
                let viewRect = CGRect(
                    x: CGFloat(column) * pieceWidth,
                    y: CGFloat(row) * pieceHeight,
                    width: column == columns - 1 ? bounds.width - CGFloat(column) * pieceWidth : pieceWidth,
                    height: row == rows - 1 ? bounds.height - CGFloat(row) * pieceHeight : pieceHeight
                ).integral

                guard viewRect.width > 0, viewRect.height > 0 else { continue }

                let cropRect = CGRect(
                    x: viewRect.minX * pixelScaleX,
                    y: CGFloat(snapshot.height) - viewRect.maxY * pixelScaleY,
                    width: viewRect.width * pixelScaleX,
                    height: viewRect.height * pixelScaleY
                ).integral

                guard let shardImage = snapshot.cropping(to: cropRect) else { continue }

                let shardLayer = CALayer()
                shardLayer.contents = shardImage
                shardLayer.contentsGravity = .resize
                shardLayer.frame = viewRect
                shardLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                shardLayer.position = CGPoint(x: viewRect.midX, y: viewRect.midY)
                shardLayer.shadowColor = NSColor.black.cgColor
                shardLayer.shadowOpacity = 0.22
                shardLayer.shadowRadius = 7
                shardLayer.shadowOffset = CGSize(width: 0, height: -2)
                shardLayer.shouldRasterize = true
                shardLayer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
                overlayLayer.addSublayer(shardLayer)

                let seed = CGFloat(row * columns + column + 1)
                let jitterX = (noise(seed * 3.7) - 0.5) * 72
                let jitterY = (noise(seed * 8.9) - 0.5) * 62
                let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
                var vector = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
                let length = max(1, sqrt(vector.x * vector.x + vector.y * vector.y))
                vector.x /= length
                vector.y /= length

                let blastPower = 96 + noise(seed * 13.1) * 92
                let endPosition = CGPoint(
                    x: shardLayer.position.x + vector.x * blastPower + jitterX,
                    y: shardLayer.position.y + vector.y * blastPower + jitterY
                )

                let delay = TimeInterval(noise(seed * 2.1) * 0.075)
                let duration = TimeInterval(0.56 + noise(seed * 5.3) * 0.22)
                maxAnimationTime = max(maxAnimationTime, delay + duration)

                let positionAnimation = CABasicAnimation(keyPath: "position")
                positionAnimation.fromValue = NSValue(point: shardLayer.position)
                positionAnimation.toValue = NSValue(point: endPosition)

                let opacityAnimation = CABasicAnimation(keyPath: "opacity")
                opacityAnimation.fromValue = 1.0
                opacityAnimation.toValue = 0.0

                let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
                scaleAnimation.fromValue = 1.0
                scaleAnimation.toValue = 0.18 + noise(seed * 7.7) * 0.16

                let rotationAnimation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotationAnimation.fromValue = 0
                rotationAnimation.toValue = (noise(seed * 11.3) - 0.5) * CGFloat.pi * 2.8

                let group = CAAnimationGroup()
                group.animations = [
                    positionAnimation,
                    opacityAnimation,
                    scaleAnimation,
                    rotationAnimation
                ]
                group.beginTime = CACurrentMediaTime() + delay
                group.duration = duration
                group.timingFunction = CAMediaTimingFunction(controlPoints: 0.12, 0.82, 0.18, 1.0)
                group.fillMode = .forwards
                group.isRemovedOnCompletion = false
                shardLayer.add(group, forKey: "premiumExplosion")
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + maxAnimationTime + 0.06) { [weak overlayLayer] in
            overlayLayer?.removeFromSuperlayer()
            completion()
        }
    }

    private func fallbackDeleteAnimation(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
            animator().frame = frame.insetBy(dx: 14, dy: 18)
        } completionHandler: {
            completion()
        }
    }

    private func snapshotForExplosion() -> CGImage? {
        layoutSubtreeIfNeeded()
        guard bounds.width > 2, bounds.height > 2,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    private func addImpactFlash(to overlayLayer: CALayer) {
        let flashLayer = CALayer()
        flashLayer.frame = bounds
        flashLayer.cornerRadius = 16
        flashLayer.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        flashLayer.opacity = 0
        overlayLayer.addSublayer(flashLayer)

        let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnimation.values = [0.0, 0.92, 0.0]
        opacityAnimation.keyTimes = [0.0, 0.22, 1.0]
        opacityAnimation.duration = 0.18
        opacityAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(opacityAnimation, forKey: "impactFlash")
    }

    private func addShockwave(to overlayLayer: CALayer) {
        let waveLayer = CAShapeLayer()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let startRadius: CGFloat = 18
        let endRadius = max(bounds.width, bounds.height) * 0.68

        waveLayer.path = CGPath(ellipseIn: CGRect(
            x: center.x - startRadius,
            y: center.y - startRadius,
            width: startRadius * 2,
            height: startRadius * 2
        ), transform: nil)
        waveLayer.fillColor = NSColor.clear.cgColor
        waveLayer.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
        waveLayer.lineWidth = 2.5
        waveLayer.opacity = 0.92
        waveLayer.shadowColor = NSColor.controlAccentColor.cgColor
        waveLayer.shadowOpacity = 0.55
        waveLayer.shadowRadius = 12
        waveLayer.shadowOffset = .zero
        overlayLayer.addSublayer(waveLayer)

        let endPath = CGPath(ellipseIn: CGRect(
            x: center.x - endRadius,
            y: center.y - endRadius,
            width: endRadius * 2,
            height: endRadius * 2
        ), transform: nil)

        let pathAnimation = CABasicAnimation(keyPath: "path")
        pathAnimation.fromValue = waveLayer.path
        pathAnimation.toValue = endPath

        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.92
        opacityAnimation.toValue = 0.0

        let widthAnimation = CABasicAnimation(keyPath: "lineWidth")
        widthAnimation.fromValue = 2.5
        widthAnimation.toValue = 0.2

        let group = CAAnimationGroup()
        group.animations = [pathAnimation, opacityAnimation, widthAnimation]
        group.duration = 0.46
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        waveLayer.add(group, forKey: "shockwave")
    }

    private func addGlowBurst(to overlayLayer: CALayer) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let sparkCount = 16

        for index in 0..<sparkCount {
            let seed = CGFloat(index + 1)
            let angle = (CGFloat(index) / CGFloat(sparkCount)) * CGFloat.pi * 2 + (noise(seed * 4.2) - 0.5) * 0.42
            let distance = 60 + noise(seed * 9.1) * 82
            let length = 5 + noise(seed * 2.8) * 7
            let thickness = 1.4 + noise(seed * 6.4) * 1.5
            let delay = TimeInterval(noise(seed * 3.3) * 0.045)
            let duration = TimeInterval(0.32 + noise(seed * 5.6) * 0.22)

            let spark = CALayer()
            spark.bounds = CGRect(x: 0, y: 0, width: length, height: thickness)
            spark.position = center
            spark.cornerRadius = thickness / 2
            spark.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
            spark.shadowColor = NSColor.controlAccentColor.cgColor
            spark.shadowOpacity = 0.8
            spark.shadowRadius = 8
            spark.shadowOffset = .zero
            spark.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
            overlayLayer.addSublayer(spark)

            let endPosition = CGPoint(
                x: center.x + cos(angle) * distance,
                y: center.y + sin(angle) * distance
            )

            let positionAnimation = CABasicAnimation(keyPath: "position")
            positionAnimation.fromValue = NSValue(point: center)
            positionAnimation.toValue = NSValue(point: endPosition)

            let opacityAnimation = CABasicAnimation(keyPath: "opacity")
            opacityAnimation.fromValue = 1.0
            opacityAnimation.toValue = 0.0

            let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
            scaleAnimation.fromValue = 1.0
            scaleAnimation.toValue = 0.12

            let group = CAAnimationGroup()
            group.animations = [positionAnimation, opacityAnimation, scaleAnimation]
            group.beginTime = CACurrentMediaTime() + delay
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            spark.add(group, forKey: "spark")
        }
    }

    /// 轻量伪随机，避免每次刷新历史列表时动画完全一样，同时不需要额外状态。
    private func noise(_ seed: CGFloat) -> CGFloat {
        let raw = sin(seed * 12.9898 + CGFloat(item.url.path.hashValue % 997) * 0.001) * 43758.5453
        return raw - floor(raw)
    }

    private func updateSelectionAppearance(animated: Bool) {
        let changes = {
            self.layer?.borderWidth = self.isSelected ? 2 : 1
            self.layer?.borderColor = self.isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.95).cgColor
                : NSColor.white.withAlphaComponent(0.18).cgColor
            self.layer?.backgroundColor = self.isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.windowBackgroundColor.withAlphaComponent(0.84).cgColor
            self.shadow?.shadowBlurRadius = self.isSelected ? 14 : 0
            self.shadow?.shadowColor = self.isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.38) : .clear
        }
        guard animated else { changes(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        }
    }

    private func relativeTime(for date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 60 { return L10n.tr("history.justNow") }
        if interval < 3600 { return L10n.format("history.minutesAgo", Int(interval / 60)) }
        if interval < 86400 { return L10n.format("history.hoursAgo", Int(interval / 3600)) }
        if interval < 172800 { return L10n.tr("history.oneDayAgo") }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

enum OCRService {
    static func recognize(image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}
