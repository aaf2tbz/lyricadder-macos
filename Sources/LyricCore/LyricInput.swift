import Foundation

/// The lyric text syntax used by the input box.
///
/// Ported from `readLyricInput()` / `readMidiLyricInput()` in the original mainScripts.js / midiScripts.js:
///  * every non-empty line is one phrase
///  * syllables are separated by spaces, or by a trailing `-` (joined syllable) / `=` (literal hyphen)
///  * a lone `-` or `=` is ignored
public enum LyricInput {

    /// One input line that produced a phrase.
    public struct Line: Equatable, Sendable {
        /// 0-based line index in the text (counting blank lines too).
        public var textLine: Int
        public var syllables: [String]
    }

    /// Splits one phrase line into syllables exactly like the original:
    /// `line.replace(/-/g, "- ").replace(/=/g, "= ").trim().split(" ")`, dropping "", "-" and "=".
    /// (Whitespace in general is accepted as a separator here, the original only split on spaces.)
    public static func syllables(inLine line: String) -> [String] {
        var spaced = ""
        spaced.reserveCapacity(line.count + 8)
        for ch in line {
            spaced.append(ch)
            if ch == "-" || ch == "=" { spaced.append(" ") }
        }
        return spaced
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { $0 != "-" && $0 != "=" }
    }

    /// Parses the whole input box into phrases (blank / whitespace-only lines are skipped).
    public static func parse(_ text: String) -> [Line] {
        var result: [Line] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for (i, raw) in lines.enumerated() {
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append(Line(textLine: i, syllables: syllables(inLine: raw)))
        }
        return result
    }

    /// Joins syllables of each phrase back into the input syntax
    /// (port of `getLyricsFromChart()` / `getLyricsFromMIDIButton()`).
    public static func format(phrases: [[String]]) -> String {
        var out: [String] = []
        for phrase in phrases {
            var line = ""
            for syl in phrase {
                if syl.hasSuffix("-") || syl.hasSuffix("=") {
                    line += syl
                } else {
                    line += syl + " "
                }
            }
            line = line.trimmingCharacters(in: .whitespaces)
            // The original drops phrases that produced no text.
            if !line.isEmpty { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// How a syllable is shown in the karaoke preview (port of soundStuff.js createLyricPreview):
    /// trailing `-` joins to the next syllable, trailing `=` shows a literal hyphen, otherwise a space follows.
    public static func displayPieces(_ syllables: [String]) -> [String] {
        var pieces: [String] = []
        for (j, raw) in syllables.enumerated() {
            var s = raw
            if s.hasSuffix("-") {
                s.removeLast()
            } else if s.hasSuffix("=") {
                s.removeLast()
                s += "-"
            } else if j != syllables.count - 1 {
                s += " "
            }
            pieces.append(s)
        }
        return pieces
    }
}
