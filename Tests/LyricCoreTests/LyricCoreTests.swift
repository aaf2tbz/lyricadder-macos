import Foundation
import Testing
@testable import LyricCore

private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

// MARK: - Lyric input syntax (readLyricInput)

@Test func syllableSplittingMatchesOriginal() {
    #expect(LyricInput.syllables(inLine: "Hel-lo there my") == ["Hel-", "lo", "there", "my"])
    #expect(LyricInput.syllables(inLine: "friends al=ways") == ["friends", "al=", "ways"])
    #expect(LyricInput.syllables(inLine: "a - b = c") == ["a", "b", "c"])           // lone separators dropped
    #expect(LyricInput.syllables(inLine: "  spaced   out  ") == ["spaced", "out"])
    #expect(LyricInput.syllables(inLine: "tri-ple-word") == ["tri-", "ple-", "word"])
}

@Test func blankLinesAreSkippedButLineNumbersKept() {
    let lines = LyricInput.parse("one two\n\n   \nthree\r\nfour-five\n")
    #expect(lines.map(\.syllables) == [["one", "two"], ["three"], ["four-", "five"]])
    #expect(lines.map(\.textLine) == [0, 3, 4])
}

@Test func formatRoundTrips() {
    let phrases = [["Hel-", "lo", "there"], ["al=", "ways"], [""]]
    #expect(LyricInput.format(phrases: phrases) == "Hel-lo there\nal=ways")
    #expect(LyricInput.parse(LyricInput.format(phrases: phrases)).map(\.syllables) == [["Hel-", "lo", "there"], ["al=", "ways"]])
}

@Test func displayPiecesLikeThePreview() {
    #expect(LyricInput.displayPieces(["Hel-", "lo", "al=", "ways"]) == ["Hel", "lo ", "al-", "ways"])
}

// MARK: - .chart

@Test func chartPhrasesAndSameTickRules() throws {
    let c = try ChartDocument(url: fixtures.appendingPathComponent("test.chart"))
    #expect(c.hasBOM)
    #expect(c.lineEnding == "\r\n")
    #expect(c.displayName == "Test Song! by The Testers")
    #expect(c.phrases.map { $0.syllables.count } == [4, 3, 4, 2])
    // Lyric listed before its same-tick phrase_start belongs to that phrase.
    #expect(c.phrases[1].syllables.first?.tick == 960)
    // Phrase closed by the next phrase_start has no end tick.
    #expect(c.phrases[1].endTick == nil)
    #expect(c.difficultySections.map(\.name) == ["ExpertSingle", "ExpertDrums"])
}

@Test func chartApplyOnlyTouchesLyricLines() throws {
    let url = fixtures.appendingPathComponent("test.chart")
    let c = try ChartDocument(url: url)
    let lyrics = try String(contentsOf: fixtures.appendingPathComponent("test.lyrics.txt"), encoding: .utf8)
    let out = try c.applying(lyrics: LyricInput.parse(lyrics))
    let changed = zip(c.lines, out.lines).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
    #expect(Set(changed) == Set(c.slotLines.flatMap { $0 }))
    #expect(out.lines.count == c.lines.count)
    #expect(out.phrases.map { $0.syllables.map(\.text) }[1] == ["friends", "al=", "ways"])
    let reparsed = try ChartDocument(data: out.serialized, url: url)
    #expect(reparsed.hasBOM && reparsed.hasTrailingNewline && reparsed.lineEnding == "\r\n")
    #expect(reparsed.lyricsText == LyricInput.format(phrases: LyricInput.parse(lyrics).map(\.syllables)))
}

@Test func chartMismatchIsRejectedWithOriginalMessage() throws {
    let c = try ChartDocument(url: fixtures.appendingPathComponent("test.chart"))
    #expect(throws: LyricError.mismatch("Not the same amount of phrases (file: 4, input: 1)")) {
        _ = try c.applying(lyrics: LyricInput.parse("only one phrase"))
    }
}

@Test func lfChartWithoutBOMAndResolution480() throws {
    let text = """
    [Song]
    {
      Name = "LF"
      Resolution = 480
    }
    [SyncTrack]
    {
      0 = B 60000
    }
    [Events]
    {
      480 = E "phrase_start"
      480 = E "lyric "
      960 = E "lyric "
      1440 = E "phrase_end"
    }
    """
    let c = try ChartDocument(data: Data(text.utf8), url: URL(fileURLWithPath: "/x/lf.chart"))
    #expect(!c.hasBOM && c.lineEnding == "\n")
    #expect(c.phrases.count == 1)
    // 60 BPM, 480 ticks per beat: tick 960 is 2 s (the original's hard-coded 192 would say 5 s).
    #expect(abs(c.tempoMap.seconds(atTick: 960) - 2.0) < 1e-9)
    let out = try c.applying(lyrics: LyricInput.parse("a b"))
    #expect(String(data: out.serialized, encoding: .utf8)!.contains("  960 = E \"lyric b\""))
}

// MARK: - Tempo

@Test func tempoMapAcrossChanges() {
    let m = TempoMap(resolution: 192, changes: [.init(tick: 0, microsecondsPerQuarter: TempoMap.bpm(120)),
                                                .init(tick: 384, microsecondsPerQuarter: TempoMap.bpm(60))])
    #expect(abs(m.seconds(atTick: 384) - 1.0) < 1e-9)
    #expect(abs(m.seconds(atTick: 576) - 2.0) < 1e-9)
}

// MARK: - MIDI

@Test func vlqRoundTrip() throws {
    for v in [0, 1, 127, 128, 255, 16383, 16384, 0x0FFFFFFF] {
        let b = MidiDocument.vlq(v)
        var i = 0
        #expect(try MidiDocument.readVLQ(b, &i) == v)
        #expect(i == b.count)
    }
}

@Test func midiFixtureWithRunningStatus() throws {
    let m = try MidiDocument(url: fixtures.appendingPathComponent("Test Band - Midi Song/notes.mid"))
    #expect(m.displayName == "Midi Song by Test Band")   // from song.ini
    #expect(m.phrases.map { $0.syllables.map(\.text) } == [["Hel-", "lo", "world"], ["sec-", "ond", "line"]])
    #expect(m.slotRefs[0][2].markers == "#")
    #expect(m.tempoMap.changes.count == 2)
}

@Test func midiWritePreservesEverythingButLyrics() throws {
    let url = fixtures.appendingPathComponent("Test Band - Midi Song/notes.mid")
    let m = try MidiDocument(url: url)
    let out = try m.applying(lyrics: LyricInput.parse("Good-bye cruel\nwor-ld ends"))
    #expect(out.phrases.map { $0.syllables.map(\.text) } == [["Good-", "bye", "cruel"], ["wor-", "ld", "ends"]])
    #expect(out.slotRefs[0][2].rawText == "cruel#")
    let vt = m.trackChunkIndices[m.vocalTrack!]
    for i in m.chunks.indices where i != vt { #expect(m.chunks[i].data == out.chunks[i].data) }
    // Re-reading the serialized bytes gives the same document.
    let again = try MidiDocument(data: out.serialized, url: url)
    #expect(again.lyricsText == "Good-bye cruel\nwor-ld ends")
}

/// Builds a tiny SMF with a PART VOCALS track from raw event bytes.
private func smf(vocals: [UInt8]) -> Data {
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        Array(type.utf8) + [UInt8(body.count >> 24 & 0xFF), UInt8(body.count >> 16 & 0xFF), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
    }
    let name: [UInt8] = [0x00, 0xFF, 0x03, 11] + Array("PART VOCALS".utf8)
    return Data(chunk("MThd", [0, 1, 0, 1, 0x01, 0xE0]) + chunk("MTrk", name + vocals + [0x00, 0xFF, 0x2F, 0x00]))
}

private func lyric(_ delta: UInt8, _ s: String) -> [UInt8] { [delta, 0xFF, 0x05, UInt8(s.utf8.count)] + Array(s.utf8) }

@Test func noteOffEndsPhraseAndSlidesAreNotSyllables() throws {
    // 0x80 note-off ends the phrase (the original treated it as a new phrase start).
    let ev: [UInt8] = [0x00, 0x90, 105, 100] + lyric(0, "one") + lyric(10, "+") + lyric(10, "two^")
        + [0x10, 0x80, 105, 64]
        + lyric(10, "outside")
        + [0x10, 0x90, 105, 100] + lyric(0, "three") + [0x10, 0x90, 105, 0]
    let m = try MidiDocument(data: smf(vocals: ev), url: URL(fileURLWithPath: "/x/notes.mid"))
    #expect(m.phrases.map { $0.syllables.map(\.text) } == [["one", "two"], ["three"]])
    let out = try m.applying(lyrics: LyricInput.parse("uno dos\ntres"))
    let again = try MidiDocument(data: out.serialized, url: m.url)
    #expect(again.slotRefs.flatMap { $0 }.map(\.rawText) == ["uno", "dos^", "tres"])
    // The slide and the out-of-phrase lyric are untouched.
    let evs = try MidiDocument.events(in: again.chunks[again.trackChunkIndices[0]].data)
    let texts: [String] = evs.compactMap { if case .meta(0x05, let d, _) = $0.event { return String(decoding: d, as: UTF8.self) } else { return nil } }
    #expect(texts == ["uno", "+", "dos^", "outside", "tres"])
}

@Test func longLyricUsesMultiByteLength() throws {
    let ev: [UInt8] = [0x00, 0x90, 105, 100] + lyric(0, "x") + [0x10, 0x90, 105, 0]
    let m = try MidiDocument(data: smf(vocals: ev), url: URL(fileURLWithPath: "/x/notes.mid"))
    let long = String(repeating: "ä", count: 100) // 200 UTF-8 bytes > 127: needs a 2-byte VLQ length
    let out = try m.applying(lyrics: LyricInput.parse(long))
    let again = try MidiDocument(data: out.serialized, url: m.url)
    #expect(again.phrases[0].syllables[0].text == long)
}

// MARK: - Comparison & karaoke timing

@Test func comparisonRows() {
    let phrases = [VocalPhrase(startTick: 0, endTick: 10, syllables: [.init(tick: 0, text: ""), .init(tick: 5, text: "")]),
                   VocalPhrase(startTick: 20, endTick: 30, syllables: [.init(tick: 20, text: "")])]
    let cmp = LyricComparison(phrases: phrases, input: LyricInput.parse("a b\nc d\ne"))
    #expect(cmp.rows.map(\.matches) == [true, false, false])
    #expect(!cmp.isWritable)
    #expect(cmp.rows[2].fileCount == nil)
}

@Test func karaokeTrackTimesAndProgress() throws {
    let c = try ChartDocument(url: fixtures.appendingPathComponent("test.chart"))
    let t = KaraokeTrack(document: c, override: LyricInput.parse("Hel-lo there my\nfriends al=ways\nthis is a test\nsing-ing"))
    #expect(t.phrases.count == 4)
    #expect(abs(t.phrases[0].syllables[1].time - 1.25) < 1e-9)
    #expect(t.phrases[1].text == "friends al-ways")
    #expect(t.phrases[1].end <= t.phrases[2].start)        // no overlap when closed by the next phrase_start
    #expect(t.phraseIndex(at: 0.5) == -1)
    #expect(t.phraseIndex(at: 2.6) == 1)
    #expect(abs(t.progress(phrase: 0, at: 1.375) - 1.5) < 1e-9)
}
