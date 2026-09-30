import AppKit
import Carbon

struct HotKeyConfiguration: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultValue = HotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_2),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static var current: HotKeyConfiguration {
        get {
            guard let data = UserDefaults.standard.data(forKey: "hotKeyConfiguration"),
                  let value = try? JSONDecoder().decode(Self.self, from: data) else { return .defaultValue }
            return value
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: "hotKeyConfiguration")
            NotificationCenter.default.post(name: .hotKeyDidChange, object: nil)
        }
    }

    var displayString: String {
        let flags = GlobalHotKey.cocoaFlags(from: carbonModifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += KeyName.name(for: UInt16(keyCode))
        return text
    }

    var normalized: HotKeyConfiguration {
        HotKeyConfiguration(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers & UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return UInt32(event.keyCode) == keyCode
            && GlobalHotKey.carbonFlags(from: flags) == normalized.carbonModifiers
    }
}

enum CaptureCommand: String, CaseIterable, Codable {
    case rectangle, ellipse, arrow, text, pen, longCapture, mosaic
    case pin, ocr, translate
    case undo, redo, cancel, copy, save

    var title: String {
        switch self {
        case .rectangle: return L10n.tr("toolbar.rectangle")
        case .ellipse: return L10n.tr("toolbar.ellipse")
        case .arrow: return L10n.tr("toolbar.arrow")
        case .text: return L10n.tr("toolbar.text")
        case .pen: return L10n.tr("toolbar.pen")
        case .longCapture: return L10n.tr("toolbar.longCapture")
        case .mosaic: return L10n.tr("toolbar.mosaic")
        case .pin: return L10n.tr("toolbar.pin")
        case .ocr: return L10n.tr("toolbar.ocr")
        case .translate: return L10n.tr("toolbar.translate")
        case .undo: return L10n.tr("toolbar.undo")
        case .redo: return L10n.tr("toolbar.redo")
        case .cancel: return L10n.tr("toolbar.cancel")
        case .copy: return L10n.tr("toolbar.confirmCopy")
        case .save: return L10n.tr("toolbar.save")
        }
    }

    var defaultShortcut: HotKeyConfiguration {
        func key(_ keyCode: Int, _ modifiers: UInt32 = 0) -> HotKeyConfiguration {
            HotKeyConfiguration(keyCode: UInt32(keyCode), carbonModifiers: modifiers)
        }
        switch self {
        case .rectangle: return key(kVK_ANSI_R)
        case .ellipse: return key(kVK_ANSI_E)
        case .arrow: return key(kVK_ANSI_A)
        case .text: return key(kVK_ANSI_T)
        case .pen: return key(kVK_ANSI_P)
        case .longCapture: return key(kVK_ANSI_L)
        case .mosaic: return key(kVK_ANSI_M)
        case .pin: return key(kVK_ANSI_I)
        case .ocr: return key(kVK_ANSI_O)
        case .translate: return key(kVK_ANSI_G)
        case .undo: return key(kVK_ANSI_Z, UInt32(cmdKey))
        case .redo: return key(kVK_ANSI_Z, UInt32(cmdKey | shiftKey))
        case .cancel: return key(kVK_Escape)
        case .copy: return key(kVK_ANSI_C, UInt32(cmdKey))
        case .save: return key(kVK_ANSI_S, UInt32(cmdKey))
        }
    }

    var group: Int {
        switch self {
        case .rectangle, .ellipse, .arrow, .text, .pen, .longCapture, .mosaic: return 0
        case .pin, .ocr, .translate: return 1
        case .undo, .redo, .cancel, .copy, .save: return 2
        }
    }
}

enum ToolShortcutStore {
    enum AssignmentResult {
        case saved
        case conflict(CaptureCommand)
        case conflictsWithGlobalCapture
        case reserved
    }

    private static let defaultsKey = "captureCommandShortcuts.v1"
    private static var cachedValues: [String: HotKeyConfiguration] = {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode([String: HotKeyConfiguration].self, from: data) else {
            return [:]
        }
        return value
    }()

    private static var stored: [String: HotKeyConfiguration] {
        get { cachedValues }
        set {
            cachedValues = newValue
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
            NotificationCenter.default.post(name: .toolShortcutsDidChange, object: nil)
        }
    }

    static func configuration(for command: CaptureCommand) -> HotKeyConfiguration {
        (stored[command.rawValue] ?? command.defaultShortcut).normalized
    }

    @discardableResult
    static func assign(_ configuration: HotKeyConfiguration, to command: CaptureCommand) -> AssignmentResult {
        let value = configuration.normalized
        let keyCode = UInt16(value.keyCode)
        if keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete) {
            return .reserved
        }
        if keyCode == UInt16(kVK_Escape), command != .cancel { return .reserved }
        if value == HotKeyConfiguration.current.normalized { return .conflictsWithGlobalCapture }
        for other in CaptureCommand.allCases where other != command {
            if ToolShortcutStore.configuration(for: other) == value { return .conflict(other) }
        }
        var values = stored
        values[command.rawValue] = value
        stored = values
        return .saved
    }

    static func restoreDefault(for command: CaptureCommand) {
        var values = stored
        values.removeValue(forKey: command.rawValue)
        stored = values
    }

    static func restoreAllDefaults() {
        cachedValues.removeAll(keepingCapacity: false)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: .toolShortcutsDidChange, object: nil)
    }

    static func command(matching event: NSEvent) -> CaptureCommand? {
        CaptureCommand.allCases.first { configuration(for: $0).matches(event) }
    }

    static func conflictingCommand(for configuration: HotKeyConfiguration) -> CaptureCommand? {
        let value = configuration.normalized
        return CaptureCommand.allCases.first { self.configuration(for: $0) == value }
    }
}

extension Notification.Name {
    static let toolShortcutsDidChange = Notification.Name("LongScreenShot.toolShortcutsDidChange")
}

final class GlobalHotKey {
    private static var nextIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void
    private let identifier: UInt32

    init?(configuration: HotKeyConfiguration, action: @escaping () -> Void) {
        identifier = Self.nextIdentifier
        Self.nextIdentifier &+= 1
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            var incoming = EventHotKeyID()
            var actualSize = 0
            guard GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                &actualSize,
                &incoming
            ) == noErr, incoming.id == owner.identifier else { return noErr }
            DispatchQueue.main.async { owner.action() }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        guard status == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x4C535348), id: identifier) // LSSH
        guard RegisterEventHotKey(configuration.keyCode, configuration.carbonModifiers, id,
                                  GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    static func cocoaFlags(from carbon: UInt32) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { result.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { result.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { result.insert(.control) }
        return result
    }

    static func carbonFlags(from cocoa: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if cocoa.contains(.command) { result |= UInt32(cmdKey) }
        if cocoa.contains(.shift) { result |= UInt32(shiftKey) }
        if cocoa.contains(.option) { result |= UInt32(optionKey) }
        if cocoa.contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}

enum KeyName {
    static func name(for code: UInt16) -> String {
        let map: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
            UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
            UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
            UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
            UInt16(kVK_ANSI_9): "9", UInt16(kVK_Space): "Space",
            UInt16(kVK_Return): "↩", UInt16(kVK_ANSI_KeypadEnter): "⌤",
            UInt16(kVK_Escape): "Esc", UInt16(kVK_Delete): "⌫",
            UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Tab): "⇥",
            UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓"
        ]
        return map[code] ?? "Key\(code)"
    }
}
