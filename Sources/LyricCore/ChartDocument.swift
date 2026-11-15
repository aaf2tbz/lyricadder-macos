import Foundation

/// A Moonscraper / Clone Hero `.chart` file.
///
/// The file is kept as its original lines so a rewrite only touches the lyric event lines;
/// BOM, line endings and the trailing newline are preserved (the original only handled CRLF and trimmed the file).
public struct ChartDocument: LyricDocument {
    public struct Section: Equatable, Sendable {
        public var name: String
        public var headerLine: Int
        /// Lines strictly between `{` and `}`.
        public var body: Range<Int>
    }

    public let url: URL
    public private(set) var lines: [String]
    public let lineEnding: String
    public let hasBOM: Bool
    public let hasTrailingNewline: Bool
    public private(set) var sections: [Section]

    public private(set) var songName: String = ""
    public private(set) var artist: String = ""
    public private(set) var resolution: Int = 192
    public private(set) var phrases: [VocalPhrase] = []
    public private(set) var tempoMap: TempoMap = TempoMap(resolution: 192, changes: [])
    public private(set) var warnings: [String] = []

    /// For each phrase, the file line of each lyric slot.
    public private(set) var slotLines: [[Int]] = []

    /// Raw bytes as read (used for the backup copy).
    public let originalData: Data

    public var displayName: String {
        let n = songName.isEmpty ? url.deletingPathExtension().lastPathComponent : songName
        return artist.isEmpty ? n : "\(n) by \(artist)"
    }

    public init(url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LyricError.unreadable("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        try self.init(data: data, url: url)
    }

    public init(data: Data, url: URL) throws {
        originalData = data
        self.url = url
        var bytes = data
        hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        if hasBOM { bytes = bytes.dropFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) else {
            throw LyricError.unreadable("\(url.lastPathComponent) is not a text file")
        }
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        var ls = text.components(separatedBy: lineEnding)
        hasTrailingNewline = ls.last == ""
        if hasTrailingNewline { ls.removeLast() }
        lines = ls
        sections = ChartDocument.findSections(ls)
        guard !sections.isEmpty else {
            throw LyricError.nothingUseful("Nothing useful could be found from the .chart file selected")
        }
        readSongInfo()
        readSyncTrack()
        readEvents()
    }

    static func findSections(_ lines: [String]) -> [Section] {
        var out: [Section] = []
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]"), t.count >= 2 {
                let name = String(t.dropFirst().dropLast())
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                if j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) == "{" {
                    var k = j + 1
                    while k < lines.count, lines[k].trimmingCharacters(in: .whitespaces) != "}" { k += 1 }
                    out.append(Section(name: name, headerLine: i, body: (j + 1)..<k))
                    i = k + 1
                    continue
                }
            }
            i += 1
        }
        return out
    }

    public func section(_ name: String) -> Section? { sections.first { $0.name == name } }

    /// Instrument/difficulty sections (`[ExpertSingle]`, `[HardDrums]` …), like the original `difficulties` array.
    public var difficultySections: [Section] {
        sections.filter { s in ["Expert", "Hard", "Medium", "Easy"].contains { s.name.hasPrefix($0) } }
    }

    // MARK: - Reading

    /// `key = value` pairs, value with surrounding quotes removed.
    static func keyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let k = line[..<eq].trimmingCharacters(in: .whitespaces)
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
        return (k, v)
    }

    private mutating func readSongInfo() {
        guard let s = section("Song") else { return }
        for l in s.body {
            guard let (k, v) = ChartDocument.keyValue(lines[l]) else { continue }
            switch k {
            case "Name": songName = v
            case "Artist": artist = v
            case "Resolution": resolution = Int(v) ?? 192
            default: break
            }
        }
    }

    private mutating func readSyncTrack() {
        var changes: [TempoMap.Change] = []
        if let s = section("SyncTrack") {
            for l in s.body {
                // `0 = B 120000`  (BPM * 1000)
                let parts = lines[l].split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 4, parts[1] == "=", parts[2] == "B", let tick = Int(parts[0]), let milli = Double(parts[3]), milli > 0 {
                    changes.append(.init(tick: tick, microsecondsPerQuarter: TempoMap.bpm(milli / 1000)))
                }
            }
        }
        tempoMap = TempoMap(resolution: resolution, changes: changes)
    }

    /// Parses `  1234 = E "text"` and returns (tick, text).
    static func parseEvent(_ line: String) -> (tick: Int, text: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let eq = t.firstIndex(of: "=") else { return nil }
        guard let tick = Int(t[..<eq].trimmingCharacters(in: .whitespaces)) else { return nil }
        let rest = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("E ") else { return nil }
        let q = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard q.hasPrefix("\""), q.hasSuffix("\""), q.count >= 2 else { return nil }
        return (tick, String(q.dropFirst().dropLast()))
    }

    /// `lyric foo-` -> "foo-", `Default` -> "" (Moonscraper's placeholder text), anything else -> nil.
    static func lyricText(_ eventText: String) -> String? {
        if eventText == "Default" { return "" }
        if eventText == "lyric" { return "" }
        if eventText.hasPrefix("lyric ") { return String(eventText.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private mutating func readEvents() {
        guard let s = section("Events") else {
            phrases = []; slotLines = []; warnings = []
            return
        }
        var items: [PhraseBuilder.Item] = []
        var slots: [SyllableSlot] = []
        var slotLine: [Int] = []
        for l in s.body {
            guard let (tick, text) = ChartDocument.parseEvent(lines[l]) else { continue }
            if text == "phrase_start" {
                items.append(.init(tick: tick, kind: .start, order: l))
            } else if text == "phrase_end" {
                items.append(.init(tick: tick, kind: .end, order: l))
            } else if let lyr = ChartDocument.lyricText(text) {
                items.append(.init(tick: tick, kind: .lyric(slotIndex: slots.count), order: l))
                slots.append(SyllableSlot(tick: tick, text: lyr))
                slotLine.append(l)
            }
        }
        let built = PhraseBuilder.build(items: items, slots: slots)
        phrases = built.phrases
        slotLines = built.slotIndices.map { $0.map { slotLine[$0] } }
        warnings = built.warnings
    }

    // MARK: - Writing

    /// Returns the chart text with the given syllables written into the lyric events.
    /// Port of modifyEventsAndOriginalChart(): `E "Default"` / `E "lyric …"` become `E "lyric <syllable>"`.
    public func applying(lyrics input: [LyricInput.Line]) throws -> ChartDocument {
        let cmp = LyricComparison(phrases: phrases, input: input)
        if let problem = cmp.problemDescription { throw LyricError.mismatch(problem) }

        var copy = self
        for (i, phrase) in input.enumerated() {
            for (j, syl) in phrase.syllables.enumerated() {
                let l = slotLines[i][j]
                copy.lines[l] = ChartDocument.rewriteLyric(line: lines[l], syllable: syl)
            }
        }
        copy.readEvents()
        return copy
    }

    static func rewriteLyric(line: String, syllable: String) -> String {
        // Keep the original indentation and tick text, replace only the event payload.
        guard let eRange = line.range(of: " E \"") else { return line }
        return String(line[..<eRange.lowerBound]) + " E \"lyric \(syllable)\""
    }

    public var serialized: Data {
        var text = lines.joined(separator: lineEnding)
        if hasTrailingNewline { text += lineEnding }
        var d = Data()
        if hasBOM { d.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        d.append(text.data(using: .utf8)!)
        return d
    }

    /// Backup file name like the original (`SongName_Artist_backup.chart`), plus a timestamp so
    /// writing twice never overwrites the backup of the untouched chart.
    public func backupFileName(date: Date = Date()) -> String {
        func clean(_ s: String) -> String { s.filter { $0.isLetter || $0.isNumber || $0 == "_" } }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let base = [clean(songName), clean(artist)].filter { !$0.isEmpty }.joined(separator: "_")
        return (base.isEmpty ? clean(url.deletingPathExtension().lastPathComponent) : base) + "_backup_\(f.string(from: date)).chart"
    }
}
