import AppKit
import ApplicationServices
import AVFoundation

@MainActor
enum PermissionState: Equatable {
    case denied
    case granted
    case notDetermined
    case restricted

    var title: String {
        switch self {
        case .denied: return "Not Allowed"
        case .granted: return "Granted"
        case .notDetermined: return "Not Requested"
        case .restricted: return "Restricted"
        }
    }

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "exclamationmark.circle.fill"
        case .notDetermined: return "circle.dashed"
        case .restricted: return "lock.circle.fill"
        }
    }
}

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphone: PermissionState = .notDetermined
    @Published private(set) var accessibility: PermissionState = .notDetermined

    private let fixture = ProcessInfo.processInfo.environment["TRANSCRIBE_FIXTURE"] != nil
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if fixture {
            microphone = .granted
            accessibility = .notDetermined
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .restricted
        }

        if AXIsProcessTrusted() {
            accessibility = .granted
        } else if UserDefaults.standard.bool(forKey: "accessibilityRequestAttempted") {
            accessibility = .denied
        } else {
            accessibility = .notDetermined
        }
    }

    func requestMicrophone() {
        guard microphone == .notDetermined else {
            if microphone == .denied { openMicrophoneSettings() }
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestAccessibility() {
        guard !fixture else { return }
        UserDefaults.standard.set(true, forKey: "accessibilityRequestAttempted")
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        refresh()
    }

    func openMicrophoneSettings() {
        openSystemSettings("Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSystemSettings("Privacy_Accessibility")
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
