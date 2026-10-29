import Foundation

struct TranscriptionInput { let contents: Data; let filename: String; let mimeType: String; let language: String }
struct TranscriptionResult { let text: String; let audioSeconds: Double }
struct TranscriptionFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

final class TranscriptionCancellation {
    private let lock = NSLock()
    private let deadline: Date
    private var cancelled = false
    private var abort: (() -> Void)?
    private var observers: [UUID: () -> Void] = [:]
    private var timer: DispatchSourceTimer?

    init(timeout: TimeInterval = 600) {
        deadline = Date().addingTimeInterval(timeout)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + max(0, timeout))
        timer.setEventHandler { [weak self] in self?.cancel() }
        self.timer = timer
        timer.resume()
    }

    deinit { timer?.cancel() }

    func cancel() {
        let callbacks: [() -> Void] = lock.withLock {
            guard !cancelled else { return [] }
            cancelled = true
            timer?.cancel(); timer = nil
            // Synchronize native callback removal with execution before its flag is freed.
            abort?()
            return Array(observers.values)
        }
        callbacks.forEach { $0() }
    }
    func check() throws {
        let expired = lock.withLock { cancelled || Date() >= deadline }
        if expired { cancel(); throw TranscriptionFailure(status: 408, message: "transcription was cancelled") }
    }
    func installAbort(_ callback: (() -> Void)?) {
        lock.withLock { abort = callback; if cancelled { callback?() } }
    }
    func observe(_ callback: @escaping () -> Void) -> UUID {
        let token = UUID()
        let callNow = lock.withLock { observers[token] = callback; return cancelled }
        if callNow { callback() }
        return token
    }
    func removeObserver(_ token: UUID) { lock.withLock { _ = observers.removeValue(forKey: token) } }
}

struct ModelSpec {
    let id: String, displayName: String, filename: String, bytes: Int64, sha256: String, url: URL, language: String

    static let parakeet = ModelSpec(
        id: "parakeet-unified-en-0.6b", displayName: "Parakeet Unified 0.6B · Q8",
        filename: "parakeet-unified-en-0.6b-Q8_0.gguf", bytes: 731_357_568,
        sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795",
        url: URL(string: "https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf/resolve/843b1b175ace04f5a89d379c79e2518c0d065b25/parakeet-unified-en-0.6b-Q8_0.gguf?download=true")!,
        language: "en")
    static let cohere = ModelSpec(
        id: "cohere-transcribe-03-2026-Q4_K_M", displayName: "Cohere Transcribe 03-2026 · Q4",
        filename: "cohere-transcribe-03-2026-Q4_K_M.gguf", bytes: 1_558_162_944,
        sha256: "0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb",
        url: URL(string: "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/dfa4adebb64f3076b7b6b90b721275cc069cb421/cohere-transcribe-03-2026-Q4_K_M.gguf?download=true")!,
        language: "")
    static let settingKey = "transcriptionModel"

    /// Model for dictation and the batch API. Live streaming always uses Parakeet.
    static var selected: ModelSpec { UserDefaults.standard.string(forKey: settingKey) == cohere.id ? cohere : parakeet }
    static var required: [ModelSpec] { selected.id == parakeet.id ? [parakeet] : [parakeet, cohere] }
}

/// Drops spoken fillers and immediate word repeats while keeping the model's punctuation and casing.
enum TranscriptCleaner {
    static func clean(_ text: String) -> String {
        var kept: [String] = [], capitalizeNext = false
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let core = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            let trailing = String(token.reversed().prefix(while: \.isPunctuation).reversed())
            let sentenceStart = kept.last.map { ".?!".contains($0.last!) } ?? true
            if core.range(of: "^(u+m+|u+h+|e+r+|a+h+|h+m+)$", options: .regularExpression) != nil {
                if sentenceStart, token.first?.isUppercase == true { capitalizeNext = true }
                // A filler that ended a sentence hands its terminal mark to the previous word.
                if let end = trailing.last(where: { ".?!".contains($0) }), var last = kept.last, !".?!".contains(last.last!) {
                    if last.hasSuffix(",") { last.removeLast() }
                    kept[kept.count - 1] = last + String(end)
                }
                continue
            }
            if let last = kept.last, !(last.last?.isPunctuation ?? true), core.contains(where: \.isLetter),
               last.trimmingCharacters(in: .punctuationCharacters).lowercased() == core {
                kept[kept.count - 1] = last + trailing
                continue
            }
            kept.append(capitalizeNext ? token.prefix(1).uppercased() + token.dropFirst() : token)
            capitalizeNext = false
        }
        return kept.joined(separator: " ")
    }
}

final class TranscriptionEngine {
    private let lock = NSLock()
    /// transcribe.cpp allows one compute call per model at a time, so this serial queue orders every batch
    /// request and live stream step. Live sessions interleave here instead of waiting for each other to end.
    fileprivate let worker = DispatchQueue(label: "com.chinwag.transcription.inference", qos: .userInitiated)
    private let loader = DispatchQueue(label: "com.chinwag.transcription.loader", qos: .utility)
    private final class Request {
        let id = UUID(), input: TranscriptionInput, cancellation: TranscriptionCancellation, spec: ModelSpec
        let completion: (Result<TranscriptionResult, Error>) -> Void
        var observer: UUID?, running = false
        init(_ input: TranscriptionInput, _ cancellation: TranscriptionCancellation, _ spec: ModelSpec,
             _ completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
            self.input = input; self.cancellation = cancellation; self.spec = spec; self.completion = completion
        }
    }
    private var models: [String: NativeModel] = [:], states: [String: String] = [:], errors: [String: String] = [:]
    private var running = 0, queued = 0, stopped = false
    private var directory: URL?, libraryURL: URL?
    private var requests: [UUID: Request] = [:]
    private var last: [String: Any]?
    /// Open native streams, touched only on `worker`, so shutdown can free them before their model.
    fileprivate var streams: [ObjectIdentifier: NativeStream] = [:]

    init(model: NativeModel? = nil) {
        guard let model else { return }
        for spec in [ModelSpec.parakeet, .cohere] { models[spec.id] = model; states[spec.id] = "ready" }
    }

    func start(modelsDirectory: URL, libraryURL: URL) {
        lock.withLock { directory = modelsDirectory; self.libraryURL = libraryURL }
        ensureLoaded()
    }

    /// Loads Parakeet, plus Cohere while it is selected, as soon as each verified model file exists.
    func ensureLoaded() { ModelSpec.required.forEach(load) }

    private func load(_ spec: ModelSpec) {
        let paths: (URL, URL)? = lock.withLock {
            guard !stopped, states[spec.id] == nil, let directory = self.directory, let library = self.libraryURL else { return nil }
            states[spec.id] = "loading"
            return (directory.appending(path: spec.filename), library)
        }
        guard let paths else { return }
        let (modelURL, libraryURL) = paths
        loader.async { [weak self] in
            guard let self else { return }
            let marker = modelURL.appendingPathExtension("sha256")
            while !self.lock.withLock({ self.stopped }) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
                let regular = attributes?[.type] as? FileAttributeType == .typeRegular
                let size = (attributes?[.size] as? NSNumber)?.int64Value
                let hash = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                if regular, size == spec.bytes, hash == spec.sha256 { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard !self.lock.withLock({ self.stopped }) else { return }
            do {
                let loaded = try NativeModel(modelURL: modelURL, libraryURL: libraryURL)
                self.lock.withLock {
                    if self.stopped { loaded.close() } else { self.models[spec.id] = loaded; self.states[spec.id] = "ready"; self.errors[spec.id] = nil }
                }
            } catch {
                self.lock.withLock { self.states[spec.id] = "error"; self.errors[spec.id] = error.localizedDescription }
            }
        }
    }

    func health() -> [String: Any] { lock.withLock {
        let spec = ModelSpec.selected, model = models[spec.id]
        var state = states[spec.id] ?? "loading"
        if stopped { state = "error" } else if state == "ready" && running > 0 { state = "transcribing" }
        return ["backend": model?.backend ?? "Metal", "device": model?.device ?? "Apple GPU",
                "error": (stopped ? "transcription engine shut down" : errors[spec.id]) ?? NSNull(),
                "lastTranscription": last ?? NSNull(), "model": spec.id, "modelDisplayName": spec.displayName,
                "pid": ProcessInfo.processInfo.processIdentifier, "queuedRequests": queued, "state": state]
    } }

    func liveModels() -> [[String: Any]] { lock.withLock {
        [["id": ModelSpec.parakeet.id, "state": stopped ? "error" : states[ModelSpec.parakeet.id] ?? "loading", "default": true]]
    } }

    func transcribe(_ input: TranscriptionInput, cancellation: TranscriptionCancellation,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
        let request = Request(input, cancellation, ModelSpec.selected, completion)
        let failure: TranscriptionFailure? = lock.withLock {
            guard !stopped, models[request.spec.id] != nil else {
                return .init(status: 503, message: errors[request.spec.id] ?? "the transcription model is still loading")
            }
            guard queued < 32 else { return .init(status: 429, message: "the transcription service queue is full") }
            queued += 1; requests[request.id] = request
            return nil
        }
        if let failure { completion(.failure(failure)); return }
        let observer = cancellation.observe { [weak self, weak request] in
            guard let request else { return }
            self?.cancel(request)
        }
        let retained = lock.withLock { () -> Bool in
            guard requests[request.id] === request else { return false }
            request.observer = observer
            return true
        }
        if !retained { cancellation.removeObserver(observer) }
        worker.async { [weak self, weak request] in
            guard let self, let request else { return }
            let input = request.input, spec = request.spec
            let cancellation = request.cancellation
            let shouldRun = self.lock.withLock { () -> Bool in
                guard !self.stopped, self.requests[request.id] === request else { return false }
                request.running = true; self.queued -= 1; self.running += 1
                return true
            }
            guard shouldRun else { return }
            let started = Date()
            let result: Result<TranscriptionResult, Error>
            do {
                try cancellation.check()
                let wav = try AudioDecoder.decode(input, cancellation: cancellation)
                var parts: [String] = []
                let chunks = AudioDecoder.chunks(wav)
                guard let model = self.lock.withLock({ self.models[spec.id] }) else { throw TranscriptionFailure(status: 503, message: "transcription model unavailable") }
                let language = input.language.isEmpty ? spec.language : input.language
                for offset in stride(from: 0, to: chunks.count, by: AudioDecoder.batchSize) {
                    let end = min(chunks.count, offset + AudioDecoder.batchSize)
                    for text in try model.runBatch(Array(chunks[offset..<end]), language: language, cancellation: cancellation) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { parts.append(trimmed) }
                    }
                }
                let text = TranscriptCleaner.clean(parts.joined(separator: " "))
                guard !text.isEmpty else { throw TranscriptionFailure(status: 422, message: "no speech was detected") }
                let seconds = Double(wav.sampleCount) / Double(wav.sampleRate)
                let completed: [String: Any] = ["audioSeconds": (seconds * 10).rounded() / 10,
                    "completedAt": ISO8601DateFormatter().string(from: Date()),
                    "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)]
                self.lock.withLock { self.last = completed }
                result = .success(.init(text: text, audioSeconds: seconds))
            } catch { result = .failure(error) }
            self.finish(request, result)
        }
    }

    /// Starts a Parakeet stream session; its audio is queued with all other compute on the shared model.
    func beginLive(model requested: String? = nil) throws -> LiveSession {
        let id = requested ?? ModelSpec.parakeet.id
        let model: NativeModel = try lock.withLock {
            guard id == ModelSpec.parakeet.id else {
                throw TranscriptionFailure(status: 404, message: "unknown live model \(id); see /v1/live/models")
            }
            guard !stopped, let model = models[id] else {
                throw TranscriptionFailure(status: 503, message: errors[id] ?? "the live model is still loading")
            }
            return model
        }
        return LiveSession(engine: self, model: model)
    }

    private func cancel(_ request: Request) {
        var completion: ((Result<TranscriptionResult, Error>) -> Void)?
        var observer: UUID?
        lock.withLock {
            guard requests[request.id] === request, !request.running else { return }
            requests.removeValue(forKey: request.id); queued -= 1
            observer = request.observer
            completion = request.completion
        }
        observer.map { request.cancellation.removeObserver($0) }
        completion?(.failure(TranscriptionFailure(status: 408, message: "transcription was cancelled")))
    }

    private func finish(_ request: Request, _ result: Result<TranscriptionResult, Error>) {
        var completion: ((Result<TranscriptionResult, Error>) -> Void)?
        var observer: UUID?
        lock.withLock {
            guard requests.removeValue(forKey: request.id) != nil else { return }
            running -= 1
            observer = request.observer
            completion = request.completion
        }
        observer.map { request.cancellation.removeObserver($0) }
        completion?(result)
    }

    func shutdown() {
        let pending: [(Request, Bool, UUID?)] = lock.withLock {
            stopped = true
            let values = Array(requests.values)
            for request in values where !request.running {
                requests.removeValue(forKey: request.id); queued -= 1
            }
            return values.map { ($0, $0.running, $0.observer) }
        }
        pending.forEach { request, running, observer in
            request.cancellation.cancel()
            if !running {
                observer.map { request.cancellation.removeObserver($0) }
                request.completion(.failure(TranscriptionFailure(status: 503, message: "transcription engine shut down")))
            }
        }
        // Finish cancellation, free streams, and remove decoder temporary files before the app exits.
        worker.sync {
            streams.values.forEach { $0.close() }; streams = [:]
            lock.withLock { models.values.forEach { $0.close() }; models = [:] }
        }
    }
}

/// One live transcript. Calls may come from any thread; all native work runs in order on the engine's queue.
final class LiveSession {
    private let engine: TranscriptionEngine, model: NativeModel
    private var stream: NativeStream?, failure: Error?, fed = 0, done = false // Inference queue only.

    fileprivate init(engine: TranscriptionEngine, model: NativeModel) { self.engine = engine; self.model = model }

    /// Queues 16 kHz mono samples; `partial` receives the cleaned hypothesis on the inference queue.
    func feed(_ samples: [Float], partial: ((String) -> Void)? = nil) {
        guard !samples.isEmpty else { return }
        engine.worker.async { [self] in
            guard !done, failure == nil else { return }
            do {
                let text = try nativeStream().feed(samples)
                fed += samples.count
                partial?(TranscriptCleaner.clean(text))
            } catch { failure = error }
        }
    }

    /// Finalizes once after all queued audio; later calls fail.
    func finish(_ completion: @escaping (Result<String, Error>) -> Void) {
        engine.worker.async { [self] in
            guard !done else { return completion(.failure(TranscriptionFailure(status: 409, message: "the live session already ended"))) }
            let result = Result { () throws -> String in
                if let failure { throw failure }
                return fed == 0 ? "" : TranscriptCleaner.clean(try nativeStream().finalize())
            }
            close()
            completion(result)
        }
    }

    func cancel() { engine.worker.async { [self] in if !done { close() } } }

    private func nativeStream() throws -> NativeStream {
        if let stream { return stream }
        let created = try model.beginStream(language: ModelSpec.parakeet.language)
        engine.streams[ObjectIdentifier(created)] = created
        stream = created
        return created
    }

    private func close() {
        done = true
        if let stream { stream.close(); engine.streams[ObjectIdentifier(stream)] = nil }
    }
}
