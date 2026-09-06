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
    @Published var modelDisplayName = "Cohere Transcribe 03-2026 · Q4"
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
        modelInstall == .ready && engineState == "ready" && activity == .idle
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
        modelDisplayName = "Cohere Transcribe 03-2026 · Q4"
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

    func transcribe(fileURL: URL) async throws -> String {
        let engine = self.engine
        let cancellation = TranscriptionCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 25 * 1024 * 1024 else {
                    throw TranscriptionFailure(status: 413, message: "audio upload is too large")
                }
                let input = TranscriptionInput(contents: try Data(contentsOf: fileURL),
                                               filename: "dictation.m4a", mimeType: "audio/mp4", language: "")
                return try await withCheckedThrowingContinuation { continuation in
                    engine.transcribe(input, cancellation: cancellation) { result in
                        continuation.resume(with: result.map(\.text))
                    }
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func health() async throws -> ServiceHealth {
        let data = try JSONSerialization.data(withJSONObject: engine.health())
        return try JSONDecoder().decode(ServiceHealth.self, from: data)
    }
}
