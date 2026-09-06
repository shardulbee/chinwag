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

    init(timeout: TimeInterval = 120) {
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

final class TranscriptionEngine {
    static let modelName = "cohere-transcribe-03-2026-Q4_K_M"
    static let modelDisplayName = "Cohere Transcribe 03-2026 · Q4"
    static let modelBytes: Int64 = 1_558_162_944
    static let modelSHA256 = "0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb"

    private let lock = NSLock(), worker = DispatchQueue(label: "com.chinwag.transcription.inference", qos: .userInitiated)
    private let loader = DispatchQueue(label: "com.chinwag.transcription.loader", qos: .utility)
    private final class Request {
        let id = UUID(), input: TranscriptionInput, cancellation: TranscriptionCancellation
        let completion: (Result<TranscriptionResult, Error>) -> Void
        var observer: UUID?, running = false
        init(_ input: TranscriptionInput, _ cancellation: TranscriptionCancellation,
             _ completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
            self.input = input; self.cancellation = cancellation; self.completion = completion
        }
    }
    private var model: NativeModel?, state = "loading", error: String?, queued = 0, stopped = false
    private var requests: [UUID: Request] = [:]
    private var last: [String: Any]?

    init(model: NativeModel? = nil) {
        self.model = model
        if model != nil { state = "ready" }
    }

    func start(modelURL: URL, libraryURL: URL) {
        loader.async { [weak self] in
            guard let self else { return }
            let marker = modelURL.appendingPathExtension("sha256")
            while !self.lock.withLock({ self.stopped }) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: modelURL.path)
                let regular = attributes?[.type] as? FileAttributeType == .typeRegular
                let size = (attributes?[.size] as? NSNumber)?.int64Value
                let hash = try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                if regular, size == Self.modelBytes, hash == Self.modelSHA256 { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard !self.lock.withLock({ self.stopped }) else { return }
            do {
                let loaded = try NativeModel(modelURL: modelURL, libraryURL: libraryURL)
                self.lock.withLock { if self.stopped { loaded.close() } else { self.model = loaded; self.state = "ready"; self.error = nil } }
            } catch {
                self.lock.withLock { self.state = "error"; self.error = error.localizedDescription }
            }
        }
    }

    func health() -> [String: Any] { lock.withLock {
        ["backend": model?.backend ?? "Metal", "device": model?.device ?? "Apple GPU",
         "error": error ?? NSNull(), "lastTranscription": last ?? NSNull(), "model": Self.modelName,
         "modelDisplayName": Self.modelDisplayName, "pid": ProcessInfo.processInfo.processIdentifier,
         "queuedRequests": queued, "state": state]
    } }

    func transcribe(_ input: TranscriptionInput, cancellation: TranscriptionCancellation,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
        let request = Request(input, cancellation, completion)
        let failure: TranscriptionFailure? = lock.withLock {
            guard !stopped, model != nil, state != "loading", state != "error" else {
                return .init(status: 503, message: error ?? "the transcription model is still loading")
            }
            guard queued < 3 else { return .init(status: 429, message: "the transcription service queue is full") }
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
            let input = request.input
            let cancellation = request.cancellation
            let shouldRun = self.lock.withLock { () -> Bool in
                guard !self.stopped, self.requests[request.id] === request else { return false }
                request.running = true; self.queued -= 1
                self.state = "transcribing"; self.error = nil
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
                guard let model = self.lock.withLock({ self.model }) else { throw TranscriptionFailure(status: 503, message: "transcription model unavailable") }
                for offset in stride(from: 0, to: chunks.count, by: AudioDecoder.batchSize) {
                    let end = min(chunks.count, offset + AudioDecoder.batchSize)
                    for text in try model.runBatch(Array(chunks[offset..<end]), language: input.language, cancellation: cancellation) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines); if !trimmed.isEmpty { parts.append(trimmed) }
                    }
                }
                let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw NSError(domain: "Chinwag", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cohere returned an empty transcription"]) }
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
            if state != "error" { state = stopped ? "error" : "ready" }
            observer = request.observer
            completion = request.completion
        }
        observer.map { request.cancellation.removeObserver($0) }
        completion?(result)
    }

    func shutdown() {
        let pending: [(Request, Bool, UUID?)] = lock.withLock {
            stopped = true; state = "error"; error = "transcription engine shut down"
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
        // Finish cancellation and remove decoder temporary files before the app exits.
        worker.sync { lock.withLock { model?.close(); model = nil } }
    }
}
