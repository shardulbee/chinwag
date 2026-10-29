import CryptoKit
import Darwin
import Foundation

/// The loopback HTTP adapter used by OpenAI-compatible transcription clients.
final class TranscriptionHTTPServer {
    private static let maximumHeaderBytes = 64 * 1024
    private static let maximumUploadBytes = 25 * 1024 * 1024
    private static let maximumRequestBytes = maximumUploadBytes + 1_000_000
    private static let requestTimeout: TimeInterval = 30
    private static let liveIdleTimeout: TimeInterval = 30
    private static let maximumLiveMessageBytes = 1024 * 1024
    private static let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, OPTIONS\r\nAccess-Control-Allow-Private-Network: true\r\n"

    private let engine: TranscriptionEngine
    private let port: UInt16
    private let acceptQueue = DispatchQueue(label: "com.chinwag.http.accept", qos: .utility)
    private let clients = DispatchQueue(label: "com.chinwag.http.clients", qos: .userInitiated,
                                        attributes: .concurrent)
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var generation: UInt64 = 0
    private var sockets = Set<Int32>()

    init(engine: TranscriptionEngine, port: UInt16 = 3212) {
        self.engine = engine
        self.port = port
    }

    /// Binds before returning. Accepting and all request work happen off the caller's queue.
    func start() throws {
        guard lock.withLock({ listener < 0 }) else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                                  sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian,
                                  sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                  sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno; Darwin.close(fd); throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let token = lock.withLock { () -> UInt64? in
            guard listener < 0 else { return nil }
            listener = fd
            generation &+= 1
            return generation
        }
        guard let token else { Darwin.close(fd); return }
        acceptQueue.async { [weak self] in self?.acceptLoop(fd, generation: token) }
    }

    func stop() {
        lock.withLock {
            if listener >= 0 {
                generation &+= 1
                Darwin.shutdown(listener, SHUT_RDWR); listener = -1
            }
            // Workers close their descriptors. Holding the lock prevents reuse during shutdown.
            for fd in sockets { Darwin.shutdown(fd, SHUT_RDWR) }
        }
        acceptQueue.sync {}
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32, generation token: UInt64) {
        defer { Darwin.close(fd) }
        while lock.withLock({ listener == fd && generation == token }) {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 100) > 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
            _ = fcntl(client, F_SETFL, 0)
            var timeout = timeval(tv_sec: 1, tv_usec: 0), one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
            let accepted = lock.withLock { () -> Bool in
                guard listener == fd, generation == token else { return false }
                sockets.insert(client)
                return true
            }
            guard accepted else { Darwin.shutdown(client, SHUT_RDWR); Darwin.close(client); return }
            clients.async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            let owned = lock.withLock { sockets.remove(fd) != nil }
            if owned { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        }
        do {
            var reader = SocketReader(fd: fd, deadline: .now() + Self.requestTimeout)
            let headerData = try reader.readThrough(Data("\r\n\r\n".utf8), limit: Self.maximumHeaderBytes)
            guard let headerText = String(data: headerData, encoding: .utf8) else { throw HTTPError(400, "malformed HTTP request") }
            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { throw HTTPError(400, "malformed HTTP request") }
            let words = requestLine.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 3, words[2] == "HTTP/1.1", !words[0].isEmpty, words[1].first == "/" else {
                throw HTTPError(400, "malformed HTTP request")
            }
            var headers: [String: [String]] = [:]
            for line in lines.dropFirst() where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                      !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw HTTPError(400, "malformed HTTP request") }
                let name = line[..<colon].lowercased()
                guard name.allSatisfy({ $0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0) }) else {
                    throw HTTPError(400, "malformed HTTP request")
                }
                headers[name, default: []].append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            let method = String(words[0]), target = words[1].split(separator: "?", maxSplits: 1)
            let path = String(target[0])
            // Live endpoints serve browser clients such as Choux; the batch API stays non-browser only.
            if !path.hasPrefix("/v1/live"), headers["origin"] != nil || headers["sec-fetch-site"] != nil {
                throw HTTPError(403, "browser requests are not allowed")
            }
            if method == "GET", path == "/healthz" { sendJSON(fd, 200, engine.health()); return }
            if method == "OPTIONS", path == "/v1/live/models" { send(fd, 204, "text/plain", Data(), csp: false, extra: Self.cors); return }
            if method == "GET", path == "/v1/live/models" {
                sendJSON(fd, 200, ["object": "list", "data": engine.liveModels()], extra: Self.cors); return
            }
            if method == "GET", path == "/v1/live" {
                let model = URLComponents(string: "/?" + (target.count > 1 ? target[1] : ""))?
                    .queryItems?.first(where: { $0.name == "model" })?.value
                try serveLive(fd, headers: headers, model: model, reader: &reader); return
            }
            guard method == "POST", path == "/v1/audio/transcriptions" else { throw HTTPError(404, "not found") }
            try validateMultipartContentType(headers["content-type"] ?? [])
            if headers["expect"]?.count == 1,
               headers["expect"]![0].lowercased().trimmingCharacters(in: .whitespaces) == "100-continue" {
                sendInterimContinue(fd)
            } else if headers["expect"] != nil {
                throw HTTPError(400, "unsupported Expect header")
            }
            let body = try readBody(&reader, headers: headers)
            let upload = try parseMultipart(body, contentTypes: headers["content-type"] ?? [])
            transcribe(upload, fd: fd)
        } catch let error as HTTPError { sendFailure(fd, error.status, error.message) }
        catch let error as POSIXError where error.code == .EAGAIN || error.code == .ETIMEDOUT {
            sendFailure(fd, 408, "request timed out")
        } catch { sendFailure(fd, 400, "malformed HTTP request") }
    }

    private func readBody(_ reader: inout SocketReader, headers: [String: [String]]) throws -> Data {
        let lengths = headers["content-length"] ?? [], encodings = headers["transfer-encoding"] ?? []
        guard !(lengths.isEmpty == false && encodings.isEmpty == false), lengths.count <= 1, encodings.count <= 1 else {
            throw HTTPError(400, "ambiguous HTTP request framing")
        }
        if let value = lengths.first {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(value) else { throw HTTPError(400, "invalid Content-Length") }
            guard count <= Self.maximumRequestBytes else { throw HTTPError(413, "request body is too large") }
            return try reader.read(count)
        }
        if let value = encodings.first {
            guard value.lowercased().trimmingCharacters(in: .whitespaces) == "chunked" else {
                throw HTTPError(400, "unsupported Transfer-Encoding")
            }
            var body = Data(), wireBytes = 0
            while true {
                let lineData = try reader.readLine(limit: 8192)
                guard lineData.count <= Self.maximumRequestBytes - wireBytes - 2 else { throw HTTPError(413, "request body is too large") }
                wireBytes += lineData.count + 2
                guard let line = String(data: lineData, encoding: .ascii) else { throw HTTPError(400, "invalid chunked request body") }
                let token = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard !token.isEmpty, token.allSatisfy({ $0.isHexDigit }), let count = Int(token, radix: 16) else {
                    throw HTTPError(400, "invalid chunked request body")
                }
                guard count <= Self.maximumRequestBytes - wireBytes - 2 else { throw HTTPError(413, "request body is too large") }
                if count == 0 {
                    while true {
                        let trailer = try reader.readLine(limit: Self.maximumHeaderBytes)
                        guard trailer.count <= Self.maximumRequestBytes - wireBytes - 2 else { throw HTTPError(413, "request body is too large") }
                        wireBytes += trailer.count + 2
                        if trailer.isEmpty { return body }
                    }
                }
                body.append(try reader.read(count)); wireBytes += count
                guard try reader.read(2) == Data("\r\n".utf8) else { throw HTTPError(400, "invalid chunked request body") }
                wireBytes += 2
            }
        }
        throw HTTPError(411, "request body length is required")
    }

    private func transcribe(_ upload: Upload, fd: Int32) {
        let cancellation = TranscriptionCancellation(), semaphore = DispatchSemaphore(value: 0)
        var result: Result<TranscriptionResult, Error>?
        engine.transcribe(.init(contents: upload.data, filename: upload.filename,
                                mimeType: upload.mimeType, language: upload.language), cancellation: cancellation) {
            result = $0; semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            var byte: UInt8 = 0
            let status = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if status == 0 { cancellation.cancel(); return }
            if status < 0 && errno != EAGAIN && errno != EWOULDBLOCK { cancellation.cancel(); return }
        }
        switch result! {
        case .success(let value):
            if upload.responseFormat == "text" { send(fd, 200, "text/plain; charset=utf-8", Data((value.text + "\n").utf8), csp: false) }
            else if upload.responseFormat == "verbose_json" {
                sendJSON(fd, 200, ["duration": (value.audioSeconds * 1000).rounded() / 1000,
                                   "language": upload.language, "text": value.text])
            } else { sendJSON(fd, 200, ["text": value.text]) }
        case .failure(let error):
            if let failure = error as? TranscriptionFailure { sendFailure(fd, failure.status, failure.message) }
            else { sendFailure(fd, 500, error.localizedDescription) }
        }
    }

    /// WebSocket `/v1/live`: binary 16 kHz mono PCM16 LE frames, then `{"type":"end"}`. Replies with
    /// `partial` messages, exactly one `final` (then close), or one `error`.
    private func serveLive(_ fd: Int32, headers: [String: [String]], model: String?, reader: inout SocketReader) throws {
        func header(_ name: String) -> String { (headers[name] ?? []).joined(separator: ",").lowercased() }
        guard header("upgrade").contains("websocket"), header("connection").contains("upgrade"),
              headers["sec-websocket-version"] == ["13"], let key = headers["sec-websocket-key"]?.first, !key.isEmpty
        else { throw HTTPError(426, "expected a WebSocket upgrade") }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        sendRaw(fd, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
        // One writer per connection keeps partials, the final, and control frames ordered off the inference queue.
        // `open` (output queue only) stops late partials from reaching a reused descriptor.
        let output = DispatchQueue(label: "com.chinwag.http.live")
        var open = true
        func write(_ opcode: UInt8, _ payload: Data) { output.async { if open { self.sendFrame(fd, opcode, payload) } } }
        func emit(_ object: [String: String]) {
            if let data = try? JSONSerialization.data(withJSONObject: object) { write(1, data) }
        }
        func closeLive(_ code: UInt16, error: String? = nil) {
            if let error { emit(["type": "error", "message": error]) }
            write(8, Data([UInt8(code >> 8), UInt8(code & 0xff)]))
            output.sync { open = false }
        }
        let session: LiveSession
        do { session = try engine.beginLive(model: model) } catch { closeLive(1008, error: error.localizedDescription); return }
        var ended = false, last = "", message = Data(), kind: UInt8 = 0
        defer { if !ended { session.cancel() }; output.sync { open = false } }
        do {
            while true {
                reader.deadline = .now() + Self.liveIdleTimeout
                let (fin, opcode, payload) = try readFrame(&reader)
                switch opcode {
                case 8: closeLive(1000); return
                case 9: write(10, payload); continue
                case 10: continue
                case 1 where kind == 0, 2 where kind == 0: kind = opcode; message = payload
                case 0 where kind != 0: message.append(payload)
                default: throw HTTPError(1002, "unexpected WebSocket frame")
                }
                guard message.count <= Self.maximumLiveMessageBytes else { throw HTTPError(1009, "WebSocket message is too large") }
                guard fin else { continue }
                defer { kind = 0; message = Data() }
                if kind == 2 {
                    guard !message.isEmpty, message.count % 2 == 0 else {
                        throw HTTPError(1003, "expected nonempty 16 kHz mono PCM16 little-endian frames")
                    }
                    let samples = message.withUnsafeBytes { raw in
                        (0..<raw.count / 2).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32_768 }
                    }
                    session.feed(samples) { text in // Inference queue, in order.
                        guard !text.isEmpty, text != last else { return }
                        last = text; emit(["type": "partial", "text": text])
                    }
                    continue
                }
                let control = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any]
                guard control?["type"] as? String == "end" else { throw HTTPError(1003, #"expected {"type":"end"}"#) }
                ended = true
                let done = DispatchSemaphore(value: 0)
                var result: Result<String, Error>!
                session.finish { result = $0; done.signal() }
                done.wait()
                switch result! {
                case .success(let text): emit(["type": "final", "text": text]); closeLive(1000)
                case .failure(let error): closeLive(1011, error: error.localizedDescription)
                }
                return
            }
        } catch let error as HTTPError {
            closeLive(UInt16(error.status), error: error.message)
        } catch let error as POSIXError where error.code == .EAGAIN || error.code == .ETIMEDOUT {
            closeLive(1008, error: "the live stream was idle for \(Int(Self.liveIdleTimeout)) seconds")
        } catch {} // The client disconnected.
    }

    private func readFrame(_ reader: inout SocketReader) throws -> (Bool, UInt8, Data) {
        let head = [UInt8](try reader.read(2))
        guard head[1] & 0x80 != 0 else { throw HTTPError(1002, "client WebSocket frames must be masked") }
        var length = UInt64(head[1] & 0x7f)
        if length == 126 { length = try reader.read(2).reduce(0) { $0 << 8 | UInt64($1) } }
        if length == 127 { length = try reader.read(8).reduce(0) { $0 << 8 | UInt64($1) } }
        guard length <= UInt64(Self.maximumLiveMessageBytes) else { throw HTTPError(1009, "WebSocket message is too large") }
        let mask = [UInt8](try reader.read(4))
        var payload = [UInt8](try reader.read(Int(length)))
        for index in payload.indices { payload[index] ^= mask[index & 3] }
        return (head[0] & 0x80 != 0, head[0] & 0x0f, Data(payload))
    }

    private func sendFrame(_ fd: Int32, _ opcode: UInt8, _ payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count <= 0xffff { frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]) }
        else { frame.append(127); frame.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) }) }
        frame.append(payload)
        sendRaw(fd, frame)
    }

    private struct Upload { let data: Data, filename: String, mimeType: String, language: String, responseFormat: String }
    private func validateMultipartContentType(_ contentTypes: [String]) throws {
        guard contentTypes.count == 1, contentTypes[0].lowercased().hasPrefix("multipart/form-data;") else {
            throw HTTPError(415, "request body must be multipart form data")
        }
    }
    private func parseMultipart(_ body: Data, contentTypes: [String]) throws -> Upload {
        try validateMultipartContentType(contentTypes)
        guard let boundary = parameter("boundary", in: contentTypes[0]), !boundary.isEmpty, boundary.count <= 70 else {
            throw HTTPError(400, "request body is not valid multipart form data")
        }
        let marker = Data(("--" + boundary).utf8), separator = Data("\r\n\r\n".utf8)
        guard body.starts(with: marker) else { throw HTTPError(400, "request body is not valid multipart form data") }
        var cursor = marker.count
        var file: (Data, String, String)?, fields: [String: [String]] = [:]
        let allowed: Set<String> = ["file", "language", "model", "prompt", "response_format", "temperature", "timestamp_granularities[]"]
        while true {
            if body[cursor...].starts(with: Data("--".utf8)) { break }
            guard body[cursor...].starts(with: Data("\r\n".utf8)) else { throw HTTPError(400, "request body is not valid multipart form data") }
            cursor += 2
            guard let headerRange = body.range(of: separator, in: cursor..<body.count), headerRange.lowerBound - cursor <= Self.maximumHeaderBytes,
                  let text = String(data: body[cursor..<headerRange.lowerBound], encoding: .utf8) else { throw HTTPError(400, "request body is not valid multipart form data") }
            var partHeaders: [String: String] = [:]
            for line in text.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPError(400, "request body is not valid multipart form data") }
                let key = String(line[..<colon]).lowercased()
                guard partHeaders[key] == nil else { throw HTTPError(400, "duplicate multipart header") }
                partHeaders[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            guard let disposition = partHeaders["content-disposition"], disposition.lowercased().hasPrefix("form-data;"),
                  let name = parameter("name", in: disposition), allowed.contains(name) else {
                let name = partHeaders["content-disposition"].flatMap { parameter("name", in: $0) } ?? ""
                throw HTTPError(400, "unknown multipart field: \(name)")
            }
            let contentStart = headerRange.upperBound
            let nextMarker = Data(("\r\n--" + boundary).utf8)
            var searchStart = contentStart
            var next: Range<Data.Index>?
            while let candidate = body.range(of: nextMarker, in: searchStart..<body.endIndex) {
                let suffix = candidate.upperBound
                let closing = body[suffix...].starts(with: Data("--".utf8)) &&
                    (suffix + 2 == body.endIndex || body[(suffix + 2)...].starts(with: Data("\r\n".utf8)))
                if body[suffix...].starts(with: Data("\r\n".utf8)) || closing {
                    next = candidate; break
                }
                searchStart = candidate.lowerBound + 1
            }
            guard let next else { throw HTTPError(400, "request body is not valid multipart form data") }
            let contents = Data(body[contentStart..<next.lowerBound]); cursor = next.lowerBound + 2 + marker.count
            let filename = parameter("filename", in: disposition)
            if name == "file" {
                guard file == nil, let filename, !filename.isEmpty else { throw HTTPError(400, "file must contain exactly one audio upload") }
                guard contents.count <= Self.maximumUploadBytes else { throw HTTPError(413, "audio upload is too large") }
                file = (contents, filename, partHeaders["content-type"] ?? "")
            } else {
                guard filename == nil else { throw HTTPError(400, "\(name) must appear at most once and contain text") }
                guard contents.count <= 64 * 1024 else { throw HTTPError(413, "multipart field is too large") }
                fields[name, default: []].append(String(data: contents, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }
        guard let file else { throw HTTPError(400, "file must contain exactly one audio upload") }
        guard !file.0.isEmpty else { throw HTTPError(400, "audio upload was empty") }
        func one(_ name: String) throws -> String {
            let values = fields[name] ?? []; guard values.count <= 1 else { throw HTTPError(400, "\(name) must appear at most once and contain text") }
            return values.first ?? ""
        }
        let format = try one("response_format").isEmpty ? "json" : one("response_format")
        guard ["json", "text", "verbose_json"].contains(format) else { throw HTTPError(400, "response_format must be json, text, or verbose_json") }
        let uploaded = file.2.split(separator: ";", maxSplits: 1).first.map { $0.lowercased().trimmingCharacters(in: .whitespaces) } ?? ""
        let supported: Set<String> = ["audio/aac", "audio/flac", "audio/mp4", "audio/mpeg", "audio/ogg", "audio/opus", "audio/wav", "audio/webm", "audio/x-caf", "audio/x-flac", "audio/x-m4a"]
        let extensions = ["aac":"audio/aac", "caf":"audio/x-caf", "flac":"audio/flac", "m4a":"audio/mp4", "mp3":"audio/mpeg", "mp4":"audio/mp4", "mpeg":"audio/mpeg", "mpga":"audio/mpeg", "oga":"audio/ogg", "ogg":"audio/ogg", "opus":"audio/opus", "wav":"audio/wav", "webm":"audio/webm"]
        let mime = supported.contains(uploaded) ? uploaded : extensions[(file.1 as NSString).pathExtension.lowercased()]
        guard let mime else { throw HTTPError(400, "\(file.1) has an unsupported audio format") }
        return Upload(data: file.0, filename: file.1, mimeType: mime, language: try one("language"), responseFormat: format)
    }

    private func parameter(_ name: String, in value: String) -> String? {
        var items: [Substring] = [], start = value.startIndex, quoted = false, escaped = false
        var index = start
        while index < value.endIndex {
            let character = value[index]
            if escaped { escaped = false }
            else if quoted && character == "\\" { escaped = true }
            else if character == "\"" { quoted.toggle() }
            else if character == ";" && !quoted { items.append(value[start..<index]); start = value.index(after: index) }
            index = value.index(after: index)
        }
        guard !quoted, !escaped else { return nil }
        items.append(value[start...])
        for item in items.dropFirst() {
            let pair = item.split(separator: "=", maxSplits: 1); guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                let raw = pair[1].trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("\"") || raw.hasSuffix("\"") {
                    guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return nil }
                    var decoded = "", escaping = false
                    for character in raw.dropFirst().dropLast() {
                        if escaping { decoded.append(character); escaping = false }
                        else if character == "\\" { escaping = true }
                        else if character == "\"" { return nil }
                        else { decoded.append(character) }
                    }
                    return escaping ? nil : decoded
                }
                return raw
            }
        }
        return nil
    }

    private struct HTTPError: Error { let status: Int; let message: String; init(_ status: Int, _ message: String) { self.status = status; self.message = message } }
    private func sendFailure(_ fd: Int32, _ status: Int, _ message: String) {
        sendJSON(fd, status, ["error": ["message": message, "type": status < 500 ? "invalid_request_error" : "server_error"]])
    }
    private func sendJSON(_ fd: Int32, _ status: Int, _ object: Any, extra: String = "") {
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"error\":{\"message\":\"response serialization failed\",\"type\":\"server_error\"}}".utf8)
        data.append(10); send(fd, status, "application/json; charset=utf-8", data, csp: true, extra: extra)
    }
    private func sendInterimContinue(_ fd: Int32) {
        let response = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)
        response.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }
    private func send(_ fd: Int32, _ status: Int, _ type: String, _ body: Data, csp: Bool, extra: String = "") {
        let reasons = [200:"OK", 204:"No Content", 400:"Bad Request", 403:"Forbidden", 404:"Not Found", 408:"Request Timeout", 411:"Length Required", 413:"Content Too Large", 415:"Unsupported Media Type", 426:"Upgrade Required", 429:"Too Many Requests", 500:"Internal Server Error", 503:"Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: private, no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        if csp { head += "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n" }
        var output = Data((head + extra + "\r\n").utf8); output.append(body)
        sendRaw(fd, output)
    }
    private func sendRaw(_ fd: Int32, _ output: Data) {
        output.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count { let n = Darwin.send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0); if n <= 0 { break }; offset += n }
        }
    }
}

private struct SocketReader {
    let fd: Int32; var deadline: DispatchTime; var buffer = Data()
    mutating func fill() throws {
        guard DispatchTime.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let count = recv(fd, &bytes, bytes.count, 0)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            guard DispatchTime.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
            return try fill()
        }
        guard count > 0 else { throw POSIXError(count == 0 ? .ECONNRESET : (.init(rawValue: errno) ?? .EIO)) }
        buffer.append(contentsOf: bytes[0..<count])
    }
    mutating func read(_ count: Int) throws -> Data {
        while buffer.count < count { try fill() }
        let result = Data(buffer.prefix(count)); buffer.removeFirst(count); return result
    }
    mutating func readThrough(_ marker: Data, limit: Int) throws -> Data {
        while buffer.range(of: marker) == nil { guard buffer.count < limit else { throw ServerReadError.tooLarge }; try fill() }
        guard let range = buffer.range(of: marker), buffer.distance(from: buffer.startIndex, to: range.upperBound) <= limit else { throw ServerReadError.tooLarge }
        let result = Data(buffer[..<range.lowerBound]); buffer.removeSubrange(..<range.upperBound); return result
    }
    mutating func readLine(limit: Int) throws -> Data { try readThrough(Data("\r\n".utf8), limit: limit) }
}
private enum ServerReadError: Error { case tooLarge }
