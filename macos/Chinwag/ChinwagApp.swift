import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct ChinwagMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private let permissions = PermissionManager()
    private let hotKey = GlobalHotKey()
    private var service: ServiceClient!
    private var modelInstaller: ModelInstaller!
    private var dictation: DictationController!
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var stateObservation: AnyCancellable?
    private var loadingTimer: Timer?
    private var loadingDimmed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        service = ServiceClient(state: state)
        modelInstaller = ModelInstaller(state: state)
        dictation = DictationController(
            state: state,
            permissions: permissions,
            hotKey: hotKey,
            service: service,
            settingsAction: { [weak self] in self?.openSettings() })
        configureStatusItem()
        configurePopover()
        stateObservation = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
                self?.fitPopover()
            }
        }
        service.startPolling()
        updateStatusItem()

        #if DEBUG
        if ProcessInfo.processInfo.environment["TRANSCRIBE_FIXTURE"] == nil {
            modelInstaller.start()
        }
        configureFixtureIfNeeded()
        #else
        modelInstaller.start()
        presentInitialSetupIfNeeded()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.stopPolling()
        loadingTimer?.invalidate()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Chinwag"
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 300, height: 190)
        popover.contentViewController = NSHostingController(
            rootView: TranscriptionPopoverView(
                state: state,
                hotKey: hotKey,
                openSettings: { [weak self] in self?.openSettings() },
                quit: { NSApp.terminate(nil) }))
        self.popover = popover
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let systemSymbol: String?
        switch state.activity {
        case .recording:
            systemSymbol = "record.circle.fill"
        case .transcribing:
            systemSymbol = "waveform"
        case .idle:
            if case .failed = state.modelInstall {
                systemSymbol = "exclamationmark.triangle"
            } else {
                switch state.engineState {
                case "transcribing": systemSymbol = "waveform"
                case "error": systemSymbol = "exclamationmark.triangle"
                default: systemSymbol = nil
                }
            }
        }

        let image: NSImage?
        if let systemSymbol {
            image = NSImage(
                systemSymbolName: systemSymbol,
                accessibilityDescription: "Chinwag: \(state.statusTitle)")
        } else {
            image = NSImage(named: NSImage.Name("ChinwagMenuTemplate"))
        }
        image?.isTemplate = true
        image?.size = NSSize(width: 16, height: 16)
        button.image = image
        button.contentTintColor = state.activity == .recording ? .systemRed : nil
        button.toolTip = "Chinwag — \(state.statusTitle)"
        button.setAccessibilityLabel("Chinwag: \(state.statusTitle)")

        let modelIsLoading: Bool
        switch state.modelInstall {
        case .checking, .downloading: modelIsLoading = true
        case .failed, .ready: modelIsLoading = false
        }
        let shouldBreathe = (modelIsLoading || state.engineState == "loading")
            && state.activity == .idle
        if shouldBreathe, loadingTimer == nil {
            loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) {
                [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.loadingDimmed.toggle()
                    self.statusItem.button?.alphaValue = self.loadingDimmed ? 0.48 : 1
                }
            }
        } else if !shouldBreathe {
            loadingTimer?.invalidate()
            loadingTimer = nil
            button.alphaValue = 1
        }
    }

    private func fitPopover() {
        guard let view = popover?.contentViewController?.view else { return }
        let height = max(160, view.fittingSize.height)
        popover.contentSize = NSSize(width: 300, height: height)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            fitPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openSettings() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: TranscriptionSettingsView(
                    state: state,
                    permissions: permissions,
                    hotKey: hotKey,
                    retryModelDownload: { [weak self] in self?.modelInstaller.retry() }))
            let window = NSWindow(contentViewController: controller)
            window.title = "Chinwag"
            window.styleMask = [.closable, .miniaturizable, .titled]
            window.setContentSize(NSSize(width: 500, height: 420))
            window.minSize = NSSize(width: 500, height: 420)
            window.maxSize = NSSize(width: 500, height: 420)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        permissions.refresh()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func presentInitialSetupIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "initialSetupPresented") else { return }
        defaults.set(true, forKey: "initialSetupPresented")
        if permissions.microphone != .granted || permissions.accessibility != .granted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openSettings()
            }
        }
    }

    #if DEBUG
    private func configureFixtureIfNeeded() {
        guard ProcessInfo.processInfo.environment["TRANSCRIBE_FIXTURE"] != nil else {
            presentInitialSetupIfNeeded()
            return
        }
        state.applyFixture()
        let presentation = ProcessInfo.processInfo.environment["TRANSCRIBE_SHOW"] ?? "popover"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if presentation == "popover" {
                self.togglePopover()
                self.popover.contentViewController?.view.window?.sharingType = .readOnly
            } else if presentation == "settings" {
                self.openSettings()
                self.settingsWindow?.sharingType = .readOnly
            } else if presentation == "hud" {
                self.dictation.showHUDFixture()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.writeCaptureMetadata()
                self.captureFixtureViews(presentation: presentation)
            }
        }
    }

    private func writeCaptureMetadata() {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIBE_CAPTURE_INFO"] else {
            return
        }
        var values: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier]
        if let window = statusItem.button?.window { values["statusWindow"] = window.windowNumber }
        if let window = popover.contentViewController?.view.window { values["popoverWindow"] = window.windowNumber }
        if let window = settingsWindow { values["settingsWindow"] = window.windowNumber }
        values["hudWindow"] = dictation.fixtureHUDWindowNumber
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private func captureFixtureViews(presentation: String) {
        guard let directory = ProcessInfo.processInfo.environment["TRANSCRIBE_CAPTURE_DIR"] else {
            return
        }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: directory),
            withIntermediateDirectories: true)
        if let button = statusItem.button {
            capture(
                button,
                to: URL(fileURLWithPath: directory).appending(path: "menu-icon.png"),
                scale: 4)
        }
        if presentation == "popover", let view = popover.contentViewController?.view {
            capture(view, to: URL(fileURLWithPath: directory).appending(path: "popover.png"))
        }
        if presentation == "settings", let window = settingsWindow,
           let view = window.contentView?.superview ?? window.contentView
        {
            capture(view, to: URL(fileURLWithPath: directory).appending(path: "settings.png"))
        }
        if presentation == "hud", let view = dictation.fixtureHUDContentView {
            capture(view, to: URL(fileURLWithPath: directory).appending(path: "hud.png"), scale: 2)
        }
    }

    private func capture(_ view: NSView, to url: URL, scale: CGFloat? = nil) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let representation: NSBitmapImageRep?
        if let scale {
            representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width * scale),
                pixelsHigh: Int(view.bounds.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0)
            representation?.size = view.bounds.size
        } else {
            representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        }
        guard let representation else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }
    #endif
}
