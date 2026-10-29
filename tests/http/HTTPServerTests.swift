import Foundation
import Darwin

struct TranscriptionInput { let contents: Data; let filename: String; let mimeType: String; let language: String }
struct TranscriptionResult { let text: String; let audioSeconds: Double }
struct TranscriptionFailure: LocalizedError { let status: Int; let message: String; var errorDescription: String? { message } }
final class TranscriptionCancellation { func cancel() {} }
final class TranscriptionEngine {
    private let lock = NSLock()
    private var calls = 0
    func health() -> [String: Any] { lock.withLock { ["state": "ready", "model": "test", "calls": calls] } }
    func transcribe(_ input: TranscriptionInput, cancellation: TranscriptionCancellation,
                    completion: @escaping (Result<TranscriptionResult, Error>) -> Void) {
        lock.withLock { calls += 1 }
        #if HTTP_PBT
        let echo = try! JSONSerialization.data(withJSONObject: [
            "bytes": input.contents.base64EncodedString(), "filename": input.filename,
            "mimeType": input.mimeType, "language": input.language,
        ])
        completion(.success(.init(text: String(decoding: echo, as: UTF8.self), audioSeconds: 1.23456)))
        #else
        completion(.success(.init(text: "hello", audioSeconds: 1.23456)))
        #endif
    }
}
final class LiveSession {
    func feed(_ samples: [Float], partial: ((String) -> Void)? = nil) { partial?("\(samples.count) samples") }
    func finish(_ completion: @escaping (Result<String, Error>) -> Void) { completion(.success("done")) }
    func cancel() {}
}
extension TranscriptionEngine {
    func liveModels() -> [[String: Any]] { [["id": "test", "state": "ready", "default": true]] }
    func beginLive(model: String?) throws -> LiveSession { LiveSession() }
}
extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

#if !HTTP_FUZZ
@main enum HTTPServerTests {
    static let port: UInt16 = 33212
    static func request(_ raw: Data) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0,0,0,0,0,0,0,0))
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        raw.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        Darwin.shutdown(fd, SHUT_WR)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true { let n = recv(fd, &bytes, bytes.count, 0); if n <= 0 { break }; result.append(contentsOf: bytes[0..<n]) }
        close(fd); return String(data: result, encoding: .utf8)!
    }
    static func fragmentedRequest(_ raw: Data) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0,0,0,0,0,0,0,0))
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        for byte in raw { var byte = byte; _ = Darwin.send(fd, &byte, 1, 0) }
        Darwin.shutdown(fd, SHUT_WR)
        var result = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true { let n = recv(fd, &bytes, bytes.count, 0); if n <= 0 { break }; result.append(contentsOf: bytes[0..<n]) }
        close(fd); return String(data: result, encoding: .utf8)!
    }
    static func multipart(format: String = "json") -> Data {
        Data(("--b\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nignored\r\n" +
              "--b\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\n\(format)\r\n" +
              "--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: application/octet-stream\r\n\r\nx\r\n--b--\r\n").utf8)
    }
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
    static func main() throws {
        let server = TranscriptionHTTPServer(engine: TranscriptionEngine(), port: port)
        try server.start(); defer { server.stop() }
        check(request(Data("GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)).contains("200 OK"), "health")
        check(request(Data("GET /healthz HTTP/1.1\r\nHost: x\r\nOrigin: null\r\n\r\n".utf8)).contains("403 Forbidden"), "browser rejection")
        let body = multipart(format: "verbose_json")
        let normal = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let response = request(normal)
        check(response.contains("200 OK") && response.contains("\"duration\":1.235") && response.contains("\"text\":\"hello\""), "multipart verbose_json")
        let signedLength = Data(String(decoding: normal, as: UTF8.self).replacingOccurrences(of: "Content-Length: ", with: "Content-Length: +").utf8)
        check(request(signedLength).contains("400 Bad Request"), "signed content length rejected")
        for invalidBody in [
            String(decoding: body, as: UTF8.self).replacingOccurrences(of: "--b--\r\n", with: "--b--garbage\r\n"),
            String(decoding: body, as: UTF8.self).replacingOccurrences(of: "Content-Disposition:", with: "Content-Disposition: form-data; name=\"evil\"\r\nContent-Disposition:"),
        ] {
            let invalid = Data(invalidBody.utf8)
            let payload = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: \(invalid.count)\r\n\r\n".utf8) + invalid
            check(request(payload).contains("400 Bad Request"), "ambiguous multipart rejected")
        }
        let chunk = String(format: "%X", body.count)
        let chunked = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Type: multipart/form-data; boundary=b\r\n\r\n\(chunk)\r\n".utf8) + body + Data("\r\n0\r\n\r\n".utf8)
        check(request(chunked).contains("200 OK"), "chunked upload")
        let ambiguous = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)
        check(request(ambiguous).contains("400 Bad Request"), "duplicate framing")
        let noType = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n".utf8)
        check(request(noType).contains("415 Unsupported Media Type"), "content type before empty body")
        let loneQuote = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=\"\r\nContent-Length: 0\r\n\r\n".utf8)
        check(request(loneQuote).contains("400 Bad Request"), "lone quoted parameter")
        for size in ["", ";x", "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"] {
            let malformed = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nTransfer-Encoding: chunked\r\n\r\n\(size)\r\n".utf8)
            check(request(malformed).contains("400 Bad Request"), "malformed chunk size \(size)")
        }
        check(fragmentedRequest(chunked).contains("200 OK"), "fragmented chunked upload")
        let quotedBody = Data("--a;b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n\r\nx\r\n--a;b--\r\n".utf8)
        let quoted = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=\"a;b\"\r\nContent-Length: \(quotedBody.count)\r\n\r\n".utf8) + quotedBody
        check(request(quoted).contains("200 OK"), "quoted parameter containing semicolon")
        let prefixBody = Data("--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n\r\nx\r\n--bNOT-A-BOUNDARY\r\ny\r\n--b--\r\n".utf8)
        let prefix = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: \(prefixBody.count)\r\n\r\n".utf8) + prefixBody
        check(request(prefix).contains("200 OK"), "boundary prefix in file")
        let expectHead = "POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: \(body.count)\r\nExpect: 100-continue\r\n\r\n"
        check(request(Data(expectHead.utf8) + body).contains("100 Continue\r\n\r\nHTTP/1.1 200 OK"), "100 continue")
        let unknownBody = Data("--b\r\nContent-Disposition: form-data; name=\"bad\"\r\n\r\nx\r\n--b--\r\n".utf8)
        let unknown = Data("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=b\r\nContent-Length: \(unknownBody.count)\r\n\r\n".utf8) + unknownBody
        check(request(unknown).contains("unknown multipart field: bad"), "unknown field")
        let active = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                  sin_port: port.bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0,0,0,0,0,0,0,0))
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = connect(active, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        let partial = Data("POST /v1/audio/transcriptions HTTP/1.1\r\n".utf8)
        partial.withUnsafeBytes { _ = Darwin.send(active, $0.baseAddress, $0.count, 0) }
        server.stop()
        try server.start()
        check(request(Data("GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)).contains("200 OK"), "restart after stop")
        var byte: UInt8 = 0
        check(recv(active, &byte, 1, 0) <= 0, "active connection stopped")
        close(active)
        print("HTTP server tests passed")
    }
}
#endif
