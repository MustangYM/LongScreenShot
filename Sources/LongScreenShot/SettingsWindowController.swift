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
    private let autoUpdateCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let quickCopyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let historyLimitField = NSTextField(string: "")
    private let historyLocationLabel = NSTextField(labelWithString: "")
    private let preferredWindowWidth: CGFloat = 700
    private let generalContentHeight: CGFloat = 740
    private let aboutContentHeight: CGFloat = 520
    private var currentPage: Page = .general

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 740),
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

    func presentFromStatusMenu() {
        guard let window else { return }
        if !window.isVisible { window.center() }
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func buildShell() {
        guard let content = window?.contentView else { return }
        topSegment.segmentCount = 2
        topSegment.selectedSegment = currentPage.rawValue
        topSegment.target = self
        topSegment.action = #selector(changePage)
        topSegment.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        pageContainer.wantsLayer = true
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            pageContainer.subviews.forEach { $0.removeFromSuperview() }
            switch currentPage {
            case .general:
                buildGeneralPage()
            case .about:
                buildAboutPage()
            }
            pageContainer.layoutSubtreeIfNeeded()
        }
        resizeWindowForCurrentPage(animated: window?.isVisible == true)
    }

    private func resizeWindowForCurrentPage(animated: Bool) {
        guard let window else { return }
        let contentHeight = currentPage == .general ? generalContentHeight : aboutContentHeight
        let targetContentRect = NSRect(x: 0, y: 0, width: preferredWindowWidth, height: contentHeight)
        let targetFrameSize = window.frameRect(forContentRect: targetContentRect).size
        var frame = window.frame
        let maxY = frame.maxY
        frame.size.width = targetFrameSize.width
        frame.size.height = targetFrameSize.height
        frame.origin.y = maxY - frame.height
        guard abs(window.frame.height - frame.height) > 0.5 || abs(window.frame.width - frame.width) > 0.5 else { return }
        guard animated else {
            window.setFrame(frame, display: true)
            return
        }
        window.setFrame(frame, display: true, animate: true)
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

        autoUpdateCheckbox.title = L10n.tr("settings.autoCheckUpdates")
        autoUpdateCheckbox.state = UpdateChecker.autoCheckEnabled ? .on : .off
        autoUpdateCheckbox.target = self
        autoUpdateCheckbox.action = #selector(toggleAutoUpdateCheck)
        let checkUpdateButton = NSButton(title: L10n.tr("settings.checkUpdates"), target: self, action: #selector(checkForUpdates))
        let updateHint = NSTextField(wrappingLabelWithString: L10n.tr("settings.updateHint"))
        updateHint.textColor = .secondaryLabelColor

        quickCopyCheckbox.title = L10n.tr("settings.quickCopyOnConfirm")
        quickCopyCheckbox.state = CapturePreferences.quickCopyOnConfirm ? .on : .off
        quickCopyCheckbox.target = self
        quickCopyCheckbox.action = #selector(toggleQuickCopyOnConfirm)

        let historyTitle = rowLabel("settings.history")
        historyCheckbox.title = L10n.tr("settings.saveHistory")
        historyCheckbox.state = CaptureHistoryPreferences.isEnabled ? .on : .off
        historyCheckbox.target = self
        historyCheckbox.action = #selector(toggleHistory)

        let historyLimitTitle = rowLabel("settings.historyLimit")
        historyLimitField.stringValue = "\(CaptureHistoryPreferences.maximumCount)"
        historyLimitField.alignment = .center
        historyLimitField.formatter = historyLimitFormatter()
        historyLimitField.target = self
        historyLimitField.action = #selector(changeHistoryLimit)

        let historyLocationTitle = rowLabel("settings.historyLocation")
        historyLocationLabel.stringValue = historyLocationText()
        historyLocationLabel.lineBreakMode = .byTruncatingMiddle
        let chooseHistoryLocationButton = NSButton(title: L10n.tr("settings.choose"), target: self, action: #selector(chooseHistoryLocation))
        let historyHint = NSTextField(wrappingLabelWithString: L10n.tr("settings.historyHint"))
        historyHint.textColor = .secondaryLabelColor

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
            autoUpdateCheckbox, checkUpdateButton, updateHint,
            quickCopyCheckbox,
            historyTitle, historyCheckbox,
            historyLimitTitle, historyLimitField,
            historyLocationTitle, historyLocationLabel, chooseHistoryLocationButton, historyHint,
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

            autoUpdateCheckbox.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            autoUpdateCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 18),
            checkUpdateButton.leadingAnchor.constraint(equalTo: autoUpdateCheckbox.trailingAnchor, constant: 14),
            checkUpdateButton.centerYAnchor.constraint(equalTo: autoUpdateCheckbox.centerYAnchor),
            updateHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            updateHint.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -42),
            updateHint.topAnchor.constraint(equalTo: autoUpdateCheckbox.bottomAnchor, constant: 10),

            quickCopyCheckbox.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            quickCopyCheckbox.topAnchor.constraint(equalTo: updateHint.bottomAnchor, constant: 18),

            historyTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            historyTitle.topAnchor.constraint(equalTo: quickCopyCheckbox.bottomAnchor, constant: 28),
            historyCheckbox.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            historyCheckbox.centerYAnchor.constraint(equalTo: historyTitle.centerYAnchor),

            historyLimitTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            historyLimitTitle.topAnchor.constraint(equalTo: historyTitle.bottomAnchor, constant: 18),
            historyLimitField.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            historyLimitField.centerYAnchor.constraint(equalTo: historyLimitTitle.centerYAnchor),
            historyLimitField.widthAnchor.constraint(equalToConstant: 72),

            historyLocationTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            historyLocationTitle.topAnchor.constraint(equalTo: historyLimitTitle.bottomAnchor, constant: 18),
            historyLocationLabel.leadingAnchor.constraint(equalTo: languagePopup.leadingAnchor),
            historyLocationLabel.centerYAnchor.constraint(equalTo: historyLocationTitle.centerYAnchor),
            historyLocationLabel.widthAnchor.constraint(equalToConstant: 250),
            chooseHistoryLocationButton.leadingAnchor.constraint(equalTo: historyLocationLabel.trailingAnchor, constant: 10),
            chooseHistoryLocationButton.centerYAnchor.constraint(equalTo: historyLocationLabel.centerYAnchor),
            historyHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            historyHint.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor, constant: -42),
            historyHint.topAnchor.constraint(equalTo: historyLocationTitle.bottomAnchor, constant: 10),

            hotKeyTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            hotKeyTitle.topAnchor.constraint(equalTo: historyHint.bottomAnchor, constant: 28),
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

    private func historyLimitFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 200
        formatter.allowsFloats = false
        return formatter
    }

    private func historyLocationText() -> String {
        CaptureHistoryPreferences.directoryURL.path
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

    @objc private func toggleAutoUpdateCheck() {
        UpdateChecker.autoCheckEnabled = autoUpdateCheckbox.state == .on
    }

    @objc private func toggleQuickCopyOnConfirm() {
        CapturePreferences.quickCopyOnConfirm = quickCopyCheckbox.state == .on
    }

    @objc private func toggleHistory() {
        CaptureHistoryPreferences.isEnabled = historyCheckbox.state == .on
    }

    @objc private func changeHistoryLimit() {
        CaptureHistoryPreferences.maximumCount = Int(historyLimitField.integerValue)
        historyLimitField.stringValue = "\(CaptureHistoryPreferences.maximumCount)"
    }

    @objc private func chooseHistoryLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = CaptureHistoryPreferences.directoryURL
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            CaptureHistoryPreferences.setDirectoryURL(url)
            self?.historyLocationLabel.stringValue = self?.historyLocationText() ?? url.path
        }
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates(userInitiated: true)
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


final class UpdateChecker {
    static let shared = UpdateChecker()

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let name: String?
        let htmlURL: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }

        var preferredUpdateURL: URL? {
            let dmgAsset = assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            if let download = dmgAsset?.browserDownloadURL, let url = URL(string: download) {
                return url
            }
            return URL(string: htmlURL)
        }
    }

    private struct Version: Comparable, CustomStringConvertible {
        let rawValue: String
        private let numbers: [Int]

        init(_ value: String) {
            var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.lowercased().hasPrefix("v") {
                cleaned.removeFirst()
            }
            rawValue = cleaned
            numbers = cleaned
                .split(separator: ".")
                .map { part in
                    let numericPrefix = part.prefix { $0.isNumber }
                    return Int(numericPrefix) ?? 0
                }
        }

        var description: String { rawValue }

        static func < (lhs: Version, rhs: Version) -> Bool {
            let count = max(lhs.numbers.count, rhs.numbers.count)
            for index in 0..<count {
                let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
                let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }

    private enum Keys {
        static let autoCheck = "autoCheckForUpdates"
        static let lastCheckAt = "lastUpdateCheckAt"
    }

    static var autoCheckEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.autoCheck) == nil { return true }
            return UserDefaults.standard.bool(forKey: Keys.autoCheck)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.autoCheck)
        }
    }

    private let releasesAPIURL = URL(string: "https://api.github.com/repos/MustangYM/LongScreenShot/releases?per_page=30")!
    private let fallbackURL = URL(string: "https://github.com/MustangYM/LongScreenShot/releases")!
    private var isChecking = false

    private init() {}

    func checkAutomaticallyIfNeeded() {
        guard Self.autoCheckEnabled else { return }
        let lastCheck = UserDefaults.standard.double(forKey: Keys.lastCheckAt)
        guard Date().timeIntervalSince1970 - lastCheck > 12 * 60 * 60 else { return }
        checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) {
        guard !isChecking else {
            if userInitiated {
                showMessage(title: L10n.tr("update.checking"), message: "")
            }
            return
        }

        isChecking = true
        var request = URLRequest(url: releasesAPIURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("LongScreenShot/\(currentVersion().description)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResponse(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        isChecking = false
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheckAt)

        if let error {
            if userInitiated {
                showUpdateCheckFailed(message: error.localizedDescription)
            }
            return
        }

        guard let http = response as? HTTPURLResponse, let data else {
            if userInitiated {
                showUpdateCheckFailed(message: L10n.tr("update.failedMessage"))
            }
            return
        }

        guard (200..<300).contains(http.statusCode) else {
            if userInitiated {
                showUpdateCheckFailed(message: "HTTP \(http.statusCode)")
            }
            return
        }

        do {
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            let stableReleases = releases.filter { !$0.draft && !$0.prerelease }
            guard let release = stableReleases.max(by: { Version($0.tagName) < Version($1.tagName) }) else {
                if userInitiated { showUpToDate() }
                return
            }

            let latest = Version(release.tagName)
            let current = currentVersion()
            if latest > current {
                showUpdateAvailable(release: release, latest: latest, current: current)
            } else if userInitiated {
                showUpToDate()
            }
        } catch {
            if userInitiated {
                showUpdateCheckFailed(message: error.localizedDescription)
            }
        }
    }

    private func currentVersion() -> Version {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return Version(raw)
    }

    private func showUpdateAvailable(release: GitHubRelease, latest: Version, current: Version) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.availableTitle")
        let fallbackName = "v\(latest.description)"
        let releaseName = (release.name?.isEmpty == false) ? (release.name ?? fallbackName) : fallbackName
        alert.informativeText = "\(releaseName)\n\n" + L10n.format("update.availableMessage", latest.description, current.description)
        alert.addButton(withTitle: L10n.tr("update.openRelease"))
        alert.addButton(withTitle: L10n.tr("common.later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.preferredUpdateURL ?? fallbackURL)
        }
    }

    private func showUpToDate() {
        showMessage(
            title: L10n.tr("update.noUpdateTitle"),
            message: L10n.format("update.noUpdateMessage", currentVersion().description)
        )
    }

    private func showUpdateCheckFailed(message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("update.failedTitle")
        alert.informativeText = message.isEmpty ? L10n.tr("update.failedMessage") : message
        alert.addButton(withTitle: L10n.tr("update.openRelease"))
        alert.addButton(withTitle: L10n.tr("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(fallbackURL)
        }
    }

    private func showMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.tr("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
