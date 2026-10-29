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
        for _ in 0..<32 {
            let token = TranscriptionCancellation()
            waiting.append(token)
            readyEngine.transcribe(input, cancellation: token) { _ in cancelled.signal() }
        }
        let rejected = DispatchSemaphore(value: 0)
        readyEngine.transcribe(input, cancellation: TranscriptionCancellation()) { result in
            if case .failure(let error) = result {
                expect((error as? TranscriptionFailure)?.status == 429, "full queue returns 429")
            } else { expect(false, "request beyond the queue limit rejected") }
            rejected.signal()
        }
        wait(rejected, "queue limit rejects promptly")
        waiting.forEach { $0.cancel() }
        for _ in 0..<32 { wait(cancelled, "cancel queued request") }
        // Live sessions queue behind active batch work instead of being rejected, and stay independent.
        let liveDone = DispatchSemaphore(value: 0)
        var finals: [String] = [], partials: [String] = []
        for count in [3, 1] {
            let live = try readyEngine.beginLive()
            live.feed(Array(repeating: 0, count: count)) { partials.append($0) }
            live.finish { result in finals.append((try? result.get()) ?? "failed"); liveDone.signal() }
        }
        do { _ = try readyEngine.beginLive(model: "unknown"); expect(false, "unknown live model rejected") }
        catch { expect((error as? TranscriptionFailure)?.status == 404, "unknown live model is 404") }
        expect((readyEngine.liveModels().first?["default"] as? Bool) == true, "Parakeet is the default live model")
        readyModel.release.signal()
        wait(readyDone, "successful completion")
        wait(liveDone, "first live session finalizes"); wait(liveDone, "second live session finalizes")
        expect(partials == ["3", "1"], "partials are cleaned per session: \(partials)")
        expect(finals == ["I heard the 3 samples.", "I heard the 1 samples."], "finals are cleaned per session: \(finals)")

        for (raw, clean) in [
            ("Um, I I think the the plan is, uh, fine.", "I think the plan is, fine."),
            ("Okay, um, here it is, uh.", "Okay, here it is."),
            ("Uh, hmm, okay.", "Okay."),
            ("Hello there er friend", "Hello there friend"),
            ("Go. Go now, Parakeet, i.e. Q3.", "Go. Go now, Parakeet, i.e. Q3."),
        ] {
            expect(TranscriptCleaner.clean(raw) == clean, "clean \(raw) -> \(TranscriptCleaner.clean(raw))")
        }
        readyEngine.shutdown()
        print("TranscriptionEngineTests passed")
    }
}
