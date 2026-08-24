import CryptoKit
import Foundation

@MainActor
final class ModelInstaller: ObservableObject {
    static let filename = "cohere-transcribe-03-2026-Q4_K_M.gguf"
    static let byteCount: Int64 = 1_558_162_944
    static let sha256 = "0ea56826d8bd5d74b7143a4a04e022dc1bb75452cfae49d98b6acb0c1d16a1fb"
    static let downloadURL = URL(
        string: "https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf/resolve/dfa4adebb64f3076b7b6b90b721275cc069cb421/\(filename)?download=true")!

    private let state: AppState
    private var installTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state
    }

    func start() {
        guard installTask == nil else { return }
        state.modelInstall = .checking
        installTask = Task { [weak self] in
            await self?.install()
            self?.installTask = nil
        }
    }

    func retry() {
        guard case .failed = state.modelInstall else { return }
        start()
    }

    private func install() async {
        let manager = FileManager.default
        let directory = manager.homeDirectoryForCurrentUser
            .appending(path: ".local/share/chinwag/models", directoryHint: .isDirectory)
        let model = directory.appending(path: Self.filename)
        let marker = model.appendingPathExtension("sha256")
        let download = directory.appending(path: ".\(Self.filename).download")

        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

            let attributes = try? manager.attributesOfItem(atPath: model.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value
            let isRegularFile = (attributes?[.type] as? FileAttributeType) == .typeRegular
            let savedHash = try? String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isRegularFile, size == Self.byteCount, savedHash == Self.sha256 {
                try secure(model: model, marker: marker)
                state.modelInstall = .ready
                return
            }

            if isRegularFile, size == Self.byteCount {
                let digest = try await Task.detached(priority: .utility) {
                    try Self.digest(of: model)
                }.value
                if digest == Self.sha256 {
                    try writeMarker(marker)
                    try secure(model: model, marker: marker)
                    state.modelInstall = .ready
                    return
                }
            }

            let downloadAttributes = try? manager.attributesOfItem(atPath: download.path)
            let downloadSize = (downloadAttributes?[.size] as? NSNumber)?.int64Value
            let downloadIsRegular = (downloadAttributes?[.type] as? FileAttributeType) == .typeRegular
            if downloadIsRegular, downloadSize == Self.byteCount {
                state.modelInstall = .downloading(1)
                let digest = try await Task.detached(priority: .utility) {
                    try Self.digest(of: download)
                }.value
                if digest == Self.sha256 {
                    try? manager.removeItem(at: model)
                    try? manager.removeItem(at: marker)
                    try manager.moveItem(at: download, to: model)
                    try writeMarker(marker)
                    try secure(model: model, marker: marker)
                    state.modelInstall = .ready
                    return
                }
            }

            try? manager.removeItem(at: model)
            try? manager.removeItem(at: marker)
            try? manager.removeItem(at: download)
            state.modelInstall = .downloading(0)

            let downloader = ModelDownload(destination: download) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .downloading = self.state.modelInstall else { return }
                    self.state.modelInstall = .downloading(progress)
                }
            }
            let downloaded = try await downloader.run(url: Self.downloadURL)
            let downloadedSize = try manager.attributesOfItem(atPath: downloaded.path)[.size]
                as? NSNumber
            guard downloadedSize?.int64Value == Self.byteCount else {
                throw ModelInstallError.invalidDownload
            }
            let digest = try await Task.detached(priority: .utility) {
                try Self.digest(of: downloaded)
            }.value
            guard digest == Self.sha256 else { throw ModelInstallError.invalidDownload }

            try manager.moveItem(at: downloaded, to: model)
            try writeMarker(marker)
            try secure(model: model, marker: marker)
            state.modelInstall = .ready
        } catch {
            try? manager.removeItem(at: download)
            state.modelInstall = .failed("Could not download the model. Check your connection and retry.")
        }
    }

    private func writeMarker(_ marker: URL) throws {
        try Self.sha256.write(to: marker, atomically: true, encoding: .utf8)
    }

    private func secure(model: URL, marker: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: model.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    nonisolated private static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private enum ModelInstallError: Error {
    case invalidDownload
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let progress: (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastProgress = -1.0
    private var session: URLSession?

    init(destination: URL, progress: @escaping (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(url: URL) async throws -> URL {
        defer {
            session?.finishTasksAndInvalidate()
            session = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64)
    {
        guard totalBytesExpectedToWrite > 0 else { return }
        let value = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        lock.lock()
        let shouldReport = value == 1 || value - lastProgress >= 0.01
        if shouldReport { lastProgress = value }
        lock.unlock()
        if shouldReport { progress(value) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL)
    {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode)
            else { throw URLError(.badServerResponse) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?)
    {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
