import Foundation

@main enum FuzzHost {
    static func main() throws {
        let servers = (33213...33220).map { TranscriptionHTTPServer(engine: TranscriptionEngine(), port: UInt16($0)) }
        for server in servers { try server.start() }
        print("ready")
        fflush(stdout)
        _ = readLine()
        for server in servers { server.stop() }
    }
}
