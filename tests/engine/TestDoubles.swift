import Foundation

final class NativeModel {
    let backend = "Metal", device = "Test GPU"
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private(set) var calls = 0

    init() {}
    convenience init(modelURL: URL, libraryURL: URL) throws { self.init() }

    func runBatch(_ chunks: [[Float]], language: String, cancellation: TranscriptionCancellation) throws -> [String] {
        lock.withLock { calls += 1 }
        entered.signal()
        while release.wait(timeout: .now() + 0.01) == .timedOut { try cancellation.check() }
        try cancellation.check()
        return ["test"]
    }
    func close() {}
    func beginStream(language: String) throws -> NativeStream { NativeStream() }
}

final class NativeStream {
    private var samples = 0
    func feed(_ chunk: [Float]) throws -> String { samples += chunk.count; return "um \(samples)" }
    func finalize() throws -> String { "Um, I I heard the the \(samples) samples." }
    func close() {}
}

#if ENGINE_TEST
enum AudioDecoder {
    static let batchSize = 6
    static func decode(_ input: TranscriptionInput, cancellation: TranscriptionCancellation) throws -> PCM16Audio {
        try cancellation.check()
        return PCM16Audio(pcm: Data([0, 0]), sampleCount: 1, sampleRate: 16_000)
    }
    static func chunks(_ wav: PCM16Audio) -> [[Float]] { [[0]] }
}

struct PCM16Audio { let pcm: Data; let sampleCount: Int; let sampleRate: Int }
#endif
