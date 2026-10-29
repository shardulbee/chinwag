import AVFoundation
import Foundation

/// Captures the default microphone as 16 kHz mono float samples while dictation is held.
@MainActor
final class DictationRecorder {
    private let state: AppState
    private var engine: AVAudioEngine?
    private var startedAt: Date?

    init(state: AppState) {
        self.state = state
    }

    /// `onSamples` runs on the audio thread for every converted buffer.
    func start(onSamples: @escaping ([Float]) -> Void) throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        try Self.installTap(on: engine.inputNode, onSamples: onSamples) { [weak self] level in
            DispatchQueue.main.async { if self?.engine != nil { self?.state.audioLevel = level } }
        }
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw RecorderError.couldNotStart
        }
        self.engine = engine
        startedAt = Date()
    }

    /// Stops capture after the last buffer has been delivered and returns the recorded duration.
    @discardableResult
    func stop() -> TimeInterval {
        guard let engine else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        state.audioLevel = 0
        defer { startedAt = nil }
        return startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    func cleanup() { stop() }

    nonisolated private static func installTap(
        on input: AVAudioInputNode, onSamples: @escaping ([Float]) -> Void,
        level: @escaping (Double) -> Void) throws
    {
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target)
        else { throw RecorderError.couldNotStart }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / format.sampleRate) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            // `.noDataNow` keeps the resampler's state between buffers.
            converter.convert(to: output, error: nil) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData
                return buffer
            }
            guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            onSamples(samples)
            let power = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
            let decibels = 10 * log10(max(power, 1e-10))
            level(pow(max(0, min(1, (Double(decibels) + 55) / 55)), 1.7))
        }
    }
}

/// Accumulates samples from the audio thread for the batch fallback model.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ chunk: [Float]) { lock.withLock { samples += chunk } }

    /// 16 kHz mono PCM16 WAV of everything captured.
    func wav() -> Data {
        let pcm = lock.withLock { samples.map { Int16(max(-1, min(1, $0)) * 32_767).littleEndian } }
        var data = Data("RIFF".utf8)
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt32(36 + pcm.count * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16).littleEndian); append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(16_000).littleEndian); append(UInt32(32_000).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count * 2).littleEndian)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

private enum RecorderError: LocalizedError {
    case couldNotStart

    var errorDescription: String? { "The microphone could not start recording." }
}
