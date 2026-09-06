import Foundation

final class NativeModel {
    static let expectedVersion = "0.2.1"
    private var pointer: OpaquePointer?
    let backend = "Metal"
    private(set) var device = "Apple GPU"

    init(modelURL: URL, libraryURL: URL) throws {
        transcribe_log_set(nil, nil)
        let version = transcribe_version().map(String.init(cString:)) ?? ""
        guard version == Self.expectedVersion else {
            throw Self.error("native transcription library is version \(version), expected \(Self.expectedVersion)")
        }
        guard chinwag_native_abi_matches() else {
            throw Self.error("native transcription library ABI does not match the vendored header")
        }
        var status = libraryURL.path.withCString { transcribe_init_backends($0) }
        if status != TRANSCRIBE_OK { status = transcribe_init_backends_default() }
        guard status == TRANSCRIBE_OK else { throw Self.statusError("initialize native backends", status) }
        var parameters = transcribe_model_load_params()
        transcribe_model_load_params_init(&parameters)
        parameters.backend = TRANSCRIBE_BACKEND_METAL
        var loaded: OpaquePointer?
        status = modelURL.path.withCString { transcribe_model_load_file($0, &parameters, &loaded) }
        guard status == TRANSCRIBE_OK, let loaded else { throw Self.statusError("load transcription model", status) }
        pointer = loaded
        if let nativeDevice = transcribe_model_device(loaded) {
            var info = transcribe_device_info()
            transcribe_device_info_init(&info)
            if transcribe_device_get_info(nativeDevice, &info) == TRANSCRIBE_OK {
                if let value = info.description, !String(cString: value).isEmpty { device = String(cString: value) }
                else if let value = info.name, !String(cString: value).isEmpty { device = String(cString: value) }
            }
        }
    }

    deinit { close() }
    func close() { if let pointer { transcribe_model_free(pointer); self.pointer = nil } }

    func runBatch(_ chunks: [[Float]], language: String, cancellation: TranscriptionCancellation) throws -> [String] {
        guard let pointer else { throw Self.error("transcription model is not loaded") }
        guard !chunks.isEmpty else { throw Self.error("transcription batch was empty") }
        guard chunks.allSatisfy({ !$0.isEmpty }) else { throw Self.error("transcription chunk was empty") }
        try cancellation.check()
        guard let abort = chinwag_native_abort_new() else { throw Self.error("allocate transcription cancellation flag") }
        cancellation.installAbort { chinwag_native_abort_set(abort) }
        defer { cancellation.installAbort(nil); chinwag_native_abort_free(abort) }

        let buffers = chunks.map { chunk -> UnsafeMutablePointer<Float> in
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: chunk.count)
            buffer.initialize(from: chunk, count: chunk.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        var pointers = buffers.map { UnsafePointer($0) as UnsafePointer<Float>? }
        var lengths = chunks.map { Int32($0.count) }
        return try pointers.withUnsafeMutableBufferPointer { pointerBuffer in
            var texts: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            var resultCount: Int32 = 0
            let status: Int32 = language.withCString { languageValue in
                lengths.withUnsafeMutableBufferPointer { lengthBuffer in
                    chinwag_native_run_batch(pointer, pointerBuffer.baseAddress, lengthBuffer.baseAddress,
                                             Int32(chunks.count), language.isEmpty ? nil : languageValue,
                                             abort, &texts, &resultCount)
                }
            }
            defer { if let texts { chinwag_native_texts_free(texts, resultCount) } }
            try cancellation.check()
            guard status == Int32(TRANSCRIBE_OK.rawValue) else { throw Self.statusError("run transcription batch", status) }
            guard resultCount == chunks.count, let texts else {
                throw Self.error("native transcription returned \(resultCount) results for \(chunks.count) chunks")
            }
            return (0..<Int(resultCount)).map { index in
                texts[index].map { String(cString: $0) } ?? ""
            }
        }
    }

    private static func statusError(_ action: String, _ status: transcribe_status) -> Error {
        let detail = transcribe_status_string(Int32(status.rawValue)).map(String.init(cString:)) ?? "unknown error"
        return error("\(action): \(detail) (status \(status.rawValue))")
    }
    private static func statusError(_ action: String, _ status: Int32) -> Error {
        statusError(action, transcribe_status(rawValue: UInt32(status)))
    }
    private static func error(_ message: String) -> Error {
        NSError(domain: "Chinwag.NativeModel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
