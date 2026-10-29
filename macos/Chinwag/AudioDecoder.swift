import Foundation

struct PCM16Audio {
    let pcm: Data
    let sampleCount: Int
    let sampleRate: Int
}

enum AudioDecoder {
    static let batchSize = 6
    private static let maximumAudioSeconds = 30 * 60
    private static let maximumDecodedBytes = maximumAudioSeconds * 16_000 * 2 + 1024 * 1024
    private static let extensions = [
        "audio/aac": "aac", "audio/flac": "flac", "audio/mp4": "m4a",
        "audio/mpeg": "mp3", "audio/ogg": "ogg", "audio/opus": "opus",
        "audio/wav": "wav", "audio/webm": "webm", "audio/x-caf": "caf",
        "audio/x-flac": "flac", "audio/x-m4a": "m4a",
    ]

    static func decode(_ input: TranscriptionInput, cancellation: TranscriptionCancellation) throws -> PCM16Audio {
        guard !input.contents.isEmpty else { throw message("audio upload was empty") }
        let mime = input.mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard let ext = extensions[mime] else {
            throw message("\(input.filename) has an unsupported audio format")
        }
        let converter = "/usr/bin/afconvert"
        guard FileManager.default.isExecutableFile(atPath: converter) else {
            throw message("the macOS afconvert audio converter is unavailable at \"\(converter)\"")
        }
        try cancellation.check()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chinwag-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.\(ext)")
        let output = directory.appendingPathComponent("decoded.wav")
        try input.contents.write(to: source, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: converter)
        process.arguments = [source.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", output.path]
        // Do not retain decoder output or risk filling a pipe while waiting for exit.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        while exited.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
            do { try cancellation.check() } catch { process.terminate(); process.waitUntilExit(); throw error }
        }
        try cancellation.check()
        guard process.terminationStatus == 0 else {
            throw message("audio conversion failed: afconvert exited with status \(process.terminationStatus)")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        if (attributes[.size] as? NSNumber)?.intValue ?? 0 > maximumDecodedBytes {
            throw message("audio recording exceeds the 30 minute local transcription limit")
        }
        let wav = try parseWAV(Data(contentsOf: output))
        if wav.sampleCount > maximumAudioSeconds * wav.sampleRate {
            throw message("audio recording exceeds the 30 minute local transcription limit")
        }
        return wav
    }

    static func parseWAV(_ data: Data) throws -> PCM16Audio {
        guard data.count >= 12, String(decoding: data[0..<4], as: UTF8.self) == "RIFF" else {
            throw message("decoded audio was not a RIFF WAV file")
        }
        guard String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw message("decoded audio was not a WAVE file")
        }
        var format: Data?, pcm: Data?, offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(little32(data, offset + 4))
            let start = offset + 8, end = start + size
            guard end >= start, end <= data.count else { throw message("decoded WAV contained a truncated \(id) chunk") }
            if id == "fmt " { format = Data(data[start..<end]) }
            if id == "data" { pcm = Data(data[start..<end]) }
            offset = end + (size & 1)
        }
        guard let format, format.count >= 16 else { throw message("decoded WAV contained no valid fmt chunk") }
        guard let pcm else { throw message("decoded WAV contained no data chunk") }
        let type = little16(format, 0), channels = little16(format, 2)
        let rate = Int(little32(format, 4)), align = little16(format, 12), bits = little16(format, 14)
        let guid: [UInt8] = [1,0,0,0,0,0,16,0,128,0,0,170,0,56,155,113]
        let extensible = type == 0xfffe && format.count >= 40 && little16(format, 16) >= 22 &&
            little16(format, 18) == 16 && Array(format[24..<40]) == guid
        guard (type == 1 || extensible), channels == 1, rate == 16_000, align == 2, bits == 16 else {
            throw message("decoded WAV was not mono 16 kHz 16-bit PCM")
        }
        guard !pcm.isEmpty else { throw message("decoded WAV contained no audio samples") }
        guard pcm.count % 2 == 0 else { throw message("decoded WAV ended with a partial sample") }
        return PCM16Audio(pcm: pcm, sampleCount: pcm.count / 2, sampleRate: rate)
    }

    static func chunks(_ wav: PCM16Audio) -> [[Float]] {
        let bounds = quietBoundaries(wav)
        return zip(bounds, bounds.dropFirst()).map { start, end in
            (start..<end).map { Float(Int16(bitPattern: little16(wav.pcm, $0 * 2))) / 32_768 }
        }
    }

    static func quietBoundaries(_ wav: PCM16Audio) -> [Int] {
        let duration = Double(wav.sampleCount) / Double(wav.sampleRate)
        let count = max(1, Int(duration / 30 + 0.5), (wav.sampleCount + 36 * wav.sampleRate - 1) / (36 * wav.sampleRate))
        if count == 1 { return [0, wav.sampleCount] }
        let frameSamples = max(1, wav.sampleRate / 100), frameCount = (wav.sampleCount + frameSamples - 1) / frameSamples
        var energy = Array(repeating: 0.0, count: frameCount + 1)
        for frame in 0..<frameCount {
            let start = frame * frameSamples, end = min(wav.sampleCount, start + frameSamples)
            var sum = 0.0
            for sample in start..<end { let a = Double(Int16(bitPattern: little16(wav.pcm, sample * 2))); sum += a * a }
            energy[frame + 1] = energy[frame] + sum / Double(end - start)
        }
        var bounds = [0], start = 0
        for remaining in stride(from: count, to: 1, by: -1) {
            let target = start + (wav.sampleCount - start + remaining / 2) / remaining
            let lower = max(start + 15 * wav.sampleRate, wav.sampleCount - (remaining - 1) * 36 * wav.sampleRate, target - 6 * wav.sampleRate)
            let upper = min(start + 36 * wav.sampleRate, wav.sampleCount - (remaining - 1) * 15 * wav.sampleRate, target + 6 * wav.sampleRate)
            var best = (lower + frameSamples - 1) / frameSamples, bestEnergy = Double.greatestFiniteMagnitude, bestDistance = Int.max
            for frame in ((lower + frameSamples - 1) / frameSamples)...(upper / frameSamples) {
                let a = max(0, frame - 5), b = min(frameCount, frame + 5)
                let candidate = (energy[b] - energy[a]) / Double(b - a), distance = abs(frame * frameSamples - target)
                if candidate < bestEnergy || (candidate == bestEnergy && distance < bestDistance) {
                    best = frame; bestEnergy = candidate; bestDistance = distance
                }
            }
            start = best * frameSamples; bounds.append(start)
        }
        bounds.append(wav.sampleCount); return bounds
    }

    private static func little16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    private static func little32(_ data: Data, _ at: Int) -> UInt32 { UInt32(little16(data, at)) | UInt32(little16(data, at + 2)) << 16 }
    private static func message(_ text: String) -> Error { NSError(domain: "Chinwag.AudioDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
