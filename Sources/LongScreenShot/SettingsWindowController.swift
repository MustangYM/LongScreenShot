import AppKit

final class SettingsWindowController: NSWindowController {
    private enum Page: Int { case general, about }

    private let topSegment = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private let pageContainer = NSView()
    private let recorder = HotKeyRecorderView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))
    private let permissionLabel = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let translationPopup = NSPopUpButton()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var currentPage: Page = .general

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        buildShell()
        refreshLanguage()
    }

    func refreshLanguage() {
        window?.title = L10n.tr("settings.title")
        topSegment.setLabel(L10n.tr("settings.general"), forSegment: 0)
        topSegment.setLabel(L10n.tr("settings.about"), forSegment: 1)
        rebuildPage()
    }

    private func buildShell() {
        guard let content = window?.contentView else { return }
        topSegment.segmentCount = 2
        topSegment.selectedSegment = currentPage.rawValue
        topSegment.target = self
        topSegment.action = #selector(changePage)
        topSegment.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(topSegment)
        content.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            topSegment.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            topSegment.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            topSegment.widthAnchor.constraint(equalToConstant: 220),
            pageContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: topSegment.bottomAnchor, constant: 18),
            pageContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    @objc private func changePage() {
        currentPage = Page(rawValue: topSegment.selectedSegment) ?? .general
        rebuildPage()
    }

    private func rebuildPage() {
        pageContainer.subviews.forEach { $0.removeFromSuperview() }
        switch currentPage {
        case .general:
            buildGeneralPage()
        case .about:
            buildAboutPage()
        }
    }

    private func buildGeneralPage() {
        let title = NSTextField(labelWithString: L10n.tr("settings.general"))
        title.font = .systemFont(ofSize: 24, weight: .semibold)

        let languageTitle = rowLabel("settings.language")
        configureLanguagePopup()

        launchAtLoginCheckbox.title = L10n.tr("settings.launchAtLogin")
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(toggleLaunchAtLogin)

        let hotKeyTitle = rowLabel("settings.hotkey")
        recorder.configuration = .current
        let restore = NSButton(title: L10n.tr("settings.restoreDefault"), target: self, action: #selector(restoreDefault))
        let hint = NSTextField(wrappingLabelWithString: L10n.tr("settings.hotkeyHint"))
        hint.textColor = .secondaryLabelColor

        let translationTitle = rowLabel("settings.translationProvider")
        configureTranslationPopup()
        let translationHint = NSTextField(wrappingLabelWithString: L10n.tr("settings.translationHint"))
        translationHint.textColor = .secondaryLabelColor

        updatePermissionLabel()
        let permissionButton = NSButton(title: L10n.tr("permission.openSettings"), target: self, action: #selector(openSettings))

        [
            title,
            languageTitle, languagePopup,
            launchAtLoginCheckbox,
            hotKeyTitle, recorder, restore, hint,
            translationTitle, translationPopup, translationHint,
            permissionLabel, permissionButton
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor, constant: 42),
            title.topAnchor.constraint(equalTo: pageContainer.topAnchor, constant: 4),

            languageTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            languageTitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 32),
            languagePopup.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor, constant: 220),
            languagePopup.centerYAnchor.constraint(equalTo: languageTitle.centerYAnchor),
            languagePopup.widthAnchor.constraint(equalToConstant: 180),

            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            launchAtLoginCheckbox.topAnchor.constraint(equalTo: languagePopup.bottomAnchor, constant: 20),

            hotKeyTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hotKeyTitle.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 32),
            recorder.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            recorder.centerYAnchor.constraint(equalTo: hotKeyTitle.centerYAnchor),
            recorder.widthAnchor.constraint(equalToConstant: 220),
            recorder.heightAnchor.constraint(equalToConstant: 34),
            restore.leadingAnchor.constraint(equalTo: recorder.trailingAnchor, constant: 12),
            restore.centerYAnchor.constraint(equalTo: recorder.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -42),
            hint.topAnchor.constraint(equalTo: recorder.bottomAnchor, constant: 12),

            translationTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            translationTitle.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 30),
            translationPopup.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            translationPopup.centerYAnchor.constraint(equalTo: translationTitle.centerYAnchor),
            translationPopup.widthAnchor.constraint(equalToConstant: 180),
            translationHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            translationHint.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -42),
            translationHint.topAnchor.constraint(equalTo: translationPopup.bottomAnchor, constant: 12),

            permissionLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            permissionLabel.topAnchor.constraint(equalTo: translationHint.bottomAnchor, constant: 34),
            permissionButton.leadingAnchor.constraint(equalTo: permissionLabel.trailingAnchor, constant: 18),
            permissionButton.centerYAnchor.constraint(equalTo: permissionLabel.centerYAnchor)
        ])
    }

    private func buildAboutPage() {
        let icon = NSImageView()
        icon.image = NSImage(named: "AppIcon")
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 70, weight: .regular)

        let appName = NSTextField(labelWithString: "LongScreenShot")
        appName.font = .systemFont(ofSize: 30, weight: .bold)
        appName.alignment = .center

        let version = NSTextField(labelWithString: versionString())
        version.font = .systemFont(ofSize: 14, weight: .medium)
        version.textColor = .secondaryLabelColor
        version.alignment = .center

        let projectTitle = NSTextField(labelWithString: "\(L10n.tr("settings.projectHomepage"))：")
        projectTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let projectLink = LinkButton(title: "MustangYM/LongScreenShot", url: URL(string: "https://github.com/MustangYM/LongScreenShot")!)

        let xTitle = NSTextField(labelWithString: "X：")
        xTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let xLink = LinkButton(title: "MustangYM", url: URL(string: "https://x.com/MustangYM")!)

        let contactTitle = NSTextField(labelWithString: "\(L10n.tr("settings.contact"))：")
        contactTitle.font = .systemFont(ofSize: 14, weight: .medium)
        let email = LinkButton(title: "MustangYM@yeah.net", url: URL(string: "mailto:MustangYM@yeah.net")!)

        let note = NSTextField(wrappingLabelWithString: L10n.tr("settings.privacyNote"))
        note.textColor = .secondaryLabelColor
        note.alignment = .center

        [icon, appName, version, projectTitle, projectLink, xTitle, xLink, contactTitle, email, note].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            pageContainer.addSubview($0)
        }

        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: pageContainer.centerXAnchor),
            icon.topAnchor.constraint(equalTo: pageContainer.topAnchor, constant: 34),
            icon.widthAnchor.constraint(equalToConstant: 84),
            icon.heightAnchor.constraint(equalToConstant: 84),
            appName.centerXAnchor.constraint(equalTo: pageContainer.centerXAnchor),
            appName.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 18),
            version.centerXAnchor.constraint(equalTo: pageContainer.centerXAnchor),
            version.topAnchor.constraint(equalTo: appName.bottomAnchor, constant: 10),
            projectTitle.trailingAnchor.constraint(equalTo: pageContainer.centerXAnchor, constant: -4),
            projectTitle.topAnchor.constraint(equalTo: version.bottomAnchor, constant: 36),
            projectLink.leadingAnchor.constraint(equalTo: pageContainer.centerXAnchor, constant: 4),
            projectLink.centerYAnchor.constraint(equalTo: projectTitle.centerYAnchor),
            xTitle.trailingAnchor.constraint(equalTo: projectTitle.trailingAnchor),
            xTitle.topAnchor.constraint(equalTo: projectTitle.bottomAnchor, constant: 16),
            xLink.leadingAnchor.constraint(equalTo: projectLink.leadingAnchor),
            xLink.centerYAnchor.constraint(equalTo: xTitle.centerYAnchor),
            contactTitle.trailingAnchor.constraint(equalTo: projectTitle.trailingAnchor),
            contactTitle.topAnchor.constraint(equalTo: xTitle.bottomAnchor, constant: 16),
            email.leadingAnchor.constraint(equalTo: projectLink.leadingAnchor),
            email.centerYAnchor.constraint(equalTo: contactTitle.centerYAnchor),
            note.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor, constant: 70),
            note.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -70),
            note.topAnchor.constraint(equalTo: contactTitle.bottomAnchor, constant: 38)
        ])
    }

    private func rowLabel(_ key: String) -> NSTextField {
        let label = NSTextField(labelWithString: L10n.tr(key))
        label.font = .systemFont(ofSize: 15, weight: .medium)
        return label
    }

    private func configureLanguagePopup() {
        languagePopup.removeAllItems()
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(withTitle: AppLanguage.current.displayName)
        languagePopup.target = self
        languagePopup.action = #selector(changeLanguage)
    }

    private func configureTranslationPopup() {
        translationPopup.removeAllItems()
        for provider in TranslationProvider.allCases {
            translationPopup.addItem(withTitle: provider.displayName)
            translationPopup.lastItem?.representedObject = provider.rawValue
        }
        translationPopup.selectItem(withTitle: TranslationProvider.current.displayName)
        translationPopup.target = self
        translationPopup.action = #selector(changeTranslationProvider)
    }

    private func updatePermissionLabel() {
        let granted = CGPreflightScreenCaptureAccess()
        permissionLabel.stringValue = granted
            ? L10n.tr("settings.screenRecordingGranted")
            : L10n.tr("settings.screenRecordingDenied")
        permissionLabel.textColor = granted ? .systemGreen : .systemOrange
    }

    private func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return L10n.format("settings.version", version, build)
    }

    @objc private func openSettings() { ScreenCaptureAuthorization.openSystemSettings() }

    @objc private func changeLanguage() {
        guard let rawValue = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue) else { return }
        AppLanguage.current = language
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.setEnabled(launchAtLoginCheckbox.state == .on)
        } catch {
            launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = L10n.tr("settings.launchFailed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func changeTranslationProvider() {
        guard let rawValue = translationPopup.selectedItem?.representedObject as? String,
              let provider = TranslationProvider(rawValue: rawValue) else { return }
        TranslationProvider.current = provider
    }

    @objc private func restoreDefault() {
        HotKeyConfiguration.current = .defaultValue
        recorder.configuration = .defaultValue
    }
}

final class HotKeyRecorderView: NSView {
    var configuration: HotKeyConfiguration = .current { didSet { needsDisplay = true } }
    private var recording = false

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { recording = false; needsDisplay = true; return }
        if event.keyCode == 51 || event.keyCode == 117 {
            configuration = .defaultValue
            HotKeyConfiguration.current = configuration
            recording = false
            return
        }
        let relevant = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard relevant.contains(.command) || relevant.contains(.option) || relevant.contains(.control) else {
            NSSound.beep(); return
        }
        configuration = HotKeyConfiguration(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: GlobalHotKey.carbonFlags(from: relevant)
        )
        HotKeyConfiguration.current = configuration
        recording = false
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        needsDisplay = true
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()
        let text = recording ? L10n.tr("settings.recordHotKey") : configuration.displayString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attrs)
    }
}

final class LinkButton: NSButton {
    private let url: URL

    init(title: String, url: URL) {
        self.url = url
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        target = self
        action = #selector(openLink)
        contentTintColor = .controlAccentColor
        font = .systemFont(ofSize: 14, weight: .semibold)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func openLink() {
        NSWorkspace.shared.open(url)
    }
}
