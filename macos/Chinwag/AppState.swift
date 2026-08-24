import Foundation

struct ServiceHealth: Decodable {
    struct LastTranscription: Decodable {
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
        backend = health.backend
        device = health.device
        engineError = health.error
        engineState = health.state
        lastTranscription = health.lastTranscription
        modelDisplayName = health.modelDisplayName
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
    private let baseURL: URL
    private var pollingTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
        self.baseURL = URL(string: "http://127.0.0.1:3212")!
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
        let currentHealth = try await health()
        guard currentHealth.model == "cohere-transcribe-03-2026-Q4_K_M" else {
            throw ServiceClientError.failed("Unexpected service on the transcription port")
        }
        guard currentHealth.state == "ready" || currentHealth.state == "transcribing" else {
            throw ServiceClientError.failed(currentHealth.error ?? "Transcription model unavailable")
        }

        let boundary = "TranscribeBoundary-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendMultipart("cohere-transcribe-03-2026-Q4_K_M\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendMultipart("json\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\n")
        body.appendMultipart("Content-Type: audio/mp4\r\n\r\n")
        body.append(try Data(contentsOf: fileURL))
        body.appendMultipart("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: baseURL.appending(path: "v1/audio/transcriptions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 125
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            if let envelope = try? JSONDecoder().decode(ServiceErrorEnvelope.self, from: data) {
                throw ServiceClientError.failed(envelope.error.message)
            }
            throw ServiceClientError.failed("Transcription failed (HTTP \(http.statusCode))")
        }
        let value = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw ServiceClientError.failed("No speech detected") }
        return text
    }

    private func health() async throws -> ServiceHealth {
        var request = URLRequest(url: baseURL.appending(path: "healthz"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ServiceHealth.self, from: data)
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct ServiceErrorEnvelope: Decodable {
    struct ServiceError: Decodable { let message: String }
    let error: ServiceError
}

private enum ServiceClientError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message): return message
        }
    }
}

private extension Data {
    mutating func appendMultipart(_ string: String) {
        append(string.data(using: .utf8)!)
    }
}
