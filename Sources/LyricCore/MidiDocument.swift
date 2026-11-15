import Foundation

/// Standard MIDI File with a Rock Band / Clone Hero `PART VOCALS` track.
///
/// Port of midiScripts.js. Differences from the original, all deliberate fixes:
///  * Note-off (0x8n) and Note-on with velocity 0 both end a phrase (the original treated 0x8n as a phrase start).
///  * Meta / SysEx lengths are variable-length quantities (the original read a single byte).
///  * Writing splices only the Lyrics meta events in place, so every other event in PART VOCALS
///    (overdrive, percussion, text events, running status …) survives byte-for-byte.
///    The original rebuilt the track from phrases + lyrics + pitches only.
///  * `+` (pitch slide) lyric events are not syllables: they are kept untouched and not counted.
///  * Pitchless markers (`#`, `^`) are remembered per event and re-appended on write.
public struct MidiDocument: LyricDocument {
    public struct Chunk: Sendable {
        public var type: String
        public var data: Data   // payload without the 8-byte prefix
    }

    public struct LyricRef: Sendable {
        public var track: Int
        /// Byte range (within the track payload) of the whole meta event `FF 05 <len> <text>` (delta excluded).
        public var range: Range<Int>
        public var rawText: String
        public var markers: String
    }

    public static let phraseNote: UInt8 = 105

    public let url: URL
    public let originalData: Data
    public private(set) var header: Chunk
    public private(set) var chunks: [Chunk]          // every chunk after the header, in file order
    public private(set) var trackChunkIndices: [Int] // indices into `chunks` that are MTrk
    public private(set) var vocalTrack: Int?         // index into trackChunkIndices
    public private(set) var format: Int = 1
    public private(set) var division: Int = 480
    public private(set) var phrases: [VocalPhrase] = []
    public private(set) var tempoMap: TempoMap = TempoMap(resolution: 480, changes: [])
    public private(set) var warnings: [String] = []
    public private(set) var slotRefs: [[LyricRef]] = []
    public private(set) var trackNames: [String] = []

    public var displayName: String {
        // The original used the containing folder's name (Clone Hero songs live in "Artist - Song/notes.mid").
        if let ini = SongIni.load(folder: url.deletingLastPathComponent()), !ini.name.isEmpty {
            return ini.artist.isEmpty ? ini.name : "\(ini.name) by \(ini.artist)"
        }
        return url.deletingLastPathComponent().lastPathComponent
    }

    public init(url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw LyricError.unreadable("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        try self.init(data: data, url: url)
    }

    public init(data: Data, url: URL) throws {
        self.url = url
        originalData = data
        let bytes = [UInt8](data)
        var idx = 0
        var hdr: Chunk?
        var cs: [Chunk] = []
        while idx + 8 <= bytes.count {
            let type = String(bytes: bytes[idx..<idx + 4], encoding: .isoLatin1) ?? "????"
            let size = Int(bytes[idx + 4]) << 24 | Int(bytes[idx + 5]) << 16 | Int(bytes[idx + 6]) << 8 | Int(bytes[idx + 7])
            let start = idx + 8
            let end = min(bytes.count, start + size)
            let chunk = Chunk(type: type, data: Data(bytes[start..<end]))
            if type == "MThd" && hdr == nil { hdr = chunk } else { cs.append(chunk) }
            idx = start + size
        }
        guard let h = hdr, h.data.count >= 6 else {
            throw LyricError.unreadable("\(url.lastPathComponent) is not a MIDI file (no MThd header)")
        }
        header = h
        chunks = cs
        trackChunkIndices = cs.indices.filter { cs[$0].type == "MTrk" }
        let hb = [UInt8](h.data)
        format = Int(hb[0]) << 8 | Int(hb[1])
        let div = Int(hb[4]) << 8 | Int(hb[5])
        division = (div & 0x8000) != 0 ? 480 : max(1, div) // SMPTE timing isn't used by CH/RB charts
        try parseTracks()
    }

    // MARK: - Event parsing

    public enum Event: Sendable {
        case channel(status: UInt8, d1: UInt8, d2: UInt8)
        case meta(type: UInt8, data: [UInt8], range: Range<Int>)
        case sysex
    }

    public struct TimedEvent: Sendable {
        public var tick: Int
        public var event: Event
    }

    static func readVLQ(_ b: [UInt8], _ i: inout Int) throws -> Int {
        var v = 0
        for _ in 0..<4 {
            guard i < b.count else { throw LyricError.unreadable("Truncated MIDI variable-length value") }
            let c = b[i]; i += 1
            v = (v << 7) | Int(c & 0x7F)
            if c & 0x80 == 0 { return v }
        }
        throw LyricError.unreadable("Invalid MIDI variable-length value")
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var out: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            out.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return out
    }

    public static func events(in track: Data) throws -> [TimedEvent] {
        let b = [UInt8](track)
        var i = 0
        var tick = 0
        var running: UInt8 = 0
        var out: [TimedEvent] = []
        while i < b.count {
            tick += try readVLQ(b, &i)
            guard i < b.count else { break }
            var status = b[i]
            let evStart = i
            if status < 0x80 {
                guard running != 0 else { throw LyricError.unreadable("MIDI data byte without running status at \(i)") }
                status = running
            } else {
                i += 1
            }
            switch status {
            case 0xFF:
                guard i < b.count else { throw LyricError.unreadable("Truncated meta event") }
                let type = b[i]; i += 1
                let len = try readVLQ(b, &i)
                let end = min(b.count, i + len)
                out.append(TimedEvent(tick: tick, event: .meta(type: type, data: Array(b[i..<end]), range: evStart..<end)))
                i = end
                // Lenient like most readers: keep running status across meta events.
            case 0xF0, 0xF7:
                let len = try readVLQ(b, &i)
                i = min(b.count, i + len)
                out.append(TimedEvent(tick: tick, event: .sysex))
                running = 0
            default:
                running = status
                let hi = status & 0xF0
                let n = (hi == 0xC0 || hi == 0xD0) ? 1 : 2
                guard i + n <= b.count else { throw LyricError.unreadable("Truncated channel event") }
                let d1 = b[i], d2: UInt8 = n == 2 ? b[i + 1] : 0
                i += n
                out.append(TimedEvent(tick: tick, event: .channel(status: status, d1: d1, d2: d2)))
            }
        }
        return out
    }

    static func decodeText(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    /// Splits RB lyric syntax into (core text, pitchless markers). The original stripped every `#` and `^`.
    public static func splitMarkers(_ text: String) -> (String, String) {
        var core = "", markers = ""
        for ch in text {
            if ch == "#" || ch == "^" { markers.append(ch) } else { core.append(ch) }
        }
        return (core, markers)
    }

    private mutating func parseTracks() throws {
        var tempo: [TempoMap.Change] = []
        trackNames = []
        vocalTrack = nil
        var vocalEvents: [TimedEvent] = []
        for (t, ci) in trackChunkIndices.enumerated() {
            let evs = try MidiDocument.events(in: chunks[ci].data)
            var name = ""
            for e in evs {
                if case .meta(let type, let d, _) = e.event {
                    if type == 0x03 && name.isEmpty { name = MidiDocument.decodeText(d) }
                    if type == 0x51 && d.count == 3 {
                        let mpq = Int(d[0]) << 16 | Int(d[1]) << 8 | Int(d[2])
                        if mpq > 0 { tempo.append(.init(tick: e.tick, microsecondsPerQuarter: Double(mpq))) }
                    }
                }
            }
            trackNames.append(name)
            if name == "PART VOCALS" && vocalTrack == nil {
                vocalTrack = t
                vocalEvents = evs
            }
        }
        tempoMap = TempoMap(resolution: division, changes: tempo)

        guard let vt = vocalTrack else {
            phrases = []; slotRefs = []
            warnings = ["No PART VOCALS track found in the MIDI file"]
            return
        }

        var items: [PhraseBuilder.Item] = []
        var slots: [SyllableSlot] = []
        var refs: [LyricRef] = []
        for (order, e) in vocalEvents.enumerated() {
            switch e.event {
            case .channel(let status, let d1, let d2):
                let hi = status & 0xF0
                guard (hi == 0x90 || hi == 0x80), d1 == MidiDocument.phraseNote else { continue }
                let isOn = hi == 0x90 && d2 > 0
                items.append(.init(tick: e.tick, kind: isOn ? .start : .end, order: order))
            case .meta(0x05, let d, let range):
                let raw = MidiDocument.decodeText(d)
                if raw.trimmingCharacters(in: .whitespaces) == "+" { continue } // pitch slide, not a syllable
                let (core, markers) = MidiDocument.splitMarkers(raw)
                items.append(.init(tick: e.tick, kind: .lyric(slotIndex: slots.count), order: order))
                slots.append(SyllableSlot(tick: e.tick, text: core))
                refs.append(LyricRef(track: vt, range: range, rawText: raw, markers: markers))
            default:
                continue
            }
        }
        let built = PhraseBuilder.build(items: items, slots: slots)
        phrases = built.phrases
        slotRefs = built.slotIndices.map { $0.map { refs[$0] } }
        warnings = built.warnings
    }

    // MARK: - Writing

    /// Returns a new MIDI file with the input syllables written into PART VOCALS.
    public func applying(lyrics input: [LyricInput.Line]) throws -> MidiDocument {
        let cmp = LyricComparison(phrases: phrases, input: input)
        if let problem = cmp.problemDescription { throw LyricError.mismatch(problem) }
        guard let vt = vocalTrack else { throw LyricError.mismatch("No PART VOCALS track found") }

        var replacements: [(Range<Int>, [UInt8])] = []
        for (i, phrase) in input.enumerated() {
            for (j, syl) in phrase.syllables.enumerated() {
                let ref = slotRefs[i][j]
                let text = Array((syl + ref.markers).utf8)
                replacements.append((ref.range, [0xFF, 0x05] + MidiDocument.vlq(text.count) + text))
            }
        }
        replacements.sort { $0.0.lowerBound > $1.0.lowerBound }
        let ci = trackChunkIndices[vt]
        var track = [UInt8](chunks[ci].data)
        for (r, bytes) in replacements { track.replaceSubrange(r, with: bytes) }

        var copy = self
        copy.chunks[ci].data = Data(track)
        try copy.parseTracks()
        return copy
    }

    public var serialized: Data {
        var out = Data()
        func put(_ c: Chunk) {
            out.append(contentsOf: Array(c.type.utf8.prefix(4)))
            let n = c.data.count
            out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(c.data)
        }
        put(header)
        chunks.forEach(put)
        return out
    }

    public func backupFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let base = url.deletingLastPathComponent().lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return (base.isEmpty ? "midi" : base) + "_backup_\(f.string(from: date)).mid"
    }

    /// The original wrote `lyricAdderOutput.mid` next to the source file instead of overwriting it.
    public var outputURL: URL { url.deletingLastPathComponent().appendingPathComponent("lyricAdderOutput.mid") }
}

/// Minimal `song.ini` reader (Clone Hero song metadata).
public struct SongIni: Sendable {
    public var name = ""
    public var artist = ""

    public static func load(folder: URL) -> SongIni? {
        let url = folder.appendingPathComponent("song.ini")
        guard let d = try? Data(contentsOf: url) else { return nil }
        let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        var ini = SongIni()
        for line in text.components(separatedBy: .newlines) {
            guard let (k, v) = ChartDocument.keyValue(line) else { continue }
            switch k.lowercased() {
            case "name": ini.name = v
            case "artist": ini.artist = v
            default: break
            }
        }
        return ini
    }
}
