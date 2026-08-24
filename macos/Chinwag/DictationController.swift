import AppKit
import ApplicationServices
import SwiftUI

@MainActor
enum DictationHUDState: Equatable {
    case copied
    case error(String)
    case hidden
    case recording
    case success
    case transcribing
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var mode: DictationHUDState = .hidden
    let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }
}

struct DictationHUDView: View {
    @ObservedObject var model: HUDModel
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            switch model.mode {
            case .recording:
                LevelMeter(level: appState.audioLevel, compact: true)
                    .frame(width: 88, height: 24)
                Text("Listening")
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcribing")
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Pasted")
            case .copied:
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.blue)
                Text("Copied — paste with ⌘V")
            case let .error(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            case .hidden:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 18)
        .frame(width: 340, height: 56)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
final class HUDController {
    private let model: HUDModel
    private let panel: NSPanel
    private var dismissTask: Task<Void, Never>?

    init(appState: AppState) {
        model = HUDModel(appState: appState)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let hostingView = TransparentHostingView(
            rootView: DictationHUDView(model: model, appState: appState))
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.cornerRadius = 28
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
    }

    #if DEBUG
    var fixtureContentView: NSView? { panel.contentView }
    var fixtureWindowNumber: Int { panel.windowNumber }

    func allowFixtureCapture() {
        panel.sharingType = .readOnly
    }
    #endif

    func show(_ mode: DictationHUDState, on screen: NSScreen? = nil) {
        dismissTask?.cancel()
        model.mode = mode
        guard mode != .hidden else {
            panel.orderOut(nil)
            return
        }
        let targetScreen = screen
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let visible = targetScreen?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.minY + 68)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()

        let delay: Duration?
        switch mode {
        case .success: delay = .milliseconds(700)
        case .copied: delay = .seconds(2)
        case .error: delay = .seconds(2)
        default: delay = nil
        }
        if let delay {
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                self?.show(.hidden, on: screen)
            }
        }
    }
}

@MainActor
final class DictationController {
    private let state: AppState
    private let permissions: PermissionManager
    private let hotKey: GlobalHotKey
    private let recorder: DictationRecorder
    private let service: ServiceClient
    private let hud: HUDController
    private var originatingApplication: pid_t?
    private var originatingFocusedElement: AXUIElement?
    private var originatingScreen: NSScreen?
    private var settingsAction: (() -> Void)?
    private var noticeID = UUID()

    init(
        state: AppState,
        permissions: PermissionManager,
        hotKey: GlobalHotKey,
        service: ServiceClient,
        settingsAction: @escaping () -> Void)
    {
        self.state = state
        self.permissions = permissions
        self.hotKey = hotKey
        self.service = service
        self.settingsAction = settingsAction
        self.recorder = DictationRecorder(state: state)
        self.hud = HUDController(appState: state)
        hotKey.onPress = { [weak self] in self?.beginDictation() }
        hotKey.onRelease = { [weak self] in self?.finishDictation() }
    }

    private func beginDictation() {
        guard state.activity == .idle else { return }
        permissions.refresh()
        guard permissions.microphone == .granted else {
            showNotice("Microphone access needed", error: true)
            hud.show(.error("Microphone access needed"))
            settingsAction?()
            return
        }
        guard state.isReady else {
            let message = state.unavailableMessage
            showNotice(message, error: true)
            hud.show(.error(message))
            return
        }
        do {
            originatingApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
            originatingFocusedElement = focusedElement()
            originatingScreen = NSScreen.screens.first(where: {
                $0.frame.contains(NSEvent.mouseLocation)
            })
            try recorder.start()
            state.activity = .recording
            hud.show(.recording, on: originatingScreen)
        } catch {
            showNotice(error.localizedDescription, error: true)
            hud.show(.error("Microphone could not start"))
            recorder.cleanup()
        }
    }

    private func finishDictation() {
        guard state.activity == .recording else { return }
        do {
            let recording = try recorder.stop()
            guard recording.duration >= 0.2 else {
                recorder.cleanup()
                state.activity = .idle
                hud.show(.error("Recording was too short"))
                return
            }
            state.activity = .transcribing
            hud.show(.transcribing, on: originatingScreen)
            Task { [weak self] in
                guard let self else { return }
                defer {
                    self.recorder.cleanup()
                    self.state.activity = .idle
                    self.originatingApplication = nil
                    self.originatingFocusedElement = nil
                    self.originatingScreen = nil
                }
                do {
                    let text = try await self.service.transcribe(fileURL: recording.fileURL)
                    self.permissions.refresh()
                    let currentApplication = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    let currentFocusedElement = self.focusedElement()
                    let focusIsUnchanged = self.originatingFocusedElement.map { original in
                        currentFocusedElement.map { CFEqual(original, $0) } ?? false
                    } ?? true
                    if self.permissions.accessibility == .granted,
                       currentApplication == self.originatingApplication,
                       focusIsUnchanged,
                       self.paste(text)
                    {
                        self.hud.show(.hidden, on: self.originatingScreen)
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self.hud.show(.copied, on: self.originatingScreen)
                        self.showNotice("Focus changed — transcript copied", error: false)
                    }
                    await self.service.refresh()
                } catch {
                    let message = error.localizedDescription
                    self.showNotice(message, error: true)
                    self.hud.show(.error(message), on: self.originatingScreen)
                }
            }
        } catch {
            recorder.cleanup()
            state.activity = .idle
            showNotice(error.localizedDescription, error: true)
            hud.show(.error("Recording failed"))
        }
    }

    private func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value)
        guard result == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    private func paste(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let transcriptChangeCount = pasteboard.changeCount

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if pasteboard.changeCount == transcriptChangeCount {
                snapshot.restore(to: pasteboard)
            }
        }
        return true
    }

    #if DEBUG
    var fixtureHUDContentView: NSView? { hud.fixtureContentView }
    var fixtureHUDWindowNumber: Int { hud.fixtureWindowNumber }

    func showHUDFixture() {
        hud.allowFixtureCapture()
        hud.show(.error("Recording was too short"))
    }
    #endif

    private func showNotice(_ message: String, error: Bool) {
        noticeID = UUID()
        let current = noticeID
        state.notice = message
        state.noticeIsError = error
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.noticeID == current else { return }
            self.state.notice = nil
        }
    }
}

private struct PasteboardSnapshot: @unchecked Sendable {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { values[type] = data }
            }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
