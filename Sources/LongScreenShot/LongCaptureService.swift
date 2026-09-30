import AppKit
import Accelerate
import CoreImage
import CoreMedia
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

// MARK: - 长截图统一调试开关

/// 开启后记录完整长截图诊断日志；测试完成后改成 false 即可完全关闭。
let LONG_CAPTURE_DEBUG_LOG_ENABLED = true

enum LongCaptureError: LocalizedError {
    case captureFailed
    case notScrollable
    case processingOverloaded
    case overlapLost

    var errorDescription: String? {
        switch self {
        case .overlapLost: return "检测到无法确认的拼接缺口，未导出不完整长图。请重新截图；出现重叠不足提示时，先回滚接续再完成。"
        case .processingOverloaded: return "采集速度超过处理能力，已停止以避免丢帧。请缩小选区后重新截图。"
        case .captureFailed: return "无法采集滚动截图帧。请重新框选可滚动内容区域后再试。"
        case .notScrollable: return "没有检测到页面滚动。请把鼠标放在可滚动内容内，并确认页面尚未到底。"
        }
    }
}


// MARK: - 长截图诊断日志

/// 只输出到 Xcode 控制台，不写入任何日志文件。
/// 在 Xcode 控制台搜索 `[LongCaptureDiag]`，即可完整复制本次长截图日志。
final class LongCaptureDiagnostics {
    static let shared = LongCaptureDiagnostics()

    let enabled = LONG_CAPTURE_DEBUG_LOG_ENABLED
    private let queue = DispatchQueue(label: "longscreenshot.diagnostics.console", qos: .utility)
    private let startTime = ProcessInfo.processInfo.systemUptime
    private var sessionSerial = 0

    private init() {
        guard enabled else { return }
        log("diagnostics.enabled output=XcodeConsole pid=\(ProcessInfo.processInfo.processIdentifier) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    func beginSession(_ summary: String) {
        guard enabled else { return }
        sessionSerial += 1
        log("================ session.begin #\(sessionSerial) \(summary) ================")
    }

    func endSession(_ summary: String) {
        guard enabled else { return }
        log("================ session.end #\(sessionSerial) \(summary) ================")
        flushSync()
    }

    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let rendered = message()
        let line = String(format: "[LongCaptureDiag %.3f] %@", elapsed, rendered)
        queue.async {
            NSLog("%@", line)
        }
    }

    /// 等待已经排队的控制台日志输出完成，便于完成/取消后立即复制。
    func flushSync() {
        guard enabled else { return }
        queue.sync {}
    }

    var logPath: String? { nil }
}

private func LCFormatRect(_ rect: CGRect) -> String {
    String(format: "{x=%.2f,y=%.2f,w=%.2f,h=%.2f}", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height)
}

private func LCFormatSize(_ size: CGSize) -> String {
    String(format: "%.0fx%.0f", size.width, size.height)
}

private func LCFormatOptionalInt(_ value: Int?) -> String {
    value.map(String.init) ?? "nil"
}

private func LCFormatOptionalDouble(_ value: Double?) -> String {
    value.map { String(format: "%.2f", $0) } ?? "nil"
}

private func LCFormatOptionalCGFloat(_ value: CGFloat?) -> String {
    value.map { String(format: "%.2f", Double($0)) } ?? "nil"
}

private func LCFormatOptionalBool(_ value: Bool?) -> String {
    value.map { String($0) } ?? "nil"
}

/// Continuous region capture backed by ScreenCaptureKit. Long screenshots need
/// the frames produced while scrolling; requesting isolated snapshots after a
/// gesture loses the intermediate overlap and can never recover once one seam is
/// missed.
final class ScrollCaptureStream: NSObject, SCStreamOutput {
    var onFrame: ((CGImage, Int, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect
    private let pixelSize: CGSize
    private let excludedWindowIDs: Set<CGWindowID>
    private let outputQueue = DispatchQueue(label: "longscreenshot.stream.output", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private let dumpRecorder = LongCaptureFrameDumpRecorder()
    private var stopped = false
    private var frameSerial = 0
    private var stream: SCStream?

    init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        pixelSize: CGSize,
        excludedWindowIDs: Set<CGWindowID>
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
        self.excludedWindowIDs = excludedWindowIDs
    }

    deinit {
        onFrame = nil
        onError = nil
        stop()
    }

    convenience init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        pixelSize: CGSize,
        excludedWindowID: CGWindowID
    ) {
        self.init(
            displayID: displayID,
            sourceRect: sourceRect,
            pixelSize: pixelSize,
            excludedWindowIDs: [excludedWindowID]
        )
    }

    func start() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.onError?(error) }
                return
            }
            self.stateLock.lock()
            let shouldStop = self.stopped
            self.stateLock.unlock()
            guard !shouldStop else { return }
            guard let content,
                  let display = content.displays.first(where: { $0.displayID == self.displayID }) else {
                DispatchQueue.main.async { self.onError?(LongCaptureError.captureFailed) }
                return
            }

            // 这里只排除截图交互窗口/长截图工具条窗口，不按 owningApplication 整个排除。
            // 这样同属于本 App 的“钉图/贴图”窗口仍会被保留在长截图结果里。
            let excluded = content.windows.filter { self.excludedWindowIDs.contains($0.windowID) }
            LongCaptureDiagnostics.shared.log("stream.prepare displayID=\(self.displayID) sourceRect=\(LCFormatRect(self.sourceRect)) pixelSize=\(LCFormatSize(self.pixelSize)) excludedWindowIDs=\(Array(self.excludedWindowIDs).sorted()) matchedExcludedWindows=\(excluded.map { $0.windowID }.sorted())")
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = self.sourceRect
            configuration.width = max(2, Int(self.pixelSize.width.rounded()))
            configuration.height = max(2, Int(self.pixelSize.height.rounded()))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 8
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.capturesAudio = false

            LongCaptureDiagnostics.shared.log("stream.start fps=60 queueDepth=8 width=\(configuration.width) height=\(configuration.height)")
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                self.stream = stream
                stream.startCapture { [weak self] error in
                    if let error {
                        LongCaptureDiagnostics.shared.log("stream.start.error \(error.localizedDescription)")
                        DispatchQueue.main.async { self?.onError?(error) }
                    } else {
                        LongCaptureDiagnostics.shared.log("stream.start.ok")
                    }
                }
            } catch {
                LongCaptureDiagnostics.shared.log("stream.addOutput.error \(error.localizedDescription)")
                DispatchQueue.main.async { self.onError?(error) }
            }
        }
    }

    func stop() {
        LongCaptureDiagnostics.shared.log("stream.stop requested frameSerial=\(frameSerial)")
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        let active = stream
        stream = nil
        active?.stopCapture(completionHandler: { _ in })
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ScreenCaptureKit may emit idle/stale/incomplete surfaces. They are especially
        // common under load and must not participate in matching or end detection.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
           let statusNumber = attachments.first?[.status] as? NSNumber,
           statusNumber.intValue != SCFrameStatus.complete.rawValue {
            return
        }
        guard let cgImage = detachedImage(from: pixelBuffer) else {
            LongCaptureDiagnostics.shared.log("stream.frame.detachFailed")
            return
        }
        frameSerial += 1
        if frameSerial <= 5 || frameSerial % 30 == 0 {
            LongCaptureDiagnostics.shared.log("stream.frame seq=\(frameSerial) size=\(cgImage.width)x\(cgImage.height)")
        }
        dumpRecorder.dumpIfNeeded(cgImage, index: frameSerial)
        onFrame?(cgImage, frameSerial, ProcessInfo.processInfo.systemUptime)
    }

    /// ScreenCaptureKit 的 sampleBuffer 底层通常挂着 IOSurface。这里把像素拷贝到
    /// 自己持有的 Data/CGImage 里，避免后续异步匹配时读到被复用的 surface。
    private func detachedImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)

        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let destinationBytesPerRow = width * 4
            var data = Data(count: destinationBytesPerRow * height)
            data.withUnsafeMutableBytes { dstBuffer in
                guard let dstBase = dstBuffer.baseAddress else { return }
                for row in 0..<height {
                    let src = baseAddress.advanced(by: row * sourceBytesPerRow)
                    let dst = dstBase.advanced(by: row * destinationBytesPerRow)
                    memcpy(dst, src, min(sourceBytesPerRow, destinationBytesPerRow))
                }
            }
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            let alpha: CGImageAlphaInfo = format == kCVPixelFormatType_32BGRA ? .premultipliedFirst : .premultipliedFirst
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: alpha.rawValue))
            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: destinationBytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        return FrameStitcher.detachedCopy(cgImage)
    }
}

private final class LongCaptureFrameDumpRecorder {
    private let enabled: Bool
    private let directory: URL?

    init() {
        enabled = UserDefaults.standard.bool(forKey: "LongCaptureDumpFrames")
        if enabled {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("LongCaptureFrameDump-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            directory = folder
            LongCaptureDiagnostics.shared.log("dump.frames directory=\(folder.path)")
        } else {
            directory = nil
        }
    }

    func dumpIfNeeded(_ image: CGImage, index: Int) {
        guard enabled, let directory, index <= 600 else { return }
        let url = directory.appendingPathComponent(String(format: "frame-%05d.png", index))
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

private struct FrameCandidateDebug {
    let reason: String
    let visualDelta: Double
    let expectedFromLast: Int?
    let measuredFromLast: CGFloat?
    let localMove: Int?
    let localTop: Int?
    let localScore: Double?
    let localMargin: Double?
    let localOverlap: Int?
    let localReliable: Bool?
    let anchorMove: Int?
    let anchorTop: Int?
    let anchorScore: Double?
    let anchorMargin: Double?
    let anchorOverlap: Int?
    let anchorReliable: Bool?

    func logSuffix(
        lastTop: Int?,
        canvasTop: Int?,
        candScroll: CGFloat,
        lastScroll: CGFloat?,
        poor: Int,
        recovering: Bool
    ) -> String {
        "reason=\(reason) visualDelta=\(String(format: "%.2f", visualDelta)) expected=\(LCFormatOptionalInt(expectedFromLast)) measured=\(LCFormatOptionalCGFloat(measuredFromLast)) localMove=\(LCFormatOptionalInt(localMove)) localTop=\(LCFormatOptionalInt(localTop)) localScore=\(LCFormatOptionalDouble(localScore)) localMargin=\(LCFormatOptionalDouble(localMargin)) localOverlap=\(LCFormatOptionalInt(localOverlap)) localReliable=\(LCFormatOptionalBool(localReliable)) anchorMove=\(LCFormatOptionalInt(anchorMove)) anchorTop=\(LCFormatOptionalInt(anchorTop)) anchorScore=\(LCFormatOptionalDouble(anchorScore)) anchorMargin=\(LCFormatOptionalDouble(anchorMargin)) anchorOverlap=\(LCFormatOptionalInt(anchorOverlap)) anchorReliable=\(LCFormatOptionalBool(anchorReliable)) lastTop=\(LCFormatOptionalInt(lastTop)) canvasTop=\(LCFormatOptionalInt(canvasTop)) candScroll=\(String(format: "%.2f", Double(candScroll))) lastScroll=\(LCFormatOptionalCGFloat(lastScroll)) poor=\(poor) recovering=\(recovering)"
    }
}

private struct FrameCandidateResult {
    let accepted: Bool
    let topOffset: Int
    let movementPixels: Int
    let poorMatch: Bool
    /// true 表示这一帧不仅能推进跟踪锚点，也足够可靠，可以写入最终长图。
    /// 重复内容页面上会出现“位移看起来合理，但 NCC 分数/候选分差很弱”的帧；
    /// 这类帧最多用于保持连续跟踪，不能落画布，否则会把错帧永久拼进去。
    let allowCanvasPlacement: Bool
    /// true 表示这帧只用于消费滚轮位置，不写画布、不推进图像锚点。
    /// 主要用于页面到达底部后继续滚动：滚轮 delta 还在增长，但画面没有实际新增内容。
    let consumeScrollOnly: Bool
    let status: String?
    let debug: FrameCandidateDebug?
}

private struct StreamFrameCandidate {
    let image: CGImage
    let scrollPosition: CGFloat
    let sequence: Int
    /// ScreenCaptureKit 产生该帧的单调时钟时间，用于统计端到端处理延迟。
    let captureTime: TimeInterval

    init(
        image: CGImage,
        scrollPosition: CGFloat,
        sequence: Int,
        captureTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        self.image = image
        self.scrollPosition = scrollPosition
        self.sequence = sequence
        self.captureTime = captureTime
    }
}

private struct StreamIngressFrame {
    let image: CGImage
    let sequence: Int
    let captureTime: TimeInterval
}

private struct ScrollPositionSample {
    let time: TimeInterval
    let position: CGFloat
}

private struct LongCaptureFrameAnchor {
    let image: CGImage
    let signature: FrameMatcher.FrameSignature?
    let topOffset: Int
    let scrollPosition: CGFloat
}

private struct PendingAcceptedTail {
    let anchor: LongCaptureFrameAnchor
    let sequence: Int
    let movementPixels: Int
    let visualDelta: Double
    let matchScore: Double?
    let matchMargin: Double?
}

/// v27：不再把“看起来可能正确”的恢复帧立即写进最终画布。
/// 这类帧先作为临时锚点继续跟踪，只有下一张连续帧再次向下推进后，
/// 才提交到画布。这样同时解决：
/// 1. 网页中段低纹理区域第一次 NCC 失败后永久断链；
/// 2. 页面到底后单张错误帧被直接追加，造成尾部重复。
private struct PendingRecoveryPlacement {
    let candidate: StreamFrameCandidate
    let anchor: LongCaptureFrameAnchor
    let movementPixels: Int
    let visualDelta: Double
    let expectedMovement: Int?
    let matchScore: Double
    let matchMargin: Double
    let stageReason: String
    let wasPoorMatch: Bool
}

private enum PendingRecoveryResolution: Equatable {
    case none
    case committed
    case rejected
}

struct LongCaptureCanvasPlacement {
    let image: CGImage
    /// 原始 viewport 在文档坐标中的顶部。
    let topOffset: Int
    /// 本次真正写入长画布的源图起点。v7 把整张 viewport 都覆盖进去，
    /// 只要 topOffset 抖 1~2px 就会在每个 placement 顶部产生横向断层。
    /// v8 只提交 overlap 末尾的一小段回补 + 新增区域。
    let sourceStart: Int
    let sourceHeight: Int
    let serial: Int
    var imageSourceStart: Int? = nil
}

struct LongCaptureCanvasSnapshot {
    let width: Int
    let height: Int
    let placements: [LongCaptureCanvasPlacement]

    func makeImage(targetWidth: Int? = nil, maximumHeight: Int? = nil) -> CGImage? {
        guard !placements.isEmpty, width > 0, height > 0 else { return nil }
        let scaleByWidth = CGFloat(targetWidth ?? width) / CGFloat(width)
        let scaleByHeight = maximumHeight.map { CGFloat($0) / CGFloat(max(1, height)) } ?? 1
        let scale = min(1, scaleByWidth, scaleByHeight)
        let outputWidth = max(1, Int(round(CGFloat(width) * scale)))
        let outputHeight = max(1, Int(round(CGFloat(height) * scale)))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = scale == 1 ? .none : .medium

        // v8：不再把每一张完整 viewport 全量覆盖进长画布。
        // 完整覆盖在 matcher 轻微抖动时会把窗口顶部行反复盖到画布中间，
        // 也就是用户看到的密集横向白线/黑线。这里每个 placement 只画：
        // 1. 接缝前少量安全回补；2. 本帧真正新增的尾部内容。
        for placement in placements.sorted(by: { $0.serial < $1.serial }) {
            let start = min(placement.image.height - 1, max(0, placement.imageSourceStart ?? placement.sourceStart))
            let height = min(placement.image.height - start, max(1, placement.sourceHeight))
            guard let patch = placement.image.cropping(to: CGRect(
                x: 0,
                y: start,
                width: placement.image.width,
                height: height
            )) else { continue }
            let destinationTop = placement.topOffset + placement.sourceStart
            let drawY = CGFloat(outputHeight) - CGFloat(destinationTop + height) * scale
            context.draw(
                patch,
                in: CGRect(
                    x: 0,
                    y: drawY,
                    width: CGFloat(width) * scale,
                    height: CGFloat(height) * scale
                )
            )
        }
        return context.makeImage()
    }
}

enum LongCaptureCanvasPlaceResult {
    case placed(sourceStart: Int, sourceHeight: Int)
    case skippedTooClose
    case skippedDuplicate
    case rejected
}

final class LongCaptureCanvasAccumulator {
    let width: Int
    let frameHeight: Int
    let maximumHeight: Int
    private(set) var contentHeight: Int
    private(set) var frameCount: Int
    private(set) var lastPlacedTopOffset: Int
    private var serial = 0
    private var placements: [LongCaptureCanvasPlacement]
    /// placements 中最后一个真正扩展画布高度的 placement。
    /// head overlap 刷新会追加覆盖层，但不能改变 place() 的单调追加基准。
    private var lastAppendPlacementIndex = 0
    private var lastTailFingerprint: PatchFingerprint?
    private var recentTailFingerprints: [PatchFingerprint] = []
    private var recentFrameSignatures: [FrameMatcher.FrameSignature] = []
    var placementCount: Int { placements.count }

    init(firstFrame: CGImage, maximumHeight: Int) {
        width = firstFrame.width
        frameHeight = firstFrame.height
        self.maximumHeight = maximumHeight
        contentHeight = firstFrame.height
        frameCount = 1
        lastPlacedTopOffset = 0
        placements = [LongCaptureCanvasPlacement(
            image: firstFrame,
            topOffset: 0,
            sourceStart: 0,
            sourceHeight: firstFrame.height,
            serial: serial
        )]

        lastTailFingerprint = Self.patchFingerprint(
            in: firstFrame,
            sourceStart: max(0, firstFrame.height - min(firstFrame.height, 420)),
            sourceHeight: min(firstFrame.height, 420)
        )
        if let lastTailFingerprint { recentTailFingerprints = [lastTailFingerprint] }
        if let signature = FrameMatcher.signature(firstFrame) { recentFrameSignatures = [signature] }
    }

    private struct PatchFingerprint {
        let pixels: [UInt8]
        let mean: Double
        let energy: Double
    }

    private static func patchFingerprint(
        in image: CGImage,
        sourceStart: Int,
        sourceHeight: Int,
        targetWidth: Int = 48,
        targetHeight: Int = 96
    ) -> PatchFingerprint? {
        let start = min(image.height - 1, max(0, sourceStart))
        let height = min(image.height - start, max(1, sourceHeight))
        guard height >= 24,
              let patch = image.cropping(to: CGRect(
                x: 0,
                y: start,
                width: image.width,
                height: height
              )) else { return nil }

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        guard let context = CGContext(
            data: &pixels,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(patch, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(max(1, pixels.count))
        var gradientTotal = 0.0
        var gradientCount = 0
        for y in 1..<targetHeight {
            for x in stride(from: 1, to: targetWidth - 1, by: 2) {
                let idx = y * targetWidth + x
                let dy = abs(Int(pixels[idx]) - Int(pixels[idx - targetWidth]))
                let dx = abs(Int(pixels[idx]) - Int(pixels[idx - 1]))
                gradientTotal += Double(dx + dy)
                gradientCount += 2
            }
        }
        let energy = gradientCount == 0 ? 0 : gradientTotal / Double(gradientCount)
        return PatchFingerprint(pixels: pixels, mean: mean, energy: energy)
    }

    private static func fingerprintMAD(_ a: PatchFingerprint, _ b: PatchFingerprint) -> Double {
        guard a.pixels.count == b.pixels.count else { return 255 }
        var total = 0
        for index in stride(from: 0, to: a.pixels.count, by: 2) {
            total += abs(Int(a.pixels[index]) - Int(b.pixels[index]))
        }
        let count = max(1, (a.pixels.count + 1) / 2)
        return Double(total) / Double(count)
    }

    private func isDuplicateFrameSignature(
        _ signature: FrameMatcher.FrameSignature?,
        tailGrowth: Int
    ) -> Bool {
        guard let signature, tailGrowth >= max(24, frameHeight / 20) else { return false }
        let bestDifference = recentFrameSignatures.suffix(8)
            .map { FrameMatcher.averageDifference($0, signature) }
            .min() ?? 255
        let duplicate = bestDifference <= 0.55
        if duplicate {
            LongCaptureDiagnostics.shared.log(
                "canvas.skipDuplicateViewport tailGrowth=\(tailGrowth) frameHeight=\(frameHeight) difference=\(String(format: "%.3f", bestDifference))"
            )
        }
        return duplicate
    }

    /// 页面到底后的橡皮筋会让同一 viewport 产生几十像素平移，
    /// 因而整屏指纹不再完全相等。这里比较最近 viewport 的最佳小平移：
    /// 只有“实际平移很小，但 matcher 想追加的尾巴明显更大”时才判重复。
    /// 正常滚动时 tailGrowth 应与 shift 接近，不会触发。
    private func isElasticDuplicateFrameSignature(
        _ signature: FrameMatcher.FrameSignature?,
        tailGrowth: Int
    ) -> Bool {
        guard let signature,
              tailGrowth >= max(72, Int(CGFloat(frameHeight) * 0.10)),
              !recentFrameSignatures.isEmpty else { return false }

        var bestScore = Double.greatestFiniteMagnitude
        var bestShift = frameHeight
        for previous in recentFrameSignatures.suffix(10) {
            let match = FrameMatcher.elasticShiftDifference(
                previous: previous,
                next: signature,
                maximumShiftRatio: 0.14
            )
            if match.score < bestScore {
                bestScore = match.score
                bestShift = match.shift
            }
        }

        let shift = abs(bestShift)
        let growthMismatch = tailGrowth >= max(
            Int(CGFloat(frameHeight) * 0.20),
            Int(CGFloat(shift) * 2.15) + 56
        )
        let duplicate = bestScore <= 3.15
            && shift <= Int(CGFloat(frameHeight) * 0.14)
            && growthMismatch

        if duplicate {
            LongCaptureDiagnostics.shared.log(
                "canvas.skipElasticDuplicate tailGrowth=\(tailGrowth) shift=\(bestShift) score=\(String(format: "%.2f", bestScore)) frameHeight=\(frameHeight)"
            )
        }
        return duplicate
    }

    private func isDuplicateTailPatch(
        frame: CGImage,
        topOffset: Int,
        sourceStart: Int,
        sourceHeight: Int,
        tailGrowth: Int
    ) -> Bool {
        let sampleHeight = min(sourceHeight, max(140, min(520, frame.height / 3)))
        guard sampleHeight >= 96,
              tailGrowth > 0,
              tailGrowth <= max(260, Int(CGFloat(frame.height) * 0.95)) else { return false }
        let sampleStart = sourceStart + max(0, sourceHeight - sampleHeight)
        guard let current = Self.patchFingerprint(
            in: frame,
            sourceStart: sampleStart,
            sourceHeight: sampleHeight
        ) else { return false }

        // 不只和“上一段”比，还和最近若干个已经写入的尾部片段比。页面到底后
        // matcher 偶尔会把更早出现过的 footer/列表尾部重新定位成新内容；只比较
        // lastTailFingerprint 会漏掉这种跨两三个 placement 的重复。
        guard current.energy >= 1.6 else { return false }
        var bestMAD = Double.greatestFiniteMagnitude
        var bestMeanDelta = Double.greatestFiniteMagnitude
        var matchedRecentIndex = -1
        for (index, previous) in recentTailFingerprints.suffix(10).enumerated() {
            guard previous.energy >= 1.6 else { continue }
            let mad = Self.fingerprintMAD(current, previous)
            let meanDelta = abs(current.mean - previous.mean)
            if mad + meanDelta < bestMAD + bestMeanDelta {
                bestMAD = mad
                bestMeanDelta = meanDelta
                matchedRecentIndex = index
            }
        }

        let matchesImmediateTail: Bool
        if let previous = lastTailFingerprint, previous.energy >= 1.6 {
            let mad = Self.fingerprintMAD(current, previous)
            let meanDelta = abs(current.mean - previous.mean)
            matchesImmediateTail = mad <= 3.0 && meanDelta <= 3.0
            if mad + meanDelta < bestMAD + bestMeanDelta {
                bestMAD = mad
                bestMeanDelta = meanDelta
            }
        } else {
            matchesImmediateTail = false
        }
        let matchesRecentTail = bestMAD <= 1.75 && bestMeanDelta <= 1.9
        let duplicate = matchesImmediateTail || matchesRecentTail
        if duplicate {
            let madText = String(format: "%.2f", bestMAD)
            let meanText = String(format: "%.2f", bestMeanDelta)
            let currentEnergyText = String(format: "%.2f", current.energy)
            LongCaptureDiagnostics.shared.log(
                "canvas.skipDuplicateTail top=\(topOffset) sourceStart=\(sourceStart) sourceHeight=\(sourceHeight) tailGrowth=\(tailGrowth) mad=\(madText) meanDelta=\(meanText) energy=\(currentEnergyText) recentIndex=\(matchedRecentIndex)"
            )
        }
        return duplicate
    }

    /// 页面到底后的橡皮筋效果会让整屏内容发生小幅纵向位移，
    /// 因而“整屏直接指纹”不再完全相同。这里允许对最近 viewport 做纵向平移后比较，
    /// 只作为底部怀疑状态下的辅助证据，不能单独用于正常滚动去重。
    func recentElasticViewportMatch(
        _ signature: FrameMatcher.FrameSignature?
    ) -> (score: Double, shift: Int)? {
        guard let signature else { return nil }
        var best: (score: Double, shift: Int)?
        for previous in recentFrameSignatures.suffix(8) {
            let candidate = FrameMatcher.elasticShiftDifference(previous: previous, next: signature)
            if best == nil || candidate.score < best!.score { best = candidate }
        }
        return best
    }

    /// 用较新的实时帧回补已经存在于画布中的重叠区域。
    /// 只用于截图刚开始时刷新第一屏里的懒加载图片/GIF 解码结果；
    /// 不改变 contentHeight、frameCount 或最后追加位置，也不会制造新内容。
    @discardableResult
    func overlayExistingRange(
        _ frame: CGImage,
        topOffset rawTopOffset: Int,
        sourceStart rawSourceStart: Int,
        sourceHeight rawSourceHeight: Int
    ) -> (sourceStart: Int, sourceHeight: Int)? {
        guard frame.width == width, frame.height == frameHeight else { return nil }
        let topOffset = max(0, rawTopOffset)
        let sourceStart = min(frame.height - 1, max(0, rawSourceStart))
        let requestedHeight = min(frame.height - sourceStart, max(0, rawSourceHeight))
        guard requestedHeight > 0 else { return nil }

        let destinationTop = topOffset + sourceStart
        guard destinationTop < contentHeight else { return nil }
        let sourceHeight = min(requestedHeight, contentHeight - destinationTop)
        guard sourceHeight > 0 else { return nil }

        serial += 1
        placements.append(LongCaptureCanvasPlacement(
            image: frame,
            topOffset: topOffset,
            sourceStart: sourceStart,
            sourceHeight: sourceHeight,
            serial: serial
        ))
        return (sourceStart, sourceHeight)
    }

    @discardableResult
    func place(
        _ frame: CGImage,
        topOffset rawTopOffset: Int,
        minimumStep: Int = 0,
        force: Bool = false,
        signature: FrameMatcher.FrameSignature? = nil,
        visuallyVerified: Bool = false
    ) -> LongCaptureCanvasPlaceResult {
        guard frame.width == width, frame.height == frameHeight else { return .rejected }
        let topOffset = max(0, rawTopOffset)

        guard placements.indices.contains(lastAppendPlacementIndex) else { return .rejected }
        let last = placements[lastAppendPlacementIndex]

        // 仍然保持文档坐标单调，防止错配回头覆盖。
        if topOffset < last.topOffset {
            if abs(last.topOffset - topOffset) <= 1 {
                let sourceStart = last.sourceStart
                let sourceHeight = last.sourceHeight
                placements[lastAppendPlacementIndex] = LongCaptureCanvasPlacement(
                    image: frame,
                    topOffset: last.topOffset,
                    sourceStart: sourceStart,
                    sourceHeight: sourceHeight,
                    serial: last.serial
                )
                contentHeight = max(contentHeight, last.topOffset + sourceStart + sourceHeight)
                lastPlacedTopOffset = last.topOffset
                return .placed(sourceStart: sourceStart, sourceHeight: sourceHeight)
            }
            return .rejected
        }

        if abs(last.topOffset - topOffset) <= 1 {
            let sourceStart = last.sourceStart
            let sourceHeight = last.sourceHeight
            placements[lastAppendPlacementIndex] = LongCaptureCanvasPlacement(
                image: frame,
                topOffset: last.topOffset,
                sourceStart: sourceStart,
                sourceHeight: sourceHeight,
                serial: last.serial
            )
            contentHeight = max(contentHeight, last.topOffset + sourceStart + sourceHeight)
            lastPlacedTopOffset = last.topOffset
            return .placed(sourceStart: sourceStart, sourceHeight: sourceHeight)
        }

        if !force, topOffset - last.topOffset < minimumStep {
            return .skippedTooClose
        }

        // ScreenSnap 的 LongCanvas 不是在接缝处反复回补 overlap，
        // 而是维护 contentMaxY，只把“还没有写入画布的新区域”追加进去。
        // 之前的 seamBacktrack 会把旧尾巴反复覆盖，弱纹理页面上容易出现重复和错位。
        // 这里改成 ScreenSnap 式 append：topOffset 必须仍然和当前画布有重叠，
        // sourceStart = 当前画布尾部在新帧中的位置。
        guard topOffset <= contentHeight else {
            LongCaptureDiagnostics.shared.log("canvas.rejectGap top=\(topOffset) contentHeight=\(contentHeight) frameHeight=\(frame.height)")
            return .rejected
        }

        let sourceStart = min(frame.height, max(0, contentHeight - topOffset))
        let sourceHeight = frame.height - sourceStart
        guard sourceHeight > 0 else { return .skippedTooClose }

        let nextHeight = topOffset + frame.height
        guard nextHeight > contentHeight else { return .skippedTooClose }
        guard nextHeight <= maximumHeight else { return .rejected }

        let tailGrowth = nextHeight - contentHeight
        // `force` may bypass the placement granularity for the last small strip, but
        // it must never bypass duplicate detection. Bypassing both was what allowed a
        // repeated footer to be appended when Done was pressed.
        if !visuallyVerified && isDuplicateFrameSignature(signature, tailGrowth: tailGrowth) {
            return .skippedDuplicate
        }
        if !visuallyVerified && isElasticDuplicateFrameSignature(signature, tailGrowth: tailGrowth) {
            return .skippedDuplicate
        }
        if !visuallyVerified && isDuplicateTailPatch(
            frame: frame,
            topOffset: topOffset,
            sourceStart: sourceStart,
            sourceHeight: sourceHeight,
            tailGrowth: tailGrowth
           ) {
            return .skippedDuplicate
        }

        // Store only the new strip after visual verification, otherwise a 1px
        // movement would retain an entire Retina viewport for every source row.
        let storedImage: CGImage
        if visuallyVerified {
            guard let patch = FrameStitcher.copyRange(from: frame, sourceStart: sourceStart, height: sourceHeight) else {
                return .rejected
            }
            storedImage = patch
        } else {
            storedImage = frame
        }
        serial += 1
        placements.append(LongCaptureCanvasPlacement(
            image: storedImage,
            topOffset: topOffset,
            sourceStart: sourceStart,
            sourceHeight: sourceHeight,
            serial: serial,
            imageSourceStart: visuallyVerified ? 0 : nil
        ))
        lastAppendPlacementIndex = placements.count - 1
        contentHeight = nextHeight
        frameCount += 1
        lastPlacedTopOffset = topOffset
        if visuallyVerified { return .placed(sourceStart: sourceStart, sourceHeight: sourceHeight) }
        let fingerprintSampleHeight = min(sourceHeight, max(140, min(520, frame.height / 3)))
        let newTailFingerprint = Self.patchFingerprint(
            in: frame,
            sourceStart: sourceStart + max(0, sourceHeight - fingerprintSampleHeight),
            sourceHeight: fingerprintSampleHeight
        )
        if let newTailFingerprint {
            lastTailFingerprint = newTailFingerprint
            recentTailFingerprints.append(newTailFingerprint)
            if recentTailFingerprints.count > 12 {
                recentTailFingerprints.removeFirst(recentTailFingerprints.count - 12)
            }
        }
        if let signature {
            recentFrameSignatures.append(signature)
            if recentFrameSignatures.count > 10 {
                recentFrameSignatures.removeFirst(recentFrameSignatures.count - 10)
            }
        }
        return .placed(sourceStart: sourceStart, sourceHeight: sourceHeight)
    }

    func snapshot() -> LongCaptureCanvasSnapshot {
        LongCaptureCanvasSnapshot(width: width, height: contentHeight, placements: placements)
    }
}

private struct LongCapturePreviewPlacement {
    let image: CGImage
    let topOffset: Int
    let serial: Int
}

/// Testable overview builder that keeps source segments and regenerates the current
/// full minimap from source pixels. It intentionally avoids repeatedly scaling an
/// already-scaled preview, so very long captures do not accumulate blur.
final class PreviewOverviewStore {
    private let sourceWidth: Int
    private let maximumWidth: Int
    private let maximumHeight: Int
    private let chunkHeight: Int
    private var segments: [CGImage] = []

    var overview: CGImage? {
        guard !segments.isEmpty else { return nil }
        let targetWidth = max(1, min(maximumWidth, sourceWidth))
        guard let full = FrameStitcher.composeSegments(segments, targetWidth: targetWidth) else { return nil }
        return FrameStitcher.composeOverviewChunks([full], width: full.width, maximumHeight: maximumHeight)
    }

    init(sourceWidth: Int, maximumWidth: Int, maximumHeight: Int, chunkHeight: Int) {
        self.sourceWidth = max(1, sourceWidth)
        self.maximumWidth = max(1, maximumWidth)
        self.maximumHeight = max(1, maximumHeight)
        self.chunkHeight = max(1, chunkHeight)
    }

    func append(_ image: CGImage, droppingLeadingSourcePixels: Int = 0) {
        let start = min(image.height - 1, max(0, droppingLeadingSourcePixels))
        let height = image.height - start
        guard height > 0,
              let segment = FrameStitcher.copyRange(from: image, sourceStart: start, height: height) else { return }

        if segment.height <= chunkHeight {
            segments.append(segment)
            return
        }

        var offset = 0
        while offset < segment.height {
            let nextHeight = min(chunkHeight, segment.height - offset)
            if let chunk = FrameStitcher.copyRange(from: segment, sourceStart: offset, height: nextHeight) {
                segments.append(chunk)
            }
            offset += nextHeight
        }
    }
}

/// 预览只使用已经降采样过的小图层，不再每次从完整 CGImage 长画布重绘。
/// 这会把实时预览从 O(完整帧数量 × 完整帧像素) 降到 O(小缩略帧数量 × 缩略像素)，
/// 长页面滚动完成后不会再卡几秒追预览。
/// iShot 式长截图预览片段：只把新增区域预缩放一次，然后交给 UI 作为独立图层追加。
/// 这里不参与截图采集、匹配、拼接；只服务实时预览。
struct LongCapturePreviewSegment {
    let image: CGImage
    let serial: Int
    let previewTop: Int
    let previewHeight: Int
    let previewWidth: Int
    let previewContentHeight: Int
}

/// 高性能预览片段缓存。
///
/// 旧实现每次预览刷新都会从一个越来越高的 CGContext 中 makeImage/crop/scale，
/// 长图越高，单次刷新成本越大。iShot 的思路是把每次新增内容作为独立小图层追加，
/// 后续只做容器缩放/裁剪，不再重新合成整张缩略图。
final class LongCapturePreviewSegmentStore {
    private let sourceWidth: Int
    private let targetWidth: Int
    private let sourceToPreviewScale: CGFloat
    private let tileHeight = 384
    private var serial = 0
    private var tileContexts: [Int: CGContext] = [:]
    private var pendingTiles: [Int: LongCapturePreviewSegment] = [:]

    private(set) var previewContentHeight: Int = 0
    private(set) var placementCount: Int = 0

    init(firstFrame: CGImage, targetWidth: Int) {
        sourceWidth = max(1, firstFrame.width)
        self.targetWidth = max(1, min(targetWidth, firstFrame.width))
        sourceToPreviewScale = CGFloat(self.targetWidth) / CGFloat(sourceWidth)
        place(firstFrame, topOffset: 0, sourceStart: 0, sourceHeight: firstFrame.height)
    }

    func place(
        _ frame: CGImage,
        topOffset sourceTopOffset: Int,
        sourceStart: Int = 0,
        sourceHeight requestedSourceHeight: Int? = nil,
        preparedPreviewFrame: CGImage? = nil
    ) {
        let start = min(frame.height - 1, max(0, sourceStart))
        let height = min(frame.height - start, max(1, requestedSourceHeight ?? (frame.height - start)))
        guard height > 0 else { return }

        let previewTop = max(0, Int(round(CGFloat(sourceTopOffset + start) * sourceToPreviewScale)))
        let requestedPreviewHeight = max(1, Int(round(CGFloat(height) * sourceToPreviewScale)))

        guard let image = makePreviewImage(
            from: frame,
            sourceStart: start,
            sourceHeight: height,
            previewHeight: requestedPreviewHeight,
            preparedPreviewFrame: preparedPreviewFrame
        ) else {
            LongCaptureDiagnostics.shared.log("preview.segment.makeFailed top=\(sourceTopOffset) sourceStart=\(start) sourceHeight=\(height)")
            return
        }
        placePreviewImage(image, previewTop: previewTop)
    }

    /// 已经在 previewQueue 完成降采样的新增区域，直接写入缩略 tile。
    /// sourceDocumentTop 是该 patch 在最终长图中的顶部坐标。
    func placePreparedPreviewPatch(_ image: CGImage, sourceDocumentTop: Int) {
        guard image.width == targetWidth, image.height > 0 else { return }
        let previewTop = max(0, Int(round(CGFloat(sourceDocumentTop) * sourceToPreviewScale)))
        placePreviewImage(image, previewTop: previewTop)
    }

    private func placePreviewImage(_ image: CGImage, previewTop: Int) {
        let previewHeight = image.height
        let previewBottom = previewTop + previewHeight
        placementCount += 1
        previewContentHeight = max(previewContentHeight, previewBottom)

        var sourceOffset = 0
        var touchedTileIndices: [Int] = []
        while sourceOffset < previewHeight {
            let globalTop = previewTop + sourceOffset
            let tileIndex = globalTop / tileHeight
            let offsetInTile = globalTop % tileHeight
            let partHeight = min(previewHeight - sourceOffset, tileHeight - offsetInTile)
            guard let context = context(forTile: tileIndex),
                  let part = image.cropping(to: CGRect(
                    x: 0,
                    y: sourceOffset,
                    width: image.width,
                    height: partHeight
                  )) else { break }
            context.interpolationQuality = .none
            context.draw(part, in: CGRect(
                x: 0,
                y: tileHeight - offsetInTile - partHeight,
                width: targetWidth,
                height: partHeight
            ))
            touchedTileIndices.append(tileIndex)
            sourceOffset += partHeight
        }

        for tileIndex in Set(touchedTileIndices) {
            guard let tileImage = tileContexts[tileIndex]?.makeImage() else { continue }
            serial += 1
            pendingTiles[tileIndex] = LongCapturePreviewSegment(
                image: tileImage,
                serial: serial,
                previewTop: tileIndex * tileHeight,
                previewHeight: tileHeight,
                previewWidth: targetWidth,
                previewContentHeight: previewContentHeight
            )
        }

        // Placements are monotonic. Once two newer tiles exist, old CGContext backing
        // stores can be released; the UI layer already owns their immutable images.
        let newestTile = max(0, (previewContentHeight - 1) / tileHeight)
        tileContexts = tileContexts.filter { $0.key >= newestTile - 1 }
    }

    func drainPendingSegments() -> [LongCapturePreviewSegment] {
        guard !pendingTiles.isEmpty else { return [] }
        let segments = pendingTiles.sorted { $0.key < $1.key }.map(\.value)
        pendingTiles.removeAll(keepingCapacity: true)
        return segments
    }

    private func context(forTile index: Int) -> CGContext? {
        if let existing = tileContexts[index] { return existing }
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: tileHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: targetWidth, height: tileHeight))
        tileContexts[index] = context
        return context
    }

    private func makePreviewImage(
        from frame: CGImage,
        sourceStart: Int,
        sourceHeight: Int,
        previewHeight: Int,
        preparedPreviewFrame: CGImage?
    ) -> CGImage? {
        // The regular path is pre-scaled on matchQueue. Only a crop of the tiny image
        // remains here, keeping full-width resampling off the main thread.
        if let preparedPreviewFrame,
           preparedPreviewFrame.width == targetWidth {
            let scaleY = CGFloat(preparedPreviewFrame.height) / CGFloat(max(1, frame.height))
            let previewStart = min(
                preparedPreviewFrame.height - 1,
                max(0, Int(round(CGFloat(sourceStart) * scaleY)))
            )
            let availableHeight = preparedPreviewFrame.height - previewStart
            let croppedHeight = min(
                availableHeight,
                max(1, Int(round(CGFloat(sourceHeight) * scaleY)))
            )
            if croppedHeight > 0,
               let cropped = preparedPreviewFrame.cropping(to: CGRect(
                x: 0,
                y: previewStart,
                width: preparedPreviewFrame.width,
                height: croppedHeight
               )) {
                return cropped
            }
        }

        guard let patch = frame.cropping(to: CGRect(
            x: 0,
            y: sourceStart,
            width: frame.width,
            height: sourceHeight
        )) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 只对新增 patch 做一次降采样；后续实时预览仅摆放 NSImageView，不再重采样整张长图。
        context.interpolationQuality = .low
        context.draw(
            patch,
            in: CGRect(x: 0, y: 0, width: CGFloat(targetWidth), height: CGFloat(previewHeight))
        )
        return context.makeImage()
    }
}

// MARK: - 连续视觉定位长截图

/// Tracks rendered pixels, independently of wheel acceleration, browser smooth
/// scrolling, event delivery delays and pauses. Failed matches never move the anchor.
final class VisualScrollTracker {
    enum Update: Equatable {
        case unchanged
        case matched(top: Int, movement: Int)
        case unmatched
    }

    private var anchor: FrameMatcher.FrameSignature
    private var anchorSamples: Samples
    private(set) var top = 0

    init(first: FrameMatcher.FrameSignature) {
        anchor = first
        anchorSamples = Samples(first.precise)
    }

    func observe(_ next: FrameMatcher.FrameSignature) -> Update {
        guard anchor.originalHeight == next.originalHeight,
              anchor.precise.width == next.precise.width else { return .unmatched }
        if FrameMatcher.averageDifference(anchor, next) < 0.20 { return .unchanged }
        let nextSamples = Samples(next.precise)
        guard let movement = Self.translation(previous: anchor.precise, next: next.precise,
                                               a: anchorSamples, b: nextSamples),
              top + movement >= 0 else { return .unmatched }
        if movement == 0 { return .unchanged }
        top += movement
        anchor = next
        anchorSamples = nextSamples
        return .matched(top: top, movement: movement)
    }

    /// Horizontal samples retain EVERY source row. Prefix sums make the NCC
    /// normalization O(1) for each displacement; Accelerate computes the dot product
    /// in optimized native code even when this application is built with Swift -Onone.
    private struct Samples {
        let width: Int
        let pixels: [Float]
        let sums: [Double]
        let squares: [Double]

        init(_ frame: FrameMatcher.GrayFrame) {
            let inset = max(1, frame.width / 12)
            let columns = Array(stride(from: inset, to: frame.width - inset, by: 4))
            width = columns.count
            var values = [Float]()
            values.reserveCapacity(width * frame.height)
            var rowSums = [Double](repeating: 0, count: frame.height + 1)
            var rowSquares = rowSums
            for row in 0..<frame.height {
                var sum = 0.0, square = 0.0
                for x in columns {
                    let value = Double(frame.pixels[row * frame.width + x])
                    values.append(Float(value))
                    sum += value
                    square += value * value
                }
                rowSums[row + 1] = rowSums[row] + sum
                rowSquares[row + 1] = rowSquares[row] + square
            }
            pixels = values
            sums = rowSums
            squares = rowSquares
        }
    }

    static func translation(previous a: FrameMatcher.GrayFrame,
                            next b: FrameMatcher.GrayFrame) -> Int? {
        guard a.width == b.width, a.height == b.height, a.height >= 32 else { return nil }
        return translation(previous: a, next: b, a: Samples(a), b: Samples(b))
    }

    private static func translation(previous a: FrameMatcher.GrayFrame,
                                    next b: FrameMatcher.GrayFrame,
                                    a samplesA: Samples, b samplesB: Samples) -> Int? {
        let limit = Int(Double(a.height) * 0.82)
        let inset = max(2, a.height / 12)
        var scores: [(shift: Int, score: Double)] = []
        scores.reserveCapacity(limit * 2 + 1)
        samplesA.pixels.withUnsafeBufferPointer { aBuffer in
            samplesB.pixels.withUnsafeBufferPointer { bBuffer in
                guard let ap = aBuffer.baseAddress, let bp = bBuffer.baseAddress else { return }
                for shift in -limit...limit {
                    // Exclude fixed header/footer bands in BOTH viewports.
                    let aStart = inset + max(0, shift)
                    let bStart = inset + max(0, -shift)
                    let rows = a.height - 2 * inset - abs(shift)
                    guard rows >= max(24, a.height / 20) else { continue }
                    let count = rows * samplesA.width
                    let n = Double(count)
                    let sa = samplesA.sums[aStart + rows] - samplesA.sums[aStart]
                    let sb = samplesB.sums[bStart + rows] - samplesB.sums[bStart]
                    let saa = samplesA.squares[aStart + rows] - samplesA.squares[aStart]
                    let sbb = samplesB.squares[bStart + rows] - samplesB.squares[bStart]
                    let va = n * saa - sa * sa, vb = n * sbb - sb * sb
                    guard n >= 32, va > n * n * 16, vb > n * n * 16 else { continue }
                    var dot: Float = 0
                    vDSP_dotpr(ap + aStart * samplesA.width, 1,
                                bp + bStart * samplesB.width, 1, &dot, vDSP_Length(count))
                    let score = max(0, 1 - (n * Double(dot) - sa * sb) / sqrt(va * vb)) * 100
                    scores.append((shift, score))
                }
            }
        }
        guard let best = scores.min(by: { $0.score < $1.score }), best.score < 4 else { return nil }
        // Separate repeating rows/cards are ambiguous even when one match is exact.
        let alternative = scores.filter { abs($0.shift - best.shift) > 3 }
            .map(\.score).min() ?? 100
        guard alternative - best.score >= 1.0 else { return nil }
        // Verify all rows at a second set of columns, not only search samples.
        let aStart = max(0, best.shift), bStart = max(0, -best.shift)
        let lower = max(0, inset - min(aStart, bStart))
        let upper = a.height - inset - max(aStart, bStart)
        var error = 0.0, count = 0
        for row in max(1, lower)..<upper {
            for x in stride(from: max(1, a.width / 12) + 1,
                            to: a.width - max(1, a.width / 12), by: 5) {
                let ai = (aStart + row) * a.width + x
                let bi = (bStart + row) * b.width + x
                let ga = Int(a.pixels[ai]) - Int(a.pixels[ai - a.width])
                let gb = Int(b.pixels[bi]) - Int(b.pixels[bi - b.width])
                error += Double(abs(ga - gb)); count += 1
            }
        }
        guard count > 0, error / Double(count) < 8 else { return nil }
        return best.shift
    }
}

final class LongCaptureService {
    var onPreview: ((CGImage, Int) -> Void)?
    var onPreviewSegment: ((LongCapturePreviewSegment, Int) -> Void)?
    var onStatus: ((String, Bool) -> Void)?

    private struct CapturedFrame {
        let image: CGImage
        let sequence: Int
        let captureTime: TimeInterval
    }

    private let snapshot: ScreenSnapshot
    private let selection: CGRect
    private let excludedWindowIDs: Set<CGWindowID>

    private let processingQueue = DispatchQueue(
        label: "longscreenshot.visual-processing",
        qos: .userInitiated
    )
    private let ingressLock = NSLock()
    private var ingressFrames: [CapturedFrame] = []
    private var ingressDrainScheduled = false
    private var ingressBytes = 0
    private var ingressOverloaded = false
    private let ingressByteLimit = 192 * 1024 * 1024

    private let stateLock = NSLock()
    private var acceptsFrames = false
    private var cancelled = false
    private var finishing = false

    private var captureStream: ScrollCaptureStream?

    // 以下状态只在 processingQueue 读写。
    private var canvasAccumulator: LongCaptureCanvasAccumulator?
    private var previewStore: LongCapturePreviewSegmentStore?
    private var visualTracker: VisualScrollTracker?
    private var overlapLost = false
    private var acceptedFrameCount = 0
    private var lastCommittedSequence = 0
    private var lastObservedSequence = 0
    private var rejectedValidationCount = 0
    private var maximumObservedProcessingAgeMS: Double = 0
    private var lastPreviewFrameCount = 0
    private var previewSerialCounter = 0
    private let maximumOutputHeight = 180_000
    private var completion: ((Result<CGImage, Error>) -> Void)?

    init(snapshot: ScreenSnapshot, selection: CGRect, excludedWindowIDs: [CGWindowID]) {
        self.snapshot = snapshot
        self.selection = selection
        self.excludedWindowIDs = Set(excludedWindowIDs)
    }

    convenience init(snapshot: ScreenSnapshot, selection: CGRect, overlayWindowID: CGWindowID) {
        self.init(snapshot: snapshot, selection: selection, excludedWindowIDs: [overlayWindowID])
    }

    deinit {
        stopCaptureResources(clearCallbacks: true)
    }

    func start() {
        guard let rawFallback = snapshot.crop(viewRect: selection) else {
            dispatchStatus("无法读取首屏截图", isError: true)
            return
        }
        let geometry = captureGeometry(referencePixelSize: CGSize(
            width: rawFallback.width,
            height: rawFallback.height
        ))
        let fallback = FrameStitcher.resizedCopy(
            rawFallback,
            width: Int(geometry.pixelSize.width),
            height: Int(geometry.pixelSize.height)
        ) ?? rawFallback


        stateLock.lock()
        acceptsFrames = true
        cancelled = false
        finishing = false
        stateLock.unlock()

        ingressLock.lock()
        ingressOverloaded = false
        ingressBytes = 0
        ingressFrames.removeAll()
        ingressLock.unlock()
        processingQueue.sync {
            self.overlapLost = false
            self.resetProcessingState(with: fallback)
        }

        LongCaptureDiagnostics.shared.beginSession(
            "visual selection=\(LCFormatRect(selection)) display=\(snapshot.displayID)"
        )
        LongCaptureDiagnostics.shared.log(
            "visual.start selection=\(LCFormatRect(selection)) fallback=\(fallback.width)x\(fallback.height) sourceRect=\(LCFormatRect(geometry.sourceRect)) pixelSize=\(LCFormatSize(geometry.pixelSize)) excludedWindowIDs=\(Array(excludedWindowIDs).sorted())"
        )

        let stream = ScrollCaptureStream(
            displayID: snapshot.displayID,
            sourceRect: geometry.sourceRect,
            pixelSize: geometry.pixelSize,
            excludedWindowIDs: excludedWindowIDs
        )
        stream.onFrame = { [weak self] image, sequence, captureTime in
            self?.receiveStreamFrame(image, sequence: sequence, captureTime: captureTime)
        }
        stream.onError = { [weak self] error in
            self?.dispatchStatus("连续采集失败：\(error.localizedDescription)", isError: true)
        }
        captureStream = stream
        stream.start()
    }

    func finish(completion: @escaping (Result<CGImage, Error>) -> Void) {
        stateLock.lock()
        guard !finishing, !cancelled else {
            stateLock.unlock()
            return
        }
        finishing = true
        acceptsFrames = false
        self.completion = completion
        stateLock.unlock()

        captureStream?.stop()
        captureStream = nil
        dispatchStatus("正在生成长图…", isError: false)

        processingQueue.async { [weak self] in
            guard let self else { return }
            self.drainIngressFramesOnProcessingQueue()
            guard !self.cancelled else { return }
            self.ingressLock.lock()
            let overloaded = self.ingressOverloaded
            self.ingressLock.unlock()
            guard !overloaded else {
                self.finishOnMain(.failure(LongCaptureError.processingOverloaded))
                return
            }
            guard !self.overlapLost else {
                self.finishOnMain(.failure(LongCaptureError.overlapLost))
                return
            }
            guard let snapshot = self.canvasAccumulator?.snapshot(),
                  let image = snapshot.makeImage() else {
                self.finishOnMain(.failure(LongCaptureError.captureFailed))
                return
            }
            LongCaptureDiagnostics.shared.log(
                "visual.finish acceptedFrames=\(self.acceptedFrameCount) height=\(snapshot.height) lastCommittedSeq=\(self.lastCommittedSequence) lastObservedSeq=\(self.lastObservedSequence) rejectedValidation=\(self.rejectedValidationCount) maxAgeMS=\(String(format: "%.1f", self.maximumObservedProcessingAgeMS))"
            )
            self.finishOnMain(.success(image))
        }
    }

    func cancel() {
        stateLock.lock()
        cancelled = true
        finishing = false
        acceptsFrames = false
        completion = nil
        stateLock.unlock()
        LongCaptureDiagnostics.shared.log("visual.cancel")
        stopCaptureResources(clearCallbacks: true)
        LongCaptureDiagnostics.shared.endSession("visual cancelled")
    }

    private func resetProcessingState(with fallback: CGImage) {
        canvasAccumulator = LongCaptureCanvasAccumulator(
            firstFrame: fallback,
            maximumHeight: maximumOutputHeight
        )
        previewStore = LongCapturePreviewSegmentStore(
            firstFrame: fallback,
            targetWidth: previewMaximumWidth
        )
        visualTracker = FrameMatcher.signature(fallback).map { VisualScrollTracker(first: $0) }
        acceptedFrameCount = 1
        lastCommittedSequence = 0
        lastObservedSequence = 0
        rejectedValidationCount = 0
        maximumObservedProcessingAgeMS = 0
        lastPreviewFrameCount = 0
        previewSerialCounter = 0
        publishPendingPreviewSegments(reason: "fallback")
    }

    private var previewMaximumWidth: Int {
        max(120, min(220, Int(selection.width * 0.22)))
    }

    private func captureGeometry(referencePixelSize: CGSize) -> (sourceRect: CGRect, pixelSize: CGSize) {
        let scaleX = max(1, referencePixelSize.width / max(1, selection.width))
        let scaleY = max(1, referencePixelSize.height / max(1, selection.height))
        let rawSourceRect = CGRect(
            x: selection.minX,
            y: snapshot.pointSize.height - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        let pixelRect = CGRect(
            x: rawSourceRect.minX * scaleX,
            y: rawSourceRect.minY * scaleY,
            width: rawSourceRect.width * scaleX,
            height: rawSourceRect.height * scaleY
        ).integral
        return (
            CGRect(
                x: pixelRect.minX / scaleX,
                y: pixelRect.minY / scaleY,
                width: pixelRect.width / scaleX,
                height: pixelRect.height / scaleY
            ),
            CGSize(width: max(2, pixelRect.width), height: max(2, pixelRect.height))
        )
    }

    private func receiveStreamFrame(_ image: CGImage, sequence: Int, captureTime: TimeInterval) {
        stateLock.lock()
        let canAccept = acceptsFrames && !cancelled
        guard canAccept else { stateLock.unlock(); return }

        var scheduleDrain = false
        ingressLock.lock()
        let frame = CapturedFrame(
            image: image,
            sequence: sequence,
            captureTime: captureTime
        )

        // Wheel coordinates are not rendered positions. Preserve every intermediate
        // frame, including animation frames after the last wheel event.
        let bytes = image.bytesPerRow * image.height
        guard !ingressOverloaded, ingressBytes + bytes <= ingressByteLimit else {
            LongCaptureDiagnostics.shared.log("visual.ingress.overloaded seq=\(sequence) queuedFrames=\(ingressFrames.count) queuedBytes=\(ingressBytes) frameBytes=\(bytes) limit=\(ingressByteLimit)")
            ingressOverloaded = true
            ingressLock.unlock()
            acceptsFrames = false
            stateLock.unlock()
            DispatchQueue.main.async { [weak self] in
                self?.captureStream?.stop()
                self?.captureStream = nil
            }
            dispatchStatus("处理积压，已停止采集以避免丢帧。请缩小选区重试。", isError: true)
            return
        }
        ingressFrames.append(frame)
        ingressBytes += bytes
        if !ingressDrainScheduled {
            ingressDrainScheduled = true
            scheduleDrain = true
        }
        ingressLock.unlock()
        stateLock.unlock()

        if scheduleDrain {
            processingQueue.async { [weak self] in
                self?.drainIngressFramesOnProcessingQueue()
            }
        }
    }

    private func drainIngressFramesOnProcessingQueue() {
        while true {
            let frame: CapturedFrame?
            ingressLock.lock()
            if ingressFrames.isEmpty {
                ingressDrainScheduled = false
                frame = nil
            } else {
                frame = ingressFrames.removeFirst()
                if let frame { ingressBytes -= frame.image.bytesPerRow * frame.image.height }
            }
            ingressLock.unlock()
            guard let frame else { break }
            let began = ProcessInfo.processInfo.systemUptime
            process(frame)
            let elapsedMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
            if frame.sequence <= 5 || frame.sequence % 60 == 0 || elapsedMS > 33 {
                ingressLock.lock()
                let queued = ingressFrames.count
                let bytes = ingressBytes
                ingressLock.unlock()
                LongCaptureDiagnostics.shared.log("visual.process seq=\(frame.sequence) durationMS=\(String(format: "%.2f", elapsedMS)) queuedFrames=\(queued) queuedMiB=\(String(format: "%.1f", Double(bytes) / 1048576))")
            }
        }
    }

    private func process(_ frame: CapturedFrame) {
        stateLock.lock()
        let isCancelled = cancelled
        stateLock.unlock()
        guard !isCancelled else { return }

        let ageMS = max(0, ProcessInfo.processInfo.systemUptime - frame.captureTime) * 1000
        maximumObservedProcessingAgeMS = max(maximumObservedProcessingAgeMS, ageMS)
        lastObservedSequence = frame.sequence

        guard let signature = FrameMatcher.signature(frame.image) else {
            overlapLost = true
            LongCaptureDiagnostics.shared.log("visual.frame.signatureFailed seq=\(frame.sequence)")
            return
        }

        guard let tracker = visualTracker,
              let accumulator = canvasAccumulator else { return }
        switch tracker.observe(signature) {
        case .unchanged:
            overlapLost = false
            // A pause is not proof of the document bottom. Keep accepting frames.
            return
        case .unmatched:
            overlapLost = true
            rejectedValidationCount += 1
            dispatchStatus("重叠不足或内容不明确，请向上滚回已采集位置后继续", isError: false)
            return
        case let .matched(top, movement):
            overlapLost = false
            guard top + frame.image.height > accumulator.contentHeight else { return }
            let placeResult = accumulator.place(
                frame.image, topOffset: top, minimumStep: 1,
                signature: signature, visuallyVerified: true
            )
            switch placeResult {
            case let .placed(sourceStart, sourceHeight):
                acceptedFrameCount = accumulator.frameCount
                lastCommittedSequence = frame.sequence
                previewStore?.place(frame.image, topOffset: top,
                                    sourceStart: sourceStart, sourceHeight: sourceHeight)
                publishPendingPreviewSegments(reason: "visual-placement")
                LongCaptureDiagnostics.shared.log(
                    "visual.place seq=\(frame.sequence) top=\(top) movement=\(movement) height=\(accumulator.contentHeight) ageMS=\(String(format: "%.1f", ageMS))"
                )
                dispatchStatus("已采集 \(acceptedFrameCount) 段", isError: false)
            case .rejected:
                dispatchStatus("已达到长图尺寸上限，请完成当前截图", isError: false)
            case .skippedDuplicate, .skippedTooClose:
                break
            }
        }
    }

    private func publishPendingPreviewSegments(reason: String) {
        guard let previewStore else { return }
        let rawSegments = previewStore.drainPendingSegments()
        guard !rawSegments.isEmpty else { return }
        let count = acceptedFrameCount
        lastPreviewFrameCount = count
        let segments = rawSegments.map { segment -> LongCapturePreviewSegment in
            previewSerialCounter += 1
            return LongCapturePreviewSegment(
                image: segment.image,
                serial: previewSerialCounter,
                previewTop: segment.previewTop,
                previewHeight: segment.previewHeight,
                previewWidth: segment.previewWidth,
                previewContentHeight: segment.previewContentHeight
            )
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for segment in segments {
                self.onPreviewSegment?(segment, count)
            }
        }
        LongCaptureDiagnostics.shared.log(
            "visual.preview.publish reason=\(reason) segments=\(segments.count) count=\(count) previewHeight=\(previewStore.previewContentHeight)"
        )
    }

    private func dispatchStatus(_ text: String, isError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.ingressLock.lock()
            let overloaded = self.ingressOverloaded
            self.ingressLock.unlock()
            self.onStatus?(overloaded ? "处理积压，已停止采集以避免丢帧。请缩小选区重试。" : text,
                           overloaded || isError)
        }
    }

    private func finishOnMain(_ result: Result<CGImage, Error>) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            LongCaptureDiagnostics.shared.endSession(
                "visual finished result=\(result.isSuccess ? "success" : "failure")"
            )
            let callback = self.completion
            self.completion = nil
            callback?(result)
            self.stopCaptureResources(clearCallbacks: false)
        }
    }

    private func stopCaptureResources(clearCallbacks: Bool) {
        stateLock.lock()
        acceptsFrames = false
        stateLock.unlock()
        captureStream?.onFrame = nil
        captureStream?.onError = nil
        captureStream?.stop()
        captureStream = nil
        ingressLock.lock()
        ingressFrames.removeAll(keepingCapacity: false)
        ingressBytes = 0
        ingressDrainScheduled = false
        ingressLock.unlock()
        if clearCallbacks {
            onPreview = nil
            onPreviewSegment = nil
            onStatus = nil
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

enum FrameMatcher {
    struct Alignment {
        let nextContentStart: Int
        let overlap: Int
        /// score = (1 - NCC) * 100，越低越好。
        let score: Double
        /// 第二候选和第一候选的分差。ScreenSnap 的 NCC 日志里也会记录 margin；
        /// 重复内容页面上 margin 过低时，即使 score 看起来不错也要更谨慎。
        let margin: Double

        init(nextContentStart: Int, overlap: Int, score: Double, margin: Double = 0) {
            self.nextContentStart = nextContentStart
            self.overlap = overlap
            self.score = score
            self.margin = margin
        }
    }

    struct GrayFrame {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    struct FrameSignature {
        let coarse: GrayFrame
        let precise: GrayFrame
        let originalHeight: Int
    }

    static func signature(_ image: CGImage) -> FrameSignature? {
        // Keep enough vertical rows for very wide selections. A fixed 160px width can
        // collapse a panoramic viewport to only a few dozen rows, making repeated text
        // lines ambiguous. The cap keeps work bounded and independent of source width.
        // v23：为 60fps 连续桥接降低签名成本。垂直方向仍保留每一行，
        // 只减少横向采样宽度，不牺牲纵向位移精度。
        let aspectAwareWidth = min(
            224,
            max(128, Int(ceil(CGFloat(image.width) / CGFloat(max(1, image.height)) * 145)))
        )
        // CGContext grayscale drawing converts/resamples the large source twice;
        // on a Retina capture this dominated Debug processing time. Convert once
        // with vImage, then derive both signatures using native vector kernels.
        let space = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
            colorSpace: Unmanaged.passUnretained(space),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            version: 0, decode: nil, renderingIntent: .defaultIntent)
        var rgba = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&rgba, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(rgba.data) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        let matrix: [Int16] = [29, 150, 77, 0] // BGRA -> luminance; alpha is ignored.
        return pixels.withUnsafeMutableBytes { bytes in
            var planar = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(image.height),
                                       width: vImagePixelCount(image.width), rowBytes: image.width)
            guard vImageMatrixMultiply_ARGB8888ToPlanar8(&rgba, &planar, matrix, 256, nil, 0,
                                                        vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
            let coarseWidth = min(aspectAwareWidth, image.width)
            let coarseHeight = max(1, image.height * coarseWidth / image.width)
            guard let coarse = scaledGray(&planar, width: coarseWidth, height: coarseHeight),
                  let precise = scaledGray(&planar, width: min(72, image.width), height: image.height) else { return nil }
            return FrameSignature(coarse: coarse, precise: precise, originalHeight: image.height)
        }
    }

    private static func scaledGray(_ source: inout vImage_Buffer, width: Int, height: Int) -> GrayFrame? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let status = pixels.withUnsafeMutableBytes { bytes -> vImage_Error in
            var output = vImage_Buffer(data: bytes.baseAddress, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: width)
            return vImageScale_Planar8(&source, &output, nil, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else { return nil }
        return GrayFrame(width: width, height: height, pixels: pixels)
    }

    static func gray(_ image: CGImage, targetWidth: Int = 160) -> GrayFrame? {
        let width = min(targetWidth, image.width)
        let height = max(1, Int(CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayFrame(width: width, height: height, pixels: pixels)
    }

    /// Horizontal downsampling keeps matching inexpensive, while retaining every
    /// source row gives exact vertical displacement instead of quantizing movement to
    /// several source pixels per gray row.
    static func verticallyPreciseGray(_ image: CGImage, targetWidth: Int = 72) -> GrayFrame? {
        let width = min(targetWidth, image.width)
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayFrame(width: width, height: height, pixels: pixels)
    }

    static func averageDifference(_ a: CGImage, _ b: CGImage) -> Double {
        guard let ga = gray(a, targetWidth: 96),
              let gb = gray(b, targetWidth: 96),
              ga.width == gb.width,
              ga.height == gb.height else { return 255 }
        return averageDifference(ga, gb)
    }

    static func averageDifference(_ a: FrameSignature, _ b: FrameSignature) -> Double {
        averageDifference(a.coarse, b.coarse)
    }

    private static func averageDifference(_ ga: GrayFrame, _ gb: GrayFrame) -> Double {
        guard ga.width == gb.width, ga.height == gb.height else { return 255 }
        var total = 0
        var count = 0
        for index in stride(from: 0, to: ga.pixels.count, by: 5) {
            total += abs(Int(ga.pixels[index]) - Int(gb.pixels[index]))
            count += 1
        }
        return count == 0 ? 255 : Double(total) / Double(count)
    }

    /// Finds a visually quiet row immediately before a nominal append boundary.
    /// Returning a backward distance lets the caller replace the old canvas tail with
    /// pixels from the new frame, avoiding seams through text, icons, and thin rules.
    static func safeSeamBacktrack(
        in image: CGImage,
        sourceStart: Int,
        maximumBacktrack: Int
    ) -> Int {
        guard sourceStart > 0, maximumBacktrack > 0,
              let frame = gray(image, targetWidth: 240), frame.height > 4 else { return 0 }
        return safeSeamBacktrack(
            frame: frame,
            originalHeight: image.height,
            sourceStart: sourceStart,
            maximumBacktrack: maximumBacktrack
        )
    }

    static func safeSeamBacktrack(
        in signature: FrameSignature,
        sourceStart: Int,
        maximumBacktrack: Int
    ) -> Int {
        safeSeamBacktrack(
            frame: signature.precise,
            originalHeight: signature.originalHeight,
            sourceStart: sourceStart,
            maximumBacktrack: maximumBacktrack
        )
    }

    private static func safeSeamBacktrack(
        frame: GrayFrame,
        originalHeight: Int,
        sourceStart: Int,
        maximumBacktrack: Int
    ) -> Int {
        guard sourceStart > 0, maximumBacktrack > 0, frame.height > 4 else { return 0 }

        let scale = CGFloat(frame.height) / CGFloat(originalHeight)
        let nominalRow = min(frame.height - 2, max(1, Int(round(CGFloat(sourceStart) * scale))))
        let searchRows = max(1, Int(ceil(CGFloat(maximumBacktrack) * scale)))
        let lower = max(1, nominalRow - searchRows)
        let xStart = max(1, frame.width / 20)
        let xEnd = min(frame.width - 1, frame.width - frame.width / 20)
        guard lower < nominalRow, xStart < xEnd else { return 0 }

        var bestRow = nominalRow
        var bestScore = Double.greatestFiniteMagnitude
        for row in lower...nominalRow {
            var energy = 0.0
            var samples = 0
            // Score a three-row band. Horizontal energy catches glyph strokes; vertical
            // energy catches their top/bottom edges. Blank page rows and flat image areas
            // therefore win naturally in both light and dark content.
            for bandRow in max(1, row - 1)...min(frame.height - 2, row + 1) {
                let base = bandRow * frame.width
                let above = (bandRow - 1) * frame.width
                let below = (bandRow + 1) * frame.width
                for x in stride(from: xStart, to: xEnd, by: 3) {
                    let center = Int(frame.pixels[base + x])
                    energy += Double(abs(center - Int(frame.pixels[base + x - 1])))
                    energy += Double(abs(Int(frame.pixels[below + x]) - Int(frame.pixels[above + x]))) * 0.7
                    samples += 1
                }
            }
            guard samples > 0 else { continue }
            let distance = nominalRow - row
            // A small distance cost keeps the seam close unless an earlier row is
            // materially quieter.
            let score = energy / Double(samples) + Double(distance) * 0.08
            if score < bestScore {
                bestScore = score
                bestRow = row
            }
        }

        let grayDistance = max(0, nominalRow - bestRow)
        let sourceDistance = Int(round(CGFloat(grayDistance) / scale))
        return min(maximumBacktrack, max(0, sourceDistance))
    }

    /// 对触控板到达页面底部后的橡皮筋位移做平移不变比较。
    /// score 是重叠区域平均灰度差，越低越像同一 viewport；shift 为灰度图行位移
    /// 映射回原始像素后的值。
    static func elasticShiftDifference(
        previous: FrameSignature,
        next: FrameSignature,
        maximumShiftRatio: CGFloat = 0.12
    ) -> (score: Double, shift: Int) {
        let a = previous.coarse
        let b = next.coarse
        guard a.width == b.width, a.height == b.height, a.height > 8 else { return (255, 0) }

        let maxShift = max(2, min(a.height / 3, Int(CGFloat(a.height) * maximumShiftRatio)))
        let xStart = max(1, a.width / 12)
        let xEnd = min(a.width - 1, a.width - a.width / 12)
        var bestScore = Double.greatestFiniteMagnitude
        var bestShift = 0

        for shift in (-maxShift)...maxShift {
            let aStart = max(0, shift)
            let bStart = max(0, -shift)
            let rowCount = a.height - abs(shift)
            guard rowCount >= Int(CGFloat(a.height) * 0.72) else { continue }

            var total = 0
            var count = 0
            // 忽略最外侧，避免滚动条、阴影和橡皮筋空白边缘影响判断。
            let rowInset = max(1, rowCount / 20)
            if rowInset * 2 >= rowCount { continue }
            for row in stride(from: rowInset, to: rowCount - rowInset, by: 2) {
                let aBase = (aStart + row) * a.width
                let bBase = (bStart + row) * b.width
                for x in stride(from: xStart, to: xEnd, by: 3) {
                    total += abs(Int(a.pixels[aBase + x]) - Int(b.pixels[bBase + x]))
                    count += 1
                }
            }
            guard count > 0 else { continue }
            let score = Double(total) / Double(count)
            if score < bestScore {
                bestScore = score
                bestShift = shift
            }
        }

        let sourceShift = Int(round(
            CGFloat(bestShift) * CGFloat(previous.originalHeight) / CGFloat(max(1, a.height))
        ))
        return (bestScore, sourceShift)
    }

    static func smallShiftDifference(previous: CGImage, next: CGImage) -> (score: Double, shift: Int) {
        guard let a = gray(previous, targetWidth: 96),
              let b = gray(next, targetWidth: 96),
              a.width == b.width,
              a.height == b.height else {
            return (255, 0)
        }
        return smallShiftDifference(
            previous: a,
            next: b,
            originalHeight: previous.height
        )
    }

    static func smallShiftDifference(
        previous: FrameSignature,
        next: FrameSignature
    ) -> (score: Double, shift: Int) {
        smallShiftDifference(
            previous: previous.coarse,
            next: next.coarse,
            originalHeight: previous.originalHeight
        )
    }

    private static func smallShiftDifference(
        previous a: GrayFrame,
        next b: GrayFrame,
        originalHeight: Int
    ) -> (score: Double, shift: Int) {
        guard a.width == b.width, a.height == b.height else { return (255, 0) }
        let maxShift = max(2, Int(CGFloat(a.height) * 0.035))
        let xStart = a.width / 10
        let xEnd = a.width - xStart
        var bestScore = Double.greatestFiniteMagnitude
        var bestShift = 0
        for shift in (-maxShift)...maxShift {
            let aStart = max(0, shift)
            let bStart = max(0, -shift)
            let rowCount = a.height - abs(shift)
            guard rowCount > 0 else { continue }
            var differences: [Int] = []
            for row in stride(from: 0, to: rowCount, by: 3) {
                for x in stride(from: xStart, to: xEnd, by: 4) {
                    let av = Int(a.pixels[(aStart + row) * a.width + x])
                    let bv = Int(b.pixels[(bStart + row) * b.width + x])
                    differences.append(abs(av - bv))
                }
            }
            differences.sort()
            let keep = max(1, Int(CGFloat(differences.count) * 0.70))
            let score = differences.isEmpty
                ? 255
                : Double(differences.prefix(keep).reduce(0, +)) / Double(keep)
            if score < bestScore {
                bestScore = score
                bestShift = shift
            }
        }
        let scaledShift = Int(CGFloat(bestShift) / CGFloat(a.height) * CGFloat(originalHeight))
        return (bestScore, scaledShift)
    }

    static func overlap(previous: CGImage, next: CGImage) -> Int {
        let result = alignment(previous: previous, next: next)
        return result.nextContentStart + result.overlap
    }

    static func isReliable(
        _ alignment: Alignment,
        expectedNewContent: Int,
        frameHeight: Int
    ) -> Bool {
        let newContent = frameHeight - alignment.nextContentStart - alignment.overlap
        let minimumOverlap = Int(CGFloat(frameHeight) * 0.30)
        guard alignment.overlap >= minimumOverlap else { return false }
        let gestureTolerance = max(
            Int(CGFloat(frameHeight) * 0.10),
            Int(CGFloat(expectedNewContent) * 0.55)
        )
        let followsMeasuredScroll = abs(newContent - expectedNewContent) <= gestureTolerance
        // score = (1 - NCC) * 100，因此 38 对应 NCC 0.62。
        return alignment.score <= 38 && followsMeasuredScroll
    }

    static func isRecoveryReliable(
        _ alignment: Alignment,
        expectedNewContent: Int,
        frameHeight: Int
    ) -> Bool {
        let newContent = frameHeight - alignment.nextContentStart - alignment.overlap
        let tolerance = max(
            Int(CGFloat(frameHeight) * 0.08),
            Int(CGFloat(expectedNewContent) * 0.35)
        )
        return alignment.score <= 32
            && alignment.overlap >= Int(CGFloat(frameHeight) * 0.30)
            && abs(newContent - expectedNewContent) <= tolerance
    }

    static func resilientAlignment(
        previous: CGImage,
        next: CGImage,
        expectedNewContent: Int
    ) -> Alignment {
        guard let previousSignature = signature(previous),
              let nextSignature = signature(next) else {
            return Alignment(
                nextContentStart: 0,
                overlap: Int(CGFloat(previous.height) * 0.70),
                score: 255
            )
        }
        return resilientAlignment(
            previous: previousSignature,
            next: nextSignature,
            expectedNewContent: expectedNewContent
        )
    }

    static func resilientAlignment(
        previous: FrameSignature,
        next: FrameSignature,
        expectedNewContent: Int
    ) -> Alignment {
        let guided = alignment(
            previous: previous,
            next: next,
            expectedNewContent: expectedNewContent
        )
        let frameHeight = next.originalHeight
        let guidedMovement = frameHeight - guided.nextContentStart - guided.overlap
        let tolerance = max(
            Int(CGFloat(frameHeight) * 0.12),
            Int(CGFloat(expectedNewContent) * 0.55)
        )
        if guided.score <= 38,
           abs(guidedMovement - expectedNewContent) <= tolerance {
            return guided
        }

        let unrestricted = alignment(previous: previous, next: next)
        let unrestrictedMovement = frameHeight
            - unrestricted.nextContentStart
            - unrestricted.overlap
        let agreesWithGesture = abs(unrestrictedMovement - expectedNewContent) <= tolerance
        if unrestricted.score + 4.0 < guided.score, agreesWithGesture {
            return unrestricted
        }
        return guided
    }


    @available(macOS 10.13, *)
    private static func visionTranslation(previous: CGImage, next: CGImage) -> CGAffineTransform? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: next, options: [:])
        let handler = VNImageRequestHandler(cgImage: previous, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
            return nil
        }
        return observation.alignmentTransform
    }

    static func visionAlignment(
        previousImage: CGImage,
        nextImage: CGImage,
        previousSignature: FrameSignature,
        nextSignature: FrameSignature,
        expectedNewContent: Int?
    ) -> Alignment? {
        guard #available(macOS 10.13, *) else { return nil }
        guard previousImage.width == nextImage.width,
              previousImage.height == nextImage.height else { return nil }
        guard let transform = visionTranslation(previous: previousImage, next: nextImage) else { return nil }

        // ScreenSnap 对横向漂移非常保守：abs(tx) > 24 直接进入 NCC 兜底。
        guard abs(transform.tx) <= 24.0 else { return nil }

        let frameHeight = nextImage.height
        let rawCandidates = [
            Int(round(transform.ty)),
            Int(round(-transform.ty))
        ]
        var best: (movement: Int, score: Double, expectedPenalty: Double)?
        for movement in rawCandidates {
            guard movement >= 1,
                  movement <= Int(CGFloat(frameHeight) * 0.82) else { continue }
            let score = nccScoreForMovement(
                previous: previousSignature,
                next: nextSignature,
                movement: movement
            )
            let expectedPenalty = expectedNewContent.map { Double(abs(movement - $0)) } ?? 0
            if let current = best {
                if score + expectedPenalty * 0.018 < current.score + current.expectedPenalty * 0.018 {
                    best = (movement, score, expectedPenalty)
                }
            } else {
                best = (movement, score, expectedPenalty)
            }
        }
        guard let best else { return nil }

        // Vision 给的是强先验，但仍用 NCC 粗验一次，避免低纹理尾部把方向选错。
        let tolerance = expectedNewContent.map {
            max(Int(CGFloat(frameHeight) * 0.22), Int(CGFloat($0) * 0.90))
        } ?? Int(CGFloat(frameHeight) * 0.38)
        if let expectedNewContent, abs(best.movement - expectedNewContent) > tolerance, best.score > 38.0 {
            return nil
        }
        guard best.score <= 48.0 else { return nil }

        return Alignment(
            nextContentStart: 0,
            overlap: max(1, frameHeight - best.movement),
            // 保留 NCC score，可靠性仍由 screenSnapReliable 判定。
            score: best.score,
            // Vision 成功时候选唯一性通常比纯 NCC 好，这里给一个较高 margin，
            // 但不把 score 伪装得过低，避免弱尾帧无条件落画布。
            margin: 32.0
        )
    }

    private static func nccScoreForMovement(
        previous: FrameSignature,
        next: FrameSignature,
        movement: Int
    ) -> Double {
        let a = previous.coarse
        let b = next.coarse
        guard a.width == b.width, a.height == b.height else { return 255 }
        let h = min(a.height, b.height)
        let displacement = min(
            max(1, Int(round(CGFloat(movement) / CGFloat(max(1, previous.originalHeight)) * CGFloat(h)))),
            max(1, h - 1)
        )
        return weightedOverlapScore(previous: a, next: b, displacement: displacement)
    }

    static func alignment(previous: CGImage, next: CGImage, expectedNewContent: Int? = nil) -> Alignment {
        guard let previousSignature = signature(previous),
              let nextSignature = signature(next) else {
            return Alignment(nextContentStart: 0, overlap: Int(CGFloat(previous.height) * 0.70), score: 255)
        }
        return alignment(
            previous: previousSignature,
            next: nextSignature,
            expectedNewContent: expectedNewContent
        )
    }

    static func alignment(
        previous: FrameSignature,
        next: FrameSignature,
        expectedNewContent: Int? = nil
    ) -> Alignment {
        if let shift = VisualScrollTracker.translation(previous: previous.precise, next: next.precise), shift > 0 {
            return Alignment(nextContentStart: 0, overlap: previous.originalHeight - shift,
                             score: weightedOverlapScore(previous: previous.precise, next: next.precise, displacement: shift),
                             margin: 1)
        }
        let a = previous.coarse
        let b = next.coarse
        guard a.width == b.width else {
            return Alignment(
                nextContentStart: 0,
                overlap: Int(CGFloat(previous.originalHeight) * 0.70),
                score: 255
            )
        }
        let originalHeight = previous.originalHeight
        let h = min(a.height, b.height)
        let minDisplacement = 1
        let maxDisplacement = max(minDisplacement, Int(CGFloat(h) * 0.88))
        let expectedGray = expectedNewContent.flatMap { value -> Int? in
            guard value > 4 else { return nil }
            return min(maxDisplacement, max(minDisplacement,
                Int(CGFloat(value) / CGFloat(originalHeight) * CGFloat(h))))
        }

        let lower: Int
        let upper: Int
        if let expectedGray {
            let tolerance = max(Int(CGFloat(h) * 0.12), Int(CGFloat(expectedGray) * 0.55))
            lower = max(minDisplacement, expectedGray - tolerance)
            upper = min(maxDisplacement, expectedGray + tolerance)
        } else {
            lower = minDisplacement
            upper = maxDisplacement
        }

        var bestDisplacement = expectedGray ?? Int(CGFloat(h) * 0.32)
        var bestScore = Double.greatestFiniteMagnitude
        var scoreByDisplacement: [Int: Double] = [:]

        func recordScore(_ score: Double, displacement: Int) {
            if let existing = scoreByDisplacement[displacement] {
                if score < existing { scoreByDisplacement[displacement] = score }
            } else {
                scoreByDisplacement[displacement] = score
            }
            if score < bestScore {
                bestScore = score
                bestDisplacement = displacement
            }
        }

        // 先粗搜，再在最优点附近细搜。相比旧版只取几个 patch 做 NCC，
        // 这里使用整段重叠区域的“有纹理行”，GitHub 代码块/表格/图片处更不容易错配。
        for displacement in stride(from: lower, through: upper, by: 3) {
            var score = weightedOverlapScore(previous: a, next: b, displacement: displacement)
            if let expectedGray {
                score += Double(abs(displacement - expectedGray)) * 0.018
            }
            recordScore(score, displacement: displacement)
        }

        let refineLower = max(lower, bestDisplacement - 5)
        let refineUpper = min(upper, bestDisplacement + 5)
        for displacement in refineLower...refineUpper {
            var score = weightedOverlapScore(previous: a, next: b, displacement: displacement)
            if let expectedGray {
                score += Double(abs(displacement - expectedGray)) * 0.018
            }
            recordScore(score, displacement: displacement)
        }

        let marginExclusionRadius = max(3, h / 120)
        let secondBestScore = scoreByDisplacement
            .filter { abs($0.key - bestDisplacement) > marginExclusionRadius }
            .map(\.value)
            .min() ?? bestScore
        let coarseMargin = max(0, secondBestScore - bestScore)

        let preciseA = previous.precise
        let preciseB = next.precise
        let coarseScaledDisplacement = min(
            originalHeight - 1,
            max(1, Int(CGFloat(bestDisplacement) / CGFloat(h) * CGFloat(originalHeight)))
        )
        guard preciseA.width == preciseB.width,
              preciseA.height == preciseB.height else {
            return Alignment(
                nextContentStart: 0,
                overlap: originalHeight - coarseScaledDisplacement,
                score: bestScore,
                margin: coarseMargin
            )
        }

        let sourcePixelsPerCoarseRow = CGFloat(originalHeight) / CGFloat(max(1, h))
        let preciseRadius = max(6, Int(ceil(sourcePixelsPerCoarseRow * 1.6)))

        // A very wide viewport has relatively few coarse rows. Repeated text/cards can
        // therefore produce several similar NCC minima (for example 214px vs 455px).
        // Refine several separated coarse candidates at full source-row precision,
        // including the scroll-guided neighbourhood, and let pixel gradients decide.
        var coarseCandidates: [Int] = []
        let sortedCoarse = scoreByDisplacement.sorted { $0.value < $1.value }
        for item in sortedCoarse {
            if coarseCandidates.allSatisfy({ abs($0 - item.key) > marginExclusionRadius }) {
                coarseCandidates.append(item.key)
            }
            if coarseCandidates.count >= 2 { break }
        }
        if !coarseCandidates.contains(bestDisplacement) {
            coarseCandidates.insert(bestDisplacement, at: 0)
        }
        if let expectedGray,
           !coarseCandidates.contains(expectedGray) {
            coarseCandidates.append(expectedGray)
        }

        var preciseDisplacement = coarseScaledDisplacement
        var preciseCompositeScore = Double.greatestFiniteMagnitude
        var chosenCoarseDisplacement = bestDisplacement
        for coarseCandidate in coarseCandidates {
            let scaled = min(
                originalHeight - 1,
                max(1, Int(round(CGFloat(coarseCandidate) / CGFloat(h) * CGFloat(originalHeight))))
            )
            let preciseLower = max(1, scaled - preciseRadius)
            let preciseUpper = min(Int(CGFloat(originalHeight) * 0.88), scaled + preciseRadius)
            guard preciseLower <= preciseUpper else { continue }
            let coarseScore = scoreByDisplacement[coarseCandidate]
                ?? weightedOverlapScore(previous: a, next: b, displacement: coarseCandidate)
            for displacement in preciseLower...preciseUpper {
                var composite = verticalGradientScore(
                    previous: preciseA,
                    next: preciseB,
                    displacement: displacement
                )
                // Coarse appearance is a tie-breaker, not the final authority.
                composite += coarseScore * 0.04
                if let expectedNewContent {
                    // The scroll value remains a soft prior, but a candidate hundreds
                    // of pixels away must have materially better visual evidence.
                    composite += Double(abs(displacement - expectedNewContent)) * 0.02
                }
                if composite < preciseCompositeScore {
                    preciseCompositeScore = composite
                    preciseDisplacement = displacement
                    chosenCoarseDisplacement = coarseCandidate
                }
            }
        }

        let chosenCoarseScore = scoreByDisplacement[chosenCoarseDisplacement]
            ?? bestScore
        let chosenSecondBest = scoreByDisplacement
            .filter { abs($0.key - chosenCoarseDisplacement) > marginExclusionRadius }
            .map(\.value)
            .min() ?? chosenCoarseScore
        let chosenMargin = max(0, chosenSecondBest - chosenCoarseScore)
        return Alignment(
            nextContentStart: 0,
            overlap: originalHeight - preciseDisplacement,
            // The precise score has a different (gradient-error) scale. Reliability is
            // still decided by the coarse NCC; the precise pass only removes vertical
            // quantization from the selected displacement.
            score: weightedOverlapScore(previous: preciseA, next: preciseB, displacement: preciseDisplacement),
            margin: chosenMargin
        )
    }


    struct ExpectedMovementValidation {
        let bestMovement: Int
        let score: Double
        let gradientScore: Double
        let margin: Double
    }

    /// 只在滚动坐标预测值附近做小范围验证，不进行全屏位移搜索。
    /// 这样相似的多张大图即使在别处有更低 NCC，也不能改变文档坐标。
    static func validateExpectedMovement(
        previous: FrameSignature,
        next: FrameSignature,
        expectedMovement: Int,
        tolerance: Int
    ) -> ExpectedMovementValidation {
        let originalHeight = min(previous.originalHeight, next.originalHeight)
        let lower = max(1, expectedMovement - max(2, tolerance))
        let upper = min(
            max(1, Int(CGFloat(originalHeight) * 0.82)),
            expectedMovement + max(2, tolerance)
        )
        guard lower <= upper else {
            return ExpectedMovementValidation(
                bestMovement: max(1, expectedMovement),
                score: 255,
                gradientScore: 255,
                margin: 0
            )
        }

        let coarseHeight = max(1, min(previous.coarse.height, next.coarse.height))
        var candidates: [(movement: Int, score: Double, gradient: Double, composite: Double)] = []
        candidates.reserveCapacity(max(1, (upper - lower) / 2 + 1))

        let coarseStep = max(1, Int(ceil(CGFloat(upper - lower + 1) / 36.0)))
        for movement in stride(from: lower, through: upper, by: coarseStep) {
            let coarseDisplacement = min(
                coarseHeight - 1,
                max(1, Int(round(
                    CGFloat(movement) / CGFloat(max(1, originalHeight)) * CGFloat(coarseHeight)
                )))
            )
            let score = weightedOverlapScore(
                previous: previous.coarse,
                next: next.coarse,
                displacement: coarseDisplacement
            )
            let gradient = verticalGradientScore(
                previous: previous.precise,
                next: next.precise,
                displacement: movement
            )
            let priorPenalty = Double(abs(movement - expectedMovement)) * 0.035
            let composite = score + gradient * 0.32 + priorPenalty
            candidates.append((movement, score, gradient, composite))
        }

        guard let coarseBest = candidates.min(by: { $0.composite < $1.composite }) else {
            return ExpectedMovementValidation(
                bestMovement: expectedMovement,
                score: 255,
                gradientScore: 255,
                margin: 0
            )
        }

        let refineRadius = max(3, coarseStep + 2)
        let refineLower = max(lower, coarseBest.movement - refineRadius)
        let refineUpper = min(upper, coarseBest.movement + refineRadius)
        var refined: [(movement: Int, score: Double, gradient: Double, composite: Double)] = []
        refined.reserveCapacity(max(1, refineUpper - refineLower + 1))
        for movement in refineLower...refineUpper {
            let coarseDisplacement = min(
                coarseHeight - 1,
                max(1, Int(round(
                    CGFloat(movement) / CGFloat(max(1, originalHeight)) * CGFloat(coarseHeight)
                )))
            )
            let score = weightedOverlapScore(
                previous: previous.coarse,
                next: next.coarse,
                displacement: coarseDisplacement
            )
            let gradient = verticalGradientScore(
                previous: previous.precise,
                next: next.precise,
                displacement: movement
            )
            let priorPenalty = Double(abs(movement - expectedMovement)) * 0.035
            refined.append((movement, score, gradient, score + gradient * 0.32 + priorPenalty))
        }

        let sorted = refined.sorted { $0.composite < $1.composite }
        let best = sorted.first ?? coarseBest
        let second = sorted.first(where: { abs($0.movement - best.movement) >= 5 })
        let margin = max(0, (second?.composite ?? best.composite) - best.composite)
        return ExpectedMovementValidation(
            bestMovement: best.movement,
            score: best.score,
            gradientScore: best.gradient,
            margin: margin
        )
    }

    private static func verticalGradientScore(
        previous a: GrayFrame,
        next b: GrayFrame,
        displacement: Int
    ) -> Double {
        let overlap = min(a.height - displacement, b.height)
        guard overlap >= max(8, Int(CGFloat(min(a.height, b.height)) * 0.10)) else { return 255 }
        let fixedTopRows = min(overlap / 5, Int(CGFloat(min(a.height, b.height)) * 0.08))
        let fixedBottomRows = min(overlap / 8, Int(CGFloat(min(a.height, b.height)) * 0.03))
        let rowStart = max(1, fixedTopRows)
        let rowEnd = overlap - fixedBottomRows
        guard rowEnd > rowStart + 4 else { return 255 }
        let xStart = max(2, a.width / 16)
        let xEnd = min(a.width - 2, a.width - a.width / 16)
        var total = 0
        var count = 0
        // Compare vertical gradients rather than raw brightness. This preserves exact
        // one-pixel row information and is insensitive to uniform brightness changes,
        // while sampling only a small signature instead of running full NCC repeatedly.
        for row in stride(from: rowStart, to: rowEnd, by: 4) {
            let aRow = displacement + row
            for x in stride(from: xStart, to: xEnd, by: 8) {
                let aGradient = Int(a.pixels[aRow * a.width + x])
                    - Int(a.pixels[(aRow - 1) * a.width + x])
                let bGradient = Int(b.pixels[row * b.width + x])
                    - Int(b.pixels[(row - 1) * b.width + x])
                total += abs(aGradient - bGradient)
                count += 1
            }
        }
        return count == 0 ? 255 : Double(total) / Double(count)
    }

    private static func weightedOverlapScore(previous a: GrayFrame, next b: GrayFrame, displacement: Int) -> Double {
        let h = min(a.height, b.height)
        let overlap = min(a.height - displacement, b.height)
        guard overlap >= max(8, Int(CGFloat(h) * 0.10)) else { return 255 }

        // Sticky web headers and bottom overlays do not move with page content. Exclude
        // small fixed bands so they cannot pull the NCC seam away from the real scroll.
        let fixedTopRows = min(overlap / 5, Int(CGFloat(h) * 0.08))
        let fixedBottomRows = min(overlap / 8, Int(CGFloat(h) * 0.03))
        let rowStart = fixedTopRows
        let rowEnd = overlap - fixedBottomRows
        guard rowEnd > rowStart + 4 else { return 255 }
        let xStart = max(1, a.width * 7 / 100)
        let xEnd = min(a.width - 2, a.width * 93 / 100)
        var count = 0.0
        var sumA = 0.0
        var sumB = 0.0
        var sumAA = 0.0
        var sumBB = 0.0
        var sumAB = 0.0

        // ScreenSnap 的 FrameSig 保存整幅灰度矩阵以及逐行 sum/sq，并用
        // vDSP_dotprD 计算 NCC。这里使用同样的统计量，只做稀疏采样。
        for row in stride(from: rowStart, to: rowEnd, by: 4) {
            let previousRow = displacement + row
            for x in stride(from: xStart, to: xEnd, by: 3) {
                let av = Double(a.pixels[previousRow * a.width + x])
                let bv = Double(b.pixels[row * b.width + x])
                count += 1
                sumA += av
                sumB += bv
                sumAA += av * av
                sumBB += bv * bv
                sumAB += av * bv
            }
        }

        guard count > 32 else { return 255 }
        let varianceA = count * sumAA - sumA * sumA
        let varianceB = count * sumBB - sumB * sumB
        let denominator = sqrt(max(0, varianceA * varianceB))
        guard denominator > 0.000001 else { return 255 }
        let ncc = max(-1, min(1, (count * sumAB - sumA * sumB) / denominator))
        return (1 - ncc) * 100
    }

    static func movement(_ alignment: Alignment, frameHeight: Int) -> Int {
        max(0, frameHeight - alignment.nextContentStart - alignment.overlap)
    }

}


enum FrameStitcher {
    static func detachedCopy(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func resizedCopy(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let outputWidth = max(1, width)
        let outputHeight = max(1, height)
        if image.width == outputWidth, image.height == outputHeight {
            return detachedCopy(image) ?? image
        }
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        return context.makeImage()
    }

    static func composeOverviewChunks(
        _ chunks: [CGImage],
        width: Int,
        maximumHeight: Int
    ) -> CGImage? {
        guard !chunks.isEmpty else { return nil }
        let sourceHeight = chunks.reduce(0) { $0 + $1.height }
        let scale = min(1, CGFloat(maximumHeight) / CGFloat(max(1, sourceHeight)))
        let outputWidth = max(1, Int(round(CGFloat(width) * scale)))
        let height = max(1, Int(round(CGFloat(sourceHeight) * scale)))
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        var top = CGFloat(height)
        for (index, chunk) in chunks.enumerated() {
            let drawnHeight: CGFloat
            if index == chunks.count - 1 {
                drawnHeight = top
            } else {
                drawnHeight = CGFloat(chunk.height) * scale
            }
            top -= drawnHeight
            context.draw(chunk, in: CGRect(
                x: 0,
                y: top,
                width: CGFloat(outputWidth),
                height: drawnHeight
            ))
        }
        return context.makeImage()
    }

    /// 直接把原图中的一段缩放到预览宽度，不先生成全分辨率 patch。
    /// 相比 copyRange + scaledSegment，可少一次大块像素分配和拷贝。
    static func scaledRange(
        from image: CGImage,
        sourceStart: Int,
        sourceHeight requestedHeight: Int,
        targetWidth: Int
    ) -> CGImage? {
        let start = min(image.height - 1, max(0, sourceStart))
        let sourceHeight = min(image.height - start, max(1, requestedHeight))
        let width = max(1, min(targetWidth, image.width))
        let scale = CGFloat(width) / CGFloat(image.width)
        let outputHeight = max(1, Int(round(CGFloat(sourceHeight) * scale)))
        guard let crop = image.cropping(to: CGRect(
            x: 0,
            y: start,
            width: image.width,
            height: sourceHeight
        )), let context = CGContext(
            data: nil,
            width: width,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: outputHeight))
        return context.makeImage()
    }

    static func scaledSegment(_ image: CGImage, targetWidth: Int) -> CGImage? {
        let width = max(1, min(targetWidth, image.width))
        let scale = CGFloat(width) / CGFloat(image.width)
        let height = max(1, Int(round(CGFloat(image.height) * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func copySegment(from image: CGImage, sourceStart: Int) -> CGImage? {
        let start = min(image.height - 1, max(0, sourceStart))
        return copyRange(from: image, sourceStart: start, height: image.height - start)
    }

    static func copyRange(from image: CGImage, sourceStart: Int, height requestedHeight: Int) -> CGImage? {
        let start = min(image.height - 1, max(0, sourceStart))
        let height = min(image.height - start, max(1, requestedHeight))
        guard let crop = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: height)),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: 0, y: 0, width: image.width, height: height))
        return context.makeImage()
    }

    /// Removes pixels from the bottom of a segmented canvas while keeping at least one
    /// source pixel. This is used to replace a questionable old seam with a clean strip
    /// from the newer frame.
    @discardableResult
    static func trimTail(_ segments: inout [CGImage], pixels: Int) -> Bool {
        var remaining = max(0, pixels)
        guard remaining > 0 else { return true }
        guard segments.reduce(0, { $0 + $1.height }) > remaining else { return false }

        while remaining > 0, let last = segments.last {
            if remaining >= last.height {
                remaining -= last.height
                segments.removeLast()
                continue
            }
            let keptHeight = last.height - remaining
            guard let kept = copyRange(from: last, sourceStart: 0, height: keptHeight) else {
                return false
            }
            segments[segments.count - 1] = kept
            remaining = 0
        }
        return remaining == 0 && !segments.isEmpty
    }

    static func composePreviewSegments(
        _ segments: [CGImage],
        maximumWidth: Int,
        maximumHeight: Int
    ) -> CGImage? {
        guard let first = segments.first else { return nil }
        let sourceHeight = segments.reduce(0) { $0 + $1.height }
        let widthScale = CGFloat(maximumWidth) / CGFloat(first.width)
        let heightScale = CGFloat(maximumHeight) / CGFloat(max(1, sourceHeight))
        let scale = min(1, widthScale, heightScale)
        let targetWidth = max(1, Int(floor(CGFloat(first.width) * scale)))
        return composeSegments(segments, targetWidth: targetWidth)
    }

    static func composeSegments(_ segments: [CGImage], targetWidth: Int? = nil) -> CGImage? {
        guard let first = segments.first else { return nil }
        let width = max(1, min(targetWidth ?? first.width, first.width))
        let scale = CGFloat(width) / CGFloat(first.width)
        let sourceHeight = segments.reduce(0) { $0 + $1.height }
        let height = max(1, Int(ceil(CGFloat(sourceHeight) * scale)))
        guard sourceHeight < 180_000,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = targetWidth == nil ? .none : .medium
        var top = CGFloat(height)
        for segment in segments {
            let drawnHeight = CGFloat(segment.height) * scale
            top -= drawnHeight
            context.draw(segment, in: CGRect(x: 0, y: top, width: CGFloat(width), height: drawnHeight))
        }
        return context.makeImage()
    }

    static func preview(
        _ frames: [CGImage],
        alignments: [FrameMatcher.Alignment],
        targetWidth: Int
    ) -> CGImage? {
        guard let first = frames.first else { return nil }
        if frames.count == 1, first.width <= targetWidth { return first }
        guard alignments.count == frames.count - 1 else { return nil }

        let additions = zip(frames.dropFirst(), alignments).map {
            max(1, $0.0.height - $0.1.nextContentStart - $0.1.overlap)
        }
        let sourceHeight = first.height + additions.reduce(0, +)
        let width = max(1, min(targetWidth, first.width))
        let scale = CGFloat(width) / CGFloat(first.width)
        let height = max(1, Int(ceil(CGFloat(sourceHeight) * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium

        var top = CGFloat(height)
        let firstHeight = CGFloat(first.height) * scale
        top -= firstHeight
        context.draw(first, in: CGRect(x: 0, y: top, width: CGFloat(width), height: firstHeight))
        for index in 1..<frames.count {
            let image = frames[index]
            let alignment = alignments[index - 1]
            let sourceStart = min(image.height - 1, alignment.nextContentStart + alignment.overlap)
            let addition = max(1, image.height - sourceStart)
            let drawnHeight = CGFloat(addition) * scale
            top -= drawnHeight
            guard let patch = image.cropping(to: CGRect(
                x: 0,
                y: sourceStart,
                width: image.width,
                height: addition
            )) else { continue }
            context.draw(patch, in: CGRect(x: 0, y: top, width: CGFloat(width), height: drawnHeight))
        }
        return context.makeImage()
    }

    static func stitch(_ frames: [CGImage], alignments providedAlignments: [FrameMatcher.Alignment]? = nil) -> CGImage? {
        guard let first = frames.first else { return nil }
        if frames.count == 1 { return first }
        let width = first.width
        let alignments: [FrameMatcher.Alignment]
        if let providedAlignments, providedAlignments.count == frames.count - 1 {
            alignments = providedAlignments
        } else {
            alignments = (1..<frames.count).map {
                FrameMatcher.alignment(previous: frames[$0 - 1], next: frames[$0])
            }
        }
        let additions = zip(frames.dropFirst(), alignments).map {
            max(1, $0.0.height - $0.1.nextContentStart - $0.1.overlap)
        }
        let totalHeight = first.height + additions.reduce(0, +)
        guard totalHeight < 180_000,
              let context = CGContext(
                data: nil,
                width: width,
                height: totalHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        var top = totalHeight
        top -= first.height
        context.draw(first, in: CGRect(x: 0, y: top, width: width, height: first.height))
        for index in 1..<frames.count {
            let image = frames[index]
            let alignment = alignments[index - 1]
            let sourceStart = min(image.height - 1, alignment.nextContentStart + alignment.overlap)
            let addition = max(1, image.height - sourceStart)
            top -= addition
            let sourceRect = CGRect(x: 0, y: sourceStart, width: image.width, height: addition)
            guard let patch = image.cropping(to: sourceRect) else { continue }
            context.draw(patch, in: CGRect(x: 0, y: top, width: width, height: addition))
        }
        return context.makeImage()
    }
}
