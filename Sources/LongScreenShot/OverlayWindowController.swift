import AppKit
import Carbon

final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayWindowController: NSWindowController, CaptureOverlayViewDelegate {
    var onCancel: (() -> Void)?
    var onComplete: ((CGImage, CaptureCompletionAction) -> Void)?
    private let snapshot: ScreenSnapshot
    private let startsInLongMode: Bool
    private var longCaptureService: LongCaptureService?
    private var longCaptureToolbarController: LongCaptureToolbarController?
    private var manualLongCaptureFinishing = false
    private var escapeHotKey: GlobalHotKey?

    init(snapshot: ScreenSnapshot, startsInLongMode: Bool) {
        self.snapshot = snapshot
        self.startsInLongMode = startsInLongMode
        let window = CaptureOverlayWindow(
            contentRect: NSRect(origin: .zero, size: snapshot.screen.frame.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: snapshot.screen
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(snapshot.screen.frame, display: false)
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        let view = CaptureOverlayView(snapshot: snapshot)
        view.delegate = self
        view.startsInLongMode = startsInLongMode
        window.contentView = view
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        escapeHotKey = GlobalHotKey(
            configuration: HotKeyConfiguration(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)
        ) { [weak self] in
            guard let self else { return }
            if self.longCaptureService != nil { self.cancelManualLongCapture() }
            else { self.onCancel?() }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.setFrame(snapshot.screen.frame, display: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)
        (window?.contentView as? CaptureOverlayView)?.refreshHoverFromCurrentPointer()
        NSCursor.crosshair.push()
    }

    override func close() {
        longCaptureService?.cancel()
        longCaptureService = nil
        longCaptureToolbarController?.close()
        longCaptureToolbarController = nil
        escapeHotKey = nil
        NSCursor.pop()
        super.close()
    }

    func overlayDidCancel(_ view: CaptureOverlayView) { onCancel?() }

    func overlay(_ view: CaptureOverlayView, requested action: CaptureCompletionAction) {
        guard let image = view.renderedSelection() else { return }
        onComplete?(image, action)
    }

    func overlayRequestedLongCapture(_ view: CaptureOverlayView) {
        guard let selection = view.selection, let window else { return }
        guard let detachedToolbar = view.beginManualLongCapture() else { return }
        window.displayIfNeeded()
        window.ignoresMouseEvents = true

        let toolbarController = LongCaptureToolbarController(
            screen: snapshot.screen,
            localFrame: detachedToolbar.frame,
            toolbar: detachedToolbar.toolbar
        )
        longCaptureToolbarController = toolbarController
        toolbarController.showWindow(nil)
        toolbarController.window?.orderFrontRegardless()

        let service = LongCaptureService(
            snapshot: snapshot,
            selection: selection,
            overlayWindowID: CGWindowID(window.windowNumber)
        )
        longCaptureService = service
        service.onPreview = { [weak view] image, count in
            view?.updateManualLongCapturePreview(image: image, frameCount: count)
        }
        service.onStatus = { [weak view] text, isError in
            view?.setManualLongCaptureStatus(text, isError: isError)
        }
        service.start()
        NSApp.deactivate()
    }

    func overlayRequestedFinishLongCapture(_ view: CaptureOverlayView, saveAfter: Bool) {
        finishManualLongCapture(saveAfter: saveAfter)
    }

    func overlayRequestedCancelLongCapture(_ view: CaptureOverlayView) {
        cancelManualLongCapture()
    }

    private func finishManualLongCapture(saveAfter: Bool) {
        guard !manualLongCaptureFinishing else { return }
        manualLongCaptureFinishing = true
        (window?.contentView as? CaptureOverlayView)?.setManualLongCaptureStatus(L10n.tr("long.finishing"), isError: false)
        longCaptureService?.finish { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(image):
                self.longCaptureService = nil
                self.longCaptureToolbarController?.close()
                self.longCaptureToolbarController = nil
                self.window?.ignoresMouseEvents = false
                if saveAfter {
                    self.window?.orderOut(nil)
                    ImageExporter.showSavePanel(for: image, preferredScreen: self.snapshot.screen) { [weak self] in self?.onCancel?() }
                } else {
                    ImageExporter.copyToPasteboard(image)
                    self.onCancel?()
                }
            case let .failure(error):
                self.manualLongCaptureFinishing = false
                (self.window?.contentView as? CaptureOverlayView)?.setManualLongCaptureStatus(
                    error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private func cancelManualLongCapture() {
        longCaptureService?.cancel()
        longCaptureService = nil
        longCaptureToolbarController?.close()
        longCaptureToolbarController = nil
        window?.ignoresMouseEvents = false
        onCancel?()
    }

}

protocol CaptureOverlayViewDelegate: AnyObject {
    func overlayDidCancel(_ view: CaptureOverlayView)
    func overlay(_ view: CaptureOverlayView, requested action: CaptureCompletionAction)
    func overlayRequestedLongCapture(_ view: CaptureOverlayView)
    func overlayRequestedFinishLongCapture(_ view: CaptureOverlayView, saveAfter: Bool)
    func overlayRequestedCancelLongCapture(_ view: CaptureOverlayView)
}

final class CaptureOverlayView: NSView, CaptureToolbarDelegate, NSTextFieldDelegate {
    private enum SelectionAdjustment: Equatable {
        case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
    }
    private enum AnnotationAdjustment: Equatable {
        case move
        case resize(SelectionAdjustment)
        case arrowStart
        case arrowEnd
    }
    private struct AnnotationHit {
        let index: Int
        let adjustment: AnnotationAdjustment
    }
    private struct MosaicPreviewKey: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let style: MosaicStyle
        let intensity: Int
    }
    weak var delegate: CaptureOverlayViewDelegate?
    let snapshot: ScreenSnapshot
    var startsInLongMode = false
    private(set) var selection: CGRect?
    private var annotations: [Annotation] = []
    private var undoSnapshots: [[Annotation]] = []
    private var redoSnapshots: [[Annotation]] = []
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var activeTool: AnnotationTool?
    private var activePoints: [CGPoint] = []
    private var toolbar: CaptureToolbarView?
    private var tooltipLabel: NSTextField?
    private let windowCandidates: [WindowCandidate]
    private var hoveredWindow: WindowCandidate?
    private var didDragSelection = false
    private var selectionAdjustment: SelectionAdjustment?
    private var selectionBeforeAdjustment: CGRect?
    private var selectedAnnotationIndex: Int?
    private var annotationAdjustment: AnnotationAdjustment?
    private var annotationBeforeAdjustment: Annotation?
    private var annotationBoundsBeforeAdjustment: CGRect?
    private var annotationsBeforeAdjustment: [Annotation] = []
    private var didAdjustAnnotation = false
    private var manualLongCaptureActive = false
    private var manualToolbarOverlayFrame: CGRect?
    private var manualPreviewImage: NSImage?
    private var manualFrameCount = 0
    private var manualCaptureStatus = L10n.tr("long.scrollHint")
    private var manualCaptureStatusIsError = false
    private var annotationColor = NSColor.systemRed
    private var strokeWidth: CGFloat = 4
    private var textSize: CGFloat = 24
    private var mosaicStyle: MosaicStyle = .pixel
    private var mosaicIntensity: CGFloat = 18
    private var selectedMosaicIndex: Int?
    private var mosaicPreviewCache: [Int: (key: MosaicPreviewKey, image: NSImage)] = [:]
    private var quickMosaicPreviewCache: [Int: (key: MosaicPreviewKey, image: NSImage)] = [:]
    private var mosaicPendingKeys: [Int: MosaicPreviewKey] = [:]
    private var mosaicRenderWork: [Int: DispatchWorkItem] = [:]
    private let mosaicRenderQueue = DispatchQueue(label: "longscreenshot.mosaic.preview", qos: .userInteractive)
    private var stylePanel: AnnotationStylePanelView?
    private var inlineTextField: NSTextField?
    private var inlineTextPoint: CGPoint?

    init(snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        self.windowCandidates = WindowDetector.candidates(in: snapshot)
        super.init(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    func refreshHoverFromCurrentPointer() {
        guard let window else { return }
        updateHoveredWindow(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selection == nil, dragStart == nil {
            updateHoveredWindow(at: point)
        } else if let hit = annotationHit(at: point) {
            cursor(for: hit.adjustment).set()
        } else if activeTool == nil, annotations.isEmpty, let adjustment = selectionAdjustment(at: point) {
            cursor(for: adjustment).set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private func updateHoveredWindow(at point: CGPoint) {
        let candidate = windowCandidates.first(where: { $0.rect.contains(point) })
        if candidate?.rect != hoveredWindow?.rect {
            hoveredWindow = candidate
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { delegate?.overlayDidCancel(self); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redoLastAnnotation() }
            else { undoLastAnnotation() }
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !isPointInsideToolbar(point) else { return }
        if selection == nil {
            dragStart = point
            dragCurrent = point
            didDragSelection = false
            return
        }
        if let hit = annotationHit(at: point) {
            selectAnnotation(at: hit.index)
            startAnnotationAdjustment(hit.adjustment, at: point)
            return
        }
        if activeTool == nil, annotations.isEmpty, let adjustment = selectionAdjustment(at: point) {
            selectionAdjustment = adjustment
            selectionBeforeAdjustment = selection
            dragStart = point
            dragCurrent = point
            if adjustment == .move { NSCursor.closedHand.set() }
            return
        }
        guard let selection, selection.contains(point), let tool = activeTool else { return }
        selectedAnnotationIndex = nil
        selectedMosaicIndex = nil
        dragStart = point
        dragCurrent = point
        if tool == .pen { activePoints = [point] }
        if tool == .text {
            beginInlineTextEditing(at: point)
            dragStart = nil
            dragCurrent = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let adjustment = annotationAdjustment {
            updateAnnotationAdjustment(adjustment, current: point)
            needsDisplay = true
            return
        }
        if let adjustment = selectionAdjustment,
           let original = selectionBeforeAdjustment,
           let start = dragStart {
            selection = adjustedSelection(original, adjustment: adjustment, delta: CGPoint(x: point.x - start.x, y: point.y - start.y))
            positionToolbar()
            needsDisplay = true
            return
        }
        if let selection, activeTool != nil {
            dragCurrent = CGPoint(x: min(max(point.x, selection.minX), selection.maxX),
                                  y: min(max(point.y, selection.minY), selection.maxY))
            if activeTool == .pen { activePoints.append(dragCurrent!) }
        } else {
            if let dragStart, hypot(point.x - dragStart.x, point.y - dragStart.y) > 3 {
                didDragSelection = true
                hoveredWindow = nil
            }
            dragCurrent = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                                  y: min(max(point.y, bounds.minY), bounds.maxY))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if annotationAdjustment != nil {
            finishAnnotationAdjustment()
            return
        }
        if selectionAdjustment != nil {
            selectionAdjustment = nil
            selectionBeforeAdjustment = nil
            dragStart = nil
            dragCurrent = nil
            NSCursor.openHand.set()
            needsDisplay = true
            return
        }
        guard let start = dragStart, let end = dragCurrent else { return }
        defer { dragStart = nil; dragCurrent = nil; activePoints = []; needsDisplay = true }
        if selection == nil {
            let rect = (!didDragSelection ? hoveredWindow?.rect : nil) ?? CGRect(between: start, and: end).integral
            guard rect.width >= 8, rect.height >= 8 else { return }
            selection = rect
            hoveredWindow = nil
            installToolbar(for: rect)
            if startsInLongMode {
                toolbar?.selectLongCapture()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self else { return }
                    self.delegate?.overlayRequestedLongCapture(self)
                }
            }
            return
        }
        guard let tool = activeTool else { return }
        switch tool {
        case .rectangle: record(.rectangle(CGRect(between: start, and: end), annotationColor, strokeWidth))
        case .ellipse: record(.ellipse(CGRect(between: start, and: end), annotationColor, strokeWidth))
        case .arrow: record(.arrow(start, end, annotationColor, strokeWidth))
        case .pen: record(.pen(activePoints, annotationColor, strokeWidth))
        case .mosaicPixel, .mosaicBlur:
            selectedMosaicIndex = record(.mosaic(
                CGRect(between: start, and: end),
                mosaicStyle,
                mosaicIntensity
            ))
        case .text: break
        }
    }

    private func beginInlineTextEditing(at point: CGPoint) {
        commitInlineTextEditing()
        guard let selection else { return }
        let width = min(300, selection.maxX - point.x)
        let field = NSTextField(frame: CGRect(
            x: point.x,
            y: max(selection.minY, point.y - textSize * 0.25),
            width: max(100, width),
            height: max(30, textSize + 12)
        ))
        field.delegate = self
        field.font = .systemFont(ofSize: textSize, weight: .semibold)
        field.textColor = annotationColor
        field.backgroundColor = NSColor.black.withAlphaComponent(0.48)
        field.drawsBackground = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.placeholderString = L10n.tr("text.placeholder")
        addSubview(field)
        inlineTextField = field
        inlineTextPoint = point
        window?.makeFirstResponder(field)
    }

    private func commitInlineTextEditing() {
        guard let field = inlineTextField else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, let point = inlineTextPoint {
            record(.text(value, point, annotationColor, textSize))
        }
        field.removeFromSuperview()
        inlineTextField = nil
        inlineTextPoint = nil
        needsDisplay = true
    }

    private func cancelInlineTextEditing() {
        inlineTextField?.removeFromSuperview()
        inlineTextField = nil
        inlineTextPoint = nil
        window?.makeFirstResponder(self)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineTextEditing()
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineTextEditing()
            delegate?.overlayDidCancel(self)
            return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        if manualLongCaptureActive {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            drawManualLongCaptureFrame()
            return
        }
        let image = NSImage(cgImage: snapshot.image, size: bounds.size)
        image.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()

        guard let selection else {
            if let preview = currentSelectionPreview {
                reveal(image: image, in: preview.rect)
                NSColor.controlAccentColor.setStroke()
                let path = NSBezierPath(rect: preview.rect)
                path.lineWidth = 2
                path.stroke()
                drawDimensions(preview.rect)
                if let label = preview.label { drawWindowLabel(label, rect: preview.rect) }
            }
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: selection).addClip()
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        for (index, annotation) in annotations.enumerated() {
            drawPreview(annotation, context: cg, cacheSlot: index)
        }
        drawSelectedAnnotationHandles()
        if annotationAdjustment == nil,
           selectionAdjustment == nil,
           let start = dragStart,
           let end = dragCurrent,
           let tool = activeTool {
            let preview: Annotation
            switch tool {
            case .rectangle: preview = .rectangle(CGRect(between: start, and: end), annotationColor, strokeWidth)
            case .ellipse: preview = .ellipse(CGRect(between: start, and: end), annotationColor, strokeWidth)
            case .arrow: preview = .arrow(start, end, annotationColor, strokeWidth)
            case .pen: preview = .pen(activePoints, annotationColor, strokeWidth)
            case .mosaicPixel, .mosaicBlur:
                preview = .mosaic(CGRect(between: start, and: end), mosaicStyle, mosaicIntensity)
            case .text: return
            }
            drawPreview(preview, context: cg, cacheSlot: -1)
        }

        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()
        if activeTool == nil, annotations.isEmpty { drawSelectionHandles(selection) }
        drawDimensions(selection)
    }

    private func drawPreview(_ annotation: Annotation, context: CGContext, cacheSlot: Int? = nil) {
        if case let .text(text, point, color, size) = annotation {
            text.draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: color
            ])
        } else if case let .mosaic(rect, style, intensity) = annotation {
            let slot = cacheSlot ?? -1
            let key = mosaicPreviewKey(rect: rect, style: style, intensity: intensity)
            if let cached = mosaicPreviewCache[slot], cached.key == key {
                cached.image.draw(in: rect)
            } else if let quick = quickMosaicPreview(slot: slot, rect: rect, style: style, intensity: intensity) {
                quick.draw(in: rect)
            }
            if mosaicPreviewCache[slot]?.key != key, mosaicPendingKeys[slot] != key {
                scheduleMosaicPreview(
                    slot: slot,
                    key: key,
                    rect: rect,
                    style: style,
                    intensity: intensity
                )
            }
        } else {
            AnnotationRenderer.draw(annotation, in: context)
        }
    }

    private func quickMosaicPreview(
        slot: Int,
        rect: CGRect,
        style: MosaicStyle,
        intensity: CGFloat
    ) -> NSImage? {
        let key = quickMosaicPreviewKey(rect: rect, style: style, intensity: intensity)
        if let cached = quickMosaicPreviewCache[slot], cached.key == key {
            return cached.image
        }
        guard let pixelRect = snapshot.pixelRect(for: rect),
              let patch = ImageEffects.quickMosaicPreviewPatch(
                from: snapshot.image,
                pixelRectTopLeft: pixelRect,
                style: style,
                intensity: intensity
              ) else { return nil }
        let image = NSImage(cgImage: patch, size: rect.size)
        quickMosaicPreviewCache[slot] = (key, image)
        return image
    }

    private func quickMosaicPreviewKey(rect: CGRect, style: MosaicStyle, intensity: CGFloat) -> MosaicPreviewKey {
        MosaicPreviewKey(
            x: Int(round(rect.minX / 3)),
            y: Int(round(rect.minY / 3)),
            width: Int(round(rect.width / 3)),
            height: Int(round(rect.height / 3)),
            style: style,
            intensity: Int(round(intensity))
        )
    }

    private func annotationHit(at point: CGPoint) -> AnnotationHit? {
        guard let selection, selection.contains(point) else { return nil }
        if let index = selectedAnnotationIndex, annotations.indices.contains(index) {
            let annotation = annotations[index]
            if let adjustment = visibleHandleHit(for: annotation, at: point) {
                return AnnotationHit(index: index, adjustment: adjustment)
            }
        }

        for index in annotations.indices.reversed() {
            let annotation = annotations[index]
            if let adjustment = visibleHandleHit(for: annotation, at: point) {
                return AnnotationHit(index: index, adjustment: adjustment)
            }
            if annotationContains(annotation, point: point) {
                return AnnotationHit(index: index, adjustment: .move)
            }
        }
        return nil
    }

    private func visibleHandleHit(for annotation: Annotation, at point: CGPoint) -> AnnotationAdjustment? {
        if case let .arrow(start, end, _, _) = annotation {
            let hit: CGFloat = 15
            if distance(point, start) <= hit { return .arrowStart }
            if distance(point, end) <= hit { return .arrowEnd }
        }
        let bounds = annotationBounds(annotation)
        guard bounds.width >= 4, bounds.height >= 4,
              let adjustment = boxHandle(at: point, in: bounds) else { return nil }
        return .resize(adjustment)
    }

    private func annotationContains(_ annotation: Annotation, point: CGPoint) -> Bool {
        let bounds = annotationBounds(annotation)
        let hit: CGFloat = 12
        switch annotation {
        case let .arrow(start, end, _, width):
            return distance(point, toSegmentFrom: start, to: end) <= max(hit, width + 4)
                || bounds.insetBy(dx: -hit, dy: -hit).contains(point)
        case let .pen(points, _, width):
            guard points.count > 1 else { return bounds.insetBy(dx: -hit, dy: -hit).contains(point) }
            for index in 1..<points.count where distance(point, toSegmentFrom: points[index - 1], to: points[index]) <= max(hit, width + 3) {
                return true
            }
            return false
        default:
            return bounds.insetBy(dx: -hit, dy: -hit).contains(point)
        }
    }

    private func annotationBounds(_ annotation: Annotation) -> CGRect {
        switch annotation {
        case let .rectangle(rect, _, width), let .ellipse(rect, _, width):
            return rect.standardized.insetBy(dx: -max(3, width / 2), dy: -max(3, width / 2))
        case let .mosaic(rect, _, _):
            return rect.standardized
        case let .arrow(start, end, _, width):
            return CGRect(between: start, and: end).standardized.insetBy(dx: -max(8, width * 2), dy: -max(8, width * 2))
        case let .text(text, point, _, size):
            let measured = (text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold)
            ])
            return CGRect(
                x: point.x,
                y: point.y,
                width: max(18, measured.width),
                height: max(16, measured.height)
            ).insetBy(dx: -4, dy: -3)
        case let .pen(points, _, width):
            guard let first = points.first else { return .zero }
            var minX = first.x
            var maxX = first.x
            var minY = first.y
            var maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x)
                maxX = max(maxX, point.x)
                minY = min(minY, point.y)
                maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -max(6, width), dy: -max(6, width))
        }
    }

    private func drawSelectedAnnotationHandles() {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        let annotation = annotations[index]
        let bounds = annotationBounds(annotation)
        guard bounds.width > 1, bounds.height > 1 else { return }

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.4
        let pattern: [CGFloat] = [4, 3]
        outline.setLineDash(pattern, count: pattern.count, phase: 0)
        outline.stroke()

        for point in handlePoints(for: bounds) {
            drawHandle(at: point, size: 10)
        }
        if case let .arrow(start, end, _, _) = annotation {
            drawHandle(at: start, size: 12)
            drawHandle(at: end, size: 12)
        }
    }

    private func drawHandle(at point: CGPoint, size: CGFloat) {
        let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5)
        NSColor.white.setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func handlePoints(for rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
    }

    private func boxHandle(at point: CGPoint, in rect: CGRect) -> SelectionAdjustment? {
        let hit: CGFloat = 14
        let nearLeft = abs(point.x - rect.minX) <= hit
        let nearRight = abs(point.x - rect.maxX) <= hit
        let nearBottom = abs(point.y - rect.minY) <= hit
        let nearTop = abs(point.y - rect.maxY) <= hit
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft, point.y >= rect.minY - hit, point.y <= rect.maxY + hit { return .left }
        if nearRight, point.y >= rect.minY - hit, point.y <= rect.maxY + hit { return .right }
        if nearTop, point.x >= rect.minX - hit, point.x <= rect.maxX + hit { return .top }
        if nearBottom, point.x >= rect.minX - hit, point.x <= rect.maxX + hit { return .bottom }
        return nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func distance(_ point: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, a) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(point, projection)
    }

    private var currentSelectionPreview: (rect: CGRect, label: String?)? {
        if didDragSelection, let start = dragStart, let end = dragCurrent {
            return (CGRect(between: start, and: end), nil)
        }
        if let hoveredWindow { return (hoveredWindow.rect, hoveredWindow.label) }
        return nil
    }

    private func reveal(image: NSImage, in rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWindowLabel(_ label: String, rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.9)
        ]
        label.draw(at: CGPoint(x: rect.minX, y: max(4, rect.minY - 19)), withAttributes: attributes)
    }

    private func drawDimensions(_ rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        text.draw(at: CGPoint(x: rect.minX, y: min(bounds.maxY - 20, rect.maxY + 5)), withAttributes: attrs)
    }

    private func selectionAdjustment(at point: CGPoint) -> SelectionAdjustment? {
        guard let selection else { return nil }
        let hit: CGFloat = 8
        let nearLeft = abs(point.x - selection.minX) <= hit
        let nearRight = abs(point.x - selection.maxX) <= hit
        let nearBottom = abs(point.y - selection.minY) <= hit
        let nearTop = abs(point.y - selection.maxY) <= hit
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft, point.y >= selection.minY - hit, point.y <= selection.maxY + hit { return .left }
        if nearRight, point.y >= selection.minY - hit, point.y <= selection.maxY + hit { return .right }
        if nearTop, point.x >= selection.minX - hit, point.x <= selection.maxX + hit { return .top }
        if nearBottom, point.x >= selection.minX - hit, point.x <= selection.maxX + hit { return .bottom }
        return selection.contains(point) ? .move : nil
    }

    private func cursor(for adjustment: SelectionAdjustment) -> NSCursor {
        switch adjustment {
        case .move: return .openHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return Self.diagonalResizeDownCursor
        case .topRight, .bottomLeft: return Self.diagonalResizeUpCursor
        }
    }

    private func cursor(for adjustment: AnnotationAdjustment) -> NSCursor {
        switch adjustment {
        case .move:
            return .openHand
        case .arrowStart, .arrowEnd:
            return .crosshair
        case let .resize(selectionAdjustment):
            return cursor(for: selectionAdjustment)
        }
    }

    private static let diagonalResizeDownCursor: NSCursor = makeDiagonalResizeCursor(isForwardSlash: false)
    private static let diagonalResizeUpCursor: NSCursor = makeDiagonalResizeCursor(isForwardSlash: true)

    private static func makeDiagonalResizeCursor(isForwardSlash: Bool) -> NSCursor {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            let start = isForwardSlash ? CGPoint(x: 5, y: 19) : CGPoint(x: 5, y: 5)
            let end = isForwardSlash ? CGPoint(x: 19, y: 5) : CGPoint(x: 19, y: 19)
            func drawLine(width: CGFloat, color: NSColor) {
                color.setStroke()
                let line = NSBezierPath()
                line.move(to: start)
                line.line(to: end)
                line.lineWidth = width
                line.lineCapStyle = .round
                line.stroke()
            }
            drawLine(width: 5.2, color: .white)
            drawLine(width: 2.2, color: .black)

            func arrowHead(at tip: CGPoint, toward other: CGPoint, width: CGFloat, color: NSColor) {
                let angle = atan2(tip.y - other.y, tip.x - other.x)
                let length: CGFloat = 5.8
                color.setStroke()
                let head = NSBezierPath()
                head.move(to: CGPoint(
                    x: tip.x - cos(angle - .pi / 6) * length,
                    y: tip.y - sin(angle - .pi / 6) * length
                ))
                head.line(to: tip)
                head.line(to: CGPoint(
                    x: tip.x - cos(angle + .pi / 6) * length,
                    y: tip.y - sin(angle + .pi / 6) * length
                ))
                head.lineWidth = width
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                head.stroke()
            }
            arrowHead(at: start, toward: end, width: 5.2, color: .white)
            arrowHead(at: end, toward: start, width: 5.2, color: .white)
            arrowHead(at: start, toward: end, width: 2.2, color: .black)
            arrowHead(at: end, toward: start, width: 2.2, color: .black)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }

    private func adjustedSelection(
        _ original: CGRect,
        adjustment: SelectionAdjustment,
        delta: CGPoint
    ) -> CGRect {
        let minimum: CGFloat = 40
        if adjustment == .move {
            let x = min(max(bounds.minX, original.minX + delta.x), bounds.maxX - original.width)
            let y = min(max(bounds.minY, original.minY + delta.y), bounds.maxY - original.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: original.size).integral
        }

        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if [.left, .topLeft, .bottomLeft].contains(adjustment) {
            minX = min(max(bounds.minX, original.minX + delta.x), maxX - minimum)
        }
        if [.right, .topRight, .bottomRight].contains(adjustment) {
            maxX = max(min(bounds.maxX, original.maxX + delta.x), minX + minimum)
        }
        if [.bottom, .bottomLeft, .bottomRight].contains(adjustment) {
            minY = min(max(bounds.minY, original.minY + delta.y), maxY - minimum)
        }
        if [.top, .topLeft, .topRight].contains(adjustment) {
            maxY = max(min(bounds.maxY, original.maxY + delta.y), minY + minimum)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    private func startAnnotationAdjustment(_ adjustment: AnnotationAdjustment, at point: CGPoint) {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        annotationAdjustment = adjustment
        annotationBeforeAdjustment = annotations[index]
        annotationBoundsBeforeAdjustment = annotationBounds(annotations[index])
        annotationsBeforeAdjustment = annotations
        didAdjustAnnotation = false
        dragStart = point
        dragCurrent = point
        if adjustment == .move { NSCursor.closedHand.set() }
    }

    private func updateAnnotationAdjustment(_ adjustment: AnnotationAdjustment, current point: CGPoint) {
        guard let selection,
              let index = selectedAnnotationIndex,
              annotations.indices.contains(index),
              let original = annotationBeforeAdjustment,
              let originalBounds = annotationBoundsBeforeAdjustment,
              let start = dragStart else { return }
        let clipped = CGPoint(
            x: min(max(point.x, selection.minX), selection.maxX),
            y: min(max(point.y, selection.minY), selection.maxY)
        )
        dragCurrent = clipped
        didAdjustAnnotation = didAdjustAnnotation || distance(start, clipped) > 0.5
        annotations[index] = adjustedAnnotation(
            original,
            adjustment: adjustment,
            originalBounds: originalBounds,
            start: start,
            current: clipped,
            limit: selection
        )
        invalidateMosaicPreview(slot: index)
    }

    private func finishAnnotationAdjustment() {
        if didAdjustAnnotation, !annotationsBeforeAdjustment.isEmpty {
            pushUndoSnapshot(annotationsBeforeAdjustment)
        }
        annotationAdjustment = nil
        annotationBeforeAdjustment = nil
        annotationBoundsBeforeAdjustment = nil
        annotationsBeforeAdjustment = []
        didAdjustAnnotation = false
        dragStart = nil
        dragCurrent = nil
        NSCursor.openHand.set()
        needsDisplay = true
    }

    private func adjustedAnnotation(
        _ annotation: Annotation,
        adjustment: AnnotationAdjustment,
        originalBounds: CGRect,
        start: CGPoint,
        current: CGPoint,
        limit: CGRect
    ) -> Annotation {
        switch adjustment {
        case .move:
            let delta = clampedMoveDelta(
                dx: current.x - start.x,
                dy: current.y - start.y,
                bounds: originalBounds,
                limit: limit
            )
            return offsetAnnotation(annotation, dx: delta.x, dy: delta.y)
        case let .resize(handle):
            let resizedBounds = adjustedAnnotationRect(
                originalBounds,
                adjustment: handle,
                delta: CGPoint(x: current.x - start.x, y: current.y - start.y),
                limit: limit
            )
            return resizeAnnotation(annotation, from: originalBounds, to: resizedBounds)
        case .arrowStart:
            if case let .arrow(_, end, color, width) = annotation {
                return .arrow(current, end, color, width)
            }
            return annotation
        case .arrowEnd:
            if case let .arrow(startPoint, _, color, width) = annotation {
                return .arrow(startPoint, current, color, width)
            }
            return annotation
        }
    }

    private func adjustedAnnotationRect(
        _ original: CGRect,
        adjustment: SelectionAdjustment,
        delta: CGPoint,
        limit: CGRect
    ) -> CGRect {
        let minimum: CGFloat = 16
        if adjustment == .move {
            let move = clampedMoveDelta(dx: delta.x, dy: delta.y, bounds: original, limit: limit)
            return original.offsetBy(dx: move.x, dy: move.y).integral
        }

        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if [.left, .topLeft, .bottomLeft].contains(adjustment) {
            minX = min(max(limit.minX, original.minX + delta.x), maxX - minimum)
        }
        if [.right, .topRight, .bottomRight].contains(adjustment) {
            maxX = max(min(limit.maxX, original.maxX + delta.x), minX + minimum)
        }
        if [.bottom, .bottomLeft, .bottomRight].contains(adjustment) {
            minY = min(max(limit.minY, original.minY + delta.y), maxY - minimum)
        }
        if [.top, .topLeft, .topRight].contains(adjustment) {
            maxY = max(min(limit.maxY, original.maxY + delta.y), minY + minimum)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
    }

    private func clampedMoveDelta(dx: CGFloat, dy: CGFloat, bounds: CGRect, limit: CGRect) -> CGPoint {
        var x = dx
        var y = dy
        if bounds.minX + x < limit.minX { x = limit.minX - bounds.minX }
        if bounds.maxX + x > limit.maxX { x = limit.maxX - bounds.maxX }
        if bounds.minY + y < limit.minY { y = limit.minY - bounds.minY }
        if bounds.maxY + y > limit.maxY { y = limit.maxY - bounds.maxY }
        return CGPoint(x: x, y: y)
    }

    private func offsetAnnotation(_ annotation: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        switch annotation {
        case let .rectangle(rect, color, width):
            return .rectangle(rect.offsetBy(dx: dx, dy: dy), color, width)
        case let .ellipse(rect, color, width):
            return .ellipse(rect.offsetBy(dx: dx, dy: dy), color, width)
        case let .arrow(start, end, color, width):
            return .arrow(
                CGPoint(x: start.x + dx, y: start.y + dy),
                CGPoint(x: end.x + dx, y: end.y + dy),
                color,
                width
            )
        case let .text(text, point, color, size):
            return .text(text, CGPoint(x: point.x + dx, y: point.y + dy), color, size)
        case let .pen(points, color, width):
            return .pen(points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, color, width)
        case let .mosaic(rect, style, intensity):
            return .mosaic(rect.offsetBy(dx: dx, dy: dy), style, intensity)
        }
    }

    private func resizeAnnotation(_ annotation: Annotation, from original: CGRect, to target: CGRect) -> Annotation {
        func transform(_ point: CGPoint) -> CGPoint {
            guard original.width > 0, original.height > 0 else { return target.origin }
            let xRatio = (point.x - original.minX) / original.width
            let yRatio = (point.y - original.minY) / original.height
            return CGPoint(
                x: target.minX + xRatio * target.width,
                y: target.minY + yRatio * target.height
            )
        }
        switch annotation {
        case let .rectangle(_, color, width):
            return .rectangle(target, color, width)
        case let .ellipse(_, color, width):
            return .ellipse(target, color, width)
        case let .mosaic(_, style, intensity):
            return .mosaic(target, style, intensity)
        case let .arrow(start, end, color, width):
            return .arrow(transform(start), transform(end), color, width)
        case let .pen(points, color, width):
            return .pen(points.map(transform), color, width)
        case let .text(text, point, color, size):
            let scale = max(0.35, min(6, max(target.width / max(1, original.width), target.height / max(1, original.height))))
            return .text(text, transform(point), color, max(8, min(160, size * scale)))
        }
    }

    private func drawSelectionHandles(_ rect: CGRect) {
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for point in points {
            let handle = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
            NSColor.white.setFill()
            handle.fill()
            NSColor.controlAccentColor.setStroke()
            handle.lineWidth = 1.5
            handle.stroke()
        }
    }

    private func installToolbar(for selection: CGRect) {
        let bar = CaptureToolbarView()
        bar.delegate = self
        addSubview(bar)
        toolbar = bar
        positionToolbar()
    }

    private func positionToolbar() {
        guard let selection, let toolbar else { return }
        let size = toolbar.fittingSize
        let x = max(10, min(selection.midX - size.width / 2, bounds.width - size.width - 10))
        let preferredBelow = selection.minY - size.height - 10
        let y = preferredBelow >= 10 ? preferredBelow : min(bounds.height - size.height - 10, selection.maxY + 10)
        toolbar.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func isPointInsideToolbar(_ point: CGPoint) -> Bool { toolbar?.frame.contains(point) == true }

    func toolbar(_ toolbar: CaptureToolbarView, selected tool: AnnotationTool?) {
        if activeTool == .text, tool != .text { commitInlineTextEditing() }
        activeTool = tool
        if tool == .mosaicPixel || tool == .mosaicBlur {
            if selectedMosaicIndex == nil {
                selectedMosaicIndex = annotations.indices.reversed().first {
                    if case .mosaic = annotations[$0] { return true }
                    return false
                }
            }
            if let selectedMosaicIndex { selectedAnnotationIndex = selectedMosaicIndex }
            loadSelectedMosaicStyle()
        } else {
            selectedMosaicIndex = nil
        }
        updateStylePanel(for: tool)
    }
    func toolbar(_ toolbar: CaptureToolbarView, hoveredDescription description: String?) {
        showToolbarTooltip(description)
    }
    func toolbarRequestedCancel(_ toolbar: CaptureToolbarView) {
        cancelInlineTextEditing()
        if manualLongCaptureActive { delegate?.overlayRequestedCancelLongCapture(self) }
        else { delegate?.overlayDidCancel(self) }
    }
    func toolbarRequestedCopy(_ toolbar: CaptureToolbarView) {
        commitInlineTextEditing()
        if manualLongCaptureActive { delegate?.overlayRequestedFinishLongCapture(self, saveAfter: false) }
        else { delegate?.overlay(self, requested: .copy) }
    }
    func toolbarRequestedSave(_ toolbar: CaptureToolbarView) {
        commitInlineTextEditing()
        if manualLongCaptureActive { delegate?.overlayRequestedFinishLongCapture(self, saveAfter: true) }
        else { delegate?.overlay(self, requested: .save) }
    }
    func toolbarRequestedPin(_ toolbar: CaptureToolbarView) { delegate?.overlay(self, requested: .pin) }
    func toolbarRequestedOCR(_ toolbar: CaptureToolbarView) { delegate?.overlay(self, requested: .ocr) }
    func toolbarRequestedTranslate(_ toolbar: CaptureToolbarView) { delegate?.overlay(self, requested: .translate) }
    func toolbarRequestedUndo(_ toolbar: CaptureToolbarView) { undoLastAnnotation() }
    func toolbarRequestedRedo(_ toolbar: CaptureToolbarView) { redoLastAnnotation() }
    func toolbarRequestedLongCapture(_ toolbar: CaptureToolbarView) {
        if manualLongCaptureActive { delegate?.overlayRequestedFinishLongCapture(self, saveAfter: false) }
        else { delegate?.overlayRequestedLongCapture(self) }
    }

    func beginManualLongCapture() -> (toolbar: CaptureToolbarView, frame: CGRect)? {
        guard let toolbar else { return nil }
        manualLongCaptureActive = true
        manualPreviewImage = nil
        let frame = toolbar.frame
        manualToolbarOverlayFrame = frame
        commitInlineTextEditing()
        stylePanel?.removeFromSuperview()
        stylePanel = nil
        toolbar.setManualLongCaptureMode()
        toolbar.removeFromSuperview()
        self.toolbar = nil
        tooltipLabel?.removeFromSuperview()
        tooltipLabel = nil
        needsDisplay = true
        return (toolbar, frame)
    }

    private func updateStylePanel(for tool: AnnotationTool?) {
        stylePanel?.removeFromSuperview()
        stylePanel = nil
        guard let tool, let toolbar, let selection else { return }
        let mode: AnnotationStylePanelView.Mode
        let value: CGFloat
        switch tool {
        case .text:
            mode = .text
            value = textSize
        case .rectangle, .ellipse, .arrow, .pen:
            mode = .stroke
            value = strokeWidth
        case .mosaicPixel, .mosaicBlur:
            mode = .mosaic
            value = mosaicIntensity
        }

        let panel = AnnotationStylePanelView(
            mode: mode,
            color: annotationColor,
            value: value,
            mosaicStyle: mosaicStyle
        )
        panel.onColorChange = { [weak self] color in
            guard let self else { return }
            self.annotationColor = color
            self.inlineTextField?.textColor = color
            self.updateSelectedAnnotationStyle(mode: mode)
        }
        panel.onValueChange = { [weak self] value in
            guard let self else { return }
            if mode == .text {
                self.textSize = value
                self.inlineTextField?.font = .systemFont(ofSize: value, weight: .semibold)
                if let field = self.inlineTextField {
                    field.frame.size.height = max(30, value + 12)
                }
            } else if mode == .stroke {
                self.strokeWidth = value
            } else {
                self.mosaicIntensity = value
            }
            self.updateSelectedAnnotationStyle(mode: mode)
        }
        panel.onMosaicStyleChange = { [weak self] style in
            guard let self else { return }
            self.mosaicStyle = style
            self.activeTool = style == .pixel ? .mosaicPixel : .mosaicBlur
            self.updateSelectedAnnotationStyle(mode: .mosaic)
        }
        addSubview(panel)
        let size = panel.fittingSize
        panel.frame = stylePanelFrame(
            size: size,
            toolbarFrame: toolbar.frame,
            selection: selection
        )
        stylePanel = panel
    }

    private func stylePanelFrame(
        size: CGSize,
        toolbarFrame: CGRect,
        selection: CGRect
    ) -> CGRect {
        let margin: CGFloat = 8
        let gap: CGFloat = 7
        let available = bounds.insetBy(dx: margin, dy: margin)
        func centeredX(_ center: CGFloat) -> CGFloat {
            max(available.minX, min(center - size.width / 2, available.maxX - size.width))
        }
        func centeredY(_ center: CGFloat) -> CGFloat {
            max(available.minY, min(center - size.height / 2, available.maxY - size.height))
        }

        var candidates: [CGRect] = []
        // First continue away from the selection in the same direction as the toolbar.
        if toolbarFrame.maxY <= selection.minY {
            candidates.append(CGRect(
                x: centeredX(toolbarFrame.midX),
                y: toolbarFrame.minY - size.height - gap,
                width: size.width,
                height: size.height
            ))
        } else if toolbarFrame.minY >= selection.maxY {
            candidates.append(CGRect(
                x: centeredX(toolbarFrame.midX),
                y: toolbarFrame.maxY + gap,
                width: size.width,
                height: size.height
            ))
        } else if toolbarFrame.maxX <= selection.minX {
            candidates.append(CGRect(
                x: toolbarFrame.minX - size.width - gap,
                y: centeredY(toolbarFrame.midY),
                width: size.width,
                height: size.height
            ))
        } else if toolbarFrame.minX >= selection.maxX {
            candidates.append(CGRect(
                x: toolbarFrame.maxX + gap,
                y: centeredY(toolbarFrame.midY),
                width: size.width,
                height: size.height
            ))
        }

        // Then try every side of the selection, preferring vertical placement.
        candidates.append(contentsOf: [
            CGRect(
                x: centeredX(selection.midX),
                y: selection.minY - size.height - gap,
                width: size.width,
                height: size.height
            ),
            CGRect(
                x: centeredX(selection.midX),
                y: selection.maxY + gap,
                width: size.width,
                height: size.height
            ),
            CGRect(
                x: selection.maxX + gap,
                y: centeredY(selection.midY),
                width: size.width,
                height: size.height
            ),
            CGRect(
                x: selection.minX - size.width - gap,
                y: centeredY(selection.midY),
                width: size.width,
                height: size.height
            )
        ])

        if let frame = candidates.first(where: {
            available.contains($0) && !$0.intersects(selection) && !$0.intersects(toolbarFrame)
        }) {
            return frame.integral
        }

        // If the outside margin is narrow, covering the toolbar is preferable to hiding
        // any screenshot pixels. The toolbar remains outside the captured selection.
        let toolbarOverlay = CGRect(
            x: centeredX(toolbarFrame.midX),
            y: centeredY(toolbarFrame.midY),
            width: size.width,
            height: size.height
        )
        if available.contains(toolbarOverlay), !toolbarOverlay.intersects(selection) {
            return toolbarOverlay.integral
        }

        // Last outside-only candidate: allow overlap with the toolbar, never selection.
        if let frame = candidates.first(where: {
            available.contains($0) && !$0.intersects(selection)
        }) {
            return frame.integral
        }
        return toolbarOverlay.integral
    }

    func renderedSelection() -> CGImage? {
        guard let selection else { return nil }
        return AnnotationRenderer.render(snapshot: snapshot, selection: selection, annotations: annotations)
    }

    @discardableResult
    private func record(_ annotation: Annotation) -> Int {
        pushUndoSnapshot(annotations)
        annotations.append(annotation)
        redoSnapshots.removeAll()
        let index = annotations.count - 1
        selectedAnnotationIndex = index
        if case let .mosaic(rect, style, intensity) = annotation {
            selectedMosaicIndex = index
            let key = mosaicPreviewKey(rect: rect, style: style, intensity: intensity)
            if let active = mosaicPreviewCache[-1], active.key == key {
                mosaicPreviewCache[index] = active
            }
            mosaicRenderWork[-1]?.cancel()
            mosaicRenderWork[-1] = nil
            mosaicPendingKeys[-1] = nil
            mosaicPreviewCache[-1] = nil
            quickMosaicPreviewCache[-1] = nil
        } else {
            selectedMosaicIndex = nil
        }
        needsDisplay = true
        return index
    }

    private func undoLastAnnotation() {
        commitInlineTextEditing()
        guard let previous = undoSnapshots.popLast() else { return }
        redoSnapshots.append(annotations)
        annotations = previous
        selectedMosaicIndex = nil
        selectedAnnotationIndex = nil
        clearMosaicPreviewCache()
        needsDisplay = true
    }

    private func redoLastAnnotation() {
        guard let next = redoSnapshots.popLast() else { return }
        undoSnapshots.append(annotations)
        annotations = next
        selectedMosaicIndex = nil
        selectedAnnotationIndex = nil
        clearMosaicPreviewCache()
        needsDisplay = true
    }

    private func pushUndoSnapshot(_ snapshot: [Annotation]) {
        undoSnapshots.append(snapshot)
        if undoSnapshots.count > 80 { undoSnapshots.removeFirst(undoSnapshots.count - 80) }
        redoSnapshots.removeAll()
    }

    private func loadSelectedMosaicStyle() {
        guard let index = selectedMosaicIndex, annotations.indices.contains(index),
              case let .mosaic(_, style, intensity) = annotations[index] else { return }
        mosaicStyle = style
        mosaicIntensity = intensity
        activeTool = style == .pixel ? .mosaicPixel : .mosaicBlur
    }

    private func selectAnnotation(at index: Int) {
        guard annotations.indices.contains(index) else { return }
        selectedAnnotationIndex = index
        let annotation = annotations[index]
        switch annotation {
        case let .rectangle(_, color, width):
            selectedMosaicIndex = nil
            annotationColor = color
            strokeWidth = width
            updateStylePanel(for: .rectangle)
        case let .ellipse(_, color, width):
            selectedMosaicIndex = nil
            annotationColor = color
            strokeWidth = width
            updateStylePanel(for: .ellipse)
        case let .arrow(_, _, color, width):
            selectedMosaicIndex = nil
            annotationColor = color
            strokeWidth = width
            updateStylePanel(for: .arrow)
        case let .pen(_, color, width):
            selectedMosaicIndex = nil
            annotationColor = color
            strokeWidth = width
            updateStylePanel(for: .pen)
        case let .text(_, _, color, size):
            selectedMosaicIndex = nil
            annotationColor = color
            textSize = size
            updateStylePanel(for: .text)
        case let .mosaic(_, style, intensity):
            selectedMosaicIndex = index
            mosaicStyle = style
            mosaicIntensity = intensity
            updateStylePanel(for: style == .pixel ? .mosaicPixel : .mosaicBlur)
        }
        needsDisplay = true
    }

    private func updateSelectedAnnotationStyle(mode: AnnotationStylePanelView.Mode) {
        guard let index = selectedAnnotationIndex, annotations.indices.contains(index) else { return }
        switch (mode, annotations[index]) {
        case (.text, let .text(text, point, _, _)):
            annotations[index] = .text(text, point, annotationColor, textSize)
            needsDisplay = true
        case (.stroke, let .rectangle(rect, _, _)):
            annotations[index] = .rectangle(rect, annotationColor, strokeWidth)
            needsDisplay = true
        case (.stroke, let .ellipse(rect, _, _)):
            annotations[index] = .ellipse(rect, annotationColor, strokeWidth)
            needsDisplay = true
        case (.stroke, let .arrow(start, end, _, _)):
            annotations[index] = .arrow(start, end, annotationColor, strokeWidth)
            needsDisplay = true
        case (.stroke, let .pen(points, _, _)):
            annotations[index] = .pen(points, annotationColor, strokeWidth)
            needsDisplay = true
        case (.mosaic, let .mosaic(rect, _, _)):
            annotations[index] = .mosaic(rect, mosaicStyle, mosaicIntensity)
            selectedMosaicIndex = index
            invalidateMosaicPreview(slot: index)
            let key = mosaicPreviewKey(rect: rect, style: mosaicStyle, intensity: mosaicIntensity)
            scheduleMosaicPreview(
                slot: index,
                key: key,
                rect: rect,
                style: mosaicStyle,
                intensity: mosaicIntensity
            )
            setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
        default:
            break
        }
    }

    private func updateSelectedMosaic() {
        guard let index = selectedMosaicIndex, annotations.indices.contains(index),
              case let .mosaic(rect, _, _) = annotations[index] else { return }
        annotations[index] = .mosaic(rect, mosaicStyle, mosaicIntensity)
        invalidateMosaicPreview(slot: index)
        let key = mosaicPreviewKey(rect: rect, style: mosaicStyle, intensity: mosaicIntensity)
        scheduleMosaicPreview(
            slot: index,
            key: key,
            rect: rect,
            style: mosaicStyle,
            intensity: mosaicIntensity
        )
        setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
    }

    private func mosaicPreviewKey(rect: CGRect, style: MosaicStyle, intensity: CGFloat) -> MosaicPreviewKey {
        MosaicPreviewKey(
            x: Int(round(rect.minX * 10)),
            y: Int(round(rect.minY * 10)),
            width: Int(round(rect.width * 10)),
            height: Int(round(rect.height * 10)),
            style: style,
            intensity: Int(round(intensity * 10))
        )
    }

    private func scheduleMosaicPreview(
        slot: Int,
        key: MosaicPreviewKey,
        rect: CGRect,
        style: MosaicStyle,
        intensity: CGFloat
    ) {
        guard let pixelRect = snapshot.pixelRect(for: rect) else { return }
        let sourceImage = snapshot.image
        mosaicRenderWork[slot]?.cancel()
        mosaicPendingKeys[slot] = key
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let source = sourceImage.cropping(to: pixelRect) else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.mosaicPendingKeys[slot] == key else { return }
                    self.mosaicPendingKeys[slot] = nil
                    self.mosaicRenderWork[slot] = nil
                }
                return
            }
            let patch = ImageEffects.mosaicPatch(
                from: source,
                pixelRectTopLeft: CGRect(x: 0, y: 0, width: source.width, height: source.height),
                style: style,
                intensity: intensity
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.mosaicPendingKeys[slot] == key else { return }
                self.mosaicPendingKeys[slot] = nil
                self.mosaicRenderWork[slot] = nil
                if let patch {
                    self.mosaicPreviewCache[slot] = (
                        key,
                        NSImage(cgImage: patch, size: rect.size)
                    )
                    self.setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
                }
            }
        }
        mosaicRenderWork[slot] = work
        mosaicRenderQueue.async(execute: work)
    }

    private func invalidateMosaicPreview(slot: Int) {
        mosaicRenderWork[slot]?.cancel()
        mosaicRenderWork[slot] = nil
        mosaicPendingKeys[slot] = nil
        mosaicPreviewCache[slot] = nil
        quickMosaicPreviewCache[slot] = nil
    }

    private func clearMosaicPreviewCache() {
        mosaicRenderWork.values.forEach { $0.cancel() }
        mosaicRenderWork.removeAll()
        mosaicPendingKeys.removeAll()
        mosaicPreviewCache.removeAll()
        quickMosaicPreviewCache.removeAll()
    }

    func updateManualLongCapturePreview(image: CGImage, frameCount: Int) {
        manualPreviewImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        manualFrameCount = frameCount
        manualCaptureStatus = frameCount > 1
            ? L10n.format("long.frames", frameCount)
            : L10n.tr("long.scrollInSelection")
        manualCaptureStatusIsError = false
        invalidateManualMinimap()
    }

    func setManualLongCaptureStatus(_ text: String, isError: Bool) {
        manualCaptureStatus = text
        manualCaptureStatusIsError = isError
        invalidateManualMinimap()
    }

    private func showToolbarTooltip(_ text: String?) {
        tooltipLabel?.removeFromSuperview()
        tooltipLabel = nil
        guard let text, let referenceFrame = toolbar?.frame ?? manualToolbarOverlayFrame else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = NSColor.black.withAlphaComponent(0.88)
        label.isBezeled = false
        label.drawsBackground = true
        label.wantsLayer = true
        label.layer?.cornerRadius = 6
        label.sizeToFit()
        label.frame.size.width += 18
        label.frame.size.height = 28
        let x = max(6, min(referenceFrame.midX - label.frame.width / 2, bounds.width - label.frame.width - 6))
        let above = referenceFrame.maxY + 7
        let y = above + label.frame.height <= bounds.height - 6 ? above : referenceFrame.minY - label.frame.height - 7
        label.frame.origin = CGPoint(x: x, y: y)
        addSubview(label)
        tooltipLabel = label
    }

    private func drawManualLongCaptureFrame() {
        guard let selection else { return }
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        let message = L10n.tr("long.manualMessage")
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.92)
        ]
        message.draw(
            at: CGPoint(x: selection.minX + 4, y: min(bounds.maxY - 22, selection.maxY + 5)),
            withAttributes: attributes
        )
        drawManualMinimap(in: selection)
    }

    private func drawManualMinimap(in selection: CGRect) {
        let minimap = manualMinimapFrame(in: selection)
        guard minimap.width >= 72, minimap.height >= 100 else { return }

        let background = NSBezierPath(roundedRect: minimap, xRadius: 8, yRadius: 8)
        NSColor.white.withAlphaComponent(0.55).setStroke()
        background.lineWidth = 1.5
        background.stroke()

        let title = L10n.tr("long.minimapTitle")
        title.draw(at: CGPoint(x: minimap.minX + 9, y: minimap.maxY - 23), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ])

        let statusColor = manualCaptureStatusIsError ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.82)
        let status = manualFrameCount > 0 && !manualCaptureStatusIsError
            ? "\(manualCaptureStatus)"
            : manualCaptureStatus
        status.draw(in: CGRect(x: minimap.minX + 9, y: minimap.minY + 7, width: minimap.width - 18, height: 34), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: statusColor
        ])

        guard let manualPreviewImage else { return }
        let content = CGRect(
            x: minimap.minX + 8,
            y: minimap.minY + 42,
            width: minimap.width - 16,
            height: minimap.height - 72
        )
        guard content.width > 0, content.height > 0 else { return }
        func fittedRect(for image: NSImage) -> CGRect {
            let scale = min(content.width / image.size.width, content.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            return CGRect(
                x: content.midX - size.width / 2,
                y: content.maxY - size.height,
                width: size.width,
                height: size.height
            )
        }
        let imageRect = fittedRect(for: manualPreviewImage)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: content, xRadius: 4, yRadius: 4).addClip()
        manualPreviewImage.draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func manualMinimapFrame(in selection: CGRect) -> CGRect {
        let desiredWidth = min(210, max(110, selection.width * 0.24))
        let width = min(selection.width - 16, desiredWidth)
        let height = selection.height - 16
        return CGRect(
            x: selection.maxX - width - 8,
            y: selection.minY + 8,
            width: width,
            height: height
        )
    }

    private func invalidateManualMinimap() {
        guard manualLongCaptureActive, let selection else {
            needsDisplay = true
            return
        }

        setNeedsDisplay(manualMinimapFrame(in: selection).insetBy(dx: -3, dy: -3))
    }
}

final class AnnotationStylePanelView: NSVisualEffectView {
    enum Mode: Equatable { case text, stroke, mosaic }

    var onColorChange: ((NSColor) -> Void)?
    var onValueChange: ((CGFloat) -> Void)?
    var onMosaicStyleChange: ((MosaicStyle) -> Void)?
    private var colorButtons: [NSButton: NSColor] = [:]
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let mode: Mode

    init(mode: Mode, color: NSColor, value: CGFloat, mosaicStyle: MosaicStyle = .pixel) {
        self.mode = mode
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        buildUI(selectedColor: color, value: value, mosaicStyle: mosaicStyle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var fittingSize: NSSize { NSSize(width: mode == .mosaic ? 286 : 326, height: 44) }

    private func buildUI(selectedColor: NSColor, value: CGFloat, mosaicStyle: MosaicStyle) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let title = NSTextField(labelWithString: mode == .text ? L10n.tr("style.text") : (mode == .stroke ? L10n.tr("style.stroke") : L10n.tr("style.mosaic")))
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        stack.addArrangedSubview(title)

        if mode == .mosaic {
            let styles = NSSegmentedControl(labels: [L10n.tr("style.pixel"), L10n.tr("style.blur")], trackingMode: .selectOne, target: self, action: #selector(changeMosaicStyle(_:)))
            styles.selectedSegment = mosaicStyle == .pixel ? 0 : 1
            styles.widthAnchor.constraint(equalToConstant: 104).isActive = true
            stack.addArrangedSubview(styles)
        } else {
            let palette: [(String, NSColor)] = [
                (L10n.tr("color.red"), .systemRed), (L10n.tr("color.orange"), .systemOrange), (L10n.tr("color.yellow"), .systemYellow),
                (L10n.tr("color.green"), .systemGreen), (L10n.tr("color.blue"), .systemBlue), (L10n.tr("color.white"), .white), (L10n.tr("color.black"), .black)
            ]
            for (name, color) in palette {
                let button = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
                button.isBordered = false
                button.toolTip = name
                button.wantsLayer = true
                button.layer?.backgroundColor = color.cgColor
                button.layer?.cornerRadius = 8
                button.layer?.borderWidth = colorsMatch(color, selectedColor) ? 2 : 0.5
                button.layer?.borderColor = NSColor.white.cgColor
                button.widthAnchor.constraint(equalToConstant: 16).isActive = true
                button.heightAnchor.constraint(equalToConstant: 16).isActive = true
                colorButtons[button] = color
                stack.addArrangedSubview(button)
            }
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        stack.addArrangedSubview(separator)

        slider.minValue = mode == .text ? 12 : (mode == .mosaic ? 4 : 1)
        slider.maxValue = mode == .text ? 72 : (mode == .mosaic ? 40 : 24)
        slider.doubleValue = Double(value)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changeValue(_:))
        slider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        stack.addArrangedSubview(slider)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valueLabel.alignment = .right
        valueLabel.widthAnchor.constraint(equalToConstant: 25).isActive = true
        stack.addArrangedSubview(valueLabel)
        updateValueLabel()

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let color = colorButtons[sender] else { return }
        colorButtons.keys.forEach { $0.layer?.borderWidth = $0 === sender ? 2 : 0.5 }
        onColorChange?(color)
    }

    @objc private func changeValue(_ sender: NSSlider) {
        slider.doubleValue = round(slider.doubleValue)
        updateValueLabel()
        onValueChange?(CGFloat(slider.doubleValue))
    }

    @objc private func changeMosaicStyle(_ sender: NSSegmentedControl) {
        onMosaicStyleChange?(sender.selectedSegment == 0 ? .pixel : .blur)
    }

    private func updateValueLabel() { valueLabel.stringValue = "\(Int(slider.doubleValue))" }

    private func colorsMatch(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        lhs.usingColorSpace(.deviceRGB) == rhs.usingColorSpace(.deviceRGB)
    }
}

final class LongCaptureToolbarController: NSWindowController {
    init(screen: NSScreen, localFrame: CGRect, toolbar: CaptureToolbarView) {
        let globalFrame = localFrame.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: localFrame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.setFrame(globalFrame, display: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        toolbar.frame = NSRect(origin: .zero, size: localFrame.size)
        panel.contentView = toolbar
        super.init(window: panel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
