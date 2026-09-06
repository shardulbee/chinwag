import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func wait(_ semaphore: DispatchSemaphore, _ message: String, seconds: Double = 1) {
    expect(semaphore.wait(timeout: .now() + seconds) == .success, message)
}

@main
enum TranscriptionEngineTests {
    static func main() throws {
        let timed = TranscriptionCancellation(timeout: 0.03)
        let timerFired = DispatchSemaphore(value: 0)
        timed.installAbort { timerFired.signal() }
        wait(timerFired, "deadline forwards cancellation during native work")
        do { try timed.check(); expect(false, "expired cancellation throws") }
        catch { expect((error as? TranscriptionFailure)?.status == 408, "cancellation status is 408") }

        let model = NativeModel()
        let engine = TranscriptionEngine(model: model)
        let firstDone = DispatchSemaphore(value: 0)
        engine.transcribe(.init(contents: Data(), filename: "a", mimeType: "audio/wav", language: ""),
                          cancellation: TranscriptionCancellation()) { _ in firstDone.signal() }
        wait(model.entered, "first request enters native model")

        let queuedDone = DispatchSemaphore(value: 0)
        let queuedCancellation = TranscriptionCancellation()
        var queuedStatus = 0
        engine.transcribe(.init(contents: Data(), filename: "b", mimeType: "audio/wav", language: ""),
                          cancellation: queuedCancellation) { result in
            if case .failure(let error) = result { queuedStatus = (error as? TranscriptionFailure)?.status ?? 0 }
            queuedDone.signal()
        }
        queuedCancellation.cancel()
        wait(queuedDone, "queued cancellation completes without waiting for active work")
        expect(queuedStatus == 408, "queued cancellation status")
        expect((engine.health()["queuedRequests"] as? Int) == 0, "queued cancellation releases capacity")

        let shutdownDone = DispatchSemaphore(value: 0)
        var shutdownCompletions = 0
        engine.transcribe(.init(contents: Data(), filename: "c", mimeType: "audio/wav", language: ""),
                          cancellation: TranscriptionCancellation()) { _ in
            shutdownCompletions += 1; shutdownDone.signal()
        }
        engine.shutdown()
        wait(shutdownDone, "shutdown completes queued request immediately")
        model.release.signal()
        wait(firstDone, "active request completes after native cancellation")
        Thread.sleep(forTimeInterval: 0.05)
        expect(shutdownCompletions == 1, "shutdown completion happens exactly once")
        expect(model.calls == 1, "shutdown never starts queued decode")

        let readyModel = NativeModel()
        let readyEngine = TranscriptionEngine(model: readyModel)
        let readyDone = DispatchSemaphore(value: 0)
        let input = TranscriptionInput(contents: Data(), filename: "d", mimeType: "audio/wav", language: "")
        readyEngine.transcribe(input, cancellation: TranscriptionCancellation()) { result in
            if case .failure = result { expect(false, "successful inference") }
            expect(readyEngine.health()["state"] as? String == "ready", "state ready before callback")
            readyDone.signal()
        }
        wait(readyModel.entered, "active request holds compute slot")
        var waiting: [TranscriptionCancellation] = []
        let cancelled = DispatchSemaphore(value: 0)
        for _ in 0..<3 {
            let token = TranscriptionCancellation()
            waiting.append(token)
            readyEngine.transcribe(input, cancellation: token) { _ in cancelled.signal() }
        }
        let rejected = DispatchSemaphore(value: 0)
        readyEngine.transcribe(input, cancellation: TranscriptionCancellation()) { result in
            if case .failure(let error) = result {
                expect((error as? TranscriptionFailure)?.status == 429, "full queue returns 429")
            } else { expect(false, "fourth waiting request rejected") }
            rejected.signal()
        }
        wait(rejected, "queue limit rejects promptly")
        waiting.forEach { $0.cancel() }
        for _ in 0..<3 { wait(cancelled, "cancel queued request") }
        readyModel.release.signal()
        wait(readyDone, "successful completion")
        readyEngine.shutdown()
        print("TranscriptionEngineTests passed")
    }
}
