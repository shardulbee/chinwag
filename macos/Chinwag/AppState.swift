import Foundation

struct ServiceHealth: Decodable, Equatable {
    struct LastTranscription: Decodable, Equatable {
        let audioSeconds: Double
        let completedAt: String
        let elapsedMs: Int
    }

    let backend: String
    let device: String
    let error: String?
    let lastTranscription: LastTranscription?
    let model: String
    let modelDisplayName: String
    let queuedRequests: Int
    let state: String
}

enum DictationActivity: Equatable {
    case idle
    case recording
    case transcribing
}

enum ModelInstallState: Equatable {
    case checking
    case downloading(Double)
    case failed(String)
    case ready
}

@MainActor
final class AppState: ObservableObject {
    @Published var activity: DictationActivity = .idle
    @Published var audioLevel: Double = 0
    @Published var engineState = "loading"
    @Published var engineError: String?
    @Published var backend = "Metal"
    @Published var device = "Apple GPU"
    @Published var modelDisplayName = ModelSpec.selected.displayName
    @Published var lastTranscription: ServiceHealth.LastTranscription?
    @Published var modelInstall: ModelInstallState = .checking
    @Published var notice: String?
    @Published var noticeIsError = false

    var statusTitle: String {
        switch activity {
        case .recording:
            return "Recording…"
        case .transcribing:
            return "Transcribing…"
        case .idle:
            switch modelInstall {
            case .checking:
                return "Checking model…"
            case let .downloading(progress):
                return "Downloading model… \(Int(progress * 100))%"
            case .failed:
                return "Model download failed"
            case .ready:
                switch engineState {
                case "ready": return "Ready"
                case "transcribing": return "Transcribing…"
                case "error": return engineError ?? "Unavailable"
                default: return "Loading model…"
                }
            }
        }
    }

    var statusSymbol: String {
        switch activity {
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .idle:
            if case .failed = modelInstall { return "exclamationmark.triangle" }
            switch engineState {
            case "ready": return "mic"
            case "transcribing": return "waveform"
            case "error": return "mic.slash"
            default: return "waveform"
            }
        }
    }

    var isReady: Bool {
        // API work in progress does not block dictation; it queues on the shared model.
        modelInstall == .ready && ["ready", "transcribing"].contains(engineState) && activity == .idle
    }

    var modelDownloadError: String? {
        guard case let .failed(message) = modelInstall else { return nil }
        return message
    }

    var unavailableMessage: String {
        switch modelInstall {
        case .checking: return "Checking the transcription model"
        case .downloading: return "The transcription model is still downloading"
        case let .failed(message): return message
        case .ready: return engineError ?? "Transcription service unavailable"
        }
    }

    func apply(_ health: ServiceHealth) {
        if backend != health.backend { backend = health.backend }
        if device != health.device { device = health.device }
        if engineError != health.error { engineError = health.error }
        if engineState != health.state { engineState = health.state }
        if lastTranscription != health.lastTranscription {
            lastTranscription = health.lastTranscription
        }
        if modelDisplayName != health.modelDisplayName {
            modelDisplayName = health.modelDisplayName
        }
    }

    func applyFixture() {
        engineState = "ready"
        engineError = nil
        modelInstall = .ready
        backend = "Metal"
        device = "Apple M3 Max"
        modelDisplayName = ModelSpec.parakeet.displayName
        lastTranscription = .init(
            audioSeconds: 35.2,
            completedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-84)),
            elapsedMs: 1_112)
    }
}

@MainActor
final class ServiceClient {
    private let state: AppState
    private let engine: TranscriptionEngine
    private var pollingTask: Task<Void, Never>?

    init(state: AppState, engine: TranscriptionEngine) {
        self.state = state
        self.engine = engine
    }

    func startPolling() {
        guard ProcessInfo.processInfo.environment["TRANSCRIBE_FIXTURE"] == nil else {
            state.applyFixture()
            return
        }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
    }

    func refresh() async {
        do {
            state.apply(try await health())
        } catch {
            state.engineState = "error"
            state.engineError = "Transcription service unavailable"
        }
    }

    func beginLive() throws -> LiveSession { try engine.beginLive() }

    func finish(_ live: LiveSession) async throws -> String {
        let text = try await withCheckedThrowingContinuation { continuation in live.finish { continuation.resume(with: $0) } }
        guard !text.isEmpty else { throw TranscriptionFailure(status: 422, message: "No speech detected") }
        return text
    }

    func transcribe(wav: Data) async throws -> String {
        let engine = self.engine
        let cancellation = TranscriptionCancellation()
        let input = TranscriptionInput(contents: wav, filename: "dictation.wav", mimeType: "audio/wav", language: "")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                engine.transcribe(input, cancellation: cancellation) { result in
                    continuation.resume(with: result.map(\.text))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func health() async throws -> ServiceHealth {
        let data = try JSONSerialization.data(withJSONObject: engine.health())
        return try JSONDecoder().decode(ServiceHealth.self, from: data)
    }
}
