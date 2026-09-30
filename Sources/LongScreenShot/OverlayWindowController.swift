import AppKit
import Carbon

final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension Notification.Name {
    static let captureOverlayLongCaptureFocusedScreen = Notification.Name("CaptureOverlayLongCaptureFocusedScreen")
}

private func CaptureOverlayScreenNumber(_ screen: NSScreen) -> NSNumber? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
}

final class OverlayWindowController: NSWindowController, CaptureOverlayViewDelegate {
    var onCancel: (() -> Void)?
    var onComplete: ((CGImage, CaptureCompletionAction, NSScreen, CGRect?) -> Void)?
    private let snapshot: ScreenSnapshot
    private let startsInLongMode: Bool
    private var longCaptureService: LongCaptureService?
    private var longCaptureToolbarController: LongCaptureToolbarController?
    private var manualLongCaptureFinishing = false
    private var escapeHotKey: GlobalHotKey?
    private var focusedScreenObserver: NSObjectProtocol?

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
        focusedScreenObserver = NotificationCenter.default.addObserver(
            forName: .captureOverlayLongCaptureFocusedScreen,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let target = notification.userInfo?["screenNumber"] as? NSNumber,
                  let own = CaptureOverlayScreenNumber(self.snapshot.screen) else { return }
            if target.uint32Value == own.uint32Value {
                self.window?.orderFrontRegardless()
            } else {
                // 长截图只保留当前截图所在屏幕的交互层。其他显示器上的覆盖窗口
                // 必须彻底隐藏，否则会留下整屏半透明遮罩。
                self.window?.orderOut(nil)
            }
        }
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
        (window?.contentView as? CaptureOverlayView)?.prepareForClose()
        longCaptureToolbarController?.close()
        longCaptureToolbarController = nil
        escapeHotKey = nil
        if let focusedScreenObserver { NotificationCenter.default.removeObserver(focusedScreenObserver) }
        focusedScreenObserver = nil
        onCancel = nil
        onComplete = nil
        NSCursor.pop()
        super.close()
    }

    func overlayDidCancel(_ view: CaptureOverlayView) { onCancel?() }

    func overlay(_ view: CaptureOverlayView, requested action: CaptureCompletionAction) {
        guard let image = view.renderedSelection() else { return }
        onComplete?(image, action, snapshot.screen, view.toastAnchorRect())
    }

    func overlayRequestedLongCapture(_ view: CaptureOverlayView) {
        guard let selection = view.selection, let window else { return }
        guard let detachedToolbar = view.beginManualLongCapture() else { return }
        if let screenNumber = CaptureOverlayScreenNumber(snapshot.screen) {
            NotificationCenter.default.post(
                name: .captureOverlayLongCaptureFocusedScreen,
                object: nil,
                userInfo: ["screenNumber": screenNumber]
            )
        }
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

        var excludedWindowIDs = [CGWindowID(window.windowNumber)]
        if let toolbarWindowNumber = toolbarController.window?.windowNumber {
            excludedWindowIDs.append(CGWindowID(toolbarWindowNumber))
        }
        let service = LongCaptureService(
            snapshot: snapshot,
            selection: selection,
            excludedWindowIDs: excludedWindowIDs
        )
        longCaptureService = service
        LongCaptureDiagnostics.shared.log("overlay.longCapture.start window=\(window.windowNumber) toolbar=\(toolbarController.window?.windowNumber ?? -1) selection=\(selection)")
        service.onPreviewSegment = { [weak view] segment, count in
            view?.appendManualLongCapturePreviewSegment(segment, frameCount: count)
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
                CaptureHistoryManager.shared.record(image)
                if saveAfter {
                    self.window?.orderOut(nil)
                    ImageExporter.showSavePanel(for: image, preferredScreen: self.snapshot.screen) { [weak self] in self?.onCancel?() }
                } else {
                    ImageExporter.copyToPasteboard(image)
                    FeedbackToast.show(
                        L10n.tr("feedback.copied"),
                        screen: self.snapshot.screen,
                        anchorRect: (self.window?.contentView as? CaptureOverlayView)?.toastAnchorRect()
                    )
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
    private static weak var activeOwner: CaptureOverlayView?

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
    private var manualPreviewPanel: ManualLongCapturePreviewPanelView?
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

    func prepareForClose() {
        cancelInlineTextEditing()
        stylePanel?.removeFromSuperview()
        stylePanel = nil
        tooltipLabel?.removeFromSuperview()
        tooltipLabel = nil
        toolbar?.removeFromSuperview()
        toolbar = nil
        clearMosaicPreviewCache()
        ImageEffects.clearCaches()
        if NSColorPanel.shared.isVisible {
            NSColorPanel.shared.close()
            NSColorPanel.shared.level = .normal
        }
        manualPreviewImage = nil
        manualPreviewPanel?.removeFromSuperview()
        manualPreviewPanel = nil
        annotations.removeAll(keepingCapacity: false)
        undoSnapshots.removeAll(keepingCapacity: false)
        redoSnapshots.removeAll(keepingCapacity: false)
        activePoints.removeAll(keepingCapacity: false)
        selectedAnnotationIndex = nil
        selectedMosaicIndex = nil
        annotationBeforeAdjustment = nil
        annotationBoundsBeforeAdjustment = nil
        annotationsBeforeAdjustment.removeAll(keepingCapacity: false)
        if let active = Self.activeOwner, active === self {
            Self.activeOwner = nil
        }
        layer?.contents = nil
    }

    private func becomeActiveOwner() {
        Self.activeOwner = self
        window?.makeFirstResponder(self)
    }

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
        becomeActiveOwner()
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
        if let active = Self.activeOwner, active !== self {
            active.handleKeyDownFromActiveOwner(event)
            return
        }
        becomeActiveOwner()
        handleKeyDownFromActiveOwner(event)
    }

    private func handleKeyDownFromActiveOwner(_ event: NSEvent) {
        if event.keyCode == 53 { delegate?.overlayDidCancel(self); return }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            FeedbackToast.show(
                undoLastAnnotation() ? L10n.tr("feedback.undone") : L10n.tr("feedback.noUndo"),
                screen: snapshot.screen,
                anchorRect: toastAnchorRect()
            )
            return
        }
        if (event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter)),
           CapturePreferences.quickCopyOnConfirm,
           selection != nil,
           inlineTextField == nil,
           !manualLongCaptureActive {
            commitInlineTextEditing()
            delegate?.overlay(self, requested: .copy)
            return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            if event.modifierFlags.contains(.shift) { redoLastAnnotation() }
            else { undoLastAnnotation() }
            return
        }
        if inlineTextField == nil,
           selection != nil,
           let command = ToolShortcutStore.command(matching: event) {
            toolbar?.perform(command)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        becomeActiveOwner()
        let point = convert(event.locationInWindow, from: nil)
        guard !isPointInsideToolbar(point) else { return }
        if event.clickCount >= 2, CapturePreferences.quickCopyOnConfirm, !manualLongCaptureActive {
            if selection == nil, let preview = currentSelectionPreview {
                selection = preview.rect.integral
                hoveredWindow = nil
                needsDisplay = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.overlay(self, requested: .copy)
                }
                return
            }
            if let selection, selection.contains(point), activeTool == nil {
                commitInlineTextEditing()
                delegate?.overlay(self, requested: .copy)
                return
            }
        }
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
        becomeActiveOwner()
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
        becomeActiveOwner()
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

    private func drawDimmedSnapshot(revealing revealRect: CGRect?) {
        let image = NSImage(cgImage: snapshot.image, size: bounds.size)
        image.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()
        if let revealRect {
            reveal(image: image, in: revealRect)
        }
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
    func toolbar(_ toolbar: CaptureToolbarView, requestedShortcutFor command: CaptureCommand) {
        showShortcutPanel(for: command, toolbar: toolbar)
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
        manualPreviewPanel?.removeFromSuperview()
        manualPreviewPanel = nil
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
        let command: CaptureCommand
        switch tool {
        case .text:
            mode = .text
            value = textSize
            command = .text
        case .rectangle, .ellipse, .arrow, .pen:
            mode = .stroke
            value = strokeWidth
            switch tool {
            case .rectangle: command = .rectangle
            case .ellipse: command = .ellipse
            case .arrow: command = .arrow
            case .pen: command = .pen
            default: command = .rectangle
            }
        case .mosaicPixel, .mosaicBlur:
            mode = .mosaic
            value = mosaicIntensity
            command = .mosaic
        }

        let panel = AnnotationStylePanelView(
            mode: mode,
            color: annotationColor,
            value: value,
            mosaicStyle: mosaicStyle,
            shortcutCommand: command
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

    private func showShortcutPanel(for command: CaptureCommand, toolbar: CaptureToolbarView) {
        guard let selection else { return }
        stylePanel?.removeFromSuperview()
        let panel = AnnotationStylePanelView(
            mode: .shortcut,
            color: annotationColor,
            value: 0,
            shortcutCommand: command
        )
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

    func toastAnchorRect() -> CGRect? {
        let base = snapshot.screen.frame
        let local = selection ?? bounds
        guard !local.isNull, local.width > 0, local.height > 0 else { return base }
        let globalRect = CGRect(
            x: base.minX + local.minX,
            y: base.minY + local.minY,
            width: local.width,
            height: local.height
        )
        let clipped = globalRect.intersection(snapshot.screen.visibleFrame)
        return clipped.isNull ? globalRect.intersection(base) : clipped
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

    @discardableResult
    private func undoLastAnnotation() -> Bool {
        commitInlineTextEditing()
        guard let previous = undoSnapshots.popLast() else { return false }
        redoSnapshots.append(annotations)
        annotations = previous
        selectedMosaicIndex = nil
        selectedAnnotationIndex = nil
        clearMosaicPreviewCache()
        needsDisplay = true
        return true
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
        // 兼容旧回调：正常长截图实时预览已经走 appendManualLongCapturePreviewSegment，
        // 不再在 draw(_:) 中反复绘制整张 manualPreviewImage。
        manualPreviewImage = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
        manualFrameCount = frameCount
        manualCaptureStatus = frameCount > 1
            ? L10n.format("long.frames", frameCount)
            : L10n.tr("long.scrollInSelection")
        manualCaptureStatusIsError = false
        updateManualPreviewPanelLayout()
    }

    func appendManualLongCapturePreviewSegment(_ segment: LongCapturePreviewSegment, frameCount: Int) {
        manualFrameCount = frameCount
        manualCaptureStatus = frameCount > 1
            ? L10n.format("long.frames", frameCount)
            : L10n.tr("long.scrollInSelection")
        manualCaptureStatusIsError = false

        let panel = ensureManualPreviewPanel()
        panel.append(segment)
        panel.setStatus(manualCaptureStatus, isError: false)
    }

    func setManualLongCaptureStatus(_ text: String, isError: Bool) {
        manualCaptureStatus = text
        manualCaptureStatusIsError = isError
        manualPreviewPanel?.setStatus(text, isError: isError)
    }

    private func ensureManualPreviewPanel() -> ManualLongCapturePreviewPanelView {
        if let manualPreviewPanel { return manualPreviewPanel }
        let panel = ManualLongCapturePreviewPanelView(frame: .zero)
        panel.isHidden = !manualLongCaptureActive
        addSubview(panel)
        manualPreviewPanel = panel
        updateManualPreviewPanelLayout()
        return panel
    }

    private func updateManualPreviewPanelLayout() {
        guard manualLongCaptureActive, let selection, let panel = manualPreviewPanel else {
            needsDisplay = true
            return
        }
        let target = manualPreviewPanelFrame(in: selection)
        let shouldHide = target.width < 36 || target.height < 80
        if panel.isHidden != shouldHide { panel.isHidden = shouldHide }
        var frameChanged = false
        if !shouldHide, panel.frame.integral != target.integral {
            panel.frame = target
            frameChanged = true
        }
        panel.needsLayout = true
        // The full-screen overlay only needs a redraw when the preview cut-out moves.
        // Segment/status updates stay entirely inside the preview panel.
        if frameChanged { needsDisplay = true }
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
        guard let selection,
              let context = NSGraphicsContext.current?.cgContext else { return }

        // 长截图开始后，当前屏幕仍保留和普通截图一致的半透明遮罩；
        // 只有真正的截图工作区保持完全透明。覆盖窗口本身被 ScreenCaptureKit 排除，
        // 所以遮罩、边框和外侧缩略图都不会进入最终长图。
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.48).cgColor)
        context.addRect(bounds)
        context.addRect(selection)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

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
    }

    private var localVisibleScreenFrame: CGRect {
        let screenFrame = snapshot.screen.frame
        let visibleFrame = snapshot.screen.visibleFrame
        return CGRect(
            x: visibleFrame.minX - screenFrame.minX,
            y: visibleFrame.minY - screenFrame.minY,
            width: visibleFrame.width,
            height: visibleFrame.height
        ).intersection(bounds)
    }

    private func manualPreviewPanelFrame(in selection: CGRect) -> CGRect {
        // 缩略图固定放在截图框外侧。高度从截图框底部一直延伸到菜单栏下沿；
        // 内容越长，ManualLongCapturePreviewPanelView 会在这个固定高度内等比缩小。
        let visible = localVisibleScreenFrame
        let gap: CGFloat = 10
        let rightAvailable = max(0, visible.maxX - selection.maxX - gap)
        let leftAvailable = max(0, selection.minX - visible.minX - gap)
        let placeOnRight = rightAvailable >= leftAvailable
        let availableWidth = placeOnRight ? rightAvailable : leftAvailable
        guard availableWidth >= 36 else { return .zero }

        let desiredWidth = min(220, max(104, selection.width * 0.22))
        let width = min(desiredWidth, availableWidth)
        let bottom = max(visible.minY, selection.minY)
        let height = max(0, visible.maxY - bottom)
        guard height >= 80 else { return .zero }

        let x = placeOnRight
            ? selection.maxX + gap
            : selection.minX - gap - width
        return CGRect(x: x, y: bottom, width: width, height: height)
            .intersection(visible)
            .integral
    }

    private func invalidateManualMinimap() {
        updateManualPreviewPanelLayout()
    }
}

private final class ManualLongCapturePreviewPanelView: NSView {
    private final class FlippedContentView: NSView {
        override var isFlipped: Bool { true }
    }

    private let clipView = NSView()
    private let contentView = FlippedContentView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var knownSerials = Set<Int>()
    private var tileLayers: [Int: CALayer] = [:]
    private var naturalWidth: CGFloat = 1
    private var naturalHeight: CGFloat = 0
    private var isApplyingLayout = false
    private var appendedSegmentCount = 0
    private var layoutPassCount = 0
    private var lastLayoutScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        clipView.wantsLayer = true
        clipView.layer?.backgroundColor = NSColor.clear.cgColor
        clipView.layer?.cornerRadius = 5
        clipView.layer?.masksToBounds = true
        addSubview(clipView)

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.isGeometryFlipped = true
        contentView.layer?.masksToBounds = true
        clipView.addSubview(contentView)

        statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        statusLabel.alignment = .center
        statusLabel.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        statusLabel.drawsBackground = true
        statusLabel.isBezeled = false
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 4
        statusLabel.layer?.masksToBounds = true
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func append(_ segment: LongCapturePreviewSegment) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard !knownSerials.contains(segment.serial) else {
            LongCaptureDiagnostics.shared.log("preview.panel.skipKnown serial=\(segment.serial) top=\(segment.previewTop)")
            return
        }
        knownSerials.insert(segment.serial)
        appendedSegmentCount += 1
        naturalWidth = max(naturalWidth, CGFloat(segment.previewWidth))
        naturalHeight = max(naturalHeight, CGFloat(segment.previewContentHeight))

        let tileKey = segment.previewTop
        let imageLayer: CALayer
        if let existing = tileLayers[tileKey] {
            imageLayer = existing
        } else {
            imageLayer = CALayer()
            imageLayer.contentsGravity = .resize
            imageLayer.magnificationFilter = .linear
            imageLayer.minificationFilter = .linear
            imageLayer.actions = [
                "position": NSNull(),
                "bounds": NSNull(),
                "contents": NSNull(),
                "transform": NSNull()
            ]
            tileLayers[tileKey] = imageLayer
            contentView.layer?.addSublayer(imageLayer)
        }
        imageLayer.frame = CGRect(
            x: 0,
            y: CGFloat(segment.previewTop),
            width: CGFloat(segment.previewWidth),
            height: CGFloat(segment.previewHeight)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = segment.image
        CATransaction.commit()
        needsLayout = true

        let durationMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        if appendedSegmentCount <= 10 || appendedSegmentCount % 20 == 0 || durationMS >= 3 {
            LongCaptureDiagnostics.shared.log("preview.panel.append count=\(appendedSegmentCount) serial=\(segment.serial) tileTop=\(segment.previewTop) tileHeight=\(segment.previewHeight) natural=\(Int(naturalWidth))x\(Int(naturalHeight)) layers=\(tileLayers.count) durationMS=\(String(format: "%.2f", durationMS))")
        }
    }

    func setStatus(_ text: String, isError: Bool) {
        if statusLabel.stringValue != text { statusLabel.stringValue = text }
        let color: NSColor = isError ? .systemRed : NSColor.white.withAlphaComponent(0.85)
        if statusLabel.textColor != color { statusLabel.textColor = color }
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    private func layoutPreview() {
        guard !isApplyingLayout else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        isApplyingLayout = true
        layoutPassCount += 1
        defer { isApplyingLayout = false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.current.duration = 0

        let statusHeight: CGFloat = statusLabel.stringValue.isEmpty ? 0 : 20
        let inset: CGFloat = 4
        let contentBottom = inset + (statusHeight > 0 ? statusHeight + 2 : 0)
        let clipFrame = CGRect(
            x: inset,
            y: contentBottom,
            width: max(1, bounds.width - inset * 2),
            height: max(1, bounds.height - contentBottom - inset)
        )
        if clipView.frame != clipFrame { clipView.frame = clipFrame }
        if statusHeight > 0 {
            let statusFrame = CGRect(x: inset, y: inset, width: bounds.width - inset * 2, height: statusHeight)
            if statusLabel.frame != statusFrame { statusLabel.frame = statusFrame }
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }

        let maxWidth = max(1, clipView.bounds.width)
        let maxHeight = max(1, clipView.bounds.height)
        let scale = min(1, maxWidth / max(1, naturalWidth), maxHeight / max(1, naturalHeight))
        let contentSize = CGSize(width: naturalWidth * scale, height: naturalHeight * scale)
        let frame = CGRect(
            x: round((maxWidth - contentSize.width) / 2),
            y: 0,
            width: max(1, contentSize.width),
            height: max(1, contentSize.height)
        )
        if contentView.frame != frame { contentView.frame = frame }
        let boundsRect = CGRect(x: 0, y: 0, width: max(1, naturalWidth), height: max(1, naturalHeight))
        if contentView.bounds != boundsRect { contentView.bounds = boundsRect }

        CATransaction.commit()
        let durationMS = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        let scaleChanged = abs(scale - lastLayoutScale) >= 0.01
        lastLayoutScale = scale
        if layoutPassCount <= 10 || layoutPassCount % 20 == 0 || durationMS >= 3 || scaleChanged {
            LongCaptureDiagnostics.shared.log("preview.panel.layout pass=\(layoutPassCount) bounds=\(Int(bounds.width))x\(Int(bounds.height)) natural=\(Int(naturalWidth))x\(Int(naturalHeight)) scale=\(String(format: "%.4f", Double(scale))) layers=\(tileLayers.count) durationMS=\(String(format: "%.2f", durationMS))")
        }
    }
}

final class AnnotationStylePanelView: NSVisualEffectView {
    enum Mode: Equatable { case text, stroke, mosaic, shortcut }

    var onColorChange: ((NSColor) -> Void)?
    var onValueChange: ((CGFloat) -> Void)?
    var onMosaicStyleChange: ((MosaicStyle) -> Void)?
    private var colorButtons: [NSButton: NSColor] = [:]
    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let mode: Mode
    private let shortcutCommand: CaptureCommand?
    private var colorWell: NSColorWell?

    init(
        mode: Mode,
        color: NSColor,
        value: CGFloat,
        mosaicStyle: MosaicStyle = .pixel,
        shortcutCommand: CaptureCommand? = nil
    ) {
        self.mode = mode
        self.shortcutCommand = shortcutCommand
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        buildUI(selectedColor: color, value: value, mosaicStyle: mosaicStyle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var fittingSize: NSSize {
        switch mode {
        case .shortcut: return NSSize(width: 270, height: 44)
        case .mosaic: return NSSize(width: shortcutCommand == nil ? 286 : 410, height: 44)
        case .text, .stroke: return NSSize(width: shortcutCommand == nil ? 352 : 476, height: 44)
        }
    }

    private func buildUI(selectedColor: NSColor, value: CGFloat, mosaicStyle: MosaicStyle) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let titleText: String
        switch mode {
        case .text: titleText = L10n.tr("style.text")
        case .stroke: titleText = L10n.tr("style.stroke")
        case .mosaic: titleText = L10n.tr("style.mosaic")
        case .shortcut: titleText = shortcutCommand?.title ?? L10n.tr("settings.shortcuts")
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        stack.addArrangedSubview(title)

        if mode == .mosaic {
            let styles = NSSegmentedControl(labels: [L10n.tr("style.pixel"), L10n.tr("style.blur")], trackingMode: .selectOne, target: self, action: #selector(changeMosaicStyle(_:)))
            styles.selectedSegment = mosaicStyle == .pixel ? 0 : 1
            styles.widthAnchor.constraint(equalToConstant: 104).isActive = true
            stack.addArrangedSubview(styles)
        } else if mode != .shortcut {
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

            let well = CaptureColorWell(frame: .zero)
            well.color = selectedColor
            well.toolTip = L10n.tr("color.custom")
            well.target = self
            well.action = #selector(changeCustomColor(_:))
            well.widthAnchor.constraint(equalToConstant: 24).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorWell = well
            stack.addArrangedSubview(well)
        }

        if mode != .shortcut {
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
        }

        if let shortcutCommand {
            let separator = NSBox()
            separator.boxType = .separator
            separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
            separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
            stack.addArrangedSubview(separator)
            let shortcutLabel = NSTextField(labelWithString: L10n.tr("settings.shortcut"))
            shortcutLabel.font = .systemFont(ofSize: 10, weight: .medium)
            stack.addArrangedSubview(shortcutLabel)
            let recorder = ToolShortcutRecorderView(command: shortcutCommand)
            recorder.widthAnchor.constraint(equalToConstant: 76).isActive = true
            recorder.heightAnchor.constraint(equalToConstant: 26).isActive = true
            stack.addArrangedSubview(recorder)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func selectColor(_ sender: NSButton) {
        guard let color = colorButtons[sender] else { return }
        colorButtons.keys.forEach { $0.layer?.borderWidth = $0 === sender ? 2 : 0.5 }
        colorWell?.color = color
        onColorChange?(color)
    }

    @objc private func changeCustomColor(_ sender: NSColorWell) {
        HSLColorAccessoryView.shared.sync(from: sender.color)
        colorButtons.forEach { button, color in
            button.layer?.borderWidth = colorsMatch(color, sender.color) ? 2 : 0.5
        }
        onColorChange?(sender.color)
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

private final class CaptureColorWell: NSColorWell {
    override func activate(_ exclusive: Bool) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        HSLColorAccessoryView.shared.attach(to: panel, color: color)
        panel.accessoryView = HSLColorAccessoryView.shared
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        super.activate(exclusive)
        panel.orderFrontRegardless()
    }
}

/// AppKit's standard panel already provides RGB sliders, the color wheel and the
/// screen eyedropper. This compact accessory adds the missing true HSL controls.
private final class HSLColorAccessoryView: NSView {
    static let shared = HSLColorAccessoryView()

    private weak var panel: NSColorPanel?
    private let hue = NSSlider(value: 0, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let saturation = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let lightness = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let hueValue = NSTextField(labelWithString: "0°")
    private let saturationValue = NSTextField(labelWithString: "0%")
    private let lightnessValue = NSTextField(labelWithString: "0%")
    private var isSynchronizing = false

    private init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 280, height: 112))
        let title = NSTextField(labelWithString: "HSL")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(row(label: "H", slider: hue, value: hueValue))
        stack.addArrangedSubview(row(label: "S", slider: saturation, value: saturationValue))
        stack.addArrangedSubview(row(label: "L", slider: lightness, value: lightnessValue))
        for slider in [hue, saturation, lightness] {
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(changeHSL)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func row(label: String, slider: NSSlider, value: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        let name = NSTextField(labelWithString: label)
        name.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        name.alignment = .center
        name.widthAnchor.constraint(equalToConstant: 14).isActive = true
        slider.widthAnchor.constraint(equalToConstant: 190).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 42).isActive = true
        row.addArrangedSubview(name)
        row.addArrangedSubview(slider)
        row.addArrangedSubview(value)
        return row
    }

    func attach(to panel: NSColorPanel, color: NSColor) {
        self.panel = panel
        sync(from: color)
    }

    func sync(from color: NSColor) {
        guard !isSynchronizing,
              let rgb = color.usingColorSpace(.deviceRGB) else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }

        let red = rgb.redComponent
        let green = rgb.greenComponent
        let blue = rgb.blueComponent
        let maximum = max(red, max(green, blue))
        let minimum = min(red, min(green, blue))
        let delta = maximum - minimum
        let l = (maximum + minimum) / 2
        var h: CGFloat = 0
        var s: CGFloat = 0
        if delta > 0.000_001 {
            s = delta / max(0.000_001, 1 - abs(2 * l - 1))
            if maximum == red {
                h = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                h = (blue - red) / delta + 2
            } else {
                h = (red - green) / delta + 4
            }
            h *= 60
            if h < 0 { h += 360 }
        }
        hue.doubleValue = Double(h)
        saturation.doubleValue = Double(s * 100)
        lightness.doubleValue = Double(l * 100)
        updateLabels()
    }

    @objc private func changeHSL() {
        guard !isSynchronizing, let panel else { return }
        let h = CGFloat(hue.doubleValue / 360)
        let s = CGFloat(saturation.doubleValue / 100)
        let l = CGFloat(lightness.doubleValue / 100)
        let alpha = panel.color.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1

        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        if s <= 0.000_001 {
            red = l; green = l; blue = l
        } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            red = Self.hueChannel(p: p, q: q, t: h + 1 / 3)
            green = Self.hueChannel(p: p, q: q, t: h)
            blue = Self.hueChannel(p: p, q: q, t: h - 1 / 3)
        }
        updateLabels()
        panel.color = NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func hueChannel(p: CGFloat, q: CGFloat, t raw: CGFloat) -> CGFloat {
        var t = raw
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1 / 6 { return p + (q - p) * 6 * t }
        if t < 1 / 2 { return q }
        if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
        return p
    }

    private func updateLabels() {
        hueValue.stringValue = "\(Int(round(hue.doubleValue)))°"
        saturationValue.stringValue = "\(Int(round(saturation.doubleValue)))%"
        lightnessValue.stringValue = "\(Int(round(lightness.doubleValue)))%"
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
