import Foundation

// Real model/API host on a test port; stdin EOF stops only this test process.
@main
enum EngineHost {
    static func main() throws {
        let engine = TranscriptionEngine()
        let server = TranscriptionHTTPServer(engine: engine, port: 3213)
        try server.start()
        engine.start(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]),
                     libraryURL: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = readLine()
        server.stop()
        engine.shutdown()
    }
}
