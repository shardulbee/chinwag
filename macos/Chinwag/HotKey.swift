import AppKit
import Carbon
import SwiftUI

struct DictationShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var keyLabel: String

    static let standard = DictationShortcut(
        keyCode: 49,
        modifiers: NSEvent.ModifierFlags.option.rawValue,
        keyLabel: "Space")

    var displayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var value = ""
        if flags.contains(.control) { value += "⌃" }
        if flags.contains(.option) { value += "⌥" }
        if flags.contains(.shift) { value += "⇧" }
        if flags.contains(.command) { value += "⌘" }
        value += " \(keyLabel)"
        return value
    }

    var carbonModifiers: UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }
}

final class GlobalHotKey: ObservableObject {
    @Published private(set) var shortcut: DictationShortcut
    @Published private(set) var registrationError: String?

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let hotKeyID = EventHotKeyID(signature: 0x5350_5454, id: 1) // SPTT

    init() {
        if let data = UserDefaults.standard.data(forKey: "dictationShortcut"),
           let stored = try? JSONDecoder().decode(DictationShortcut.self, from: data)
        {
            shortcut = stored
        } else {
            shortcut = .standard
        }
        installEventHandler()
        register()
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func update(_ newShortcut: DictationShortcut) {
        shortcut = newShortcut
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: "dictationShortcut")
        }
        register()
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<GlobalHotKey>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    let kind = GetEventKind(event)
                    DispatchQueue.main.async {
                        if kind == UInt32(kEventHotKeyPressed) {
                            owner.onPress?()
                        } else if kind == UInt32(kEventHotKeyReleased) {
                            owner.onRelease?()
                        }
                    }
                    return noErr
                },
                buffer.count,
                buffer.baseAddress,
                context,
                &eventHandler)
        }
    }

    private func register() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        let result = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey)
        registrationError = result == noErr ? nil : "That shortcut is already in use."
    }
}

@MainActor
final class ShortcutCapture: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var error: String?

    private weak var hotKey: GlobalHotKey?
    private var monitor: Any?

    init(hotKey: GlobalHotKey) {
        self.hotKey = hotKey
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func toggle() {
        isCapturing ? stop() : start()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
        error = nil
    }

    private func start() {
        error = nil
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                Task { @MainActor in self.stop() }
                return nil
            }
            let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let modifiers = event.modifierFlags.intersection(allowed)
            guard !modifiers.isEmpty else {
                Task { @MainActor in self.error = "Include ⌘, ⌥, ⇧, or ⌃." }
                return nil
            }
            let shortcut = DictationShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers.rawValue,
                keyLabel: Self.keyLabel(for: event))
            Task { @MainActor in
                self.hotKey?.update(shortcut)
                self.stop()
            }
            return nil
        }
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let named: [UInt16: String] = [
            36: "Return",
            48: "Tab",
            49: "Space",
            51: "Delete",
            53: "Escape",
            115: "Home",
            116: "Page Up",
            117: "Forward Delete",
            119: "End",
            121: "Page Down",
            123: "←",
            124: "→",
            125: "↓",
            126: "↑",
        ]
        if let name = named[event.keyCode] { return name }
        let functionKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = functionKeys[event.keyCode] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}

struct ShortcutRecorder: View {
    @ObservedObject private var hotKey: GlobalHotKey
    @StateObject private var capture: ShortcutCapture

    init(hotKey: GlobalHotKey) {
        self.hotKey = hotKey
        _capture = StateObject(wrappedValue: ShortcutCapture(hotKey: hotKey))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(capture.isCapturing ? "Type Shortcut…" : hotKey.shortcut.displayName) {
                capture.toggle()
            }
            .buttonStyle(.bordered)
            .tint(capture.isCapturing ? .accentColor : .secondary)
            .frame(minWidth: 132)
            .help(capture.isCapturing ? "Press Escape to cancel" : "Record a global shortcut")

            if let error = capture.error ?? hotKey.registrationError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { capture.stop() }
    }
}
