import Foundation

/// Persistent settings. Replaces `../lyricAdder_backups/config.json` (which was relative to the working
/// directory) with `~/Library/Application Support/LyricAdder/config.json`.
public struct AppConfig: Codable, Equatable, Sendable {
    public var pathToBackupFolder: String
    public var version: String
    public var pathToChartFile: String
    public var lyricsInput: String
    public var mainPageDoNotShow: Bool

    public static let appVersion = "1.2.2"

    public static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("LyricAdder", isDirectory: true)
    }

    public static var configURL: URL { supportFolder.appendingPathComponent("config.json") }

    public static var `default`: AppConfig {
        AppConfig(pathToBackupFolder: supportFolder.appendingPathComponent("backups").path,
                  version: appVersion, pathToChartFile: "", lyricsInput: "", mainPageDoNotShow: false)
    }

    /// Port of main.js testPaths()/testVersion(): create folders + config, bump the stored version.
    public static func load() -> AppConfig {
        let fm = FileManager.default
        var cfg = AppConfig.default
        if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(AppConfig.self, from: d) {
            cfg = c
        }
        cfg.version = appVersion
        try? fm.createDirectory(atPath: cfg.pathToBackupFolder, withIntermediateDirectories: true)
        cfg.save()
        return cfg
    }

    public func save() {
        try? FileManager.default.createDirectory(at: AppConfig.supportFolder, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: AppConfig.configURL, options: .atomic) }
    }
}

public enum LoadedDocument {
    case chart(ChartDocument)
    case midi(MidiDocument)

    public static func load(url: URL) throws -> LoadedDocument {
        switch url.pathExtension.lowercased() {
        case "mid", "midi": return .midi(try MidiDocument(url: url))
        default: return .chart(try ChartDocument(url: url))
        }
    }

    public var document: any LyricDocument {
        switch self {
        case .chart(let c): return c
        case .midi(let m): return m
        }
    }

    public var isMidi: Bool { if case .midi = self { return true } else { return false } }

    public struct WriteResult {
        public var written: URL
        public var backup: URL
        public var reloaded: LoadedDocument
    }

    /// Validates, writes a backup of the untouched file, then writes the new file.
    /// .chart: overwrites the original (like testAndWriteChart). MIDI: writes lyricAdderOutput.mid next to it.
    public func write(lyrics: String, backupFolder: URL, date: Date = Date()) throws -> WriteResult {
        let input = LyricInput.parse(lyrics)
        let fm = FileManager.default
        try? fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)

        switch self {
        case .chart(let c):
            let updated = try c.applying(lyrics: input)
            let backup = backupFolder.appendingPathComponent(c.backupFileName(date: date))
            do { try c.originalData.write(to: backup, options: .atomic) } catch {
                throw LyricError.writeFailed("Problems writing the backup of the original chart, stopping the process: \(error.localizedDescription)")
            }
            do { try updated.serialized.write(to: c.url, options: .atomic) } catch {
                throw LyricError.writeFailed("Problems occured while writing the chart file: \(error.localizedDescription)")
            }
            return WriteResult(written: c.url, backup: backup, reloaded: .chart(try ChartDocument(url: c.url)))
        case .midi(let m):
            let updated = try m.applying(lyrics: input)
            let backup = backupFolder.appendingPathComponent(m.backupFileName(date: date))
            do { try m.originalData.write(to: backup, options: .atomic) } catch {
                throw LyricError.writeFailed("Problems writing the backup of the original MIDI, stopping the process: \(error.localizedDescription)")
            }
            let out = m.outputURL
            do { try updated.serialized.write(to: out, options: .atomic) } catch {
                throw LyricError.writeFailed("Problems writing the updated midi file: \(error.localizedDescription)")
            }
            return WriteResult(written: out, backup: backup, reloaded: .midi(try MidiDocument(url: m.url)))
        }
    }
}

/// Timed lyrics for the karaoke preview (port of soundStuff.js combineArrays()).
public struct KaraokeTrack: Equatable, Sendable {
    public struct Syllable: Equatable, Sendable {
        public var time: Double
        /// Display text (joined syllables have their `-` removed, `=` shows as `-`, others get a trailing space).
        public var display: String
        public var raw: String
    }

    public struct Phrase: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var syllables: [Syllable]
        public var text: String { syllables.map(\.display).joined() }

        /// Time at which syllable `i` should be fully highlighted.
        public func syllableEnd(_ i: Int) -> Double {
            let t = syllables[i].time
            let next = i + 1 < syllables.count ? syllables[i + 1].time : end
            return min(max(next, t + 0.05), t + 1.5)
        }
    }

    public var phrases: [Phrase]

    public init(phrases: [Phrase]) { self.phrases = phrases }

    /// - Parameter override: syllables from the input box. Used per phrase when its count matches the file,
    ///   so you can preview lyrics before writing them (the original could only preview the file).
    public init(document: any LyricDocument, override: [LyricInput.Line]? = nil) {
        let map = document.tempoMap
        var out: [Phrase] = []
        for (i, p) in document.phrases.enumerated() {
            var raws = p.syllables.map(\.text)
            if let o = override, i < o.count, o[i].syllables.count == raws.count { raws = o[i].syllables }
            let pieces = LyricInput.displayPieces(raws)
            let syls = zip(p.syllables, zip(pieces, raws)).map { slot, pr in
                Syllable(time: map.seconds(atTick: slot.tick), display: pr.0, raw: pr.1)
            }
            let startT = map.seconds(atTick: p.startTick)
            let lastT = syls.last?.time ?? startT
            let endT: Double
            if let e = p.endTick { endT = max(map.seconds(atTick: e), lastT) } else { endT = lastT + 1.0 }
            out.append(Phrase(start: min(startT, syls.first?.time ?? startT), end: endT, syllables: syls))
        }
        // A phrase closed by the next phrase_start (no phrase_end) must not overlap it.
        for i in out.indices.dropLast() where document.phrases[i].endTick == nil {
            out[i].end = max(out[i].syllables.last?.time ?? out[i].start, min(out[i].end, out[i + 1].start))
        }
        phrases = out
    }

    /// Index of the phrase being sung (or the last one started) at `time`; -1 before the first phrase.
    public func phraseIndex(at time: Double) -> Int {
        var lo = 0, hi = phrases.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if phrases[mid].start <= time { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }

    /// Fractional highlight progress through phrase `p` measured in syllables (0 … count).
    public func progress(phrase p: Int, at time: Double) -> Double {
        let ph = phrases[p]
        var acc = 0.0
        for i in ph.syllables.indices {
            let t0 = ph.syllables[i].time
            if time < t0 { break }
            let t1 = ph.syllableEnd(i)
            acc = Double(i) + min(1, (time - t0) / max(0.001, t1 - t0))
        }
        return acc
    }

    public var duration: Double { phrases.last?.end ?? 0 }
}
