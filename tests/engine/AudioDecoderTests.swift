import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    let bytes = withUnsafeBytes(of: &little) { Array($0) }
    data.append(contentsOf: bytes)
}

@main
enum AudioDecoderTests {
    static func main() throws {
        var wav = Data("RIFF".utf8)
        append(UInt32(38), to: &wav)
        wav.append(Data("WAVEfmt ".utf8)); append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav); append(UInt16(1), to: &wav)
        append(UInt32(16_000), to: &wav); append(UInt32(32_000), to: &wav)
        append(UInt16(2), to: &wav); append(UInt16(16), to: &wav)
        wav.append(Data("data".utf8)); append(UInt32(2), to: &wav); append(UInt16(0), to: &wav)
        let parsed = try AudioDecoder.parseWAV(wav)
        expect(parsed.sampleCount == 1, "WAV sample count")
        expect(parsed.sampleRate == 16_000, "WAV sample rate")

        let audio = PCM16Audio(pcm: Data(repeating: 0, count: 32_000), sampleCount: 16_000, sampleRate: 16_000)
        expect(AudioDecoder.quietBoundaries(audio) == [0, 16_000], "short audio has one chunk")
        let long = PCM16Audio(pcm: Data(repeating: 0, count: 600 * 32_000), sampleCount: 600 * 16_000, sampleRate: 16_000)
        let bounds = AudioDecoder.quietBoundaries(long)
        expect(bounds.count == 21 && bounds.last == long.sampleCount, "ten minutes splits into twenty chunks")
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            expect((15 * 16_000...36 * 16_000).contains(end - start), "chunk duration bounds")
        }
        for invalid in [Data(), Data(wav.prefix(20)), Data(wav.dropLast())] {
            do { _ = try AudioDecoder.parseWAV(invalid); expect(false, "malformed WAV rejected") }
            catch {}
        }
        let normalized = AudioDecoder.chunks(PCM16Audio(pcm: Data([0, 128, 255, 127]), sampleCount: 2, sampleRate: 16_000))
        expect(normalized[0][0] == -1 && normalized[0][1] == Float(32767) / 32768, "PCM normalization")
        print("AudioDecoderTests passed")
    }
}
