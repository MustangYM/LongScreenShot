import AppKit
import ObjectiveC

final class PinWindowController: NSWindowController {
    private static var pins: [PinWindowController] = []

    static func pin(image: CGImage) {
        let controller = PinWindowController(image: image)
        pins.append(controller)
        controller.showWindow(nil)
    }

    static func closeAll() {
        pins.forEach { $0.close() }
        pins.removeAll()
        OCRResultWindowController.closeAll()
        TranslationResultWindowController.closeAll()
    }

    init(image: CGImage) {
        let rawSize = NSSize(width: image.width, height: image.height)
        let maxSize = NSSize(width: 720, height: 560)
        let scale = min(1, maxSize.width / rawSize.width, maxSize.height / rawSize.height)
        let size = NSSize(width: rawSize.width * scale, height: rawSize.height * scale)
        let window = NSPanel(
            contentRect: NSRect(origin: NSEvent.mouseLocation, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 120, height: 90)
        let view = PinImageView(image: NSImage(cgImage: image, size: size))
        view.onClose = { [weak window] in window?.close() }
        window.contentView = view
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PinImageView: NSImageView {
    var onClose: (() -> Void)?
    var onFrameChange: (() -> Void)?
    private let closeButton = NSButton()
    private var dragStartMouse: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var resizeStartFrame: CGRect?
    private var activeResizeEdges: ResizeEdges = []

    init(image: NSImage) {
        super.init(frame: NSRect(origin: .zero, size: image.size))
        self.image = image
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L10n.tr("toolbar.cancel"))
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.frame = NSRect(x: 7, y: bounds.height - 29, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        activeResizeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        if activeResizeEdges.isEmpty {
            dragStartWindowOrigin = window?.frame.origin
            resizeStartFrame = nil
        } else {
            resizeStartFrame = window?.frame
            dragStartWindowOrigin = nil
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouse else { return }
        let current = NSEvent.mouseLocation
        if let startFrame = resizeStartFrame, !activeResizeEdges.isEmpty {
            resizeWindow(
                from: startFrame,
                delta: CGPoint(x: current.x - startMouse.x, y: current.y - startMouse.y)
            )
        } else if let startOrigin = dragStartWindowOrigin {
            window?.setFrameOrigin(CGPoint(
                x: startOrigin.x + current.x - startMouse.x,
                y: startOrigin.y + current.y - startMouse.y
            ))
            onFrameChange?()
        }
    }
    override func mouseUp(with event: NSEvent) {
        dragStartMouse = nil
        dragStartWindowOrigin = nil
        resizeStartFrame = nil
        activeResizeEdges = []
    }
    override func mouseMoved(with event: NSEvent) {
        let edges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        if edges.contains(.left) || edges.contains(.right) {
            if edges.contains(.top) || edges.contains(.bottom) { NSCursor.crosshair.set() }
            else { NSCursor.resizeLeftRight.set() }
        } else if edges.contains(.top) || edges.contains(.bottom) {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.openHand.set()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        closeButton.isHidden = true
        NSCursor.arrow.set()
    }

    private func resizeEdges(at point: CGPoint) -> ResizeEdges {
        let hit: CGFloat = 9
        var edges: ResizeEdges = []
        if point.x <= hit { edges.insert(.left) }
        if point.x >= bounds.width - hit { edges.insert(.right) }
        if point.y <= hit { edges.insert(.bottom) }
        if point.y >= bounds.height - hit { edges.insert(.top) }
        return edges
    }

    private func resizeWindow(from start: CGRect, delta: CGPoint) {
        guard let window else { return }
        var frame = start
        if activeResizeEdges.contains(.left) {
            frame.origin.x += delta.x
            frame.size.width -= delta.x
        }
        if activeResizeEdges.contains(.right) { frame.size.width += delta.x }
        if activeResizeEdges.contains(.bottom) {
            frame.origin.y += delta.y
            frame.size.height -= delta.y
        }
        if activeResizeEdges.contains(.top) { frame.size.height += delta.y }

        let minimum = window.minSize
        if frame.width < minimum.width {
            if activeResizeEdges.contains(.left) { frame.origin.x -= minimum.width - frame.width }
            frame.size.width = minimum.width
        }
        if frame.height < minimum.height {
            if activeResizeEdges.contains(.bottom) { frame.origin.y -= minimum.height - frame.height }
            frame.size.height = minimum.height
        }
        window.setFrame(frame.integral, display: true)
        onFrameChange?()
    }
    @objc private func closePin() { onClose?() }
}

final class OCRResultWindowController: NSWindowController {
    private static var results: [OCRResultWindowController] = []
    private var textWindow: NSPanel!

    static func show(image: CGImage, text: String) {
        let controller = OCRResultWindowController(image: image, text: text)
        results.append(controller)
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        controller.textWindow.orderFrontRegardless()
    }

    static func closeAll() {
        results.forEach { $0.close() }
        results.removeAll()
    }

    init(image: CGImage, text: String) {
        let rawSize = NSSize(width: image.width, height: image.height)
        let maxSize = NSSize(width: 560, height: 440)
        let scale = min(1, maxSize.width / rawSize.width, maxSize.height / rawSize.height)
        let imageSize = NSSize(width: rawSize.width * scale, height: rawSize.height * scale)
        let origin = NSEvent.mouseLocation
        let imagePanel = NSPanel(
            contentRect: NSRect(origin: origin, size: imageSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        imagePanel.level = .floating
        imagePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        imagePanel.hasShadow = true
        imagePanel.acceptsMouseMovedEvents = true
        imagePanel.backgroundColor = .windowBackgroundColor
        imagePanel.minSize = NSSize(width: 120, height: 90)
        let imageView = PinImageView(image: NSImage(cgImage: image, size: imageSize))
        imagePanel.contentView = imageView
        super.init(window: imagePanel)

        imageView.onClose = { [weak self] in self?.close() }
        textWindow = Self.makeTextWindow(
            text: text.isEmpty ? L10n.tr("ocr.noText") : text,
            frame: NSRect(x: origin.x + imageSize.width + 8, y: origin.y, width: 340, height: max(220, imageSize.height))
        )
        let resultPanel = textWindow!
        imageView.onFrameChange = { [weak imagePanel, weak resultPanel] in
            guard let imagePanel, let resultPanel else { return }
            resultPanel.setFrameOrigin(CGPoint(
                x: imagePanel.frame.maxX + 8,
                y: imagePanel.frame.minY
            ))
        }
        imagePanel.addChildWindow(textWindow, ordered: .above)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func close() {
        if let textWindow {
            window?.removeChildWindow(textWindow)
            textWindow.close()
        }
        super.close()
    }

    private static func makeTextWindow(text: String, frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .windowBackgroundColor
        panel.minSize = NSSize(width: 220, height: 150)
        panel.isMovableByWindowBackground = true

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 9
        container.layer?.masksToBounds = true
        panel.contentView = container

        let title = NSTextField(labelWithString: L10n.tr("ocr.title"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let copyButton = NSButton(title: L10n.tr("common.copy"), target: nil, action: nil)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        let copyTarget = OCRCopyTarget(text: text)
        copyButton.target = copyTarget
        copyButton.action = #selector(OCRCopyTarget.copyText)
        objc_setAssociatedObject(panel, Unmanaged.passUnretained(panel).toOpaque(), copyTarget, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        [title, copyButton, scroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 13),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 11),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -7),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -7)
        ])
        return panel
    }
}

final class TranslationResultWindowController: NSWindowController {
    private static var results: [TranslationResultWindowController] = []

    static func show(sourceText: String, translatedText: String, provider: TranslationProvider) {
        let controller = TranslationResultWindowController(
            sourceText: sourceText,
            translatedText: translatedText,
            provider: provider
        )
        results.append(controller)
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
    }

    static func closeAll() {
        results.forEach { $0.close() }
        results.removeAll()
    }

    init(sourceText: String, translatedText: String, provider: TranslationProvider) {
        let mouse = NSEvent.mouseLocation
        let window = NSPanel(
            contentRect: NSRect(x: mouse.x, y: mouse.y, width: 760, height: 430),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.format("translation.windowTitle", provider.displayName)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hasShadow = true
        window.minSize = NSSize(width: 520, height: 280)
        window.isMovableByWindowBackground = true

        let container = NSVisualEffectView(frame: NSRect(origin: .zero, size: window.frame.size))
        container.material = .hudWindow
        container.state = .active
        container.wantsLayer = true
        window.contentView = container

        let title = NSTextField(labelWithString: L10n.tr("translation.title"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: L10n.tr("translation.subtitle"))
        subtitle.font = .systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        let copySource = NSButton(title: L10n.tr("translation.copySource"), target: nil, action: nil)
        let copyTranslated = NSButton(title: L10n.tr("translation.copyTranslated"), target: nil, action: nil)
        let openWeb = NSButton(title: L10n.tr("translation.openWeb"), target: nil, action: nil)

        let sourceTitle = NSTextField(labelWithString: L10n.tr("translation.source"))
        sourceTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let translatedTitle = NSTextField(labelWithString: L10n.tr("translation.translated"))
        translatedTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let sourceScroll = Self.makeTextPane(text: sourceText.isEmpty ? L10n.tr("ocr.noText") : sourceText)
        let translatedScroll = Self.makeTextPane(text: translatedText.isEmpty ? L10n.tr("translation.empty") : translatedText)

        let target = TranslationWindowActionTarget(
            sourceText: sourceText,
            translatedText: translatedText,
            provider: provider
        )
        copySource.target = target
        copySource.action = #selector(TranslationWindowActionTarget.copySource)
        copyTranslated.target = target
        copyTranslated.action = #selector(TranslationWindowActionTarget.copyTranslated)
        openWeb.target = target
        openWeb.action = #selector(TranslationWindowActionTarget.openBrowser)
        objc_setAssociatedObject(window, Unmanaged.passUnretained(window).toOpaque(), target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        [title, subtitle, copySource, copyTranslated, openWeb, sourceTitle, translatedTitle, sourceScroll, translatedScroll].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            subtitle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            openWeb.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            openWeb.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            copyTranslated.trailingAnchor.constraint(equalTo: openWeb.leadingAnchor, constant: -8),
            copyTranslated.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            copySource.trailingAnchor.constraint(equalTo: copyTranslated.leadingAnchor, constant: -8),
            copySource.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            sourceTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sourceTitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            translatedTitle.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: 8),
            translatedTitle.centerYAnchor.constraint(equalTo: sourceTitle.centerYAnchor),

            sourceScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            sourceScroll.trailingAnchor.constraint(equalTo: container.centerXAnchor, constant: -7),
            sourceScroll.topAnchor.constraint(equalTo: sourceTitle.bottomAnchor, constant: 7),
            sourceScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            translatedScroll.leadingAnchor.constraint(equalTo: container.centerXAnchor, constant: 7),
            translatedScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            translatedScroll.topAnchor.constraint(equalTo: translatedTitle.bottomAnchor, constant: 7),
            translatedScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])

        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func close() {
        Self.results.removeAll { $0 === self }
        super.close()
    }

    private static func makeTextPane(text: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.12)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor

        let textView = NSTextView()
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }
}

private struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let bottom = ResizeEdges(rawValue: 1 << 2)
    static let top = ResizeEdges(rawValue: 1 << 3)
}

private final class OCRCopyTarget: NSObject {
    private let text: String
    init(text: String) { self.text = text }
    @objc func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private final class TranslationWindowActionTarget: NSObject {
    private let sourceText: String
    private let translatedText: String
    private let provider: TranslationProvider

    init(sourceText: String, translatedText: String, provider: TranslationProvider) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.provider = provider
    }

    @objc func copySource() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sourceText, forType: .string)
    }

    @objc func copyTranslated() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translatedText, forType: .string)
    }

    @objc func openBrowser() {
        if let url = provider.browserURL(for: sourceText) {
            NSWorkspace.shared.open(url)
        }
    }
}
