import AVFoundation
import Foundation

@MainActor
final class DictationRecorder {
    private let state: AppState
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var directoryURL: URL?

    init(state: AppState) {
        self.state = state
    }

    func start() throws {
        guard recorder == nil else { return }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "sharpi-dictation-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let output = root.appending(path: "dictation.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: output, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            try? FileManager.default.removeItem(at: root)
            throw RecorderError.couldNotStart
        }
        directoryURL = root
        self.recorder = recorder
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.updateMeter() }
        }
    }

    func stop() throws -> (fileURL: URL, duration: TimeInterval) {
        guard let recorder, let directoryURL else { throw RecorderError.notRecording }
        let duration = recorder.currentTime
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        self.recorder = nil
        state.audioLevel = 0
        let fileURL = directoryURL.appending(path: "dictation.m4a")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return (fileURL, duration)
    }

    func cleanup() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        state.audioLevel = 0
        if let directoryURL { try? FileManager.default.removeItem(at: directoryURL) }
        directoryURL = nil
    }

    private func updateMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (Double(decibels) + 55) / 55))
        state.audioLevel = pow(normalized, 1.7)
    }
}

private enum RecorderError: LocalizedError {
    case couldNotStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "The microphone could not start recording."
        case .notRecording: return "No dictation is being recorded."
        }
    }
}
