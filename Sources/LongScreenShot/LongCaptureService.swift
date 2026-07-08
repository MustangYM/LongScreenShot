import AppKit
import CoreImage
import CoreMedia
import CoreGraphics
import CoreVideo
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

enum LongCaptureError: LocalizedError {
    case captureFailed
    case notScrollable

    var errorDescription: String? {
        switch self {
        case .captureFailed: return "无法采集滚动截图帧。请重新框选可滚动内容区域后再试。"
        case .notScrollable: return "没有检测到页面滚动。请把鼠标放在可滚动内容内，并确认页面尚未到底。"
        }
    }
}


private final class LongCaptureDiagnostics {
    static let shared = LongCaptureDiagnostics()

    private let queue = DispatchQueue(label: "longscreenshot.diagnostics.write", qos: .utility)
    private let startTime = ProcessInfo.processInfo.systemUptime
    private let fileURL: URL?
    let enabled: Bool

    private init() {
        if let value = UserDefaults.standard.object(forKey: "LongCaptureDiagnosticsEnabled") as? Bool {
            enabled = value
        } else {
            enabled = true
        }

        if enabled {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("LongCaptureDiagnostics-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            fileURL = folder.appendingPathComponent("long-capture.log")
            log("diagnostics.enabled file=\(fileURL?.path ?? "nil")")
        } else {
            fileURL = nil
        }
    }

    func log(_ message: String) {
        guard enabled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let line = String(format: "[LongCaptureDiag %.3f] %@", elapsed, message)
        NSLog("%@", line)
        guard let fileURL else { return }
        queue.async {
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
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
    var onFrame: ((CGImage, Int) -> Void)?
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
            configuration.queueDepth = 12
            configuration.showsCursor = false
            configuration.capturesAudio = false

            LongCaptureDiagnostics.shared.log("stream.start fps=60 queueDepth=12 width=\(configuration.width) height=\(configuration.height)")
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
        guard let cgImage = detachedImage(from: pixelBuffer) else {
            LongCaptureDiagnostics.shared.log("stream.frame.detachFailed")
            return
        }
        frameSerial += 1
        if frameSerial <= 5 || frameSerial % 30 == 0 {
            LongCaptureDiagnostics.shared.log("stream.frame seq=\(frameSerial) size=\(cgImage.width)x\(cgImage.height)")
        }
        dumpRecorder.dumpIfNeeded(cgImage, index: frameSerial)
        onFrame?(cgImage, frameSerial)
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

private struct LongCaptureCanvasPlacement {
    let image: CGImage
    /// 原始 viewport 在文档坐标中的顶部。
    let topOffset: Int
    /// 本次真正写入长画布的源图起点。v7 把整张 viewport 都覆盖进去，
    /// 只要 topOffset 抖 1~2px 就会在每个 placement 顶部产生横向断层。
    /// v8 只提交 overlap 末尾的一小段回补 + 新增区域。
    let sourceStart: Int
    let sourceHeight: Int
    let serial: Int
}

private struct LongCaptureCanvasSnapshot {
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
            let start = min(placement.image.height - 1, max(0, placement.sourceStart))
            let height = min(placement.image.height - start, max(1, placement.sourceHeight))
            guard let patch = placement.image.cropping(to: CGRect(
                x: 0,
                y: start,
                width: placement.image.width,
                height: height
            )) else { continue }
            let destinationTop = placement.topOffset + start
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

private enum LongCaptureCanvasPlaceResult {
    case placed(sourceStart: Int, sourceHeight: Int)
    case skippedTooClose
    case skippedDuplicate
    case rejected
}

private final class LongCaptureCanvasAccumulator {
    let width: Int
    let frameHeight: Int
    let maximumHeight: Int
    private(set) var contentHeight: Int
    private(set) var frameCount: Int
    private(set) var lastPlacedTopOffset: Int
    private var serial = 0
    private var placements: [LongCaptureCanvasPlacement]
    private var lastTailFingerprint: PatchFingerprint?
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

    private func isDuplicateTailPatch(
        frame: CGImage,
        topOffset: Int,
        sourceStart: Int,
        sourceHeight: Int,
        tailGrowth: Int
    ) -> Bool {
        guard let previous = lastTailFingerprint else { return false }
        let sampleHeight = min(sourceHeight, max(140, min(520, frame.height / 3)))
        guard sampleHeight >= 96,
              tailGrowth > 0,
              tailGrowth <= max(260, Int(CGFloat(frame.height) * 0.55)) else { return false }
        let sampleStart = sourceStart + max(0, sourceHeight - sampleHeight)
        guard let current = Self.patchFingerprint(
            in: frame,
            sourceStart: sampleStart,
            sourceHeight: sampleHeight
        ) else { return false }

        // Blank/flat patches are too ambiguous. Only reject when both patches have
        // enough internal texture and the normalized thumbnail is nearly identical.
        guard current.energy >= 1.6, previous.energy >= 1.6 else { return false }
        let mad = Self.fingerprintMAD(current, previous)
        let meanDelta = abs(current.mean - previous.mean)
        let duplicate = mad <= 2.2 && meanDelta <= 2.4
        if duplicate {
            let madText = String(format: "%.2f", mad)
            let meanText = String(format: "%.2f", meanDelta)
            let currentEnergyText = String(format: "%.2f", current.energy)
            let previousEnergyText = String(format: "%.2f", previous.energy)
            LongCaptureDiagnostics.shared.log("canvas.skipDuplicateTail top=\(topOffset) sourceStart=\(sourceStart) sourceHeight=\(sourceHeight) tailGrowth=\(tailGrowth) mad=\(madText) meanDelta=\(meanText) energy=\(currentEnergyText)/\(previousEnergyText)")
        }
        return duplicate
    }

    @discardableResult
    func place(
        _ frame: CGImage,
        topOffset rawTopOffset: Int,
        minimumStep: Int = 0,
        force: Bool = false,
        signature: FrameMatcher.FrameSignature? = nil
    ) -> LongCaptureCanvasPlaceResult {
        guard frame.width == width, frame.height == frameHeight else { return .rejected }
        let topOffset = max(0, rawTopOffset)

        guard let last = placements.last else { return .rejected }

        // 仍然保持文档坐标单调，防止错配回头覆盖。
        if topOffset < last.topOffset {
            if abs(last.topOffset - topOffset) <= 1 {
                let sourceStart = last.sourceStart
                let sourceHeight = last.sourceHeight
                placements[placements.count - 1] = LongCaptureCanvasPlacement(
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
            placements[placements.count - 1] = LongCaptureCanvasPlacement(
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
        if !force,
           isDuplicateTailPatch(
            frame: frame,
            topOffset: topOffset,
            sourceStart: sourceStart,
            sourceHeight: sourceHeight,
            tailGrowth: tailGrowth
           ) {
            return .skippedDuplicate
        }

        serial += 1
        placements.append(LongCaptureCanvasPlacement(
            image: frame,
            topOffset: topOffset,
            sourceStart: sourceStart,
            sourceHeight: sourceHeight,
            serial: serial
        ))
        contentHeight = nextHeight
        frameCount += 1
        lastPlacedTopOffset = topOffset
        let fingerprintSampleHeight = min(sourceHeight, max(140, min(520, frame.height / 3)))
        lastTailFingerprint = Self.patchFingerprint(
            in: frame,
            sourceStart: sourceStart + max(0, sourceHeight - fingerprintSampleHeight),
            sourceHeight: fingerprintSampleHeight
        ) ?? lastTailFingerprint
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
private final class LongCapturePreviewCoverageStore {
    private let sourceWidth: Int
    private let targetWidth: Int
    private let sourceToPreviewScale: CGFloat
    private let growPad: Int = 1024

    private var context: CGContext?
    private var bufferMinY: Int = 0
    private var bufferHeight: Int = 0
    private var contentMinY: Int = 0
    private var contentMaxY: Int = 0
    private var hasContent = false
    private(set) var previewContentHeight: Int = 0
    private(set) var placementCount: Int = 0
    private var cachedOverview: CGImage?
    private var cachedOverviewMaximumHeight: Int = 0
    private var overviewDirty = true

    init(firstFrame: CGImage, targetWidth: Int) {
        sourceWidth = max(1, firstFrame.width)
        self.targetWidth = max(1, min(targetWidth, firstFrame.width))
        sourceToPreviewScale = CGFloat(self.targetWidth) / CGFloat(sourceWidth)

        let firstHeight = max(1, Int(round(CGFloat(firstFrame.height) * sourceToPreviewScale)))
        bufferMinY = 0
        bufferHeight = max(firstHeight, growPad)
        context = Self.makeContext(width: self.targetWidth, height: bufferHeight)
        place(firstFrame, topOffset: 0, sourceStart: 0, sourceHeight: firstFrame.height)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let context = CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.interpolationQuality = .low
        return context
    }

    private func ensureBufferCovers(_ minY: Int, _ maxY: Int) {
        guard minY < maxY else { return }
        if let context, minY >= bufferMinY, maxY <= bufferMinY + bufferHeight, bufferHeight > 0 {
            _ = context
            return
        }

        let oldContext = context
        let oldMinY = bufferMinY
        let oldHeight = bufferHeight
        let newMinY: Int
        let newMaxY: Int

        if bufferHeight <= 0 {
            newMinY = max(0, minY - growPad / 2)
            newMaxY = maxY + growPad
        } else {
            newMinY = min(bufferMinY, max(0, minY - growPad / 2))
            newMaxY = max(bufferMinY + bufferHeight, maxY + growPad)
        }

        let newHeight = max(1, newMaxY - newMinY)
        guard let newContext = Self.makeContext(width: targetWidth, height: newHeight) else { return }
        newContext.interpolationQuality = .none

        if let oldContext,
           oldHeight > 0,
           let oldImage = oldContext.makeImage() {
            let oldDrawY = CGFloat(newHeight - ((oldMinY - newMinY) + oldHeight))
            newContext.draw(
                oldImage,
                in: CGRect(
                    x: 0,
                    y: oldDrawY,
                    width: CGFloat(targetWidth),
                    height: CGFloat(oldHeight)
                )
            )
        }

        context = newContext
        bufferMinY = newMinY
        bufferHeight = newHeight
        LongCaptureDiagnostics.shared.log("preview.buffer.grow minY=\(bufferMinY) height=\(bufferHeight) requested=\(minY)-\(maxY)")
    }

    func place(
        _ frame: CGImage,
        topOffset sourceTopOffset: Int,
        sourceStart: Int = 0,
        sourceHeight requestedSourceHeight: Int? = nil
    ) {
        let start = min(frame.height - 1, max(0, sourceStart))
        let height = min(frame.height - start, max(1, requestedSourceHeight ?? (frame.height - start)))
        let previewTop = max(0, Int(round(CGFloat(sourceTopOffset + start) * sourceToPreviewScale)))
        let previewHeight = max(1, Int(round(CGFloat(height) * sourceToPreviewScale)))
        let previewBottom = previewTop + previewHeight

        ensureBufferCovers(previewTop, previewBottom)
        guard let context,
              let patch = frame.cropping(to: CGRect(
                x: 0,
                y: start,
                width: frame.width,
                height: height
              )) else { return }

        context.interpolationQuality = .low
        let drawY = CGFloat(bufferHeight - ((previewTop - bufferMinY) + previewHeight))
        context.draw(
            patch,
            in: CGRect(
                x: 0,
                y: drawY,
                width: CGFloat(targetWidth),
                height: CGFloat(previewHeight)
            )
        )

        if hasContent {
            contentMinY = min(contentMinY, previewTop)
            contentMaxY = max(contentMaxY, previewBottom)
        } else {
            contentMinY = previewTop
            contentMaxY = previewBottom
            hasContent = true
        }
        previewContentHeight = max(1, contentMaxY - contentMinY)
        placementCount += 1
        overviewDirty = true
    }

    func makeOverview(maximumHeight: Int) -> CGImage? {
        if !overviewDirty, cachedOverviewMaximumHeight == maximumHeight, let cachedOverview {
            return cachedOverview
        }
        guard hasContent, let context, contentMaxY > contentMinY else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        guard let fullBuffer = context.makeImage() else { return nil }
        let cropY = max(0, contentMinY - bufferMinY)
        let cropHeight = max(1, min(bufferHeight - cropY, contentMaxY - contentMinY))
        guard let cropped = fullBuffer.cropping(to: CGRect(
            x: 0,
            y: cropY,
            width: targetWidth,
            height: cropHeight
        )) else { return nil }

        let scale = min(1, CGFloat(maximumHeight) / CGFloat(max(1, cropHeight)))
        if scale >= 0.999 {
            let duration = ProcessInfo.processInfo.systemUptime - started
            if duration > 0.05 {
                LongCaptureDiagnostics.shared.log("preview.overview.fastButSlow duration=\(String(format: "%.2f", duration))s buffer=\(targetWidth)x\(bufferHeight) crop=\(targetWidth)x\(cropHeight)")
            }
            cachedOverview = cropped
            cachedOverviewMaximumHeight = maximumHeight
            overviewDirty = false
            return cropped
        }

        let outputWidth = max(1, Int(round(CGFloat(targetWidth) * scale)))
        let outputHeight = max(1, Int(round(CGFloat(cropHeight) * scale)))
        guard let output = Self.makeContext(width: outputWidth, height: outputHeight) else { return cropped }
        output.interpolationQuality = .medium
        output.draw(
            cropped,
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(outputWidth),
                height: CGFloat(outputHeight)
            )
        )
        let result = output.makeImage() ?? cropped
        cachedOverview = result
        cachedOverviewMaximumHeight = maximumHeight
        overviewDirty = false
        return result
    }
}

final class LongCaptureService {
    var onPreview: ((CGImage, Int) -> Void)?
    var onStatus: ((String, Bool) -> Void)?

    private let snapshot: ScreenSnapshot
    private let selection: CGRect
    private let excludedWindowIDs: Set<CGWindowID>

    private var canvasAccumulator: LongCaptureCanvasAccumulator?
    private var previewStore: LongCapturePreviewCoverageStore?
    private var previewCanvas: CGImage?
    private var previewFlushWorkItem: DispatchWorkItem?
    private var previewGeneration = 0
    private var previewRenderInFlight = false
    private var previewRenderPending = false
    private var lastPreviewFlushTime = 0.0
    private var lastPreviewRenderedContentHeight = 0
    private var lastPreviewRenderedPlacementCount = 0
    private var lastPreviewRenderedTime = 0.0
    private var acceptedFrameCount = 0
    private var lastRawAnchor: LongCaptureFrameAnchor?
    private var canvasAnchor: LongCaptureFrameAnchor?
    private var latestObservedFrame: CGImage?
    private var latestObservedSequence = 0
    private var lastAcceptedSequence = 0
    private var latestObservedScrollPosition: CGFloat = 0
    private var trackingLost = false
    private var captureStream: ScrollCaptureStream?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?

    private var totalObservedScroll: CGFloat = 0
    private var acceptedScrollPosition: CGFloat = 0
    private var lastFrameAttemptTime = Date.distantPast
    private var lastQueuedScrollPosition: CGFloat = 0
    private var acceptedOutputHeight = 0
    private var consecutivePoorMatches = 0
    // ScreenSnap 的 ScrollStitcher 会维护一个 px/point 的弱先验；它只用来收窄 NCC 搜索，
    // 不能作为硬门槛。之前多次“截到一半断掉”就是滚轮 delta 被当成硬事实导致的。
    private var scrollPixelsPerPoint: CGFloat = 0
    private var fallbackCooldownFrames = 0
    private let matchQueue = DispatchQueue(label: "longscreenshot.frame.match", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "longscreenshot.preview.render", qos: .userInitiated)
    private var matchInFlight = false
    private var pendingFrameQueue: [StreamFrameCandidate] = []
    private var isStopping = false
    private var finishRequested = false
    private var finishCompletion: ((Result<CGImage, Error>) -> Void)?
    private var gatedFrameCount = 0
    private var queuedFrameCount = 0
    private var skippedTooCloseCount = 0
    private var rejectedPlacementCount = 0
    private var poorMatchCount = 0
    private var compactedQueueCount = 0
    private var droppedBacklogFrameCount = 0
    // v14：页面到底后，滚轮还会继续产生 delta，但画面几乎不再变化。
    // 这类帧只能“消费滚动位置”，不能继续推进 topOffset，否则底部会拼出重复内容。
    private var bottomNoVisualProgressCount = 0
    private var reachedVisualEnd = false
    // v16：一旦连续静帧确认页面已经到底，后续向下滚动只消费滚轮，不再进入 matcher。
    // 否则短页面/重复纹理页面会在到底后被弱 NCC 重新“恢复”，把底部旧内容重复拼到尾部。
    private var reachedVisualEndScrollPosition: CGFloat = 0
    private var lastUnplacedAcceptedTail: PendingAcceptedTail?

    // ScreenCaptureKit 仍然以 60fps 捕获，但 matcher 不能按 60fps 逐帧处理。
    // v12：快速滚动时 24fps matcher 采样间隔过大，容易让相邻帧 overlap 掉到 40% 左右后断链。
    // 队列仍保持有界，但略微放大，配合 45fps 采样保留更多过渡帧。
    private let maximumPendingFrames = 32
    private let maximumOutputHeight = 180_000
    // ScreenSnap 的 ScrollStitcher 里有 previewInterval≈0.2s：预览本来就是粗颗粒刷新，
    // 不能像最终画布一样每个 placement 都重绘一次 overview。
    // v14：最终拼接仍保持 v13/v10 的稳定细节；预览只做粗颗粒输出，减少越长越滞后的问题。
    private let previewMaximumLatency = 0.20
    private var previewMinimumRenderGrowth: Int {
        max(36, min(96, Int(CGFloat(previewMaximumHeight) * 0.16)))
    }
    private var previewMaximumWidth: Int {
        let desiredMinimapWidth = min(210, max(110, selection.width * 0.24))
        let minimapWidth = min(selection.width - 16, desiredMinimapWidth)
        return max(72, Int(floor(minimapWidth - 16)))
    }
    private var previewMaximumHeight: Int {
        max(100, min(900, Int(floor(selection.height - 88))))
    }

    private func minimumCanvasPlacementStep(frameHeight: Int) -> Int {
        // 预览和最终画布都只写“有意义的新段”。颗粒度按 ScreenSnap 的思路偏粗，
        // 但每次写入会从当前 contentHeight 接上，完整结果不会因为少写中间帧而缺内容。
        max(160, min(420, Int(CGFloat(frameHeight) * 0.20)))
    }

    private func normalizedTopOffsetForCanvasPlacement(
        rawTopOffset: Int,
        frameHeight: Int,
        contentHeight: Int,
        sequence: Int
    ) -> Int {
        // v18：快速滚动恢复时，Vision/NCC 有时会给出“刚好越过当前画布尾部几像素”的 top。
        // ScreenSnap 的 LongCanvas 本质是 contentMaxY append；这种 1~几十像素的小 gap
        // 不应该让画布拒绝，否则 raw anchor 会跑到画布前面，后面就会一直 rejected，
        // 表现为“长截图截到一半断掉”。这里把小 gap 夹回 contentHeight，宁可有极小重叠，
        // 也不要让跟踪链从画布尾部断开。
        let gap = rawTopOffset - contentHeight
        guard gap > 0 else { return rawTopOffset }

        let tolerance = max(12, min(56, Int(CGFloat(frameHeight) * 0.035)))
        if gap <= tolerance {
            LongCaptureDiagnostics.shared.log("canvas.clampTinyGap seq=\(sequence) rawTop=\(rawTopOffset) contentHeight=\(contentHeight) gap=\(gap) tolerance=\(tolerance)")
            return contentHeight
        }
        return rawTopOffset
    }

    /// v21：到底后的重复追加有一个很稳定的特征：
    /// 实际滚轮只多滚了一点点，但 matcher 算出来的新 tailGrowth 接近一整屏。
    /// 这不是页面产生了新内容，而是底部回弹/重复纹理把旧尾巴错当成新帧。
    /// 用 pxPerPoint 的弱先验只做“反作弊”判断：只拦截明显不可能的尾部增长，不影响正常快滚。
    private func isImplausibleTailGrowthAfterSmallScroll(
        tailGrowth: Int,
        frameHeight: Int,
        candidateScrollPosition: CGFloat,
        contentHeight: Int
    ) -> Bool {
        guard tailGrowth > 0, frameHeight > 0 else { return false }
        guard scrollPixelsPerPoint > 0.25 else { return false }

        let scrollGap = max(0, candidateScrollPosition - acceptedScrollPosition)
        guard scrollGap >= 1 else { return false }

        let expectedGrowth = scrollGap * scrollPixelsPerPoint
        let tailGrowthFloat = CGFloat(tailGrowth)
        let frameFloat = CGFloat(frameHeight)

        // 如果用户真的快滚了很多，不能用这个规则卡掉恢复。
        // 只处理“滚轮增量不大，但图像却要追加大半屏”的底部重复特征。
        guard scrollGap <= frameFloat * 0.55 else { return false }

        let absoluteLargeTail = tailGrowthFloat >= frameFloat * 0.52
        let muchLargerThanExpected = tailGrowthFloat >= max(expectedGrowth * 2.35 + 120, frameFloat * 0.48)
        let alreadyLongEnough = contentHeight >= frameHeight * 3
        return alreadyLongEnough && absoluteLargeTail && muchLargerThanExpected
    }

    /// v22：短滚动范围页面到底时，NCC 很容易在重复/相似行里找到一个“看起来很可靠”的较大 top。
    /// 如果照常 append，会把底部已经出现过的一段再次追加，形成用户截图里的上下重叠。
    /// 这类坏帧的特征是：
    /// 1. 已经至少写过一段真实新增内容；
    /// 2. 视觉变化极小；
    /// 3. 本次滚轮增量只对应几十像素，但 matcher 要追加接近半屏的新尾巴。
    /// 处理方式不是直接丢掉整帧，而是只把“按滚轮先验合理可能新增的最底部小尾巴”补上，
    /// 然后立即锁定页面底部。这样既不会漏掉 Initial commit 这类最后一两行，也不会整段重复。
    @discardableResult
    private func appendConservativeShortRangeBottomTailIfNeeded(
        result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        accumulator: LongCaptureCanvasAccumulator,
        rawTopOffset: Int,
        placementTopOffset: Int,
        signature: FrameMatcher.FrameSignature?
    ) -> Bool {
        guard !finishRequested, !reachedVisualEnd else { return false }
        let frameHeight = max(1, candidate.image.height)

        // 只处理短可视区域/短滚动范围。长页面正常中段不能被这个规则提前锁死。
        let shortViewport = selection.height <= 360 || frameHeight <= 720
        guard shortViewport, accumulator.frameCount >= 2 else { return false }
        guard accumulator.contentHeight <= frameHeight * 3 else { return false }

        let tailGrowth = placementTopOffset + frameHeight - accumulator.contentHeight
        guard tailGrowth > 0 else { return false }
        guard tailGrowth >= max(96, Int(CGFloat(frameHeight) * 0.28)) else { return false }

        let visualDelta = result.debug?.visualDelta ?? 255
        guard visualDelta <= 4.5 else { return false }

        let scrollGap = max(0, candidate.scrollPosition - acceptedScrollPosition)
        guard scrollGap > 0, scrollGap <= CGFloat(frameHeight) * 0.45 else { return false }

        let expectedGrowth: CGFloat
        if scrollPixelsPerPoint > 0.25 {
            expectedGrowth = scrollGap * scrollPixelsPerPoint
        } else {
            expectedGrowth = CGFloat(max(0, result.movementPixels))
        }
        guard expectedGrowth > 0 else { return false }

        let tooLargeForScroll = CGFloat(tailGrowth) >= max(expectedGrowth * 2.0 + 64, CGFloat(frameHeight) * 0.38)
        guard tooLargeForScroll else { return false }

        let conservativeHeight = min(
            tailGrowth,
            max(48, min(Int(CGFloat(frameHeight) * 0.24), Int(expectedGrowth * 1.45 + 32)))
        )
        guard conservativeHeight > 0,
              conservativeHeight <= tailGrowth - max(28, frameHeight / 12) else { return false }

        let sourceStart = max(0, frameHeight - conservativeHeight)
        let conservativeTop = max(accumulator.lastPlacedTopOffset, accumulator.contentHeight - sourceStart)
        let placementResult = accumulator.place(
            candidate.image,
            topOffset: conservativeTop,
            minimumStep: 0,
            force: true,
            signature: signature
        )

        switch placementResult {
        case let .placed(actualSourceStart, actualSourceHeight):
            let anchor = LongCaptureFrameAnchor(
                image: candidate.image,
                signature: signature,
                topOffset: conservativeTop,
                scrollPosition: candidate.scrollPosition
            )
            canvasAnchor = anchor
            lastRawAnchor = anchor
            lastUnplacedAcceptedTail = nil
            acceptedOutputHeight = accumulator.contentHeight
            acceptedFrameCount = accumulator.frameCount
            previewStore?.place(
                candidate.image,
                topOffset: conservativeTop,
                sourceStart: actualSourceStart,
                sourceHeight: actualSourceHeight
            )
            schedulePreviewRender()
            LongCaptureDiagnostics.shared.log("canvas.placeShortBottomTail seq=\(candidate.sequence) rawTop=\(rawTopOffset) normalTop=\(placementTopOffset) conservativeTop=\(conservativeTop) tailGrowth=\(tailGrowth) conservativeHeight=\(conservativeHeight) sourceStart=\(actualSourceStart) sourceHeight=\(actualSourceHeight) contentHeight=\(accumulator.contentHeight) scrollGap=\(String(format: "%.2f", Double(scrollGap))) expected=\(String(format: "%.2f", Double(expectedGrowth))) visual=\(String(format: "%.2f", visualDelta))")
            lockReachedVisualEnd(
                reason: "shortRangeConservativeTail",
                candidate: candidate,
                result: result,
                contentHeight: accumulator.contentHeight
            )
            return true
        case .skippedDuplicate:
            LongCaptureDiagnostics.shared.log("canvas.shortBottomTailDuplicate seq=\(candidate.sequence) rawTop=\(rawTopOffset) normalTop=\(placementTopOffset) tailGrowth=\(tailGrowth)")
            lockReachedVisualEnd(
                reason: "shortRangeDuplicateTail",
                candidate: candidate,
                result: result,
                contentHeight: accumulator.contentHeight
            )
            return true
        case .skippedTooClose, .rejected:
            LongCaptureDiagnostics.shared.log("canvas.shortBottomTailRejected seq=\(candidate.sequence) rawTop=\(rawTopOffset) conservativeTop=\(conservativeTop) tailGrowth=\(tailGrowth) conservativeHeight=\(conservativeHeight) result=\(placementResult)")
            return false
        }
    }
    private func lockReachedVisualEnd(
        reason: String,
        candidate: StreamFrameCandidate,
        result: FrameCandidateResult?,
        contentHeight: Int
    ) {
        reachedVisualEnd = true
        reachedVisualEndScrollPosition = max(reachedVisualEndScrollPosition, candidate.scrollPosition)
        bottomNoVisualProgressCount = max(bottomNoVisualProgressCount, 4)
        trackingLost = false
        consecutivePoorMatches = 0
        fallbackCooldownFrames = 0
        lastUnplacedAcceptedTail = nil
        lastAcceptedSequence = max(lastAcceptedSequence, candidate.sequence)
        acceptedScrollPosition = max(acceptedScrollPosition, candidate.scrollPosition)
        lastQueuedScrollPosition = max(lastQueuedScrollPosition, candidate.scrollPosition)
        if !pendingFrameQueue.isEmpty {
            LongCaptureDiagnostics.shared.log("end.lock.dropQueue reason=\(reason) seq=\(candidate.sequence) dropped=\(pendingFrameQueue.count)")
            pendingFrameQueue.removeAll()
        }
        let visualText = result?.debug.map { String(format: "%.2f", $0.visualDelta) } ?? "nil"
        let localScoreText = LCFormatOptionalDouble(result?.debug?.localScore)
        let localMarginText = LCFormatOptionalDouble(result?.debug?.localMargin)
        LongCaptureDiagnostics.shared.log("end.lock reason=\(reason) seq=\(candidate.sequence) top=\(result?.topOffset ?? -1) move=\(result?.movementPixels ?? -1) contentHeight=\(contentHeight) frameHeight=\(candidate.image.height) scroll=\(String(format: "%.2f", Double(candidate.scrollPosition))) visual=\(visualText) score=\(localScoreText) margin=\(localMarginText)")
        onStatus?("页面已到底，已锁定尾部，继续滚动不会追加重复内容", false)
    }


    /// v19：快速滚动丢锚时，不能只允许“完全 accepted”的帧写入画布。
    /// 日志里出现过这种断链：弱帧虽然 NCC 没达到正式接受阈值，但它和当前画布尾部
    /// 仍有几十像素真实 overlap；下一帧反而跳到 contentHeight 之后几百像素，被 canvas.rejectGap。
    /// ScreenSnap 的 LongCanvas 只关心 contentMaxY append，这类“低 overlap 但可信”的恢复帧应该作为桥接段写入，
    /// 否则 raw anchor 会一直在画布前方游离，表现为截图截到一半停止增长。
    @discardableResult
    private func promoteWeakOverlapBridgeIfNeeded(
        result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        signature: FrameMatcher.FrameSignature?
    ) -> Bool {
        guard !finishRequested, !reachedVisualEnd else { return false }
        guard result.poorMatch, result.movementPixels > 0 else { return false }
        guard let accumulator = canvasAccumulator else { return false }

        let frameHeight = max(1, candidate.image.height)
        let contentHeight = accumulator.contentHeight

        // v17 的短截图尾部锁定用于解决“到底后继续拖导致重复追加”。
        // 这里的桥接只给真正长内容使用，避免把短图到底后的弱匹配再次写入画布。
        guard contentHeight > frameHeight * 3, selection.height > 360 else { return false }

        let rawTopOffset = min(
            maximumOutputHeight - candidate.image.height,
            max(0, result.topOffset)
        )
        guard rawTopOffset >= accumulator.lastPlacedTopOffset else { return false }

        let nextHeight = rawTopOffset + frameHeight
        let canvasOverlap = contentHeight - rawTopOffset
        let tailGrowth = nextHeight - contentHeight

        // 必须真的能从画布尾部继续追加：top 在 contentHeight 之前，并且会带来新内容。
        guard tailGrowth > 0 else { return false }
        guard canvasOverlap > 0 else { return false }

        // v21：v19 的弱桥接能救“中途断链”，但它也会把网页底部回弹/重复尾巴
        // 当成低重叠桥接写进去。底部重复的典型特征是：用户实际只滚了很小一段，
        // 但 tailGrowth 接近一整屏。这里先用 pxPerPoint 反作弊拦掉这种不可能增长。
        if isImplausibleTailGrowthAfterSmallScroll(
            tailGrowth: tailGrowth,
            frameHeight: frameHeight,
            candidateScrollPosition: candidate.scrollPosition,
            contentHeight: contentHeight
        ) {
            LongCaptureDiagnostics.shared.log("bridge.rejectBottomLike seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(contentHeight) canvasOverlap=\(canvasOverlap) tailGrowth=\(tailGrowth) scrollGap=\(String(format: "%.2f", Double(candidate.scrollPosition - acceptedScrollPosition))) pxPerPoint=\(String(format: "%.3f", Double(scrollPixelsPerPoint)))")
            return false
        }

        // 这是“桥接低 overlap”，不是普通 accepted。
        // overlap 太大时继续走正常 matcher；overlap 太小则风险太高。
        let minimumBridgeOverlap = max(48, Int(CGFloat(frameHeight) * 0.04))
        let maximumBridgeOverlap = max(minimumBridgeOverlap + 1, Int(CGFloat(frameHeight) * 0.22))
        guard canvasOverlap >= minimumBridgeOverlap, canvasOverlap <= maximumBridgeOverlap else { return false }

        let debug = result.debug
        let localScore = debug?.localScore ?? 255.0
        let localMargin = debug?.localMargin ?? 0.0
        let anchorScore = debug?.anchorScore ?? 255.0
        let anchorMargin = debug?.anchorMargin ?? 0.0
        let visualDelta = debug?.visualDelta ?? 0.0
        let localOverlap = debug?.localOverlap ?? 0
        let anchorOverlap = debug?.anchorOverlap ?? 0
        let bestOverlap = max(localOverlap, anchorOverlap)

        let scoreLooksUsable = localScore <= 58.0 || anchorScore <= 58.0
        let marginLooksUsable = localMargin >= 24.0 || anchorMargin >= 24.0
        let enoughPatchOverlap = bestOverlap >= max(320, Int(CGFloat(frameHeight) * 0.28))

        guard visualDelta >= 8.0, enoughPatchOverlap, (scoreLooksUsable || marginLooksUsable) else {
            LongCaptureDiagnostics.shared.log("bridge.rejectWeak seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(contentHeight) canvasOverlap=\(canvasOverlap) tailGrowth=\(tailGrowth) visual=\(String(format: "%.2f", visualDelta)) score=\(String(format: "%.2f", localScore))/\(String(format: "%.2f", anchorScore)) margin=\(String(format: "%.2f", localMargin))/\(String(format: "%.2f", anchorMargin)) overlap=\(bestOverlap)")
            return false
        }

        let bridgeAnchor = LongCaptureFrameAnchor(
            image: candidate.image,
            signature: signature,
            topOffset: rawTopOffset,
            scrollPosition: candidate.scrollPosition
        )

        let placementResult = accumulator.place(
            candidate.image,
            topOffset: rawTopOffset,
            minimumStep: 0,
            force: true,
            signature: signature
        )

        switch placementResult {
        case let .placed(sourceStart, sourceHeight):
            lastRawAnchor = bridgeAnchor
            canvasAnchor = bridgeAnchor
            lastAcceptedSequence = candidate.sequence
            acceptedScrollPosition = candidate.scrollPosition
            lastQueuedScrollPosition = max(lastQueuedScrollPosition, candidate.scrollPosition)
            trackingLost = false
            consecutivePoorMatches = 0
            bottomNoVisualProgressCount = 0
            reachedVisualEnd = false
            fallbackCooldownFrames = 0
            lastUnplacedAcceptedTail = nil

            previewStore?.place(
                candidate.image,
                topOffset: rawTopOffset,
                sourceStart: sourceStart,
                sourceHeight: sourceHeight
            )
            acceptedOutputHeight = accumulator.contentHeight
            acceptedFrameCount = accumulator.frameCount
            schedulePreviewRender()

            LongCaptureDiagnostics.shared.log("canvas.placeWeakBridge seq=\(candidate.sequence) top=\(rawTopOffset) move=\(result.movementPixels) canvasOverlap=\(canvasOverlap) tailGrowth=\(tailGrowth) sourceStart=\(sourceStart) sourceHeight=\(sourceHeight) contentHeight=\(accumulator.contentHeight) frameCount=\(accumulator.frameCount) score=\(String(format: "%.2f", localScore))/\(String(format: "%.2f", anchorScore)) margin=\(String(format: "%.2f", localMargin))/\(String(format: "%.2f", anchorMargin)) visual=\(String(format: "%.2f", visualDelta))")
            onStatus?("已用低重叠桥接帧恢复长截图…", false)
            return true

        case .skippedTooClose:
            LongCaptureDiagnostics.shared.log("bridge.skipTooClose seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(accumulator.contentHeight) canvasOverlap=\(canvasOverlap)")
            return false

        case .skippedDuplicate:
            LongCaptureDiagnostics.shared.log("bridge.skipDuplicate seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(accumulator.contentHeight) canvasOverlap=\(canvasOverlap)")
            return false

        case .rejected:
            LongCaptureDiagnostics.shared.log("bridge.rejected seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(accumulator.contentHeight) canvasOverlap=\(canvasOverlap) tailGrowth=\(tailGrowth)")
            return false
        }
    }

    private func shouldLockVisualEndAfterRepeatedPoor(
        result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        accumulator: LongCaptureCanvasAccumulator
    ) -> Bool {
        guard !finishRequested, !reachedVisualEnd else { return false }
        guard result.poorMatch else { return false }

        let frameHeight = max(1, candidate.image.height)
        let contentHeight = accumulator.contentHeight
        let visualDelta = result.debug?.visualDelta ?? Double.greatestFiniteMagnitude
        guard visualDelta <= 9.5 else { return false }
        guard consecutivePoorMatches >= 5 else { return false }

        let predictedTop = max(0, result.topOffset)
        let nextHeight = predictedTop + frameHeight
        let canvasOverlap = contentHeight - predictedTop
        let tailGrowth = nextHeight - contentHeight
        guard tailGrowth > 0 else { return false }

        // v20：v19 只对短截图启用“到底锁尾”，长图到底后继续往下滚时，
        // 也会出现同一屏尾部被 NCC 当成新内容的情况：连续 poor、visualDelta 很低、
        // top 卡在 contentHeight 附近，并且 tailGrowth 接近一整屏。
        // 这不是正常中途恢复，而是页面已经到底后的重复尾巴，应立即锁住。
        let shortTailSensitiveCapture = contentHeight <= frameHeight * 3 || selection.height <= 360
        let scrolledPastAccepted = candidate.scrollPosition - acceptedScrollPosition
        let unreliable = !(result.debug?.localReliable ?? false) && !(result.debug?.anchorReliable ?? false)
        if shortTailSensitiveCapture {
            let isTryingToExtendTail = nextHeight > contentHeight && canvasOverlap < Int(CGFloat(frameHeight) * 0.90)
            guard isTryingToExtendTail else { return false }
            return scrolledPastAccepted >= CGFloat(frameHeight) * 0.20 || unreliable
        }

        // 长图专用：只在强特征下锁尾，避免误伤中途丢锚恢复。
        // v21：除了“贴近尾部 + 接近整屏”的旧规则，还加入“滚轮增量很小但
        // tailGrowth 不可能地大”的规则，专门拦截网页底部回弹/继续拖动造成的重复追加。
        let overlapRatio = CGFloat(max(0, canvasOverlap)) / CGFloat(frameHeight)
        let growthRatio = CGFloat(tailGrowth) / CGFloat(frameHeight)
        let almostFullScreenTailDuplicate =
            canvasOverlap >= 0 &&
            overlapRatio <= 0.18 &&
            growthRatio >= 0.66 &&
            scrolledPastAccepted >= CGFloat(frameHeight) * 0.14

        let impossibleSmallScrollTail = isImplausibleTailGrowthAfterSmallScroll(
            tailGrowth: tailGrowth,
            frameHeight: frameHeight,
            candidateScrollPosition: candidate.scrollPosition,
            contentHeight: contentHeight
        )

        return almostFullScreenTailDuplicate || impossibleSmallScrollTail
    }

    private func shouldIgnoreAcceptedAfterBottomLikeRecovery(
        result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        accumulator: LongCaptureCanvasAccumulator,
        rawTopOffset: Int,
        previousPoorCount: Int
    ) -> Bool {
        guard !finishRequested, !reachedVisualEnd else { return false }
        guard previousPoorCount >= 5 || trackingLost else { return false }

        let frameHeight = max(1, candidate.image.height)
        let contentHeight = accumulator.contentHeight
        let visualDelta = result.debug?.visualDelta ?? Double.greatestFiniteMagnitude
        guard visualDelta <= 10.0 else { return false }

        let nextHeight = rawTopOffset + frameHeight
        let canvasOverlap = contentHeight - rawTopOffset
        let tailGrowth = nextHeight - contentHeight
        guard tailGrowth > 0 else { return false }

        let shortTailSensitiveCapture = contentHeight <= frameHeight * 3 || selection.height <= 360
        let overlapRatio = CGFloat(max(0, canvasOverlap)) / CGFloat(frameHeight)
        let growthRatio = CGFloat(tailGrowth) / CGFloat(frameHeight)
        let scrolledPastAccepted = candidate.scrollPosition - acceptedScrollPosition

        if shortTailSensitiveCapture {
            // v23：短可视区第一次真正滚动成功时，也可能先经历 1~2 次 poor，
            // 然后才出现第一个 accepted。v22 在 frameCount==1 时就按“底部重复”锁尾，
            // 会导致用户已经滚动了，但最终只输出第一屏。
            // 所以这里必须先放过“第一段真实追加”。只有已经写入过至少一段新内容后，
            // 才允许短图底部重复锁定规则生效。
            guard accumulator.frameCount >= 2 else {
                LongCaptureDiagnostics.shared.log("end.allowFirstShortRangeAppend seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(contentHeight) frameHeight=\(frameHeight) poorBefore=\(previousPoorCount) visual=\(String(format: "%.2f", visualDelta)) overlapRatio=\(String(format: "%.2f", Double(overlapRatio))) growthRatio=\(String(format: "%.2f", Double(growthRatio)))")
                return false
            }

            // 到底后继续拖动时，弱纹理/NCC 会偶尔给出一个 accepted，但它通常只和现有画布
            // 保持很小或中等 overlap，然后把同一屏底部当成新内容追加。
            // 对短截图来说，连续 poor 后出现这种 accepted，宁可锁尾，也不要追加重复段。
            return overlapRatio < 0.75 || scrolledPastAccepted >= CGFloat(frameHeight) * 0.65
        }

        // v21：长截图到底后也要挡住“低视觉变化 + 不可能的尾部增长”的 accepted。
        // 这个判断比短图更严格，避免把正常中途恢复误判成到底。
        let almostFullScreenTailDuplicate = canvasOverlap >= 0 &&
            overlapRatio <= 0.18 &&
            growthRatio >= 0.66 &&
            scrolledPastAccepted >= CGFloat(frameHeight) * 0.14
        let impossibleSmallScrollTail = isImplausibleTailGrowthAfterSmallScroll(
            tailGrowth: tailGrowth,
            frameHeight: frameHeight,
            candidateScrollPosition: candidate.scrollPosition,
            contentHeight: contentHeight
        )
        return almostFullScreenTailDuplicate || impossibleSmallScrollTail
    }

    private func commitPendingTailIfNeeded(reason: String) {
        if reachedVisualEnd {
            if let pending = lastUnplacedAcceptedTail {
                LongCaptureDiagnostics.shared.log("tail.rejectCommitAfterEnd reason=\(reason) seq=\(pending.sequence) endScroll=\(String(format: "%.2f", Double(reachedVisualEndScrollPosition)))")
            }
            lastUnplacedAcceptedTail = nil
            return
        }
        guard let pending = lastUnplacedAcceptedTail, let accumulator = canvasAccumulator else { return }
        let anchor = pending.anchor
        let tailGrowth = anchor.topOffset + anchor.image.height - accumulator.contentHeight
        guard tailGrowth >= 2 else {
            LongCaptureDiagnostics.shared.log("tail.skipCommit reason=\(reason) seq=\(pending.sequence) tailGrowth=\(tailGrowth) top=\(anchor.topOffset) contentHeight=\(accumulator.contentHeight)")
            lastUnplacedAcceptedTail = nil
            return
        }
        guard anchor.topOffset + 1 >= accumulator.lastPlacedTopOffset,
              anchor.topOffset <= accumulator.contentHeight else {
            LongCaptureDiagnostics.shared.log("tail.rejectCommit reason=\(reason) seq=\(pending.sequence) top=\(anchor.topOffset) lastPlaced=\(accumulator.lastPlacedTopOffset) contentHeight=\(accumulator.contentHeight) tailGrowth=\(tailGrowth)")
            lastUnplacedAcceptedTail = nil
            return
        }

        if pending.visualDelta < 10.0, (pending.matchMargin ?? 0) < 18.0 {
            LongCaptureDiagnostics.shared.log("tail.rejectCommitLowVisual reason=\(reason) seq=\(pending.sequence) visualDelta=\(String(format: "%.2f", pending.visualDelta)) top=\(anchor.topOffset) tailGrowth=\(tailGrowth) score=\(LCFormatOptionalDouble(pending.matchScore)) margin=\(LCFormatOptionalDouble(pending.matchMargin))")
            lastUnplacedAcceptedTail = nil
            return
        }

        let placementResult = accumulator.place(
            anchor.image,
            topOffset: anchor.topOffset,
            minimumStep: 0,
            force: true,
            signature: anchor.signature
        )
        switch placementResult {
        case let .placed(sourceStart, sourceHeight):
            canvasAnchor = anchor
            previewStore?.place(
                anchor.image,
                topOffset: anchor.topOffset,
                sourceStart: sourceStart,
                sourceHeight: sourceHeight
            )
            acceptedOutputHeight = accumulator.contentHeight
            acceptedFrameCount = accumulator.frameCount
            LongCaptureDiagnostics.shared.log("tail.commit reason=\(reason) seq=\(pending.sequence) top=\(anchor.topOffset) tailGrowth=\(tailGrowth) sourceStart=\(sourceStart) sourceHeight=\(sourceHeight) contentHeight=\(accumulator.contentHeight) move=\(pending.movementPixels) score=\(LCFormatOptionalDouble(pending.matchScore)) margin=\(LCFormatOptionalDouble(pending.matchMargin))")
        case .skippedTooClose:
            LongCaptureDiagnostics.shared.log("tail.skipTooClose reason=\(reason) seq=\(pending.sequence) tailGrowth=\(tailGrowth)")
        case .skippedDuplicate:
            LongCaptureDiagnostics.shared.log("tail.skipDuplicate reason=\(reason) seq=\(pending.sequence) tailGrowth=\(tailGrowth)")
        case .rejected:
            LongCaptureDiagnostics.shared.log("tail.rejected reason=\(reason) seq=\(pending.sequence) top=\(anchor.topOffset) tailGrowth=\(tailGrowth)")
        }
        lastUnplacedAcceptedTail = nil
    }

    /// v3：快速滚动时如果连续多帧都无法达到正式 NCC 阈值，但其中有一个
    /// 单调、仍有足够 overlap 的尾部候选，就把它作为“恢复桥”先提交。
    /// 这不是普通接受：只有在已经连续丢锚多帧后才触发，用来避免 matcher 永远
    /// 卡在旧锚点上反复 nccRejected。
    @discardableResult
    private func promotePendingTailForRecoveryIfNeeded(reason: String) -> Bool {
        if reachedVisualEnd {
            if let pending = lastUnplacedAcceptedTail {
                LongCaptureDiagnostics.shared.log("tail.promoteRejectAfterEnd reason=\(reason) seq=\(pending.sequence) endScroll=\(String(format: "%.2f", Double(reachedVisualEndScrollPosition)))")
            }
            lastUnplacedAcceptedTail = nil
            return false
        }
        guard let pending = lastUnplacedAcceptedTail, let accumulator = canvasAccumulator else { return false }
        let anchor = pending.anchor
        let tailGrowth = anchor.topOffset + anchor.image.height - accumulator.contentHeight
        guard tailGrowth >= max(32, anchor.image.height / 12) else { return false }
        guard anchor.topOffset + 1 >= accumulator.lastPlacedTopOffset,
              anchor.topOffset <= accumulator.contentHeight else { return false }

        // v5：弱锚点只能作为“相邻过渡桥”，不能跨很远的滚轮距离硬接。
        // 这次缺失大段内容的根因就是 seq=145 这类远距离 weak tail 被 promote，
        // 画布直接从前面的内容跳到了底部 frame 的下半截。
        let bridgeScrollGap = max(0, anchor.scrollPosition - acceptedScrollPosition)
        let maximumWeakBridgeScrollGap = max(CGFloat(420), CGFloat(anchor.image.height) * 0.85)
        guard bridgeScrollGap <= maximumWeakBridgeScrollGap else {
            LongCaptureDiagnostics.shared.log("tail.promoteRejectFarGap reason=\(reason) seq=\(pending.sequence) scrollGap=\(String(format: "%.2f", Double(bridgeScrollGap))) limit=\(String(format: "%.2f", Double(maximumWeakBridgeScrollGap))) top=\(anchor.topOffset) tailGrowth=\(tailGrowth) score=\(LCFormatOptionalDouble(pending.matchScore)) margin=\(LCFormatOptionalDouble(pending.matchMargin))")
            return false
        }

        // v4：低视觉变化的 rejected tail 很可能是页面到底后的重复尾帧。
        // 这类候选不能用于 lostRecovery 桥接，否则会把 GitHub footer / license badge
        // 重复拼到长图尾部。真正的快速滚动桥接帧通常 visualDelta 明显更高。
        guard pending.visualDelta >= 10.0 else {
            LongCaptureDiagnostics.shared.log("tail.promoteRejectLowVisual reason=\(reason) seq=\(pending.sequence) visualDelta=\(String(format: "%.2f", pending.visualDelta)) top=\(anchor.topOffset) tailGrowth=\(tailGrowth) score=\(LCFormatOptionalDouble(pending.matchScore)) margin=\(LCFormatOptionalDouble(pending.matchMargin))")
            return false
        }

        let placementResult = accumulator.place(
            anchor.image,
            topOffset: anchor.topOffset,
            minimumStep: 0,
            force: true,
            signature: anchor.signature
        )
        switch placementResult {
        case let .placed(sourceStart, sourceHeight):
            lastRawAnchor = anchor
            canvasAnchor = anchor
            lastAcceptedSequence = max(lastAcceptedSequence, pending.sequence)
            acceptedScrollPosition = max(acceptedScrollPosition, anchor.scrollPosition)
            lastQueuedScrollPosition = max(lastQueuedScrollPosition, anchor.scrollPosition)
            acceptedOutputHeight = accumulator.contentHeight
            acceptedFrameCount = accumulator.frameCount
            trackingLost = false
            consecutivePoorMatches = 0
            bottomNoVisualProgressCount = 0
            reachedVisualEnd = false
            fallbackCooldownFrames = 0
            lastUnplacedAcceptedTail = nil

            // 已经在这个桥接帧之前的 backlog 没必要继续处理；继续处理只会把锚点
            // 又拉回旧位置。保留桥接点之后的帧，让后续 matcher 从新锚点继续追。
            let before = pendingFrameQueue.count
            pendingFrameQueue = pendingFrameQueue.filter { queued in
                queued.sequence > pending.sequence && queued.scrollPosition > anchor.scrollPosition + 0.25
            }

            previewStore?.place(
                anchor.image,
                topOffset: anchor.topOffset,
                sourceStart: sourceStart,
                sourceHeight: sourceHeight
            )
            schedulePreviewRender()
            LongCaptureDiagnostics.shared.log("tail.promoteRecovery reason=\(reason) seq=\(pending.sequence) top=\(anchor.topOffset) tailGrowth=\(tailGrowth) sourceStart=\(sourceStart) sourceHeight=\(sourceHeight) contentHeight=\(accumulator.contentHeight) queueBefore=\(before) queueAfter=\(pendingFrameQueue.count) score=\(LCFormatOptionalDouble(pending.matchScore)) margin=\(LCFormatOptionalDouble(pending.matchMargin))")
            onStatus?("快速滚动中已用弱锚点恢复，继续滚动即可", false)
            return true

        case .skippedTooClose:
            LongCaptureDiagnostics.shared.log("tail.promoteSkipTooClose reason=\(reason) seq=\(pending.sequence) tailGrowth=\(tailGrowth)")
            return false
        case .skippedDuplicate:
            LongCaptureDiagnostics.shared.log("tail.promoteSkipDuplicate reason=\(reason) seq=\(pending.sequence) tailGrowth=\(tailGrowth)")
            return false
        case .rejected:
            LongCaptureDiagnostics.shared.log("tail.promoteRejected reason=\(reason) seq=\(pending.sequence) top=\(anchor.topOffset) tailGrowth=\(tailGrowth)")
            return false
        }
    }

    init(snapshot: ScreenSnapshot, selection: CGRect, excludedWindowIDs: [CGWindowID]) {
        self.snapshot = snapshot
        self.selection = selection
        self.excludedWindowIDs = Set(excludedWindowIDs)
    }

    convenience init(snapshot: ScreenSnapshot, selection: CGRect, overlayWindowID: CGWindowID) {
        self.init(snapshot: snapshot, selection: selection, excludedWindowIDs: [overlayWindowID])
    }

    func start() {
        guard let rawFirst = snapshot.crop(viewRect: selection) else { return }
        let geometry = captureGeometry(referencePixelSize: CGSize(width: rawFirst.width, height: rawFirst.height))
        let first = FrameStitcher.resizedCopy(
            rawFirst,
            width: Int(geometry.pixelSize.width),
            height: Int(geometry.pixelSize.height)
        ) ?? rawFirst

        isStopping = false
        finishRequested = false
        finishCompletion = nil
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        lastPreviewFlushTime = ProcessInfo.processInfo.systemUptime
        previewGeneration = 0
        previewRenderInFlight = false
        previewRenderPending = false
        lastPreviewRenderedContentHeight = 0
        lastPreviewRenderedPlacementCount = 0
        lastPreviewRenderedTime = 0

        let accumulator = LongCaptureCanvasAccumulator(firstFrame: first, maximumHeight: maximumOutputHeight)
        canvasAccumulator = accumulator
        previewStore = LongCapturePreviewCoverageStore(firstFrame: first, targetWidth: previewMaximumWidth)
        acceptedFrameCount = 1
        let firstSignature = FrameMatcher.signature(first)
        let firstAnchor = LongCaptureFrameAnchor(
            image: first,
            signature: firstSignature,
            topOffset: 0,
            scrollPosition: 0
        )
        lastRawAnchor = firstAnchor
        canvasAnchor = firstAnchor
        latestObservedFrame = first
        latestObservedSequence = 0
        lastAcceptedSequence = 0
        latestObservedScrollPosition = 0
        trackingLost = false
        totalObservedScroll = 0
        acceptedScrollPosition = 0
        acceptedOutputHeight = first.height
        consecutivePoorMatches = 0
        scrollPixelsPerPoint = 0
        fallbackCooldownFrames = 0
        matchInFlight = false
        pendingFrameQueue = []
        gatedFrameCount = 0
        queuedFrameCount = 0
        skippedTooCloseCount = 0
        rejectedPlacementCount = 0
        poorMatchCount = 0
        compactedQueueCount = 0
        droppedBacklogFrameCount = 0
        bottomNoVisualProgressCount = 0
        reachedVisualEnd = false
        reachedVisualEndScrollPosition = 0
        lastUnplacedAcceptedTail = nil
        lastFrameAttemptTime = Date.distantPast
        lastQueuedScrollPosition = 0
        LongCaptureDiagnostics.shared.log("service.start selection=\(LCFormatRect(selection)) rawFirst=\(rawFirst.width)x\(rawFirst.height) normalizedFirst=\(first.width)x\(first.height) sourceRect=\(LCFormatRect(geometry.sourceRect)) pixelSize=\(LCFormatSize(geometry.pixelSize)) previewMax=\(previewMaximumWidth)x\(previewMaximumHeight) excludedWindowIDs=\(Array(excludedWindowIDs).sorted())")
        renderPreviewImmediately()
        installScrollMonitor()
        startCaptureStream(sourceRect: geometry.sourceRect, pixelSize: geometry.pixelSize)
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
        let alignedSourceRect = CGRect(
            x: pixelRect.minX / scaleX,
            y: pixelRect.minY / scaleY,
            width: pixelRect.width / scaleX,
            height: pixelRect.height / scaleY
        )
        return (
            alignedSourceRect,
            CGSize(width: max(2, pixelRect.width), height: max(2, pixelRect.height))
        )
    }

    private func startCaptureStream(sourceRect: CGRect, pixelSize: CGSize) {
        let stream = ScrollCaptureStream(
            displayID: snapshot.displayID,
            sourceRect: sourceRect,
            pixelSize: pixelSize,
            excludedWindowIDs: excludedWindowIDs
        )
        stream.onFrame = { [weak self] image, sequence in
            DispatchQueue.main.async { self?.receiveStreamFrame(image, sequence: sequence) }
        }
        stream.onError = { [weak self] error in
            DispatchQueue.main.async { self?.onStatus?("连续采集失败：\(error.localizedDescription)", true) }
        }
        captureStream = stream
        stream.start()
    }

    func finish(completion: @escaping (Result<CGImage, Error>) -> Void) {
        guard !finishRequested, !isStopping else { return }
        finishRequested = true
        finishCompletion = completion
        let latestAlreadyQueued = pendingFrameQueue.contains(where: { $0.sequence == latestObservedSequence })
        let latestAlreadyAccepted = latestObservedSequence <= lastAcceptedSequence
        let latestScrollGap = max(0, latestObservedScrollPosition - acceptedScrollPosition)
        if let latestObservedFrame,
           !latestAlreadyQueued,
           !latestAlreadyAccepted,
           latestScrollGap >= 4 {
            enqueueOrProcess(StreamFrameCandidate(
                image: latestObservedFrame,
                scrollPosition: latestObservedScrollPosition,
                sequence: latestObservedSequence
            ))
            LongCaptureDiagnostics.shared.log("finish.enqueueLatest seq=\(latestObservedSequence) scrollGap=\(String(format: "%.2f", Double(latestScrollGap)))")
        } else {
            LongCaptureDiagnostics.shared.log("finish.skipLatest seq=\(latestObservedSequence) alreadyAccepted=\(latestAlreadyAccepted) alreadyQueued=\(latestAlreadyQueued) scrollGap=\(String(format: "%.2f", Double(latestScrollGap)))")
        }
        LongCaptureDiagnostics.shared.log("finish.request latestSeq=\(latestObservedSequence) lastAcceptedSeq=\(lastAcceptedSequence) pending=\(pendingFrameQueue.count) inFlight=\(matchInFlight) acceptedFrames=\(acceptedFrameCount) acceptedHeight=\(acceptedOutputHeight) totalScroll=\(String(format: "%.2f", Double(totalObservedScroll)))")
        if pendingFrameQueue.count > 12 {
            let before = pendingFrameQueue.count
            pendingFrameQueue = Array(pendingFrameQueue.suffix(12))
            LongCaptureDiagnostics.shared.log("finish.trimPendingForPreview before=\(before) kept=\(pendingFrameQueue.count) first=\(pendingFrameQueue.first?.sequence ?? -1) last=\(pendingFrameQueue.last?.sequence ?? -1)")
        }
        // v8：点击完成时先把当前已经接受的低分辨率预览同步刷出来；
        // 后续 pending 帧继续处理，但 UI 不再等 backlog 才更新预览。
        renderPreviewImmediately()
        captureStream?.stop()
        captureStream = nil
        removeScrollMonitor()
        onStatus?(pendingFrameQueue.isEmpty && !matchInFlight
            ? "正在生成长图…"
            : "正在处理最后 \(pendingFrameQueue.count + (matchInFlight ? 1 : 0)) 帧…", false)
        finishIfQueueDrained()
    }

    func cancel() {
        LongCaptureDiagnostics.shared.log("service.cancel pending=\(pendingFrameQueue.count) inFlight=\(matchInFlight) acceptedFrames=\(acceptedFrameCount) acceptedHeight=\(acceptedOutputHeight)")
        isStopping = true
        finishRequested = false
        finishCompletion = nil
        captureStream?.stop()
        captureStream = nil
        removeScrollMonitor()
        pendingFrameQueue = []
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        previewStore = nil
        previewRenderInFlight = false
        previewRenderPending = false
        lastPreviewRenderedContentHeight = 0
        lastPreviewRenderedPlacementCount = 0
        lastPreviewRenderedTime = 0
        lastUnplacedAcceptedTail = nil
        scrollPixelsPerPoint = 0
        fallbackCooldownFrames = 0
    }

    private func receiveStreamFrame(_ rawCurrent: CGImage, sequence: Int) {
        guard !isStopping, !finishRequested, let accumulator = canvasAccumulator else { return }
        let current: CGImage
        if rawCurrent.width == accumulator.width, rawCurrent.height == accumulator.frameHeight {
            current = rawCurrent
        } else if abs(rawCurrent.width - accumulator.width) <= 4,
                  abs(rawCurrent.height - accumulator.frameHeight) <= 4,
                  let resized = FrameStitcher.resizedCopy(rawCurrent, width: accumulator.width, height: accumulator.frameHeight) {
            current = resized
        } else {
            LongCaptureDiagnostics.shared.log("receive.sizeMismatch seq=\(sequence) raw=\(rawCurrent.width)x\(rawCurrent.height) expected=\(accumulator.width)x\(accumulator.frameHeight)")
            return
        }

        latestObservedFrame = current
        latestObservedSequence = sequence
        latestObservedScrollPosition = totalObservedScroll
        guard acceptedOutputHeight < maximumOutputHeight else {
            LongCaptureDiagnostics.shared.log("receive.maxHeight seq=\(sequence) acceptedHeight=\(acceptedOutputHeight) max=\(maximumOutputHeight)")
            onStatus?("已达到长图安全高度，请点击 ✓ 完成当前长图", false)
            return
        }

        let now = Date()
        let measuredScroll = max(0, totalObservedScroll - lastQueuedScrollPosition)

        // v16：已经确认到底后，继续向下滚动不会产生新内容，只会让弱纹理/NCC
        // 在底部重复内容上反复找“新锚点”。直接消费滚轮并忽略帧，避免短图尾部重复。
        if reachedVisualEnd, measuredScroll >= 0.5 {
            lastQueuedScrollPosition = totalObservedScroll
            acceptedScrollPosition = max(acceptedScrollPosition, totalObservedScroll)
            trackingLost = false
            consecutivePoorMatches = 0
            fallbackCooldownFrames = 0
            gatedFrameCount += 1
            if gatedFrameCount <= 5 || gatedFrameCount % 30 == 0 {
                LongCaptureDiagnostics.shared.log("receive.endLocked seq=\(sequence) measuredScroll=\(String(format: "%.2f", Double(measuredScroll))) totalScroll=\(String(format: "%.2f", Double(totalObservedScroll))) contentHeight=\(accumulator.contentHeight) endScroll=\(String(format: "%.2f", Double(reachedVisualEndScrollPosition)))")
            }
            return
        }

        let elapsed = now.timeIntervalSince(lastFrameAttemptTime)
        // 不再把滚轮 delta 当作硬门槛。ScreenSnap 的做法是用它做弱先验。
        // 但我们的 Swift matcher 没有 ScreenSnap 的 vDSP 速度，采样频率必须贴合吞吐，
        // 否则只会把队列塞爆，预览也会跟着滞后。
        // v15：丢锚时不能因为 trackingLost 直接放行 60fps 原始帧。
        // v14 后半段卡 3～4 秒的根因就是 trackingLost 后队列继续灌入大量几乎相同的帧，
        // matcher 在用户已经停下以后还要慢慢消化旧帧。ScreenSnap 的预览是粗颗粒状态机，
        // 丢锚恢复也要按低频探测，而不是逐帧硬追。
        let targetSamplingFPS = trackingLost ? 12.0 : 18.0
        let enoughTimePassed = elapsed >= (1.0 / targetSamplingFPS)
        let motionReady = measuredScroll >= 0.5 && enoughTimePassed
        let hasScrolledSinceAnchor = totalObservedScroll > (lastRawAnchor?.scrollPosition ?? acceptedScrollPosition) + 0.25
        let idleProbe = elapsed >= 0.10 && hasScrolledSinceAnchor && !matchInFlight && pendingFrameQueue.isEmpty
        let recoveryProbe = trackingLost && enoughTimePassed && (measuredScroll >= 0.25 || pendingFrameQueue.isEmpty)
        guard motionReady || idleProbe || recoveryProbe else {
            gatedFrameCount += 1
            if gatedFrameCount <= 5 || gatedFrameCount % 90 == 0 {
                LongCaptureDiagnostics.shared.log("receive.gate seq=\(sequence) gated=\(gatedFrameCount) measuredScroll=\(String(format: "%.2f", Double(measuredScroll))) totalScroll=\(String(format: "%.2f", Double(totalObservedScroll))) elapsed=\(String(format: "%.3f", elapsed)) queue=\(pendingFrameQueue.count)")
            }
            return
        }

        lastFrameAttemptTime = now
        lastQueuedScrollPosition = totalObservedScroll
        queuedFrameCount += 1
        if queuedFrameCount <= 8 || queuedFrameCount % 30 == 0 {
            LongCaptureDiagnostics.shared.log("receive.queue seq=\(sequence) queued=\(queuedFrameCount) measuredScroll=\(String(format: "%.2f", Double(measuredScroll))) totalScroll=\(String(format: "%.2f", Double(totalObservedScroll))) queue=\(pendingFrameQueue.count) inFlight=\(matchInFlight) motionReady=\(motionReady) idleProbe=\(idleProbe)")
        }
        enqueueOrProcess(StreamFrameCandidate(image: current, scrollPosition: totalObservedScroll, sequence: sequence))
    }

    /// v8：预览慢的根因不是小图合成，而是 matcher backlog。
    /// 队列如果积压上百帧，预览只能跟着旧 accepted frame 慢慢追。
    /// 这里在入队阶段就把 backlog 控制住：保留少量连续桥接帧 + 均匀抽样 + 最新帧。
    private func trimPendingQueueForLatencyIfNeeded(reason: String) {
        // v15：正常跟踪时保留少量桥接帧；丢锚以后队列必须更小，
        // 否则预览会等 matcher 把几十个旧帧全部跑完才追到最新。
        let hardLimit = trackingLost ? min(maximumPendingFrames, 14) : maximumPendingFrames
        guard pendingFrameQueue.count > hardLimit else { return }
        let original = pendingFrameQueue
        var kept: [StreamFrameCandidate] = []
        var seen = Set<Int>()

        func keep(_ item: StreamFrameCandidate) {
            if !seen.contains(item.sequence) {
                kept.append(item)
                seen.insert(item.sequence)
            }
        }

        // 旧锚点附近保留连续桥，避免 matcher 立刻断链。
        let prefixCount = trackingLost ? 3 : 5
        for item in original.prefix(prefixCount) { keep(item) }

        // 中间做均匀抽样，避免快速滚动时整段过渡帧被切没。
        let middleBudget = trackingLost ? 3 : 8
        if original.count > prefixCount + 12, middleBudget > 0 {
            let start = prefixCount
            let end = max(start, original.count - 12)
            let span = max(1, end - start)
            if span <= middleBudget {
                for item in original[start..<end] { keep(item) }
            } else {
                for i in 0..<middleBudget {
                    let index = start + min(span - 1, Int(round(Double(i) * Double(span - 1) / Double(max(1, middleBudget - 1)))))
                    keep(original[index])
                }
            }
        }

        // 最新帧必须保留，否则用户停下后预览还在处理旧画面。
        for item in original.suffix(trackingLost ? 8 : 12) { keep(item) }

        kept.sort { $0.sequence < $1.sequence }
        if kept.count > hardLimit {
            let prefix = Array(kept.prefix(prefixCount))
            let suffix = Array(kept.suffix(max(1, hardLimit - prefix.count)))
            kept = prefix + suffix
        }
        pendingFrameQueue = kept
        LongCaptureDiagnostics.shared.log("queue.trimForLatency reason=\(reason) before=\(original.count) kept=\(pendingFrameQueue.count) first=\(pendingFrameQueue.first?.sequence ?? -1) last=\(pendingFrameQueue.last?.sequence ?? -1) trackingLost=\(trackingLost)")
    }

    private func enqueueOrProcess(_ candidate: StreamFrameCandidate) {
        if matchInFlight {
            pendingFrameQueue.append(candidate)
            let queueLimit = trackingLost ? min(maximumPendingFrames, 14) : maximumPendingFrames
            if pendingFrameQueue.count > queueLimit {
                trimPendingQueueForLatencyIfNeeded(reason: "enqueue")
            }
            if pendingFrameQueue.count == queueLimit || pendingFrameQueue.count % 8 == 0 {
                LongCaptureDiagnostics.shared.log("queue.depth seq=\(candidate.sequence) depth=\(pendingFrameQueue.count) max=\(queueLimit) trackingLost=\(trackingLost)")
            }
            return
        }
        processCandidateFrame(candidate)
    }

    /// 队列满时不能把靠近当前锚点的“桥接帧”挤掉。ScreenSnap 的 ScrollStitcher
    /// 也是先保证连续帧链不断，再让最新帧慢慢追上；否则快滚后只剩远距离帧，NCC 必断。
    private func compactPendingFramesAndAppend(_ candidate: StreamFrameCandidate) {
        guard !pendingFrameQueue.isEmpty else {
            pendingFrameQueue.append(candidate)
            return
        }

        if trackingLost, pendingFrameQueue.count >= maximumPendingFrames {
            // 丢锚以后不能一直保留旧 backlog、丢掉新帧。日志里的
            // queue.dropWhileLost 正是卡死的原因：matcher 反复处理旧帧，
            // 最新画面永远进不了恢复链。这里保留少量靠近旧锚点的桥接帧，
            // 同时不断让最新帧进入队列，才能在用户停下/减速后重新接上。
            let protectedPrefix = min(12, max(0, pendingFrameQueue.count - 1))
            let removalIndex = min(protectedPrefix, pendingFrameQueue.count - 1)
            let removed = pendingFrameQueue.remove(at: removalIndex)
            pendingFrameQueue.append(candidate)
            droppedBacklogFrameCount += 1
            if droppedBacklogFrameCount <= 5 || droppedBacklogFrameCount % 20 == 0 {
                LongCaptureDiagnostics.shared.log("queue.compactWhileLost newSeq=\(candidate.sequence) removedSeq=\(removed.sequence) removedIndex=\(removalIndex) protectedPrefix=\(protectedPrefix) compactedWhileLost=\(droppedBacklogFrameCount) depth=\(pendingFrameQueue.count) bridgeFrom=\(pendingFrameQueue.first?.sequence ?? -1) latest=\(pendingFrameQueue.last?.sequence ?? -1)")
            }
            return
        }

        let protectedPrefix = trackingLost
            ? min(12, max(0, pendingFrameQueue.count - 1))
            : min(28, max(0, pendingFrameQueue.count - 1))
        var previousPosition = protectedPrefix == 0
            ? (lastRawAnchor?.scrollPosition ?? 0)
            : pendingFrameQueue[protectedPrefix - 1].scrollPosition
        var smallestGap = CGFloat.greatestFiniteMagnitude
        var removalIndex = protectedPrefix
        if protectedPrefix < pendingFrameQueue.count {
            for index in protectedPrefix..<pendingFrameQueue.count {
                let queued = pendingFrameQueue[index]
                let gap = max(0, queued.scrollPosition - previousPosition)
                if gap < smallestGap {
                    smallestGap = gap
                    removalIndex = index
                }
                previousPosition = queued.scrollPosition
            }
        } else {
            smallestGap = 0
            removalIndex = pendingFrameQueue.count - 1
        }

        let removed = pendingFrameQueue[removalIndex]
        pendingFrameQueue.remove(at: removalIndex)
        pendingFrameQueue.append(candidate)
        compactedQueueCount += 1
        LongCaptureDiagnostics.shared.log("queue.compact newSeq=\(candidate.sequence) removedSeq=\(removed.sequence) removedIndex=\(removalIndex) protectedPrefix=\(protectedPrefix) compacted=\(compactedQueueCount) depth=\(pendingFrameQueue.count) smallestGap=\(String(format: "%.2f", Double(smallestGap)))")
    }

    private func processCandidateFrame(_ candidate: StreamFrameCandidate) {
        guard !isStopping, let lastRawAnchor else { return }
        matchInFlight = true

        let current = candidate.image
        let cachedCanvasAnchor = canvasAnchor
        let pxPerPoint = scrollPixelsPerPoint
        // 一旦已经丢锚或正在恢复，必须允许无先验兜底搜索。
        // 旧版每次匹配超过 15ms 就禁用 fallback 120 帧，快速滚动时会导致
        // “只按已经漂移的滚轮先验找”，从而一直恢复不了。
        let cooldown = (trackingLost || consecutivePoorMatches > 0) ? 0 : fallbackCooldownFrames
        if fallbackCooldownFrames > 0 { fallbackCooldownFrames -= 1 }
        LongCaptureDiagnostics.shared.log("match.start seq=\(candidate.sequence) lastTop=\(lastRawAnchor.topOffset) canvasTop=\(cachedCanvasAnchor?.topOffset ?? -1) candScroll=\(String(format: "%.2f", Double(candidate.scrollPosition))) pxPerPoint=\(String(format: "%.3f", Double(pxPerPoint))) cooldown=\(cooldown) queue=\(pendingFrameQueue.count) poor=\(consecutivePoorMatches) trackingLost=\(trackingLost)")
        let currentConsecutivePoorMatches = consecutivePoorMatches
        let selectionHeight = max(1, selection.height)
        let currentlyLost = trackingLost

        matchQueue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let currentSignature = FrameMatcher.signature(current)
            let result = Self.evaluateCandidate(
                frame: current,
                frameSignature: currentSignature,
                lastAnchor: lastRawAnchor,
                canvasAnchor: cachedCanvasAnchor,
                candidateScrollPosition: candidate.scrollPosition,
                selectionHeight: selectionHeight,
                consecutivePoorMatches: currentConsecutivePoorMatches,
                recovering: currentlyLost,
                scrollPixelsPerPoint: pxPerPoint,
                fallbackCooldownFrames: cooldown
            )
            let durationMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
            DispatchQueue.main.async {
                self?.applyCandidateResult(
                    result,
                    candidate: candidate,
                    signature: currentSignature,
                    matchDurationMS: durationMS
                )
            }
        }
    }

    private func applyCandidateResult(
        _ result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        signature: FrameMatcher.FrameSignature?,
        matchDurationMS: Double
    ) {
        defer {
            matchInFlight = false
            if !isStopping, !pendingFrameQueue.isEmpty {
                let next = pendingFrameQueue.removeFirst()
                processCandidateFrame(next)
            } else if finishRequested {
                finishIfQueueDrained()
            }
        }
        guard !isStopping else { return }
        if trackingLost || consecutivePoorMatches > 0 {
            // 恢复阶段宁可多花一点计算，也不能禁用 fallback；否则会一直跟着错误先验走。
            fallbackCooldownFrames = 0
        } else if matchDurationMS > 55, pendingFrameQueue.count > maximumPendingFrames / 2 {
            // 只有在队列明显积压时才短暂降载。旧版固定 120 帧太长，
            // 快速滚动时几乎等于永久关闭兜底搜索。
            fallbackCooldownFrames = max(fallbackCooldownFrames, 4)
            LongCaptureDiagnostics.shared.log("match.cooldown seq=\(candidate.sequence) durationMS=\(String(format: "%.1f", matchDurationMS)) cooldown=4")
        }
        let previousAnchor = lastRawAnchor
        let lastTopForLog = previousAnchor?.topOffset
        let canvasTopForLog = canvasAnchor?.topOffset
        let lastScrollForLog = previousAnchor?.scrollPosition
        if let debug = result.debug {
            LongCaptureDiagnostics.shared.log("match.result seq=\(candidate.sequence) accepted=\(result.accepted) poorMatch=\(result.poorMatch) placeAllowed=\(result.allowCanvasPlacement) top=\(result.topOffset) move=\(result.movementPixels) \(debug.logSuffix(lastTop: lastTopForLog, canvasTop: canvasTopForLog, candScroll: candidate.scrollPosition, lastScroll: lastScrollForLog, poor: consecutivePoorMatches, recovering: trackingLost))")
        } else {
            LongCaptureDiagnostics.shared.log("match.result seq=\(candidate.sequence) accepted=\(result.accepted) poorMatch=\(result.poorMatch) placeAllowed=\(result.allowCanvasPlacement) top=\(result.topOffset) move=\(result.movementPixels)")
        }

        // v21：只要尾部已经锁定，所有已经排队但尚未处理的旧帧都必须丢弃。
        // v20 只在 accepted 分支里挡住，poor/softTrack 仍可能把 raw anchor 推到尾部之外，
        // 最后造成重复追加或错排。这里在分支之前统一处理。
        if reachedVisualEnd, !finishRequested {
            lastAcceptedSequence = max(lastAcceptedSequence, candidate.sequence)
            acceptedScrollPosition = max(acceptedScrollPosition, candidate.scrollPosition)
            lastQueuedScrollPosition = max(lastQueuedScrollPosition, candidate.scrollPosition)
            trackingLost = false
            consecutivePoorMatches = 0
            fallbackCooldownFrames = 0
            if !pendingFrameQueue.isEmpty {
                LongCaptureDiagnostics.shared.log("match.dropQueueAfterEnd seq=\(candidate.sequence) dropped=\(pendingFrameQueue.count)")
                pendingFrameQueue.removeAll()
            }
            LongCaptureDiagnostics.shared.log("match.ignoredAfterEnd seq=\(candidate.sequence) accepted=\(result.accepted) poor=\(result.poorMatch) top=\(result.topOffset) move=\(result.movementPixels) endScroll=\(String(format: "%.2f", Double(reachedVisualEndScrollPosition)))")
            onStatus?("页面已到底，已忽略后续重复帧", false)
            return
        }

        if result.consumeScrollOnly {
            // 画面没变时只消费弱先验，不推进图像坐标。这样到底后不会把同一段内容
            // 反复拼到尾部，同时下一帧的滚轮先验也不会无限变大。
            if let previousAnchor {
                lastRawAnchor = LongCaptureFrameAnchor(
                    image: previousAnchor.image,
                    signature: previousAnchor.signature,
                    topOffset: previousAnchor.topOffset,
                    scrollPosition: candidate.scrollPosition
                )
            }
            lastAcceptedSequence = candidate.sequence
            acceptedScrollPosition = max(acceptedScrollPosition, candidate.scrollPosition)
            lastQueuedScrollPosition = max(lastQueuedScrollPosition, candidate.scrollPosition)
            bottomNoVisualProgressCount += 1
            if bottomNoVisualProgressCount >= 3, let accumulator = canvasAccumulator {
                LongCaptureDiagnostics.shared.log("scroll.consumeOnly seq=\(candidate.sequence) bottomNoProgress=\(bottomNoVisualProgressCount) reachedEnd=true totalScroll=\(String(format: "%.2f", Double(candidate.scrollPosition))) lastTop=\(previousAnchor?.topOffset ?? -1)")
                lockReachedVisualEnd(
                    reason: "stillFrameNoProgress",
                    candidate: candidate,
                    result: result,
                    contentHeight: accumulator.contentHeight
                )
                return
            }
            LongCaptureDiagnostics.shared.log("scroll.consumeOnly seq=\(candidate.sequence) bottomNoProgress=\(bottomNoVisualProgressCount) reachedEnd=\(reachedVisualEnd) totalScroll=\(String(format: "%.2f", Double(candidate.scrollPosition))) lastTop=\(previousAnchor?.topOffset ?? -1)")
            if let status = result.status { onStatus?(status, false) }
            return
        }

        if result.accepted, let accumulator = canvasAccumulator {
            // v16：如果队列里还有“确认到底之前”已经进来的帧，它们可能在 reachedVisualEnd
            // 之后才跑出 accepted。此时绝不能再写 canvas，否则就会出现短图底部重复。
            if reachedVisualEnd, !finishRequested {
                lastAcceptedSequence = candidate.sequence
                acceptedScrollPosition = max(acceptedScrollPosition, candidate.scrollPosition)
                lastQueuedScrollPosition = max(lastQueuedScrollPosition, candidate.scrollPosition)
                trackingLost = false
                consecutivePoorMatches = 0
                fallbackCooldownFrames = 0
                LongCaptureDiagnostics.shared.log("match.acceptedIgnoredAfterEnd seq=\(candidate.sequence) top=\(result.topOffset) move=\(result.movementPixels) contentHeight=\(accumulator.contentHeight) totalScroll=\(String(format: "%.2f", Double(candidate.scrollPosition)))")
                onStatus?("页面已到底，已忽略后续重复帧", false)
                return
            }

            let rawTopOffset = min(
                maximumOutputHeight - candidate.image.height,
                max(0, result.topOffset)
            )
            let placementTopOffset = normalizedTopOffsetForCanvasPlacement(
                rawTopOffset: rawTopOffset,
                frameHeight: candidate.image.height,
                contentHeight: accumulator.contentHeight,
                sequence: candidate.sequence
            )
            let previousPoorCountBeforeAccept = consecutivePoorMatches
            if shouldIgnoreAcceptedAfterBottomLikeRecovery(
                result: result,
                candidate: candidate,
                accumulator: accumulator,
                rawTopOffset: rawTopOffset,
                previousPoorCount: previousPoorCountBeforeAccept
            ) {
                lockReachedVisualEnd(
                    reason: "acceptedAfterBottomLikeRecovery",
                    candidate: candidate,
                    result: result,
                    contentHeight: accumulator.contentHeight
                )
                LongCaptureDiagnostics.shared.log("match.acceptedIgnoredAsBottomDuplicate seq=\(candidate.sequence) top=\(rawTopOffset) poorBefore=\(previousPoorCountBeforeAccept) contentHeight=\(accumulator.contentHeight) scroll=\(String(format: "%.2f", Double(candidate.scrollPosition)))")
                return
            }
            if appendConservativeShortRangeBottomTailIfNeeded(
                result: result,
                candidate: candidate,
                accumulator: accumulator,
                rawTopOffset: rawTopOffset,
                placementTopOffset: placementTopOffset,
                signature: signature
            ) {
                return
            }
            let rawAnchor = LongCaptureFrameAnchor(
                image: candidate.image,
                signature: signature,
                topOffset: placementTopOffset,
                scrollPosition: candidate.scrollPosition
            )
            let rawAnchorBeforeAccept = lastRawAnchor

            if let previousAnchor {
                let scrollDelta = candidate.scrollPosition - previousAnchor.scrollPosition
                if scrollDelta > 1.0, result.movementPixels >= 3 {
                    let ratio = CGFloat(result.movementPixels) / scrollDelta
                    if ratio.isFinite, ratio > 0, ratio <= 8 {
                        if scrollPixelsPerPoint <= 0 {
                            scrollPixelsPerPoint = ratio
                        } else {
                            scrollPixelsPerPoint = scrollPixelsPerPoint * 0.9 + ratio * 0.1
                        }
                    }
                }
            }

            lastRawAnchor = rawAnchor
            lastAcceptedSequence = candidate.sequence
            acceptedScrollPosition = candidate.scrollPosition
            trackingLost = false
            consecutivePoorMatches = 0
            bottomNoVisualProgressCount = 0
            reachedVisualEnd = false

            guard result.allowCanvasPlacement else {
                lastUnplacedAcceptedTail = nil
                onStatus?(result.status ?? "正在跟踪滚动…", false)
                return
            }

            let minPlacementStep = minimumCanvasPlacementStep(frameHeight: candidate.image.height)
            let shouldForceFinalTail = finishRequested
            let placementResult = accumulator.place(
                candidate.image,
                topOffset: placementTopOffset,
                minimumStep: minPlacementStep,
                force: shouldForceFinalTail,
                signature: signature
            )

            switch placementResult {
            case let .placed(sourceStart, sourceHeight):
                canvasAnchor = rawAnchor
                lastUnplacedAcceptedTail = nil
                LongCaptureDiagnostics.shared.log("canvas.place seq=\(candidate.sequence) top=\(placementTopOffset) move=\(result.movementPixels) sourceStart=\(sourceStart) sourceHeight=\(sourceHeight) contentHeight=\(accumulator.contentHeight) frameCount=\(accumulator.frameCount) placements=\(accumulator.placementCount) previewPlacements=\(previewStore?.placementCount ?? -1) minStep=\(minPlacementStep) pxPerPoint=\(String(format: "%.3f", Double(scrollPixelsPerPoint)))")
                previewStore?.place(
                    candidate.image,
                    topOffset: placementTopOffset,
                    sourceStart: sourceStart,
                    sourceHeight: sourceHeight
                )
                acceptedOutputHeight = accumulator.contentHeight
                acceptedFrameCount = accumulator.frameCount
                schedulePreviewRender()
                onStatus?(result.status ?? "已采集 \(acceptedFrameCount) 帧", false)
            case .skippedTooClose:
                skippedTooCloseCount += 1
                let tailGrowth = placementTopOffset + candidate.image.height - accumulator.contentHeight
                if tailGrowth > 0 {
                    lastUnplacedAcceptedTail = PendingAcceptedTail(
                        anchor: rawAnchor,
                        sequence: candidate.sequence,
                        movementPixels: result.movementPixels,
                        visualDelta: result.debug?.visualDelta ?? 0,
                        matchScore: result.debug?.localScore,
                        matchMargin: result.debug?.localMargin
                    )
                }
                acceptedOutputHeight = max(acceptedOutputHeight, placementTopOffset + candidate.image.height)
                LongCaptureDiagnostics.shared.log("canvas.skipTooClose seq=\(candidate.sequence) top=\(placementTopOffset) lastPlaced=\(accumulator.lastPlacedTopOffset) contentHeight=\(accumulator.contentHeight) skipped=\(skippedTooCloseCount) minStep=\(minPlacementStep) tailGrowth=\(tailGrowth)")
                onStatus?("正在跟踪滚动…已采集 \(acceptedFrameCount) 帧", false)
            case .skippedDuplicate:
                skippedTooCloseCount += 1
                lastUnplacedAcceptedTail = nil
                LongCaptureDiagnostics.shared.log("canvas.skipDuplicate seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(accumulator.contentHeight) minStep=\(minPlacementStep)")
                onStatus?("已跳过重复尾部帧，继续滚动…", false)
            case .rejected:
                // v18：画布拒绝写入时，不能把 lastRawAnchor 留在这个已被拒绝的 top 上。
                // 否则 matcher 会继续从“画布前方很远的位置”往下追，后续即使用户停住也无法恢复，
                // 表现为长截图截到中途断掉。恢复到进入本次 accepted 前的 raw anchor。
                lastRawAnchor = rawAnchorBeforeAccept
                rejectedPlacementCount += 1
                trackingLost = true
                consecutivePoorMatches += 1
                LongCaptureDiagnostics.shared.log("canvas.rejected seq=\(candidate.sequence) rawTop=\(rawTopOffset) top=\(placementTopOffset) lastPlaced=\(accumulator.lastPlacedTopOffset) contentHeight=\(accumulator.contentHeight) rejected=\(rejectedPlacementCount)")
                onStatus?("检测到非单调锚点，已跳过这一帧", false)
            }
            return
        }

        if result.poorMatch {
            poorMatchCount += 1
            consecutivePoorMatches += 1
            if let accumulator = canvasAccumulator,
               shouldLockVisualEndAfterRepeatedPoor(
                result: result,
                candidate: candidate,
                accumulator: accumulator
               ) {
                lockReachedVisualEnd(
                    reason: "repeatedPoorTail",
                    candidate: candidate,
                    result: result,
                    contentHeight: accumulator.contentHeight
                )
                return
            }
            if promoteWeakOverlapBridgeIfNeeded(
                result: result,
                candidate: candidate,
                signature: signature
            ) {
                return
            }
            trackingLost = true
            let status = consecutivePoorMatches >= 6
                ? "持续跟不上当前内容，请稍微往回滚动一点恢复锚点"
                : (result.status ?? "暂未找到可靠锚点，继续滚动时会自动恢复")
            rememberRejectedTailCandidateIfNeeded(
                result: result,
                candidate: candidate,
                signature: signature
            )

            let didSoftTrack = softAdvanceTrackingAnchorIfNeeded(
                result: result,
                candidate: candidate,
                signature: signature
            )
            if didSoftTrack {
                // raw anchor 已经推进，下一帧会从新画面继续匹配；canvas 不写弱帧。
                // 保留 trackingLost=true/consecutivePoorMatches，用于继续放开 fallback。
            }

            if false, !finishRequested, consecutivePoorMatches >= 8,
               promotePendingTailForRecoveryIfNeeded(reason: "lostRecovery") {
                LongCaptureDiagnostics.shared.log("match.recoveredByPromotedTail seq=\(candidate.sequence) queue=\(pendingFrameQueue.count)")
                return
            }

            if finishRequested, consecutivePoorMatches >= 8 {
                LongCaptureDiagnostics.shared.log("finish.dropPoorTail seq=\(candidate.sequence) poor=\(consecutivePoorMatches) dropped=\(pendingFrameQueue.count) rememberedTail=\(lastUnplacedAcceptedTail != nil)")
                pendingFrameQueue.removeAll()
            } else if consecutivePoorMatches >= 6, pendingFrameQueue.count > 8 {
                let before = pendingFrameQueue.count
                trimPendingQueueForLatencyIfNeeded(reason: "poor")
                // 如果已经连续丢锚，继续处理几十个旧帧只会让预览在用户停下后慢慢追。
                // 保留最新几帧，让恢复直接朝当前画面靠近。
                if consecutivePoorMatches >= 8, pendingFrameQueue.count > 6 {
                    pendingFrameQueue = Array(pendingFrameQueue.suffix(6))
                }
                LongCaptureDiagnostics.shared.log("queue.trimAfterPoorUniform seq=\(candidate.sequence) poor=\(consecutivePoorMatches) before=\(before) kept=\(pendingFrameQueue.count) first=\(pendingFrameQueue.first?.sequence ?? -1) last=\(pendingFrameQueue.last?.sequence ?? -1)")
            }
            LongCaptureDiagnostics.shared.log("match.poor seq=\(candidate.sequence) poorCount=\(poorMatchCount) consecutivePoor=\(consecutivePoorMatches) queue=\(pendingFrameQueue.count) status=\(status)")
            onStatus?(status, false)
        } else if let status = result.status {
            onStatus?(status, false)
        }
    }


    /// v6：参考 ScreenSnap 的核心思路：丢锚时可以推进“跟踪锚点”，但不能把弱帧写入画布。
    /// 之前的 tail.promoteRecovery 是把弱锚点直接提交到 canvas，容易造成跳段和尾部重复；
    /// 正确做法是只更新 lastRawAnchor/lastRawSig，让下一帧继续从新画面附近匹配。
    @discardableResult
    private func softAdvanceTrackingAnchorIfNeeded(
        result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        signature: FrameMatcher.FrameSignature?
    ) -> Bool {
        guard let accumulator = canvasAccumulator else { return false }
        guard result.poorMatch, result.movementPixels > 0 else { return false }
        let rawTopOffset = min(
            maximumOutputHeight - candidate.image.height,
            max(0, result.topOffset)
        )
        guard rawTopOffset + 1 >= (lastRawAnchor?.topOffset ?? 0) else { return false }

        let frameHeight = candidate.image.height
        let overlap = result.debug?.localOverlap ?? 0
        let score = result.debug?.localScore ?? 255
        let margin = result.debug?.localMargin ?? 0
        let visualDelta = result.debug?.visualDelta ?? 0
        let movement = result.movementPixels

        // 只允许仍然和当前画布有重叠的弱帧推进 raw anchor。
        // 如果 rawTopOffset 已经超过 contentHeight，说明中间真断了，不能伪造连续性。
        let canvasOverlap = accumulator.contentHeight - rawTopOffset
        let hasUsefulCanvasOverlap = canvasOverlap >= max(180, Int(CGFloat(frameHeight) * 0.16))
        let isSmallForwardGap = canvasOverlap >= -96 && overlap >= Int(CGFloat(frameHeight) * 0.65) && score <= 45.0 && margin >= 18.0
        guard hasUsefulCanvasOverlap || isSmallForwardGap else {
            LongCaptureDiagnostics.shared.log("match.softRejectNoCanvasOverlap seq=\(candidate.sequence) top=\(rawTopOffset) contentHeight=\(accumulator.contentHeight) canvasOverlap=\(canvasOverlap) move=\(movement) score=\(String(format: "%.2f", score)) margin=\(String(format: "%.2f", margin)) visualDelta=\(String(format: "%.2f", visualDelta))")
            return false
        }

        // 对应 ScreenSnap 里 fallback 只在位移没有超过可见范围约 68% 时尝试。
        guard movement <= Int(CGFloat(frameHeight) * 0.68) else {
            LongCaptureDiagnostics.shared.log("match.softRejectTooFar seq=\(candidate.sequence) top=\(rawTopOffset) move=\(movement) frameHeight=\(frameHeight) score=\(String(format: "%.2f", score)) margin=\(String(format: "%.2f", margin))")
            return false
        }

        // 弱帧必须有基本可信度：NCC 不是完全离谱，或者候选分差较明显；
        // 但不要求达到正式落画布阈值，因为它不写入最终图。
        let plausibleScore = score <= 86.0 || margin >= 10.0
        let enoughOverlap = overlap >= max(260, Int(CGFloat(frameHeight) * 0.28))
        guard plausibleScore, enoughOverlap, visualDelta > 0.2 else {
            LongCaptureDiagnostics.shared.log("match.softRejectWeak seq=\(candidate.sequence) top=\(rawTopOffset) move=\(movement) overlap=\(overlap) score=\(String(format: "%.2f", score)) margin=\(String(format: "%.2f", margin)) visualDelta=\(String(format: "%.2f", visualDelta))")
            return false
        }

        lastRawAnchor = LongCaptureFrameAnchor(
            image: candidate.image,
            signature: signature,
            topOffset: rawTopOffset,
            scrollPosition: candidate.scrollPosition
        )
        lastAcceptedSequence = max(lastAcceptedSequence, candidate.sequence)
        lastQueuedScrollPosition = max(lastQueuedScrollPosition, candidate.scrollPosition)
        fallbackCooldownFrames = 0
        LongCaptureDiagnostics.shared.log("match.softTrack seq=\(candidate.sequence) top=\(rawTopOffset) move=\(movement) canvasOverlap=\(canvasOverlap) overlap=\(overlap) score=\(String(format: "%.2f", score)) margin=\(String(format: "%.2f", margin)) visualDelta=\(String(format: "%.2f", visualDelta)) poor=\(consecutivePoorMatches)")
        return true
    }

    /// 丢锚时不要立刻把尾部全部判死刑。日志里 seq=210 之后的帧虽然 NCC
    /// 分数不够“正式接受”，但它们仍然给出了单调的 topOffset，而且和当前画布
    /// 有几百像素 overlap。以前 finish.dropPoorTail 会把这批帧整段丢掉，最终
    /// 长图就直接缺尾巴。这里先记住一个“可疑但可作为最终尾巴”的候选；只有
    /// 用户点完成且后面没有更可靠帧时，才用 commitPendingTailIfNeeded(force)
    /// 把它补到画布末尾。
    private func rememberRejectedTailCandidateIfNeeded(
        result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        signature: FrameMatcher.FrameSignature?
    ) {
        // v6：rejected tail 不再用于最终提交。弱帧只允许 softTrack 推进 raw anchor，
        // 不能在 finish 阶段补画布，否则会再次出现 footer/license 重复或跳段。
        return
        guard let accumulator = canvasAccumulator else { return }
        guard result.movementPixels > 0 else { return }
        let rawTopOffset = min(
            maximumOutputHeight - candidate.image.height,
            max(0, result.topOffset)
        )
        let tailGrowth = rawTopOffset + candidate.image.height - accumulator.contentHeight
        guard tailGrowth >= 24 else { return }
        guard rawTopOffset + 1 >= accumulator.lastPlacedTopOffset,
              rawTopOffset <= accumulator.contentHeight else { return }

        let overlap = result.debug?.localOverlap ?? 0
        let score = result.debug?.localScore ?? 255
        let margin = result.debug?.localMargin ?? 0
        let visualDelta = result.debug?.visualDelta ?? 0
        let frameHeight = candidate.image.height

        // 约束要比正式落画布宽一点，但仍然排除明显错配：
        // 1. 必须和现有画布有足够 overlap；
        // 2. 分数不能离谱，或者候选分差足够明显；
        // 3. visualDelta 不能接近 0，否则可能只是到底后的重复静止帧。
        let enoughOverlap = overlap >= max(260, Int(CGFloat(frameHeight) * 0.28))
        let strongPlausible = score <= 72.0 || margin >= 12.0
        let emergencyBridgePlausible = score <= 84.0
            && margin >= 6.0
            && overlap >= Int(CGFloat(frameHeight) * 0.48)
        let scoreStillPlausible = strongPlausible || emergencyBridgePlausible
        // v4：低 visualDelta 的 tail 不再记录为可提交/可恢复尾巴。
        // 日志中的坏例子是 seq=208/211：visualDelta 约 6~7，score 很弱，
        // 但被 v3 记住并 promote，最终在 GitHub footer 后重复拼出 license badge。
        let hasRealVisualChange = visualDelta >= 10.0
        guard enoughOverlap, scoreStillPlausible, hasRealVisualChange else { return }

        let candidateBottom = rawTopOffset + candidate.image.height
        let existingBottom = lastUnplacedAcceptedTail.map { $0.anchor.topOffset + $0.anchor.image.height } ?? -1
        if candidateBottom + 2 < existingBottom { return }

        let anchor = LongCaptureFrameAnchor(
            image: candidate.image,
            signature: signature,
            topOffset: rawTopOffset,
            scrollPosition: candidate.scrollPosition
        )
        lastUnplacedAcceptedTail = PendingAcceptedTail(
            anchor: anchor,
            sequence: candidate.sequence,
            movementPixels: result.movementPixels,
            visualDelta: visualDelta,
            matchScore: score,
            matchMargin: margin
        )
        LongCaptureDiagnostics.shared.log("tail.rememberRejected seq=\(candidate.sequence) top=\(rawTopOffset) tailGrowth=\(tailGrowth) overlap=\(overlap) score=\(String(format: "%.2f", score)) margin=\(String(format: "%.2f", margin)) visualDelta=\(String(format: "%.2f", visualDelta)) contentHeight=\(accumulator.contentHeight)")
    }

    private func finishIfQueueDrained() {
        guard finishRequested, !matchInFlight, pendingFrameQueue.isEmpty,
              let completion = finishCompletion else { return }
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        LongCaptureDiagnostics.shared.log("finish.queueDrained acceptedFrames=\(acceptedFrameCount) acceptedHeight=\(acceptedOutputHeight) poor=\(poorMatchCount) skipped=\(skippedTooCloseCount) rejected=\(rejectedPlacementCount) compacted=\(compactedQueueCount)")

        finishCompletion = nil
        finishRequested = false
        isStopping = true

        // v20：先提交最后一个 skippedTooClose 的有效尾巴，再判断是否“没有滚动”。
        // 短页面只需要轻微滚动时，frameCount 可能暂时仍是 1；旧版先判 frameCount，
        // 会误报“需要滚动页面”。
        commitPendingTailIfNeeded(reason: "finish")

        guard let refreshedAccumulator = canvasAccumulator else {
            completion(.failure(LongCaptureError.captureFailed))
            return
        }

        if refreshedAccumulator.frameCount <= 1 {
            let userDidScroll = totalObservedScroll >= 6 || skippedTooCloseCount > 0
            guard userDidScroll else {
                isStopping = false
                installScrollMonitor()
                if let first = latestObservedFrame {
                    let geometry = captureGeometry(referencePixelSize: CGSize(width: first.width, height: first.height))
                    startCaptureStream(sourceRect: geometry.sourceRect, pixelSize: geometry.pixelSize)
                }
                LongCaptureDiagnostics.shared.log("finish.failure.notScrollable frameCount=\(canvasAccumulator?.frameCount ?? 0) contentHeight=\(canvasAccumulator?.contentHeight ?? 0) totalScroll=\(String(format: "%.2f", Double(totalObservedScroll))) skipped=\(skippedTooCloseCount) queued=\(queuedFrameCount)")
                completion(.failure(LongCaptureError.notScrollable))
                return
            }
            LongCaptureDiagnostics.shared.log("finish.singleFrameAccepted frameCount=\(refreshedAccumulator.frameCount) contentHeight=\(refreshedAccumulator.contentHeight) totalScroll=\(String(format: "%.2f", Double(totalObservedScroll))) skipped=\(skippedTooCloseCount) queued=\(queuedFrameCount)")
        }
        let canvasSnapshot = refreshedAccumulator.snapshot()
        LongCaptureDiagnostics.shared.log("finish.compose.start width=\(canvasSnapshot.width) height=\(canvasSnapshot.height) placements=\(canvasSnapshot.placements.count)")
        DispatchQueue.global(qos: .userInitiated).async {
            let started = ProcessInfo.processInfo.systemUptime
            let result = canvasSnapshot.makeImage()
            let duration = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async {
                LongCaptureDiagnostics.shared.log("finish.compose.end success=\(result != nil) duration=\(String(format: "%.2f", duration))s image=\(result.map { "\($0.width)x\($0.height)" } ?? "nil")")
                if let result { completion(.success(result)) }
                else { completion(.failure(LongCaptureError.captureFailed)) }
            }
        }
    }

    private static func evaluateCandidate(
        frame: CGImage,
        frameSignature: FrameMatcher.FrameSignature?,
        lastAnchor: LongCaptureFrameAnchor,
        canvasAnchor: LongCaptureFrameAnchor?,
        candidateScrollPosition: CGFloat,
        selectionHeight: CGFloat,
        consecutivePoorMatches: Int,
        recovering: Bool,
        scrollPixelsPerPoint: CGFloat,
        fallbackCooldownFrames: Int
    ) -> FrameCandidateResult {
        let visualDelta: Double
        if let lastSignature = lastAnchor.signature, let frameSignature {
            visualDelta = FrameMatcher.averageDifference(lastSignature, frameSignature)
        } else {
            visualDelta = FrameMatcher.averageDifference(lastAnchor.image, frame)
        }
        let scrollDelta = max(0, candidateScrollPosition - lastAnchor.scrollPosition)
        let expectedFromLast: Int? = {
            guard scrollPixelsPerPoint > 0, scrollDelta > 0.25 else { return nil }
            let value = Int(round(scrollDelta * scrollPixelsPerPoint))
            guard value > 0, value < Int(CGFloat(frame.height) * 0.95) else { return nil }
            return value
        }()

        var localMoveDebug: Int?
        var localTopDebug: Int?
        var localScoreDebug: Double?
        var localMarginDebug: Double?
        var localOverlapDebug: Int?
        var localReliableDebug: Bool?
        var anchorMoveDebug: Int?
        var anchorTopDebug: Int?
        var anchorScoreDebug: Double?
        var anchorMarginDebug: Double?
        var anchorOverlapDebug: Int?
        var anchorReliableDebug: Bool?

        func makeResult(
            accepted: Bool,
            topOffset: Int,
            movementPixels: Int,
            poorMatch: Bool,
            status: String?,
            reason: String,
            allowCanvasPlacement: Bool = true,
            consumeScrollOnly: Bool = false
        ) -> FrameCandidateResult {
            let debug = FrameCandidateDebug(
                reason: reason,
                visualDelta: visualDelta,
                expectedFromLast: expectedFromLast,
                measuredFromLast: scrollDelta,
                localMove: localMoveDebug,
                localTop: localTopDebug,
                localScore: localScoreDebug,
                localMargin: localMarginDebug,
                localOverlap: localOverlapDebug,
                localReliable: localReliableDebug,
                anchorMove: anchorMoveDebug,
                anchorTop: anchorTopDebug,
                anchorScore: anchorScoreDebug,
                anchorMargin: anchorMarginDebug,
                anchorOverlap: anchorOverlapDebug,
                anchorReliable: anchorReliableDebug
            )
            return FrameCandidateResult(
                accepted: accepted,
                topOffset: topOffset,
                movementPixels: movementPixels,
                poorMatch: poorMatch,
                allowCanvasPlacement: allowCanvasPlacement,
                consumeScrollOnly: consumeScrollOnly,
                status: status,
                debug: debug
            )
        }

        // ScreenSnap 的 stillFrameMAD 默认是 0.2。画面几乎没变化时不推进锚点，
        // 这正是避免底部“同一段内容重复采样很多次”的关键。
        if visualDelta <= 0.2 {
            return makeResult(
                accepted: false,
                topOffset: lastAnchor.topOffset,
                movementPixels: 0,
                poorMatch: false,
                status: "画面未发生有效变化，已忽略这一帧",
                reason: "stillFrameMAD<=0.2",
                consumeScrollOnly: true
            )
        }

        let allowFallbackSearch = recovering || consecutivePoorMatches > 0 || fallbackCooldownFrames == 0
        let localAlignment = screenSnapAlignment(
            previous: lastAnchor,
            nextImage: frame,
            nextSignature: frameSignature,
            expectedMovement: expectedFromLast,
            allowFallback: allowFallbackSearch
        )
        let localMovement = FrameMatcher.movement(localAlignment, frameHeight: frame.height)
        let localTop = lastAnchor.topOffset + localMovement
        let localReliable = screenSnapReliable(
            alignment: localAlignment,
            movement: localMovement,
            expectedMovement: expectedFromLast,
            frameHeight: frame.height,
            recovering: recovering || consecutivePoorMatches > 0
        )
        localMoveDebug = localMovement
        localTopDebug = localTop
        localScoreDebug = localAlignment.score
        localMarginDebug = localAlignment.margin
        localOverlapDebug = localAlignment.overlap
        localReliableDebug = localReliable

        // 到达页面底部后，滚轮 delta 还会继续增长，但真实画面只会发生极小变化
        // （惯性/橡皮筋/固定 header 的轻微刷新）。这时 NCC 往往给出一个“看似
        // 有位移但 score 很差”的候选。不能把它当 poor，也不能推进 topOffset，
        // 否则尾部会重复拼接，且快速滚动后会进入 trackingLost。
        // v4：尾部重复的核心特征不是完全静止，而是“低视觉变化 + 弱 NCC 候选”。
        // GitHub 这类页面到底后，footer / license badge 仍可能因为惯性滚动、亚像素重绘
        // 产生 5~8 的 visualDelta；如果继续把这类帧当 poorMatch，会触发
        // tail.promoteRecovery，把底部旧内容强行拼到长图尾部。
        let lowVisualDelta = visualDelta <= 8.5
        let weakOrAmbiguousLocalMatch = localAlignment.score >= 52.0 || localAlignment.margin < 12.0
        // v5：不能只要 visualDelta 低就判定到底。GitHub README 底部很多区域
        // 是大白底 + 少量文字，快速滚动时 visualDelta 也会只有 6~9；v4 在这种
        // 场景把真实的后续内容当成 consumeOnly，直接导致“3/4/Uninstall/Notes”
        // 大段丢失。现在只有在候选位移很小，或已经连续观察到无视觉进展时，
        // 才把低 visualDelta 当作到底重复帧消费掉。
        let tinyVisualMovement = localMovement <= max(96, Int(CGFloat(frame.height) * 0.08))
        if false, lowVisualDelta, scrollDelta >= 2.0, weakOrAmbiguousLocalMatch, tinyVisualMovement {
            return makeResult(
                accepted: false,
                topOffset: lastAnchor.topOffset,
                movementPixels: 0,
                poorMatch: false,
                status: "页面可能已到底，已忽略重复尾帧",
                reason: "lowVisualNoReliableProgress",
                consumeScrollOnly: true
            )
        }

        if localReliable, localTop + 1 >= lastAnchor.topOffset {
            return makeResult(
                accepted: true,
                topOffset: max(lastAnchor.topOffset, localTop),
                movementPixels: localMovement,
                poorMatch: false,
                status: nil,
                reason: "localNCC"
            )
        }

        if let canvasAnchor,
           canvasAnchor.topOffset != lastAnchor.topOffset || canvasAnchor.scrollPosition != lastAnchor.scrollPosition {
            let canvasScrollDelta = max(0, candidateScrollPosition - canvasAnchor.scrollPosition)
            let expectedFromCanvas: Int? = {
                guard scrollPixelsPerPoint > 0, canvasScrollDelta > 0.25 else { return nil }
                let value = Int(round(canvasScrollDelta * scrollPixelsPerPoint))
                guard value > 0, value < Int(CGFloat(frame.height) * 1.2) else { return nil }
                return value
            }()
            let anchorAlignment = screenSnapAlignment(
                previous: canvasAnchor,
                nextImage: frame,
                nextSignature: frameSignature,
                expectedMovement: expectedFromCanvas,
                allowFallback: allowFallbackSearch
            )
            let anchorMovement = FrameMatcher.movement(anchorAlignment, frameHeight: frame.height)
            let anchorTop = canvasAnchor.topOffset + anchorMovement
            let anchorReliable = screenSnapReliable(
                alignment: anchorAlignment,
                movement: anchorMovement,
                expectedMovement: expectedFromCanvas,
                frameHeight: frame.height,
                recovering: true
            )
            anchorMoveDebug = anchorMovement
            anchorTopDebug = anchorTop
            anchorScoreDebug = anchorAlignment.score
            anchorMarginDebug = anchorAlignment.margin
            anchorOverlapDebug = anchorAlignment.overlap
            anchorReliableDebug = anchorReliable

            let agreesWithLocal = abs(anchorTop - localTop) <= max(6, Int(CGFloat(frame.height) * 0.01))
            if anchorReliable, anchorTop + 1 >= lastAnchor.topOffset {
                if agreesWithLocal || !localReliable || anchorAlignment.score + 4.0 < localAlignment.score {
                    return makeResult(
                        accepted: true,
                        topOffset: max(lastAnchor.topOffset, anchorTop),
                        movementPixels: max(1, anchorTop - lastAnchor.topOffset),
                        poorMatch: false,
                        status: "已用主锚点恢复一帧",
                        reason: agreesWithLocal ? "anchorNCCAgree" : "anchorNCCRecover"
                    )
                }
            }
        }

        if localMovement <= 0 || localMovement < max(1, Int(CGFloat(frame.height) * 0.0015)) {
            return makeResult(
                accepted: false,
                topOffset: lastAnchor.topOffset,
                movementPixels: 0,
                poorMatch: false,
                status: "当前画面新增内容太少；继续向下滚动即可",
                reason: "movementTooSmall",
                consumeScrollOnly: true
            )
        }

        return makeResult(
            accepted: false,
            topOffset: max(lastAnchor.topOffset, localTop),
            movementPixels: max(0, localMovement),
            poorMatch: true,
            status: "暂未找到可靠锚点，正在从连续帧中恢复",
            reason: "nccRejected"
        )
    }

    private static func screenSnapAlignment(
        previous anchor: LongCaptureFrameAnchor,
        nextImage: CGImage,
        nextSignature: FrameMatcher.FrameSignature?,
        expectedMovement: Int?,
        allowFallback: Bool
    ) -> FrameMatcher.Alignment {
        let guided: FrameMatcher.Alignment?
        if let expectedMovement {
            guided = alignment(
                previous: anchor,
                nextImage: nextImage,
                nextSignature: nextSignature,
                expectedMovement: expectedMovement
            )
            if let guided, guided.score <= 38.0 {
                return guided
            }
        } else {
            guided = nil
        }

        guard allowFallback else {
            return guided ?? alignment(
                previous: anchor,
                nextImage: nextImage,
                nextSignature: nextSignature,
                expectedMovement: nil
            )
        }

        let fallback = alignment(
            previous: anchor,
            nextImage: nextImage,
            nextSignature: nextSignature,
            expectedMovement: nil
        )
        guard let guided else { return fallback }
        return fallback.score + 2.0 < guided.score ? fallback : guided
    }

    private static func screenSnapReliable(
        alignment: FrameMatcher.Alignment,
        movement: Int,
        expectedMovement: Int?,
        frameHeight: Int,
        recovering: Bool
    ) -> Bool {
        guard movement >= 1 else { return false }
        guard movement <= Int(CGFloat(frameHeight) * 0.82) else { return false }
        guard alignment.overlap >= max(9, Int(CGFloat(frameHeight) * 0.18)) else { return false }

        // ScreenSnap 默认 nccAccept=0.62；兜底搜索里还出现 0.68。这里用 score=(1-NCC)*100。
        let normalLimit = 38.0
        let recoveryLimit = 32.0
        let scoreLimit = recovering ? recoveryLimit : normalLimit
        if alignment.score <= scoreLimit { return true }

        // margin 大说明候选唯一，即使滚轮先验不准也可以接受。重复内容区域 margin 通常很小。
        if alignment.score <= normalLimit, alignment.margin >= 4.0 { return true }

        if let expectedMovement, expectedMovement > 0 {
            let tolerance = max(Int(CGFloat(frameHeight) * 0.18), Int(CGFloat(expectedMovement) * 0.85))
            let followsPrior = abs(movement - expectedMovement) <= tolerance
            if followsPrior, alignment.score <= 45.0, alignment.margin >= 2.0 {
                return true
            }
            // score 约 50 的候选只能在“非常唯一 + overlap 足够大”时用于继续跟踪。
            // 上一版这里放到 56/62，日志里已经出现局部拼接不齐：说明弱纹理区域
            // 会把错误候选也算成可靠。这里收紧到 52/58，并要求更高 overlap。
            if false,
               followsPrior,
               alignment.score <= (recovering ? 58.0 : 52.0),
               alignment.margin >= 22.0,
               alignment.overlap >= Int(CGFloat(frameHeight) * 0.62) {
                return true
            }
        }
        return false
    }

    private static func alignment(
        previous anchor: LongCaptureFrameAnchor,
        nextImage: CGImage,
        nextSignature: FrameMatcher.FrameSignature?,
        expectedMovement: Int?
    ) -> FrameMatcher.Alignment {
        // ScreenSnap 首选 Vision 的 VNTranslationalImageRegistrationRequest，
        // 只有 Vision 无法给出稳定平移时才进入 NCC 兜底。
        if let previousSignature = anchor.signature,
           let nextSignature,
           let vision = FrameMatcher.visionAlignment(
            previousImage: anchor.image,
            nextImage: nextImage,
            previousSignature: previousSignature,
            nextSignature: nextSignature,
            expectedNewContent: expectedMovement
           ) {
            return vision
        }
        if let previousSignature = anchor.signature, let nextSignature {
            return FrameMatcher.alignment(
                previous: previousSignature,
                next: nextSignature,
                expectedNewContent: expectedMovement
            )
        }
        return FrameMatcher.alignment(
            previous: anchor.image,
            next: nextImage,
            expectedNewContent: expectedMovement
        )
    }

    private func installScrollMonitor() {
        guard globalScrollMonitor == nil, localScrollMonitor == nil else { return }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            DispatchQueue.main.async { self?.receiveScroll(event) }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.receiveScroll(event)
            return event
        }
    }

    private func receiveScroll(_ event: NSEvent) {
        let globalSelection = selection.offsetBy(
            dx: snapshot.screen.frame.minX,
            dy: snapshot.screen.frame.minY
        )
        guard globalSelection.contains(NSEvent.mouseLocation) else { return }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
        let delta = abs(event.scrollingDeltaY) * multiplier
        totalObservedScroll += delta
        if delta >= 8 || Int(totalObservedScroll) % 500 < Int(delta) {
            LongCaptureDiagnostics.shared.log("scroll.delta delta=\(String(format: "%.2f", Double(delta))) precise=\(event.hasPreciseScrollingDeltas) total=\(String(format: "%.2f", Double(totalObservedScroll))) mouse=\(String(format: "%.2f,%.2f", Double(NSEvent.mouseLocation.x), Double(NSEvent.mouseLocation.y)))")
        }
    }

    private func removeScrollMonitor() {
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        globalScrollMonitor = nil
        localScrollMonitor = nil
    }

    private func publishPreview() {
        guard !isStopping, let previewCanvas else { return }
        onPreview?(previewCanvas, acceptedFrameCount)
    }

    private func renderPreviewImmediately() {
        guard let previewStore else { return }
        let started = ProcessInfo.processInfo.systemUptime
        previewCanvas = previewStore.makeOverview(maximumHeight: previewMaximumHeight)
        let duration = ProcessInfo.processInfo.systemUptime - started
        lastPreviewFlushTime = ProcessInfo.processInfo.systemUptime
        lastPreviewRenderedTime = lastPreviewFlushTime
        lastPreviewRenderedContentHeight = previewStore.previewContentHeight
        lastPreviewRenderedPlacementCount = previewStore.placementCount
        LongCaptureDiagnostics.shared.log("preview.immediate duration=\(String(format: "%.2f", duration))s placements=\(previewStore.placementCount) previewHeight=\(previewStore.previewContentHeight) output=\(previewCanvas.map { "\($0.width)x\($0.height)" } ?? "nil")")
        publishPreview()
    }

    private func schedulePreviewRender() {
        guard let previewStore else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let heightGrowth = previewStore.previewContentHeight - lastPreviewRenderedContentHeight
        let placementGrowth = previewStore.placementCount - lastPreviewRenderedPlacementCount
        let elapsed = now - lastPreviewRenderedTime
        let firstPreview = lastPreviewRenderedContentHeight <= 0
        let grewEnough = heightGrowth >= previewMinimumRenderGrowth
        let staleEnough = elapsed >= previewMaximumLatency

        if firstPreview || (staleEnough && (grewEnough || placementGrowth >= 2)) {
            LongCaptureDiagnostics.shared.log("preview.render.coarseNow placements=\(previewStore.placementCount) previewHeight=\(previewStore.previewContentHeight) heightGrowth=\(heightGrowth) placementGrowth=\(placementGrowth) elapsed=\(String(format: "%.2f", elapsed)) threshold=\(previewMinimumRenderGrowth)")
            renderPreviewAsync()
            return
        }

        guard previewFlushWorkItem == nil else { return }
        let delay = max(0.035, previewMaximumLatency - elapsed)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.previewFlushWorkItem = nil
            self.renderPreviewAsync()
        }
        previewFlushWorkItem = work
        LongCaptureDiagnostics.shared.log("preview.render.defer placements=\(previewStore.placementCount) previewHeight=\(previewStore.previewContentHeight) heightGrowth=\(heightGrowth) placementGrowth=\(placementGrowth) delay=\(String(format: "%.2f", delay)) threshold=\(previewMinimumRenderGrowth)")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func renderPreviewAsync() {
        guard let previewStore else { return }
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        lastPreviewFlushTime = ProcessInfo.processInfo.systemUptime

        guard !previewRenderInFlight else {
            previewRenderPending = true
            LongCaptureDiagnostics.shared.log("preview.render.coalesce placements=\(previewStore.placementCount) previewHeight=\(previewStore.previewContentHeight)")
            return
        }
        previewRenderInFlight = true
        previewRenderPending = false
        previewGeneration += 1
        let generation = previewGeneration
        let maximumHeight = previewMaximumHeight
        let requestPlacements = previewStore.placementCount
        let requestHeight = previewStore.previewContentHeight
        LongCaptureDiagnostics.shared.log("preview.render.start generation=\(generation) placements=\(requestPlacements) previewHeight=\(requestHeight) maxHeight=\(maximumHeight)")
        previewQueue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let image = previewStore.makeOverview(maximumHeight: maximumHeight)
            let duration = ProcessInfo.processInfo.systemUptime - started
            DispatchQueue.main.async {
                guard let self else { return }
                let current = self.previewGeneration
                let needsLatestPreview = self.previewRenderPending
                self.previewRenderInFlight = false
                self.previewRenderPending = false
                LongCaptureDiagnostics.shared.log("preview.render.end generation=\(generation) current=\(current) pending=\(needsLatestPreview) success=\(image != nil) duration=\(String(format: "%.2f", duration))s placements=\(requestPlacements) image=\(image.map { "\($0.width)x\($0.height)" } ?? "nil")")
                if current == generation, let image {
                    self.previewCanvas = image
                    self.lastPreviewRenderedTime = ProcessInfo.processInfo.systemUptime
                    self.lastPreviewRenderedContentHeight = requestHeight
                    self.lastPreviewRenderedPlacementCount = requestPlacements
                    self.publishPreview()
                }
                if needsLatestPreview, !self.isStopping, self.previewStore != nil {
                    self.schedulePreviewRender()
                }
            }
        }
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
        guard let coarse = gray(image, targetWidth: 160),
              let precise = verticallyPreciseGray(image, targetWidth: 128) else { return nil }
        return FrameSignature(
            coarse: coarse,
            precise: precise,
            originalHeight: image.height
        )
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
    static func verticallyPreciseGray(_ image: CGImage, targetWidth: Int = 128) -> GrayFrame? {
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
        let maxDisplacement = max(minDisplacement, Int(CGFloat(h) * 0.70))
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
        for displacement in stride(from: lower, through: upper, by: 2) {
            var score = weightedOverlapScore(previous: a, next: b, displacement: displacement)
            if let expectedGray {
                score += Double(abs(displacement - expectedGray)) * 0.018
            }
            recordScore(score, displacement: displacement)
        }

        let refineLower = max(lower, bestDisplacement - 4)
        let refineUpper = min(upper, bestDisplacement + 4)
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

        let coarseScaledDisplacement = min(
            originalHeight - 1,
            max(1, Int(CGFloat(bestDisplacement) / CGFloat(h) * CGFloat(originalHeight)))
        )
        let preciseA = previous.precise
        let preciseB = next.precise
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
        let preciseRadius = max(8, Int(ceil(sourcePixelsPerCoarseRow * 2.0)))
        let preciseLower = max(1, coarseScaledDisplacement - preciseRadius)
        let preciseUpper = min(Int(CGFloat(originalHeight) * 0.70), coarseScaledDisplacement + preciseRadius)
        let expectedPrecise = expectedNewContent.map {
            min(preciseUpper, max(preciseLower, $0))
        }
        var preciseDisplacement = coarseScaledDisplacement
        var preciseScore = Double.greatestFiniteMagnitude
        if preciseLower <= preciseUpper {
            for displacement in preciseLower...preciseUpper {
                var score = verticalGradientScore(
                    previous: preciseA,
                    next: preciseB,
                    displacement: displacement
                )
                if let expectedPrecise {
                    score += Double(abs(displacement - expectedPrecise)) * 0.004
                }
                if score < preciseScore {
                    preciseScore = score
                    preciseDisplacement = displacement
                }
            }
        }
        return Alignment(
            nextContentStart: 0,
            overlap: originalHeight - preciseDisplacement,
            // The precise score has a different (gradient-error) scale. Reliability is
            // still decided by the coarse NCC; the precise pass only removes vertical
            // quantization from the selected displacement.
            score: bestScore,
            margin: coarseMargin
        )
    }

    private static func verticalGradientScore(
        previous a: GrayFrame,
        next b: GrayFrame,
        displacement: Int
    ) -> Double {
        let overlap = min(a.height - displacement, b.height)
        guard overlap >= max(8, Int(CGFloat(min(a.height, b.height)) * 0.30)) else { return 255 }
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
        for row in stride(from: rowStart, to: rowEnd, by: 3) {
            let aRow = displacement + row
            for x in stride(from: xStart, to: xEnd, by: 6) {
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
        guard overlap >= max(8, Int(CGFloat(h) * 0.30)) else { return 255 }

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
        for row in stride(from: rowStart, to: rowEnd, by: 3) {
            let previousRow = displacement + row
            for x in stride(from: xStart, to: xEnd, by: 2) {
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
