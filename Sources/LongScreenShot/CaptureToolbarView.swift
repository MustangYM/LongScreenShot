import AppKit

protocol CaptureToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: CaptureToolbarView, selected tool: AnnotationTool?)
    func toolbar(_ toolbar: CaptureToolbarView, hoveredDescription description: String?)
    func toolbarRequestedLongCapture(_ toolbar: CaptureToolbarView)
    func toolbarRequestedPin(_ toolbar: CaptureToolbarView)
    func toolbarRequestedOCR(_ toolbar: CaptureToolbarView)
    func toolbarRequestedTranslate(_ toolbar: CaptureToolbarView)
    func toolbarRequestedUndo(_ toolbar: CaptureToolbarView)
    func toolbarRequestedRedo(_ toolbar: CaptureToolbarView)
    func toolbarRequestedCancel(_ toolbar: CaptureToolbarView)
    func toolbarRequestedCopy(_ toolbar: CaptureToolbarView)
    func toolbarRequestedSave(_ toolbar: CaptureToolbarView)
}

final class CaptureToolbarView: NSVisualEffectView {
    weak var delegate: CaptureToolbarDelegate?
    private var toolButtons: [NSButton: AnnotationTool] = [:]
    private var selectedButton: NSButton?
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        buildButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var fittingSize: NSSize { NSSize(width: stack.fittingSize.width + 18, height: 56) }

    private func buildButtons() {
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        addTool("rectangle", L10n.tr("toolbar.rectangle"), .rectangle)
        addTool("circle", L10n.tr("toolbar.ellipse"), .ellipse)
        addTool("arrow.up.right", L10n.tr("toolbar.arrow"), .arrow)
        addTool("text.tool", L10n.tr("toolbar.text"), .text)
        addTool("curve.pen", L10n.tr("toolbar.pen"), .pen)
        addAction("long.capture", L10n.tr("toolbar.longCapture"), #selector(longCapture))
        addTool("mosaic.tool", L10n.tr("toolbar.mosaic"), .mosaicPixel)
        addAction("pin.fill", L10n.tr("toolbar.pin"), #selector(pin))
        addAction("text.viewfinder", "OCR", #selector(ocr))
        addAction("character.bubble", L10n.tr("toolbar.translate"), #selector(translate))
        addSeparator()
        addAction("arrow.uturn.backward", L10n.tr("toolbar.undo"), #selector(undo))
        addAction("arrow.uturn.forward", L10n.tr("toolbar.redo"), #selector(redo))
        addAction("xmark", L10n.tr("toolbar.cancel"), #selector(cancel))
        addAction("checkmark", L10n.tr("toolbar.confirmCopy"), #selector(copyImage), accent: true)
        addAction("square.and.arrow.down", L10n.tr("toolbar.save"), #selector(save))
    }

    private func button(symbol: String, tip: String, action: Selector) -> NSButton {
        let baseImage: NSImage?
        switch symbol {
        case "long.capture":
            baseImage = Self.longCaptureImage()
        case "text.tool":
            baseImage = Self.textToolImage()
        case "curve.pen":
            baseImage = Self.curvePenImage()
        case "mosaic.tool":
            baseImage = Self.mosaicImage()
        default:
            baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        }
        let image = ["long.capture", "text.tool", "curve.pen", "mosaic.tool"].contains(symbol)
            ? baseImage
            : baseImage?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        let button = HoverButton(image: image ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.onHover = { [weak self, weak button] isHovering in
            guard let self else { return }
            self.delegate?.toolbar(self, hoveredDescription: isHovering ? button?.toolTip : nil)
        }
        button.contentTintColor = .labelColor
        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.widthAnchor.constraint(equalToConstant: 40).isActive = true
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(button)
        return button
    }

    private func addTool(_ symbol: String, _ tip: String, _ tool: AnnotationTool, action: Selector = #selector(selectTool(_:))) {
        let item = button(symbol: symbol, tip: tip, action: action)
        toolButtons[item] = tool
    }

    private func addAction(_ symbol: String, _ tip: String, _ action: Selector, accent: Bool = false) {
        let item = button(symbol: symbol, tip: tip, action: action)
        if accent { item.contentTintColor = .controlAccentColor }
    }

    private func addSeparator() {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(line)
    }

    private static func longCaptureImage() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let page = NSBezierPath(roundedRect: CGRect(x: 4.8, y: 3.2, width: 13.8, height: 17.6), xRadius: 2.8, yRadius: 2.8)
            page.lineWidth = 1.8
            page.stroke()

            let lines = NSBezierPath()
            for y in [16.5, 13.5, 10.5, 7.5] as [CGFloat] {
                lines.move(to: CGPoint(x: 7.2, y: y))
                lines.line(to: CGPoint(x: 13.5, y: y))
            }
            lines.lineWidth = 1.35
            lines.lineCapStyle = .round
            lines.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: 19.9, y: 16.7))
            arrow.line(to: CGPoint(x: 19.9, y: 7.3))
            arrow.move(to: CGPoint(x: 17.6, y: 14.3))
            arrow.line(to: CGPoint(x: 19.9, y: 17.1))
            arrow.line(to: CGPoint(x: 22.2, y: 14.3))
            arrow.move(to: CGPoint(x: 17.6, y: 9.7))
            arrow.line(to: CGPoint(x: 19.9, y: 6.9))
            arrow.line(to: CGPoint(x: 22.2, y: 9.7))
            arrow.lineWidth = 2.1
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func mosaicImage() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let frame = NSBezierPath(roundedRect: CGRect(x: 3.6, y: 3.6, width: 16.8, height: 16.8), xRadius: 3.2, yRadius: 3.2)
            frame.lineWidth = 1.7
            frame.stroke()

            NSColor.labelColor.withAlphaComponent(0.86).setFill()
            let blockRects = [
                CGRect(x: 6.2, y: 14.1, width: 3.8, height: 3.8),
                CGRect(x: 10.6, y: 14.1, width: 3.8, height: 3.8),
                CGRect(x: 15.0, y: 14.1, width: 2.8, height: 3.8),
                CGRect(x: 6.2, y: 9.7, width: 3.8, height: 3.8),
                CGRect(x: 10.6, y: 9.7, width: 3.8, height: 3.8),
                CGRect(x: 15.0, y: 9.7, width: 2.8, height: 3.8),
                CGRect(x: 6.2, y: 6.2, width: 3.8, height: 3.0),
                CGRect(x: 10.6, y: 6.2, width: 3.8, height: 3.0),
                CGRect(x: 15.0, y: 6.2, width: 2.8, height: 3.0)
            ]
            for (index, rect) in blockRects.enumerated() {
                NSColor.labelColor.withAlphaComponent(index.isMultiple(of: 2) ? 0.92 : 0.48).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
            }

            NSColor.labelColor.setStroke()
            let slash = NSBezierPath()
            slash.move(to: CGPoint(x: 14.6, y: 4.8))
            slash.curve(
                to: CGPoint(x: 21.0, y: 11.2),
                controlPoint1: CGPoint(x: 18.0, y: 4.9),
                controlPoint2: CGPoint(x: 20.9, y: 7.8)
            )
            slash.lineWidth = 2.1
            slash.lineCapStyle = .round
            slash.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func textToolImage() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .black),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            "T".draw(in: CGRect(x: 0, y: 1.5, width: 24, height: 22), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func curvePenImage() -> NSImage {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let curve = NSBezierPath()
            curve.move(to: CGPoint(x: 3, y: 7))
            curve.curve(
                to: CGPoint(x: 20.5, y: 17),
                controlPoint1: CGPoint(x: 8, y: 21),
                controlPoint2: CGPoint(x: 14, y: 2.5)
            )
            curve.lineWidth = 2.4
            curve.lineCapStyle = .round
            curve.stroke()
            let tip = NSBezierPath()
            tip.move(to: CGPoint(x: 18.2, y: 14.5))
            tip.line(to: CGPoint(x: 22, y: 18.5))
            tip.line(to: CGPoint(x: 17.1, y: 20.2))
            tip.lineWidth = 1.8
            tip.lineJoinStyle = .round
            tip.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = toolButtons[sender] else { return }
        if selectedButton === sender {
            selectedButton = nil
            sender.contentTintColor = .labelColor
            (sender as? HoverButton)?.isSelectedAppearance = false
            delegate?.toolbar(self, selected: nil)
        } else {
            selectedButton?.contentTintColor = .labelColor
            (selectedButton as? HoverButton)?.isSelectedAppearance = false
            selectedButton = sender
            sender.contentTintColor = .controlAccentColor
            (sender as? HoverButton)?.isSelectedAppearance = true
            delegate?.toolbar(self, selected: tool)
        }
    }

    func selectLongCapture() {}

    func setManualLongCaptureMode() {
        selectedButton?.contentTintColor = .labelColor
        (selectedButton as? HoverButton)?.isSelectedAppearance = false
        selectedButton = nil
        toolButtons.keys.forEach { $0.isEnabled = false }
        let unavailable = Set([
            L10n.tr("toolbar.pin"),
            "OCR",
            L10n.tr("toolbar.translate"),
            L10n.tr("toolbar.undo"),
            L10n.tr("toolbar.redo")
        ])
        for case let button as NSButton in stack.arrangedSubviews {
            if let tip = button.toolTip, unavailable.contains(tip) { button.isEnabled = false }
            if button.toolTip == L10n.tr("toolbar.longCapture") {
                button.toolTip = L10n.tr("toolbar.finishLongCapture")
                button.contentTintColor = .controlAccentColor
                (button as? HoverButton)?.isSelectedAppearance = true
            }
        }
        delegate?.toolbar(self, selected: nil)
    }

    @objc private func longCapture() { delegate?.toolbarRequestedLongCapture(self) }
    @objc private func pin() { delegate?.toolbarRequestedPin(self) }
    @objc private func ocr() { delegate?.toolbarRequestedOCR(self) }
    @objc private func translate() { delegate?.toolbarRequestedTranslate(self) }
    @objc private func undo() { delegate?.toolbarRequestedUndo(self) }
    @objc private func redo() { delegate?.toolbarRequestedRedo(self) }
    @objc private func cancel() { delegate?.toolbarRequestedCancel(self) }
    @objc private func copyImage() { delegate?.toolbarRequestedCopy(self) }
    @objc private func save() { delegate?.toolbarRequestedSave(self) }
}

final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    var isSelectedAppearance = false { didSet { updateBackground() } }
    private var isHovering = false

    private func updateBackground() {
        wantsLayer = true
        layer?.backgroundColor = (isSelectedAppearance
            ? NSColor.controlAccentColor.withAlphaComponent(0.22)
            : (isHovering ? NSColor.white.withAlphaComponent(0.12) : .clear)).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        updateBackground()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        updateBackground()
        onHover?(false)
    }
}
