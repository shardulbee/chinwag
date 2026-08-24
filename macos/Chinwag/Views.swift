import AppKit
import SwiftUI

struct LevelMeter: View {
    let level: Double
    var compact = false

    private var segments: Int { compact ? 10 : 14 }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 2 : 3) {
            ForEach(0..<segments, id: \.self) { index in
                Capsule()
                    .fill(index < max(1, Int(level * Double(segments))) ? Color.accentColor : .secondary.opacity(0.18))
                    .frame(width: compact ? 5 : 7, height: compact ? meterHeight(index) : 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private func meterHeight(_ index: Int) -> CGFloat {
        let pattern: [CGFloat] = [8, 12, 16, 21, 16, 12, 18, 22, 14, 9]
        return pattern[index % pattern.count]
    }
}

struct TranscriptionPopoverView: View {
    @ObservedObject var state: AppState
    @ObservedObject var hotKey: GlobalHotKey
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                statusImage
                    .renderingMode(.template)
                    .foregroundStyle(statusColor)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("\(state.modelDisplayName) · \(state.backend)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if state.activity == .recording {
                    Circle().fill(.red).frame(width: 7, height: 7).padding(.top, 5)
                }
            }
            .padding(.bottom, 13)

            Divider()

            Group {
                if state.activity == .recording {
                    HStack {
                        LevelMeter(level: state.audioLevel)
                        Spacer()
                        Text("Release \(hotKey.shortcut.displayName)")
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 42)
                } else if state.activity == .transcribing || state.engineState == "transcribing" {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Turning speech into text…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 42)
                } else {
                    HStack(spacing: 5) {
                        Text("Hold")
                        Text(hotKey.shortcut.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(.secondary.opacity(0.12)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(.secondary.opacity(0.2), lineWidth: 0.5))
                        Text("to dictate")
                        Spacer()
                        Text("Push to talk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 42)
                }
            }
            .font(.system(size: 12))

            if let last = state.lastTranscription {
                HStack {
                    Text("Last transcription")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(lastRun(last))
                        .monospacedDigit()
                }
                .font(.system(size: 11))
                .padding(.bottom, 12)
            }

            if let notice = state.notice {
                Label(notice, systemImage: state.noticeIsError ? "exclamationmark.triangle.fill" : "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(state.noticeIsError ? Color.orange : Color.secondary)
                    .lineLimit(2)
                    .padding(.bottom, 12)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Settings…", action: openSettings)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                Spacer()
                Button("Quit", action: quit)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }
            .font(.system(size: 12))
            .padding(.vertical, 12)
            .padding(.bottom, -4)
        }
        .padding(16)
        .frame(width: 300)
        .background(.regularMaterial)
    }

    private var statusImage: Image {
        if state.activity == .recording {
            return Image(systemName: "record.circle.fill")
        }
        if state.activity == .transcribing || state.engineState == "transcribing" {
            return Image(systemName: "waveform")
        }
        if state.engineState == "error" {
            return Image(systemName: "exclamationmark.triangle")
        }
        return Image(nsImage: NSImage(named: NSImage.Name("ChinwagMenuTemplate")) ?? NSImage())
    }

    private var statusColor: Color {
        if state.activity == .recording { return .red }
        if state.engineState == "error" { return .orange }
        return .primary
    }

    private func lastRun(_ last: ServiceHealth.LastTranscription) -> String {
        let duration = last.audioSeconds >= 10
            ? String(format: "%.0fs", last.audioSeconds)
            : String(format: "%.1fs", last.audioSeconds)
        let elapsed = last.elapsedMs >= 1_000
            ? String(format: "%.1fs", Double(last.elapsedMs) / 1_000)
            : "\(last.elapsedMs)ms"
        return "\(duration) audio → \(elapsed)"
    }
}

struct TranscriptionSettingsView: View {
    @ObservedObject var permissions: PermissionManager
    @ObservedObject var hotKey: GlobalHotKey

    var body: some View {
        Form {
            Section("Dictation") {
                HStack(alignment: .center) {
                    SettingsLabel(
                        title: "Global Hotkey",
                        caption: "Hold to record, then release to transcribe and paste.")
                    Spacer(minLength: 24)
                    ShortcutRecorder(hotKey: hotKey)
                }
                .padding(.vertical, 2)
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    caption: "Required to capture audio for dictation.",
                    state: permissions.microphone,
                    request: permissions.requestMicrophone,
                    openSettings: permissions.openMicrophoneSettings)
                PermissionRow(
                    title: "Accessibility",
                    caption: "Required to paste transcribed text into other apps.",
                    state: permissions.accessibility,
                    request: permissions.requestAccessibility,
                    openSettings: permissions.openAccessibilitySettings)
            }

            Section("Model") {
                HStack(alignment: .center) {
                    SettingsLabel(
                        title: "Transcription Model",
                        caption: "Model selection is unavailable in this version.")
                    Spacer(minLength: 18)
                    Picker("Transcription Model", selection: .constant("cohere")) {
                        Text("Cohere Transcribe 03-2026 · Q4").tag("cohere")
                    }
                    .labelsHidden()
                    .frame(width: 270)
                    .disabled(true)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 420)
    }
}

private struct SettingsLabel: View {
    let title: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let caption: String
    let state: PermissionState
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            SettingsLabel(title: title, caption: caption)
            Spacer(minLength: 18)
            HStack(spacing: 8) {
                if state == .notDetermined {
                    Button("Request Access…", action: request)
                } else if state == .denied {
                    Button("Open Settings…", action: openSettings)
                } else {
                    Image(systemName: state.symbol)
                        .foregroundStyle(statusColor)
                    Text(state.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 160, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        case .restricted: return .orange
        }
    }
}
