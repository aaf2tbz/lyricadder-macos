import Foundation

/// A lyric slot inside a phrase (one `lyric` event in a .chart, one Lyrics meta event in a MIDI).
public struct SyllableSlot: Equatable, Sendable {
    public var tick: Int
    /// Text currently stored in the file, with format markers removed (e.g. MIDI `#`/`^`).
    public var text: String
}

public struct VocalPhrase: Equatable, Sendable {
    public var startTick: Int
    /// End tick (phrase_end / note-off), or nil when the phrase was closed by the next phrase_start.
    public var endTick: Int?
    public var syllables: [SyllableSlot]
}

/// Tick -> seconds conversion.
///
/// The original soundStuff.js hard-coded 192 ticks per beat; this uses the file's real resolution.
public struct TempoMap: Equatable, Sendable {
    public struct Change: Equatable, Sendable {
        public var tick: Int
        /// Microseconds per quarter note.
        public var microsecondsPerQuarter: Double
    }

    public var resolution: Int
    public private(set) var changes: [Change]
    private var startSeconds: [Double] = []

    public init(resolution: Int, changes: [Change]) {
        self.resolution = max(1, resolution)
        var sorted = changes.sorted { $0.tick < $1.tick }
        if sorted.first.map({ $0.tick > 0 }) ?? true {
            // Default 120 BPM until the first tempo event (SMF / .chart default).
            sorted.insert(Change(tick: 0, microsecondsPerQuarter: 500_000), at: 0)
        }
        self.changes = sorted
        var acc = 0.0
        startSeconds = []
        for (i, c) in sorted.enumerated() {
            if i > 0 {
                let prev = sorted[i - 1]
                acc += Double(c.tick - prev.tick) * prev.microsecondsPerQuarter / 1_000_000 / Double(self.resolution)
            }
            startSeconds.append(acc)
        }
    }

    public static func bpm(_ bpm: Double) -> Double { 60_000_000 / bpm }

    public func seconds(atTick tick: Int) -> Double {
        // Binary search for the last change at or before `tick`.
        var lo = 0, hi = changes.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if changes[mid].tick <= tick { lo = mid } else { hi = mid - 1 }
        }
        let c = changes[lo]
        return startSeconds[lo] + Double(tick - c.tick) * c.microsecondsPerQuarter / 1_000_000 / Double(resolution)
    }
}

/// Something lyrics can be written into: a .chart or a MIDI file.
public protocol LyricDocument {
    var url: URL { get }
    var displayName: String { get }
    var phrases: [VocalPhrase] { get }
    var tempoMap: TempoMap { get }
    /// Problems spotted while reading (e.g. phrase markers placed back to back).
    var warnings: [String] { get }
}

public extension LyricDocument {
    var lyricEventCount: Int { phrases.reduce(0) { $0 + $1.syllables.count } }

    /// Lyrics currently stored in the file, in the input box syntax.
    var lyricsText: String { LyricInput.format(phrases: phrases.map { $0.syllables.map(\.text) }) }
}

/// Per-phrase comparison between the file and the input box.
public struct LyricComparison: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var phrase: Int          // 1-based like the original UI
        public var fileCount: Int?      // nil: phrase only exists in the input
        public var inputCount: Int?     // nil: phrase only exists in the file
        public var textLine: Int?       // input line the phrase came from
        public var matches: Bool { fileCount == inputCount }
    }

    public var rows: [Row]
    public var filePhraseCount: Int
    public var inputPhraseCount: Int
    public var fileLyricCount: Int
    public var inputSyllableCount: Int

    public init(phrases: [VocalPhrase], input: [LyricInput.Line]) {
        let n = max(phrases.count, input.count)
        rows = (0..<n).map { i in
            Row(phrase: i + 1,
                fileCount: i < phrases.count ? phrases[i].syllables.count : nil,
                inputCount: i < input.count ? input[i].syllables.count : nil,
                textLine: i < input.count ? input[i].textLine : nil)
        }
        filePhraseCount = phrases.count
        inputPhraseCount = input.count
        fileLyricCount = phrases.reduce(0) { $0 + $1.syllables.count }
        inputSyllableCount = input.reduce(0) { $0 + $1.syllables.count }
    }

    public var isWritable: Bool { filePhraseCount > 0 && filePhraseCount == inputPhraseCount && rows.allSatisfy(\.matches) }

    /// Same messages as testReadChartAndLrics() in the original.
    public var problemDescription: String? {
        if filePhraseCount == 0 { return "No phrases with lyric events were found in the file" }
        if inputPhraseCount == 0 { return "No lyrics written in the text box" }
        if filePhraseCount != inputPhraseCount { return "Not the same amount of phrases (file: \(filePhraseCount), input: \(inputPhraseCount))" }
        let bad = rows.filter { !$0.matches }
        if bad.isEmpty { return nil }
        return bad.map { "(phrase: \($0.phrase), lyric events: \($0.fileCount ?? 0), syllables: \($0.inputCount ?? 0))" }.joined()
    }
}

public enum LyricError: LocalizedError, Equatable {
    case unreadable(String)
    case nothingUseful(String)
    case mismatch(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s), .nothingUseful(let s), .mismatch(let s), .writeFailed(let s): return s
        }
    }
}

/// Builds the phrase list from a flat, file-ordered list of phrase markers and lyric slots.
///
/// Port of the phrase grouping in readAndModifyEvents() / separateLyrics(), with the same-tick rules made explicit:
///  * a lyric on the same tick as a phrase_start belongs to that new phrase even if it is listed first
///    (the original swapped such events in place)
///  * when a phrase_end and phrase_start share a tick, the end is applied first
///  * a phrase is closed by phrase_end or by the next phrase_start; lyrics outside phrases are ignored
enum PhraseBuilder {
    enum Kind: Equatable { case start, end, lyric(slotIndex: Int) }
    struct Item { var tick: Int; var kind: Kind; var order: Int }

    static func build(items: [Item], slots: [SyllableSlot]) -> (phrases: [VocalPhrase], slotIndices: [[Int]], warnings: [String]) {
        let startTicks = Set(items.filter { $0.kind == .start }.map(\.tick))
        func rank(_ it: Item) -> Int {
            switch it.kind {
            case .end: return startTicks.contains(it.tick) ? 0 : 3
            case .start: return 1
            case .lyric: return 2
            }
        }
        let sorted = items.sorted { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a.order < b.order
        }

        var phrases: [VocalPhrase] = []
        var indices: [[Int]] = []
        var warnings: [String] = []
        var open: VocalPhrase?
        var openIdx: [Int] = []
        var last: Kind?
        var lastTick = -1

        func close(_ end: Int?) {
            if var p = open {
                p.endTick = end
                phrases.append(p)
                indices.append(openIdx)
            }
            open = nil
            openIdx = []
        }

        for it in sorted {
            switch it.kind {
            case .start:
                if last == .start { warnings.append("start: \(it.tick)") }
                if let l = last, l == .start || l == .end, it.tick == lastTick { warnings.append("on same tick: \(it.tick)") }
                close(nil)
                open = VocalPhrase(startTick: it.tick, endTick: nil, syllables: [])
            case .end:
                if last == .end { warnings.append("end: \(it.tick)") }
                if let l = last, l == .start || l == .end, it.tick == lastTick, !startTicks.contains(it.tick) {
                    warnings.append("on same tick: \(it.tick)")
                }
                close(it.tick)
            case .lyric(let si):
                if open != nil {
                    open!.syllables.append(slots[si])
                    openIdx.append(si)
                }
            }
            last = it.kind
            lastTick = it.tick
        }
        close(nil)

        // Phrases without any lyric events are dropped from the count (an empty phrase can't take syllables).
        var outP: [VocalPhrase] = [], outI: [[Int]] = []
        for (p, i) in zip(phrases, indices) where !p.syllables.isEmpty {
            outP.append(p); outI.append(i)
        }
        let w = warnings.isEmpty ? [] : ["Multiple phrase events after one another found around:" + warnings.map { " " + $0 + "," }.joined()]
        return (outP, outI, w)
    }
}
