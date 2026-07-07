import AppKit
import CoreImage
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

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

/// Continuous region capture backed by ScreenCaptureKit. Long screenshots need
/// the frames produced while scrolling; requesting isolated snapshots after a
/// gesture loses the intermediate overlap and can never recover once one seam is
/// missed.
final class ScrollCaptureStream: NSObject, SCStreamOutput {
    var onFrame: ((CGImage) -> Void)?
    var onError: ((Error) -> Void)?

    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect
    private let pixelSize: CGSize
    private let excludedWindowID: CGWindowID
    private let outputQueue = DispatchQueue(label: "longscreenshot.stream.output", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let stateLock = NSLock()
    private var stopped = false
    private var stream: SCStream?

    init(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect,
        pixelSize: CGSize,
        excludedWindowID: CGWindowID
    ) {
        self.displayID = displayID
        self.sourceRect = sourceRect
        self.pixelSize = pixelSize
        self.excludedWindowID = excludedWindowID
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
            let excluded = content.windows.filter { $0.windowID == self.excludedWindowID }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = self.sourceRect
            configuration.width = max(2, Int(self.pixelSize.width))
            configuration.height = max(2, Int(self.pixelSize.height))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 6
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
                self.stream = stream
                stream.startCapture { [weak self] error in
                    if let error { DispatchQueue.main.async { self?.onError?(error) } }
                }
            } catch {
                DispatchQueue.main.async { self.onError?(error) }
            }
        }
    }

    func stop() {
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
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        onFrame?(cgImage)
    }
}

private struct FrameCandidateResult {
    let accepted: Bool
    let alignment: FrameMatcher.Alignment?
    let newContent: Int
    let poorMatch: Bool
    let status: String?
}

private struct StreamFrameCandidate {
    let image: CGImage
    let scrollPosition: CGFloat
}

/// A full-document preview assembled from immutable, fixed-width thumbnail chunks.
/// Source strips are downsampled exactly once. Overview regeneration always reads those
/// chunks, so it neither accumulates blur nor touches full-resolution history.
final class PreviewOverviewStore {
    private let width: Int
    private let maximumHeight: Int
    private let chunkHeight: Int
    private var completedChunks: [CGImage] = []
    private var pendingCanvas: CGImage?
    private var pendingHeight = 0
    private(set) var overview: CGImage?
    private(set) var baseThumbnailHeight = 0

    init(sourceWidth: Int, maximumWidth: Int, maximumHeight: Int, chunkHeight: Int = 1_024) {
        self.width = max(1, min(maximumWidth, sourceWidth))
        self.maximumHeight = max(1, maximumHeight)
        self.chunkHeight = max(128, chunkHeight)
    }

    func append(
        _ image: CGImage,
        droppingLeadingSourcePixels drop: Int = 0,
        rebuildOverview shouldRebuildOverview: Bool = true
    ) {
        let visible: CGImage
        if drop > 0,
           let cropped = image.cropping(to: CGRect(
            x: 0,
            y: min(image.height - 1, drop),
            width: image.width,
            height: max(1, image.height - min(image.height - 1, drop))
           )) {
            visible = cropped
        } else {
            visible = image
        }
        guard let thumbnail = FrameStitcher.scaledSegment(visible, targetWidth: width) else { return }
        appendThumbnail(thumbnail)
        if shouldRebuildOverview { rebuildOverview() }
    }

    private func appendThumbnail(_ image: CGImage) {
        var offset = 0
        while offset < image.height {
            let available = chunkHeight - pendingHeight
            let amount = min(available, image.height - offset)
            guard let piece = image.cropping(to: CGRect(
                x: 0,
                y: offset,
                width: image.width,
                height: amount
            )) else { return }
            if let pendingCanvas {
                self.pendingCanvas = FrameStitcher.composeSegments([pendingCanvas, piece])
            } else {
                pendingCanvas = piece
            }
            pendingHeight += amount
            baseThumbnailHeight += amount
            offset += amount

            if pendingHeight == chunkHeight {
                if let pendingCanvas { completedChunks.append(pendingCanvas) }
                pendingCanvas = nil
                pendingHeight = 0
            }
        }
    }

    private func rebuildOverview() {
        var chunks = completedChunks
        if let pendingCanvas { chunks.append(pendingCanvas) }
        overview = FrameStitcher.composeOverviewChunks(
            chunks,
            width: width,
            maximumHeight: maximumHeight
        )
    }
}

final class LongCaptureService {
    var onPreview: ((CGImage, Int) -> Void)?
    var onStatus: ((String, Bool) -> Void)?

    private let snapshot: ScreenSnapshot
    private let selection: CGRect
    private let overlayWindowID: CGWindowID

    private var recentFrames: [CGImage] = []
    private var canvasSegments: [CGImage] = []
    private var previewCanvas: CGImage?
    private var previewStore: PreviewOverviewStore?
    private var pendingPreviewStrips: [(image: CGImage, drop: Int)] = []
    private var pendingPreviewSourcePixels = 0
    private var previewFlushWorkItem: DispatchWorkItem?
    private var lastPreviewFlushTime = 0.0
    private var acceptedFrameCount = 0
    private var lastRawFrame: CGImage?
    private var lastRawSignature: FrameMatcher.FrameSignature?
    private var lastRawScrollPosition: CGFloat = 0
    private var latestObservedFrame: CGImage?
    private var latestObservedScrollPosition: CGFloat = 0
    private var trackedOffsetPixels = 0
    private var trackingLost = false
    private var captureStream: ScrollCaptureStream?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?

    private var totalObservedScroll: CGFloat = 0
    private var acceptedScrollPosition: CGFloat = 0
    private var lastScrollTime = Date.distantPast
    private var lastFrameAttemptTime = Date.distantPast
    private var lastQueuedScrollPosition: CGFloat = 0
    private var acceptedOutputHeight = 0
    private var consecutivePoorMatches = 0
    private let matchQueue = DispatchQueue(label: "longscreenshot.frame.match", qos: .userInitiated)
    private var matchInFlight = false
    private var pendingFrameQueue: [StreamFrameCandidate] = []
    private var isStopping = false
    private var finishRequested = false
    private var finishCompletion: ((Result<CGImage, Error>) -> Void)?

    // ScreenSnap 会保留连续帧队列，而不是只保留“最新帧”。快速滚动时丢掉
    // 中间帧会立刻失去重叠关系，因此这里允许一个有界的顺序队列。
    private let maximumPendingFrames = 18
    private let maximumOutputHeight = 180_000
    private let previewBatchFraction: CGFloat = 0.25
    private let previewMaximumLatency = 0.45
    private var previewMaximumWidth: Int {
        let desiredMinimapWidth = min(210, max(110, selection.width * 0.24))
        let minimapWidth = min(selection.width - 16, desiredMinimapWidth)
        return max(72, Int(floor(minimapWidth - 16)))
    }
    private var previewMaximumHeight: Int {
        max(100, min(900, Int(floor(selection.height - 88))))
    }

    init(snapshot: ScreenSnapshot, selection: CGRect, overlayWindowID: CGWindowID) {
        self.snapshot = snapshot
        self.selection = selection
        self.overlayWindowID = overlayWindowID
    }

    func start() {
        guard let first = snapshot.crop(viewRect: selection) else { return }
        isStopping = false
        finishRequested = false
        finishCompletion = nil
        recentFrames = [first]
        canvasSegments = [first]
        let previewStore = PreviewOverviewStore(
            sourceWidth: first.width,
            maximumWidth: previewMaximumWidth,
            maximumHeight: previewMaximumHeight
        )
        previewStore.append(first)
        self.previewStore = previewStore
        previewCanvas = previewStore.overview
        pendingPreviewStrips = []
        pendingPreviewSourcePixels = 0
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        lastPreviewFlushTime = ProcessInfo.processInfo.systemUptime
        acceptedFrameCount = 1
        lastRawFrame = first
        lastRawSignature = FrameMatcher.signature(first)
        lastRawScrollPosition = 0
        latestObservedFrame = first
        latestObservedScrollPosition = 0
        trackedOffsetPixels = 0
        trackingLost = false
        totalObservedScroll = 0
        acceptedScrollPosition = 0
        acceptedOutputHeight = first.height
        consecutivePoorMatches = 0
        matchInFlight = false
        pendingFrameQueue = []
        lastScrollTime = Date.distantPast
        lastFrameAttemptTime = Date.distantPast
        lastQueuedScrollPosition = 0
        publishPreview()
        installScrollMonitor()
        startCaptureStream(pixelSize: CGSize(width: first.width, height: first.height))
    }

    private func startCaptureStream(pixelSize: CGSize) {
        let sourceRect = CGRect(
            x: selection.minX,
            y: snapshot.pointSize.height - selection.maxY,
            width: selection.width,
            height: selection.height
        )
        let stream = ScrollCaptureStream(
            displayID: snapshot.displayID,
            sourceRect: sourceRect,
            pixelSize: pixelSize,
            excludedWindowID: overlayWindowID
        )
        stream.onFrame = { [weak self] image in
            DispatchQueue.main.async { self?.receiveStreamFrame(image) }
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
        // Include the newest frame already delivered by ScreenCaptureKit even if the
        // regular sampling gate had not queued it yet. This closes the small race between
        // reaching the bottom and immediately clicking the completion button.
        if let latestObservedFrame {
            let finalCandidate = StreamFrameCandidate(
                image: latestObservedFrame,
                scrollPosition: latestObservedScrollPosition
            )
            if matchInFlight {
                if pendingFrameQueue.count < maximumPendingFrames {
                    pendingFrameQueue.append(finalCandidate)
                } else {
                    compactPendingFramesAndAppend(finalCandidate)
                }
            } else {
                processCandidateFrame(finalCandidate)
            }
        }
        captureStream?.stop()
        captureStream = nil
        removeScrollMonitor()
        onStatus?(pendingFrameQueue.isEmpty && !matchInFlight
            ? "正在生成长图…"
            : "正在处理最后 \(pendingFrameQueue.count + (matchInFlight ? 1 : 0)) 帧…", false)
        finishIfQueueDrained()
    }

    func cancel() {
        isStopping = true
        finishRequested = false
        finishCompletion = nil
        captureStream?.stop()
        captureStream = nil
        removeScrollMonitor()
        pendingFrameQueue = []
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        pendingPreviewStrips = []
        pendingPreviewSourcePixels = 0
    }

    private func receiveStreamFrame(_ current: CGImage) {
        guard !isStopping, !finishRequested else { return }
        latestObservedFrame = current
        latestObservedScrollPosition = totalObservedScroll
        guard let first = recentFrames.first,
              current.width == first.width,
              current.height == first.height else { return }
        guard acceptedOutputHeight < maximumOutputHeight else {
            onStatus?("已达到长图安全高度，请点击 ✓ 完成当前长图", false)
            return
        }

        let now = Date()
        let measuredScroll = max(0, totalObservedScroll - lastQueuedScrollPosition)
        let minimumMotion = max(4, selection.height * 0.006)
        let enoughTimePassed = now.timeIntervalSince(lastFrameAttemptTime) >= (1.0 / 24.0)
        let motionReady = measuredScroll >= minimumMotion && enoughTimePassed
        let idleProbe = now.timeIntervalSince(lastFrameAttemptTime) >= (1.0 / 12.0)
        // Limit forwarding to useful motion samples. Matching every 1–2 point video
        // frame only creates a queue that the preview must chase after scrolling stops.
        guard motionReady || idleProbe else {
            return
        }
        lastFrameAttemptTime = now
        lastQueuedScrollPosition = totalObservedScroll
        let candidate = StreamFrameCandidate(image: current, scrollPosition: totalObservedScroll)
        if matchInFlight {
            if pendingFrameQueue.count < maximumPendingFrames {
                pendingFrameQueue.append(candidate)
            } else {
                compactPendingFramesAndAppend(candidate)
            }
            return
        }
        processCandidateFrame(candidate)
    }

    /// When matching falls behind capture, keep the queue spread across the whole
    /// scroll interval instead of silently dropping every newest (tail) frame. Removing
    /// the closest adjacent pair preserves overlap while ensuring the final viewport is
    /// still represented in the queue.
    private func compactPendingFramesAndAppend(_ candidate: StreamFrameCandidate) {
        guard !pendingFrameQueue.isEmpty else {
            pendingFrameQueue.append(candidate)
            return
        }
        var previousPosition = lastRawScrollPosition
        var smallestGap = CGFloat.greatestFiniteMagnitude
        var removalIndex = 0
        for (index, queued) in pendingFrameQueue.enumerated() {
            let gap = max(0, queued.scrollPosition - previousPosition)
            if gap < smallestGap {
                smallestGap = gap
                removalIndex = index
            }
            previousPosition = queued.scrollPosition
        }
        pendingFrameQueue.remove(at: removalIndex)
        pendingFrameQueue.append(candidate)
    }

    private func processCandidateFrame(_ candidate: StreamFrameCandidate) {
        guard !isStopping, let last = lastRawFrame ?? recentFrames.last else { return }
        matchInFlight = true

        let current = candidate.image
        let measuredScroll = max(0, candidate.scrollPosition - lastRawScrollPosition)
        let currentConsecutivePoorMatches = consecutivePoorMatches
        let selectionHeight = max(1, selection.height)
        let currentlyLost = trackingLost
        let cachedLastSignature = lastRawSignature

        matchQueue.async { [weak self] in
            let previousSignature = cachedLastSignature ?? FrameMatcher.signature(last)
            let currentSignature = FrameMatcher.signature(current)
            let result = Self.evaluateCandidate(
                frame: current,
                last: last,
                frameSignature: currentSignature,
                lastSignature: previousSignature,
                measuredScroll: measuredScroll,
                selectionHeight: selectionHeight,
                consecutivePoorMatches: currentConsecutivePoorMatches,
                recovering: currentlyLost
            )
            DispatchQueue.main.async {
                self?.applyCandidateResult(
                    result,
                    candidate: candidate,
                    signature: currentSignature
                )
            }
        }
    }

    private func applyCandidateResult(
        _ result: FrameCandidateResult,
        candidate: StreamFrameCandidate,
        signature: FrameMatcher.FrameSignature?
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

        if result.accepted, result.alignment != nil {
            lastRawFrame = candidate.image
            lastRawSignature = signature
            lastRawScrollPosition = candidate.scrollPosition
            trackedOffsetPixels += result.newContent
            trackingLost = false
            consecutivePoorMatches = 0

            let minimumCommit = max(10, Int(CGFloat(candidate.image.height) * 0.022))
            guard trackedOffsetPixels >= minimumCommit else { return }
            let committedContent = min(
                trackedOffsetPixels,
                Int(CGFloat(candidate.image.height) * 0.70)
            )
            guard appendContent(
                from: candidate.image,
                pixels: committedContent,
                signature: signature
            ) else { return }
            acceptedScrollPosition = candidate.scrollPosition
            trackedOffsetPixels = 0
            let status = result.status?.replacingOccurrences(of: "已采集 0 帧", with: "已采集 \(acceptedFrameCount) 帧") ?? "已采集 \(acceptedFrameCount) 帧"
            onStatus?(status, false)
            return
        }

        if result.poorMatch {
            consecutivePoorMatches += 1
            trackingLost = true
            let scale = CGFloat(candidate.image.height) / max(1, selection.height)
            let estimatedFromAccepted = Int(max(0, candidate.scrollPosition - acceptedScrollPosition) * scale)
            trackedOffsetPixels = min(
                Int(CGFloat(candidate.image.height) * 0.55),
                max(trackedOffsetPixels, estimatedFromAccepted)
            )
            // 重新锚定原始帧；下一张连续帧只需恢复很小的相邻位移，不会
            // 永远和很久以前的画布帧硬匹配。
            lastRawFrame = candidate.image
            lastRawSignature = signature
            lastRawScrollPosition = candidate.scrollPosition
        }
        if let status = result.status {
            onStatus?(status, false)
        }
    }

    @discardableResult
    private func appendContent(
        from frame: CGImage,
        pixels committedContent: Int,
        signature: FrameMatcher.FrameSignature? = nil
    ) -> Bool {
        let nextHeight = acceptedOutputHeight + committedContent
        guard nextHeight <= maximumOutputHeight else {
            onStatus?("已达到长图安全高度，请点击 ✓ 完成当前长图", false)
            return false
        }
        let nominalSourceStart = max(0, frame.height - committedContent)
        // A mathematically correct seam can still cross the middle of a glyph when
        // adjacent-frame offsets differ by a rounded pixel. Move the seam upward to
        // a nearby quiet row, remove that same tail from the old canvas, then let the
        // newer frame replace it.
        let maximumBacktrack = min(
            max(0, nominalSourceStart - 1),
            min(140, max(28, frame.height / 12)),
            max(0, acceptedOutputHeight - 1)
        )
        let seamBacktrack = signature.map {
            FrameMatcher.safeSeamBacktrack(
                in: $0,
                sourceStart: nominalSourceStart,
                maximumBacktrack: maximumBacktrack
            )
        } ?? FrameMatcher.safeSeamBacktrack(
            in: frame,
            sourceStart: nominalSourceStart,
            maximumBacktrack: maximumBacktrack
        )
        let sourceStart = max(0, nominalSourceStart - seamBacktrack)
        guard let segment = FrameStitcher.copySegment(from: frame, sourceStart: sourceStart) else {
            onStatus?("无法复制长图新增区域，已跳过这一帧", true)
            return false
        }
        guard FrameStitcher.trimTail(&canvasSegments, pixels: seamBacktrack) else {
            onStatus?("无法回补长图接缝，已跳过这一帧", true)
            return false
        }
        canvasSegments.append(segment)
        queuePreviewStrip(
            segment,
            droppingLeadingSourcePixels: seamBacktrack,
            sourcePixels: committedContent,
            frameHeight: frame.height
        )
        recentFrames.append(frame)
        if recentFrames.count > 4 { recentFrames.removeFirst(recentFrames.count - 4) }
        acceptedFrameCount += 1
        acceptedOutputHeight = nextHeight
        return true
    }

    private func finishIfQueueDrained() {
        guard finishRequested, !matchInFlight, pendingFrameQueue.isEmpty,
              let completion = finishCompletion else { return }

        // A final slow movement can be below the normal live-preview commit threshold.
        // It is still real matched content, so include it before producing the result.
        if !trackingLost, trackedOffsetPixels >= 2, let lastRawFrame {
            let tail = min(trackedOffsetPixels, Int(CGFloat(lastRawFrame.height) * 0.70))
            if appendContent(from: lastRawFrame, pixels: tail, signature: lastRawSignature) {
                acceptedScrollPosition = lastRawScrollPosition
                trackedOffsetPixels = 0
            }
        }

        flushPreviewStrips()

        finishCompletion = nil
        finishRequested = false
        isStopping = true

        guard acceptedFrameCount > 1 else {
            isStopping = false
            installScrollMonitor()
            if let first = recentFrames.first {
                startCaptureStream(pixelSize: CGSize(width: first.width, height: first.height))
            }
            completion(.failure(LongCaptureError.notScrollable))
            return
        }

        let capturedSegments = canvasSegments
        DispatchQueue.global(qos: .userInitiated).async {
            let result = FrameStitcher.composeSegments(capturedSegments)
            DispatchQueue.main.async {
                if let result { completion(.success(result)) }
                else { completion(.failure(LongCaptureError.captureFailed)) }
            }
        }
    }

    private static func evaluateCandidate(
        frame: CGImage,
        last: CGImage,
        frameSignature: FrameMatcher.FrameSignature?,
        lastSignature: FrameMatcher.FrameSignature?,
        measuredScroll: CGFloat,
        selectionHeight: CGFloat,
        consecutivePoorMatches: Int,
        recovering: Bool
    ) -> FrameCandidateResult {
        let visualDelta: Double
        if let lastSignature, let frameSignature {
            visualDelta = FrameMatcher.averageDifference(lastSignature, frameSignature)
        } else {
            visualDelta = FrameMatcher.averageDifference(last, frame)
        }
        if visualDelta < 0.35 {
            return FrameCandidateResult(
                accepted: false,
                alignment: nil,
                newContent: 0,
                poorMatch: false,
                status: nil
            )
        }

        if visualDelta < 2.2 {
            let shifted: (score: Double, shift: Int)
            if let lastSignature, let frameSignature {
                shifted = FrameMatcher.smallShiftDifference(
                    previous: lastSignature,
                    next: frameSignature
                )
            } else {
                shifted = FrameMatcher.smallShiftDifference(previous: last, next: frame)
            }
            if shifted.score < 2.6,
               abs(shifted.shift) <= max(3, Int(CGFloat(frame.height) * 0.018)) {
                return FrameCandidateResult(
                    accepted: false,
                    alignment: nil,
                    newContent: 0,
                    poorMatch: false,
                    status: nil
                )
            }
        }

        let scale = CGFloat(frame.height) / max(1, selectionHeight)
        let measuredPixels = Int(measuredScroll * scale)
        let measuredLooksSane = measuredPixels >= 2 && measuredPixels <= Int(CGFloat(frame.height) * 0.70)
        let expectedPixels: Int? = measuredLooksSane ? measuredPixels : nil

        // 周期探测只用于观察稳定性；没有任何滚动预算时不能把动画、GIF 或
        // 光标变化当成页面位移写入长图。
        guard expectedPixels != nil || consecutivePoorMatches > 0 else {
            return FrameCandidateResult(
                accepted: false,
                alignment: nil,
                newContent: 0,
                poorMatch: false,
                status: nil
            )
        }

        let alignment: FrameMatcher.Alignment
        if let lastSignature, let frameSignature {
            if let expectedPixels {
                alignment = FrameMatcher.resilientAlignment(
                    previous: lastSignature,
                    next: frameSignature,
                    expectedNewContent: expectedPixels
                )
            } else {
                alignment = FrameMatcher.alignment(
                    previous: lastSignature,
                    next: frameSignature
                )
            }
        } else if let expectedPixels {
            alignment = FrameMatcher.resilientAlignment(
                previous: last,
                next: frame,
                expectedNewContent: expectedPixels
            )
        } else {
            alignment = FrameMatcher.alignment(previous: last, next: frame)
        }

        let consumed = min(frame.height, alignment.nextContentStart + alignment.overlap)
        let newContent = frame.height - consumed
        let minimumUsefulContent = max(14, Int(CGFloat(frame.height) * 0.022))
        let maximumUsefulContent = Int(CGFloat(frame.height) * 0.70)

        if newContent < minimumUsefulContent {
            return FrameCandidateResult(
                accepted: false,
                alignment: nil,
                newContent: 0,
                poorMatch: false,
                status: "当前画面新增内容太少；继续向下滚动即可"
            )
        }
        if newContent > maximumUsefulContent {
            return FrameCandidateResult(
                accepted: false,
                alignment: nil,
                newContent: 0,
                poorMatch: true,
                status: "滚动过快导致重叠太少，已跳过这一帧"
            )
        }

        let expectedForReliability = expectedPixels ?? newContent
        let reliable = recovering
            ? FrameMatcher.isRecoveryReliable(
                alignment,
                expectedNewContent: expectedForReliability,
                frameHeight: frame.height
            )
            : FrameMatcher.isReliable(
                alignment,
                expectedNewContent: expectedForReliability,
                frameHeight: frame.height
            )
        if reliable {
            return FrameCandidateResult(
                accepted: true,
                alignment: alignment,
                newContent: newContent,
                poorMatch: false,
                status: "已采集 \(0) 帧"
            )
        }

        return FrameCandidateResult(
            accepted: false,
            alignment: nil,
            newContent: 0,
            poorMatch: true,
            status: "暂未找到可靠接缝，正在从连续帧中恢复"
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
        totalObservedScroll += abs(event.scrollingDeltaY) * multiplier
        lastScrollTime = Date()
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

    private func queuePreviewStrip(
        _ image: CGImage,
        droppingLeadingSourcePixels drop: Int,
        sourcePixels: Int,
        frameHeight: Int
    ) {
        pendingPreviewStrips.append((image, drop))
        pendingPreviewSourcePixels += sourcePixels
        let now = ProcessInfo.processInfo.systemUptime
        let sourceThreshold = max(96, Int(CGFloat(frameHeight) * previewBatchFraction))
        if pendingPreviewSourcePixels >= sourceThreshold
            || now - lastPreviewFlushTime >= previewMaximumLatency {
            flushPreviewStrips()
            return
        }

        guard previewFlushWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.previewFlushWorkItem = nil
            self?.flushPreviewStrips()
        }
        previewFlushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + previewMaximumLatency, execute: work)
    }

    private func flushPreviewStrips() {
        guard !pendingPreviewStrips.isEmpty, let previewStore else { return }
        previewFlushWorkItem?.cancel()
        previewFlushWorkItem = nil
        let strips = pendingPreviewStrips
        pendingPreviewStrips = []
        pendingPreviewSourcePixels = 0
        for (index, strip) in strips.enumerated() {
            previewStore.append(
                strip.image,
                droppingLeadingSourcePixels: strip.drop,
                rebuildOverview: index == strips.count - 1
            )
        }
        previewCanvas = previewStore.overview
        lastPreviewFlushTime = ProcessInfo.processInfo.systemUptime
        publishPreview()
    }
}

enum FrameMatcher {
    struct Alignment {
        let nextContentStart: Int
        let overlap: Int
        let score: Double
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
                for x in stride(from: xStart, to: xEnd, by: 2) {
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
            let score = energy / Double(samples) + Double(distance) * 0.22
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

        // 先粗搜，再在最优点附近细搜。相比旧版只取几个 patch 做 NCC，
        // 这里使用整段重叠区域的“有纹理行”，GitHub 代码块/表格/图片处更不容易错配。
        for displacement in stride(from: lower, through: upper, by: 2) {
            var score = weightedOverlapScore(previous: a, next: b, displacement: displacement)
            if let expectedGray {
                score += Double(abs(displacement - expectedGray)) * 0.018
            }
            if score < bestScore {
                bestScore = score
                bestDisplacement = displacement
            }
        }

        let refineLower = max(lower, bestDisplacement - 4)
        let refineUpper = min(upper, bestDisplacement + 4)
        for displacement in refineLower...refineUpper {
            var score = weightedOverlapScore(previous: a, next: b, displacement: displacement)
            if let expectedGray {
                score += Double(abs(displacement - expectedGray)) * 0.018
            }
            if score < bestScore {
                bestScore = score
                bestDisplacement = displacement
            }
        }

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
                score: bestScore
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
            score: bestScore
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
        for row in stride(from: rowStart, to: rowEnd, by: 2) {
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
}


enum FrameStitcher {
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
