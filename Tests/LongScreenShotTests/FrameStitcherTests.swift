import CoreGraphics
import XCTest
@testable import LongScreenShot

final class FrameStitcherTests: XCTestCase {
    func testDuplicateDetection() throws {
        let image = try makePattern(width: 120, height: 220)
        XCTAssertLessThan(FrameMatcher.averageDifference(image, image), 0.01)
    }

    func testOverlapAndStitchedDimensions() throws {
        let source = try makePattern(width: 120, height: 400)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 220)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 100, width: 120, height: 220)))
        let overlap = FrameMatcher.overlap(previous: first, next: second)
        XCTAssertEqual(overlap, 120, accuracy: 12)
        let guided = FrameMatcher.alignment(previous: first, next: second, expectedNewContent: 100)
        let guidedNewContent = second.height - guided.nextContentStart - guided.overlap
        XCTAssertEqual(guidedNewContent, 100, accuracy: 5)
        let stitched = try XCTUnwrap(FrameStitcher.stitch([first, second]))
        XCTAssertEqual(stitched.width, 120)
        XCTAssertEqual(stitched.height, 320, accuracy: 12)
        let expected = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: stitched.height)))
        XCTAssertLessThan(FrameMatcher.averageDifference(stitched, expected), 4.0)
    }

    func testNCCAlignmentSurvivesUniformBrightnessChange() throws {
        let source = try makePattern(width: 120, height: 400)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 220)))
        let rawSecond = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 100, width: 120, height: 220)))
        let second = try brighten(rawSecond, alpha: 0.18)
        let alignment = FrameMatcher.alignment(previous: first, next: second, expectedNewContent: 100)
        let newContent = second.height - alignment.nextContentStart - alignment.overlap
        XCTAssertEqual(newContent, 100, accuracy: 6)
        XCTAssertLessThan(alignment.score, 6)
    }

    func testBothMosaicStylesChangePixels() throws {
        let source = try makePattern(width: 180, height: 180)
        let rect = CGRect(x: 0, y: 0, width: 180, height: 180)
        let pixel = try XCTUnwrap(ImageEffects.mosaicPatch(from: source, pixelRectTopLeft: rect, style: .pixel, intensity: 18))
        let blur = try XCTUnwrap(ImageEffects.mosaicPatch(from: source, pixelRectTopLeft: rect, style: .blur, intensity: 18))
        XCTAssertGreaterThan(FrameMatcher.averageDifference(source, pixel), 1.0)
        XCTAssertGreaterThan(FrameMatcher.averageDifference(source, blur), 1.0)
        let stronger = try XCTUnwrap(ImageEffects.mosaicPatch(from: source, pixelRectTopLeft: rect, style: .pixel, intensity: 34))
        XCTAssertGreaterThan(FrameMatcher.averageDifference(pixel, stronger), 1.0)
        let strongerBlur = try XCTUnwrap(ImageEffects.mosaicPatch(from: source, pixelRectTopLeft: rect, style: .blur, intensity: 34))
        XCTAssertGreaterThan(FrameMatcher.averageDifference(blur, strongerBlur), 0.5)
    }

    func testBottomBounceProducesAlmostNoNewContent() throws {
        let source = try makePattern(width: 120, height: 260)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 220)))
        let bounced = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 2, width: 120, height: 220)))
        let shifted = FrameMatcher.smallShiftDifference(previous: first, next: bounced)
        XCTAssertLessThan(shifted.score, 2.5)
        XCTAssertLessThanOrEqual(abs(shifted.shift), 12)
    }

    func testAlignmentRecoversWhenScrollDeltaOverestimatesPageMovement() throws {
        let source = try makePattern(width: 120, height: 440)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 220)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 100, width: 120, height: 220)))
        let alignment = FrameMatcher.resilientAlignment(
            previous: first,
            next: second,
            expectedNewContent: 190
        )
        let newContent = second.height - alignment.nextContentStart - alignment.overlap
        XCTAssertEqual(newContent, 100, accuracy: 7)
        XCTAssertLessThan(alignment.score, 10)
    }

    func testPreviewIsDownsampledInsteadOfFullResolution() throws {
        let source = try makePattern(width: 120, height: 400)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 220)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 100, width: 120, height: 220)))
        let alignment = FrameMatcher.alignment(previous: first, next: second, expectedNewContent: 100)
        let segment = try XCTUnwrap(FrameStitcher.copySegment(
            from: second,
            sourceStart: alignment.nextContentStart + alignment.overlap
        ))
        let firstPreview = try XCTUnwrap(FrameStitcher.scaledSegment(first, targetWidth: 60))
        let segmentPreview = try XCTUnwrap(FrameStitcher.scaledSegment(segment, targetWidth: 60))
        let preview = try XCTUnwrap(FrameStitcher.composeSegments([firstPreview, segmentPreview]))
        XCTAssertEqual(preview.width, 60)
        XCTAssertEqual(preview.height, 160, accuracy: 3)
    }

    func testHighVisualScoreCanRecoverWhenItAgreesWithMeasuredScroll() {
        let githubImageTransition = FrameMatcher.Alignment(
            nextContentStart: 0,
            overlap: 920,
            score: 35
        )
        XCTAssertTrue(FrameMatcher.isReliable(
            githubImageTransition,
            expectedNewContent: 480,
            frameHeight: 1400
        ))
        XCTAssertFalse(FrameMatcher.isReliable(
            githubImageTransition,
            expectedNewContent: 120,
            frameHeight: 1400
        ))
    }

    func testIncrementalSegmentsComposeWithoutKeepingFullFrames() throws {
        let source = try makePattern(width: 120, height: 400)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 220)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 100, width: 120, height: 220)))
        let segment = try XCTUnwrap(FrameStitcher.copySegment(from: second, sourceStart: 120))
        XCTAssertEqual(segment.height, 100)
        let composed = try XCTUnwrap(FrameStitcher.composeSegments([first, segment]))
        XCTAssertEqual(composed.height, 320)
        let expected = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 120, height: 320)))
        XCTAssertLessThan(FrameMatcher.averageDifference(composed, expected), 4)
    }

    func testFastScrollSequenceKeepsContinuousOverlap() throws {
        let source = try makePattern(width: 120, height: 1_500)
        let viewportHeight = 300
        let step = 180
        var frames: [CGImage] = []
        for y in stride(from: 0, through: 900, by: step) {
            frames.append(try XCTUnwrap(source.cropping(to: CGRect(
                x: 0,
                y: y,
                width: 120,
                height: viewportHeight
            ))))
        }
        var segments = [try XCTUnwrap(frames.first)]
        for index in 1..<frames.count {
            let alignment = FrameMatcher.resilientAlignment(
                previous: frames[index - 1],
                next: frames[index],
                expectedNewContent: step
            )
            let movement = viewportHeight - alignment.nextContentStart - alignment.overlap
            XCTAssertEqual(movement, step, accuracy: 7)
            XCTAssertTrue(FrameMatcher.isReliable(
                alignment,
                expectedNewContent: step,
                frameHeight: viewportHeight
            ))
            segments.append(try XCTUnwrap(FrameStitcher.copySegment(
                from: frames[index],
                sourceStart: alignment.nextContentStart + alignment.overlap
            )))
        }
        let composed = try XCTUnwrap(FrameStitcher.composeSegments(segments))
        XCTAssertEqual(composed.height, viewportHeight + (frames.count - 1) * step, accuracy: 7)
        let expected = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: 120,
            height: composed.height
        )))
        XCTAssertLessThan(FrameMatcher.averageDifference(composed, expected), 4)
    }

    func testVeryWideFastScrollKeepsSourceRowPrecision() throws {
        let source = try makeFineRowPattern(width: 3_440, height: 1_700)
        let viewportHeight = 700
        let step = 455 // 65% of the visible height
        let first = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0, y: 0, width: 3_440, height: viewportHeight
        )))
        let second = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0, y: step, width: 3_440, height: viewportHeight
        )))
        let third = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0, y: step * 2, width: 3_440, height: viewportHeight
        )))

        for (previous, next) in [(first, second), (second, third)] {
            let alignment = FrameMatcher.alignment(
                previous: previous,
                next: next,
                expectedNewContent: step
            )
            let movement = viewportHeight - alignment.nextContentStart - alignment.overlap
            XCTAssertEqual(movement, step, accuracy: 2)
            XCTAssertLessThan(alignment.score, 38)
        }
    }

    func testPreviewTilesReplaceTailWithoutGapsOrVerticalFlip() throws {
        let source = try makePattern(width: 600, height: 2_400)
        let first = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0, y: 0, width: 600, height: 600
        )))
        let store = LongCapturePreviewSegmentStore(firstFrame: first, targetWidth: 120)
        var latestTiles: [Int: LongCapturePreviewSegment] = [:]

        func drain() {
            for tile in store.drainPendingSegments() { latestTiles[tile.previewTop] = tile }
        }
        drain()

        for top in [500, 1_000, 1_500] {
            let frame = try XCTUnwrap(source.cropping(to: CGRect(
                x: 0, y: top, width: 600, height: 600
            )))
            store.place(frame, topOffset: top, sourceStart: 100, sourceHeight: 500)
            drain()
        }
        let last = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0, y: 1_800, width: 600, height: 600
        )))
        store.place(last, topOffset: 1_800, sourceStart: 300, sourceHeight: 300)
        drain()

        let previewHeight = store.previewContentHeight
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 120,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for tile in latestTiles.values.sorted(by: { $0.previewTop < $1.previewTop }) {
            context.draw(tile.image, in: CGRect(
                x: 0,
                y: previewHeight - tile.previewTop - tile.previewHeight,
                width: tile.previewWidth,
                height: tile.previewHeight
            ))
        }
        let tiled = try XCTUnwrap(context.makeImage())
        let expectedContext = try XCTUnwrap(CGContext(
            data: nil,
            width: 120,
            height: previewHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        expectedContext.interpolationQuality = .low
        expectedContext.draw(source, in: CGRect(x: 0, y: 0, width: 120, height: previewHeight))
        let expected = try XCTUnwrap(expectedContext.makeImage())
        XCTAssertEqual(tiled.width, expected.width)
        XCTAssertEqual(tiled.height, expected.height)
        XCTAssertLessThan(FrameMatcher.averageDifference(tiled, expected), 4)
        XCTAssertLessThanOrEqual(latestTiles.count, 2)
    }

    func testSeamBacktrackAndTailReplacementPreserveExactContent() throws {
        let source = try makeTextLikePattern(width: 160, height: 420)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 240)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 100, width: 160, height: 240)))
        let nominalStart = 140
        let backtrack = FrameMatcher.safeSeamBacktrack(
            in: second,
            sourceStart: nominalStart,
            maximumBacktrack: 50
        )
        XCTAssertGreaterThan(backtrack, 0)

        var segments = [first]
        XCTAssertTrue(FrameStitcher.trimTail(&segments, pixels: backtrack))
        segments.append(try XCTUnwrap(FrameStitcher.copySegment(
            from: second,
            sourceStart: nominalStart - backtrack
        )))
        let composed = try XCTUnwrap(FrameStitcher.composeSegments(segments))
        XCTAssertEqual(composed.height, 340)
        let expected = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 340)))
        XCTAssertLessThan(FrameMatcher.averageDifference(composed, expected), 1)
    }

    func testPreviewCanvasHasBoundedBackingSize() throws {
        let source = try makePattern(width: 240, height: 1_500)
        let segments = [source, source, source]
        let preview = try XCTUnwrap(FrameStitcher.composePreviewSegments(
            segments,
            maximumWidth: 240,
            maximumHeight: 800
        ))
        XCTAssertLessThanOrEqual(preview.width, 240)
        XCTAssertLessThanOrEqual(preview.height, 801)
    }

    func testAlignmentRetainsSinglePixelVerticalPrecision() throws {
        let source = try makeFineRowPattern(width: 360, height: 900)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 360, height: 520)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 137, width: 360, height: 520)))
        let alignment = FrameMatcher.alignment(
            previous: first,
            next: second,
            expectedNewContent: 137
        )
        let movement = second.height - alignment.nextContentStart - alignment.overlap
        XCTAssertEqual(movement, 137, accuracy: 1)
    }

    func testIncrementalPreviewCanvasStaysBoundedAndKeepsGrowing() throws {
        let source = try makePattern(width: 600, height: 1_800)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 600, height: 600)))
        let replacementTail = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 576, width: 600, height: 124)))
        let store = PreviewOverviewStore(
            sourceWidth: 600,
            maximumWidth: 240,
            maximumHeight: 800,
            chunkHeight: 128
        )
        store.append(first)
        let initial = try XCTUnwrap(store.overview)
        store.append(replacementTail, droppingLeadingSourcePixels: 24)
        let updated = try XCTUnwrap(store.overview)
        XCTAssertLessThanOrEqual(updated.width, 240)
        XCTAssertLessThanOrEqual(updated.height, 800)
        XCTAssertGreaterThan(updated.height, initial.height)
        let expectedSource = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 600, height: 700)))
        let expected = try XCTUnwrap(FrameStitcher.scaledSegment(expectedSource, targetWidth: updated.width))
        XCTAssertEqual(updated.height, expected.height, accuracy: 1)
        XCTAssertLessThan(FrameMatcher.averageDifference(updated, expected), 5)
    }

    func testChunkedOverviewShowsTheWholeDocumentWithoutCumulativeBlur() throws {
        let source = try makePattern(width: 600, height: 1_800)
        let store = PreviewOverviewStore(
            sourceWidth: 600,
            maximumWidth: 200,
            maximumHeight: 300,
            chunkHeight: 128
        )
        for start in stride(from: 0, to: 1_800, by: 300) {
            let segment = try XCTUnwrap(source.cropping(to: CGRect(
                x: 0,
                y: start,
                width: 600,
                height: 300
            )))
            store.append(segment)
        }
        let result = try XCTUnwrap(store.overview)
        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 300)
        let fullThumbnail = try XCTUnwrap(FrameStitcher.scaledSegment(source, targetWidth: 200))
        let expected = try XCTUnwrap(FrameStitcher.composeOverviewChunks(
            [fullThumbnail],
            width: 200,
            maximumHeight: 300
        ))
        XCTAssertLessThan(FrameMatcher.averageDifference(result, expected), 6)
    }

    func testVisualTrackingFastScrollPauseReverseAndSmallFinalTail() throws {
        let source = try makeFineRowPattern(width: 720, height: 3000)
        let height = 600
        func frame(_ top: Int) throws -> CGImage {
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: top, width: 720, height: height)))
        }
        let first = try frame(0)
        let tracker = VisualScrollTracker(first: try XCTUnwrap(FrameMatcher.signature(first)))
        let canvas = LongCaptureCanvasAccumulator(firstFrame: first, maximumHeight: 180000)
        var end = height
        // Includes a 75% viewport jump, a long pause, a reversal and a 7px tail.
        for top in [120, 450, 900, 900, 900, 900, 900, 900, 810, 900, 1250, 1257] {
            let image = try frame(top)
            let result = tracker.observe(try XCTUnwrap(FrameMatcher.signature(image)))
            XCTAssertNotEqual(result, .unmatched, "top=\(top)")
            XCTAssertEqual(tracker.top, top)
            if top + height > end {
                let placement = canvas.place(image, topOffset: tracker.top,
                                             signature: FrameMatcher.signature(image), visuallyVerified: true)
                guard case .placed = placement else { XCTFail("Expected canvas growth"); continue }
                end = top + height
            }
        }
        let actual = try XCTUnwrap(canvas.snapshot().makeImage())
        let expected = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 720, height: end)))
        XCTAssertEqual(actual.height, 1857)
        XCTAssertLessThan(FrameMatcher.averageDifference(actual, expected), 0.01)
    }

    func testVisualTrackingRejectsMissingOverlapAndRecoversOnReturn() throws {
        let source = try makeFineRowPattern(width: 500, height: 3000)
        func signature(_ top: Int) throws -> FrameMatcher.FrameSignature {
            let image = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: top, width: 500, height: 600)))
            return try XCTUnwrap(FrameMatcher.signature(image))
        }
        let tracker = VisualScrollTracker(first: try signature(0))
        XCTAssertEqual(tracker.observe(try signature(1100)), .unmatched)
        XCTAssertEqual(tracker.top, 0)
        XCTAssertEqual(tracker.observe(try signature(240)), .matched(top: 240, movement: 240))
        XCTAssertEqual(tracker.observe(try signature(600)), .matched(top: 600, movement: 360))
    }

    func testVisualTrackingRefusesAmbiguousRepeatedRows() throws {
        let source = try makeTextLikePattern(width: 600, height: 1500)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 600, height: 600)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 101, width: 600, height: 600)))
        let tracker = VisualScrollTracker(first: try XCTUnwrap(FrameMatcher.signature(first)))
        XCTAssertEqual(tracker.observe(try XCTUnwrap(FrameMatcher.signature(second))), .unmatched)
        XCTAssertEqual(tracker.top, 0)
    }

    func testVisualTrackingWideViewportPreservesSingleRows() throws {
        let source = try makeFineRowPattern(width: 3440, height: 1400)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 3440, height: 700)))
        let next = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 455, width: 3440, height: 700)))
        let tracker = VisualScrollTracker(first: try XCTUnwrap(FrameMatcher.signature(first)))
        XCTAssertEqual(tracker.observe(try XCTUnwrap(FrameMatcher.signature(next))), .matched(top: 455, movement: 455))
    }

    // Replays the user's 1948x1458 Retina selection. Run this in Debug too:
    // Release-only tests hid the scalar NCC bottleneck that filled the ingress queue.
    func testRetinaCapturePipelineKeepsUpWith60FPSInDebug() throws {
        let width = 1948, height = 1458
        let source = try makeFineRowPattern(width: width, height: 4400)
        func frame(_ top: Int) throws -> CGImage {
            try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: top, width: width, height: height)))
        }
        let first = try frame(0)
        let tracker = VisualScrollTracker(first: try XCTUnwrap(FrameMatcher.signature(first)))
        let canvas = LongCaptureCanvasAccumulator(firstFrame: first, maximumHeight: 180000)
        let preview = LongCapturePreviewSegmentStore(firstFrame: first, targetWidth: 214)
        // Startup mismatch, stationary frames, then rendered scrolling at 60fps.
        let positions = Array(repeating: 2200, count: 12) + Array(repeating: 0, count: 12)
            + Array(stride(from: 12, through: 1152, by: 12))
        var totalMS = 0.0, backlogMS = 0.0, peakBacklogMS = 0.0
        var copyMS = 0.0, signatureMS = 0.0, trackingMS = 0.0
        for (index, position) in positions.enumerated() {
            let captured = try frame(position)
            let started = ProcessInfo.processInfo.systemUptime
            try autoreleasepool {
                let image = try XCTUnwrap(FrameStitcher.detachedCopy(captured))
                let copied = ProcessInfo.processInfo.systemUptime
                copyMS += (copied - started) * 1000
                let signature = try XCTUnwrap(FrameMatcher.signature(image))
                let signed = ProcessInfo.processInfo.systemUptime
                signatureMS += (signed - copied) * 1000
                let update = tracker.observe(signature)
                trackingMS += (ProcessInfo.processInfo.systemUptime - signed) * 1000
                if index < 12 {
                    XCTAssertEqual(update, .unmatched)
                } else {
                    XCTAssertEqual(tracker.top, position)
                    if position + height > canvas.contentHeight {
                        guard case let .placed(start, added) = canvas.place(image, topOffset: tracker.top,
                            signature: signature, visuallyVerified: true) else {
                            XCTFail("Expected new strip at \(position)"); return
                        }
                        preview.place(image, topOffset: tracker.top, sourceStart: start, sourceHeight: added)
                        _ = preview.drainPendingSegments()
                    }
                }
            }
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            totalMS += ms
            backlogMS = max(0, backlogMS + ms - 1000.0 / 60)
            peakBacklogMS = max(peakBacklogMS, backlogMS)
        }
        print("RetinaProfile copyMS=\(copyMS) signatureMS=\(signatureMS) trackingMS=\(trackingMS)")
        let meanMS = totalMS / Double(positions.count)
        let queuedBytes = ceil(peakBacklogMS / (1000.0 / 60)) * Double(width * height * 4)
        print("RetinaPipeline frames=\(positions.count) meanMS=\(meanMS) peakBacklogMS=\(peakBacklogMS) queuedMiB=\(queuedBytes / 1048576)")
        XCTAssertLessThan(meanMS, 1000.0 / 60, "Processing must sustain the configured frame rate, including Debug builds")
        XCTAssertLessThan(queuedBytes, 192 * 1024 * 1024, "Must not trip the ingress limit at startup")
        XCTAssertEqual(canvas.contentHeight, height + 1152)
    }

    private func makePattern(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in stride(from: 0, to: height, by: 4) {
            let value = CGFloat((y * 37 + y * y * 3) % 255) / 255
            context.setFillColor(red: value, green: 1 - value, blue: CGFloat(y % 83) / 83, alpha: 1)
            context.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 4))
            context.setFillColor(gray: CGFloat((y * 11) % 255) / 255, alpha: 1)
            context.fill(CGRect(x: CGFloat((y * 7) % width), y: CGFloat(y), width: 9, height: 4))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTextLikePattern(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 8, to: height - 8, by: 24) {
            context.setFillColor(gray: 0.12, alpha: 1)
            for x in stride(from: 10, to: width - 12, by: 17) {
                context.fill(CGRect(x: x, y: y, width: 11, height: 9))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeFineRowPattern(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        for y in 0..<height {
            let red = CGFloat((y * 47 + y * y * 3) % 251) / 250
            let green = CGFloat((y * 19 + 37) % 241) / 240
            context.setFillColor(red: red, green: green, blue: 1 - red * 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
            context.setFillColor(gray: CGFloat((y * 31) % 255) / 255, alpha: 1)
            context.fill(CGRect(x: (y * 13) % max(1, width - 15), y: y, width: 15, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func brighten(_ image: CGImage, alpha: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(gray: 1, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(context.makeImage())
    }
}
