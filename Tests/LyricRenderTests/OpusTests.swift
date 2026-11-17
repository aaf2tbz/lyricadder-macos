import Foundation
import Testing
@testable import LyricRender

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

// Fixtures/tone.opus: 1.000 s of a 440 Hz stereo sine at 48 kHz, made with `opusenc --bitrate 32` (libopus 1.5).
// Pre-skip is 312 and the last granule position is 48312, so a correct decode is exactly 48000 frames.

private func zeroCrossingHz(_ s: [Float], rate: Double) -> Double {
    var n = 0
    for i in 1..<s.count where (s[i - 1] < 0) != (s[i] < 0) { n += 1 }
    return Double(n) / 2 / (Double(s.count) / rate)
}

@Test func decodesOggOpus() throws {
    let a = try AudioDecoder.decode(url: fixtures.appendingPathComponent("tone.opus"))
    #expect(a.sampleRate == 48000)
    #expect(a.channels.count == 2)
    #expect(a.frameCount == 48000)
    let hz = zeroCrossingHz(Array(a.channels[0][4800..<43200]), rate: a.sampleRate)
    #expect(abs(hz - 440) < 2)
    // Pre-skip trimmed correctly: the tone starts at the first sample, not after a gap of silence.
    #expect(a.channels[0][100..<400].contains { abs($0) > 0.05 })
}

@Test func opusSavedAsOggIsDetected() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let ogg = dir.appendingPathComponent("song.ogg")
    try FileManager.default.copyItem(at: fixtures.appendingPathComponent("tone.opus"), to: ogg)
    #expect(try AudioDecoder.decode(url: ogg).frameCount == 48000)
}

@Test func songFolderFindsOpusStems() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for name in ["song.opus", "vocals.opus", "guitar.opus", "crowd.opus", "preview.opus"] {
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("tone.opus"), to: dir.appendingPathComponent(name))
    }
    let files = AudioDecoder.songFiles(in: dir).map(\.lastPathComponent)
    #expect(files == ["guitar.opus", "song.opus", "vocals.opus"])
    let mix = try AudioDecoder.mix(urls: AudioDecoder.songFiles(in: dir))
    #expect(mix.used.count == 3)
    #expect(mix.skipped.isEmpty)
    #expect(mix.audio.frameCount == 48000)
}
