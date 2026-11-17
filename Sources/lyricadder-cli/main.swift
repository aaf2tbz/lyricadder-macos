import Foundation
import ImageIO
import LyricCore
import LyricRender
import Metal
import UniformTypeIdentifiers

// Headless front end for the same core the app uses. Handy for scripting and for verifying the port.

/// 32-bit float WAV, interleaved (for comparing the decoders with other tools).
func writeFloatWav(_ a: DecodedAudio, to url: URL) throws {
    let ch = a.channels.count, n = a.frameCount
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let dataBytes = UInt32(n * ch * 4)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(3); u16(UInt16(ch)); u32(UInt32(a.sampleRate)); u32(UInt32(a.sampleRate) * UInt32(ch * 4)); u16(UInt16(ch * 4)); u16(32)
    d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
    var inter = [Float](repeating: 0, count: n * ch)
    for c in 0..<ch { for i in 0..<n { inter[i * ch + c] = a.channels[c][i] } }
    inter.withUnsafeBytes { d.append(contentsOf: $0) }
    try d.write(to: url)
}

func usage() -> Never {
    print("""
    lyricadder-cli — LyricAdder native port, command line

      info <file.chart|file.mid>                 phrases, lyric event counts and current lyrics
      lyrics <file>                              print the lyrics stored in the file (input box syntax)
      check <file> <lyrics.txt>                  compare lyrics with the file's phrases
      apply <file> <lyrics.txt> [--out <path>] [--backup-dir <dir>]
                                                 write lyrics (chart: overwrite or --out; midi: lyricAdderOutput.mid or --out)
      timing <file>                              print phrase/syllable times in seconds
      decode-audio <audio file> [--wav <out.wav>]
                                                 decode with the app's decoder and print format / duration / peak
      render-frame <file> <seconds> <out.png> [--size WxH] [--scale S]
                                                 render one Metal karaoke frame offscreen
      check-shaders                              compile the Metal shaders on this GPU
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func load(_ path: String) -> LoadedDocument {
    do { return try LoadedDocument.load(url: URL(fileURLWithPath: path)) } catch { fail("error: \(error.localizedDescription)") }
}

func readText(_ path: String) -> String {
    guard let d = FileManager.default.contents(atPath: path), let s = String(data: d, encoding: .utf8) else { fail("error: cannot read \(path)") }
    return s
}

switch cmd {
case "info":
    guard args.count >= 1 else { usage() }
    let doc = load(args[0]).document
    print("name: \(doc.displayName)")
    print("phrases: \(doc.phrases.count)")
    print("lyric events: \(doc.lyricEventCount)")
    print("resolution: \(doc.tempoMap.resolution), tempo changes: \(doc.tempoMap.changes.count)")
    for w in doc.warnings { print("warning: \(w)") }
    for (i, p) in doc.phrases.enumerated() {
        print("phrase \(i + 1) @\(p.startTick)-\(p.endTick.map(String.init) ?? "next") [\(p.syllables.count)]: \(p.syllables.map(\.text).joined(separator: "|"))")
    }

case "lyrics":
    guard args.count >= 1 else { usage() }
    print(load(args[0]).document.lyricsText)

case "check":
    guard args.count >= 2 else { usage() }
    let doc = load(args[0]).document
    let input = LyricInput.parse(readText(args[1]))
    let cmp = LyricComparison(phrases: doc.phrases, input: input)
    print("phrases: file \(cmp.filePhraseCount), input \(cmp.inputPhraseCount)")
    print("lyric events: \(cmp.fileLyricCount), syllables: \(cmp.inputSyllableCount)")
    for r in cmp.rows where !r.matches {
        print("mismatch phrase \(r.phrase): file \(r.fileCount.map(String.init) ?? "-"), input \(r.inputCount.map(String.init) ?? "-")")
    }
    if let p = cmp.problemDescription { print("not writable: \(p)"); exit(1) }
    print("ok: writable")

case "apply":
    let out = option("--out")
    let backupDir = option("--backup-dir")
    guard args.count >= 2 else { usage() }
    let loaded = load(args[0])
    let input = LyricInput.parse(readText(args[1]))
    if let out {
        do {
            let data: Data
            switch loaded {
            case .chart(let c): data = try c.applying(lyrics: input).serialized
            case .midi(let m): data = try m.applying(lyrics: input).serialized
            }
            try data.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        } catch { fail("error: \(error.localizedDescription)") }
    } else {
        let backup = URL(fileURLWithPath: backupDir ?? AppConfig.load().pathToBackupFolder)
        do {
            let r = try loaded.write(lyrics: readText(args[1]), backupFolder: backup)
            print("backup: \(r.backup.path)")
            print("wrote: \(r.written.path)")
        } catch { fail("error: \(error.localizedDescription)") }
    }

case "timing":
    guard args.count >= 1 else { usage() }
    let track = KaraokeTrack(document: load(args[0]).document)
    for (i, p) in track.phrases.enumerated() {
        let syl = p.syllables.map { String(format: "%.3f:%@", $0.time, $0.display) }.joined(separator: " ")
        print(String(format: "phrase %d %.3f-%.3f  ", i + 1, p.start, p.end) + syl)
    }

case "decode-audio":
    let wavOut = option("--wav")
    guard args.count >= 1 else { usage() }
    let start = Date()
    do {
        let a = try AudioDecoder.decode(url: URL(fileURLWithPath: args[0]))
        if let wavOut { try writeFloatWav(a, to: URL(fileURLWithPath: wavOut)) }
        var peak: Float = 0
        for c in a.channels { for x in c { peak = max(peak, abs(x)) } }
        print(String(format: "channels: %d, rate: %.0f, frames: %d, duration: %.3fs, peak: %.4f, decoded in %.2fs",
                     a.channels.count, a.sampleRate, a.frameCount, a.duration, peak, Date().timeIntervalSince(start)))
    } catch { fail("error: \(error.localizedDescription)") }

case "render-frame":
    let sizeArg = option("--size") ?? "1280x720"
    let scale = Double(option("--scale") ?? "1") ?? 1
    guard args.count >= 3, let t = Double(args[1]) else { usage() }
    let dims = sizeArg.split(separator: "x").compactMap { Int($0) }
    guard dims.count == 2 else { usage() }
    let doc = load(args[0]).document
    guard let r = KaraokeRenderer() else { fail("error: Metal is not available") }
    r.setTrack(KaraokeTrack(document: doc))
    r.title = doc.displayName
    guard let img = r.renderImage(width: dims[0], height: dims[1], scale: CGFloat(scale), time: t) else { fail("error: render failed") }
    let url = URL(fileURLWithPath: args[2]) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { fail("error: cannot write png") }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("rendered \(args[2]) on \(r.device.name)")

case "check-shaders":
    guard let r = KaraokeRenderer() else { fail("error: shader compile or Metal init failed") }
    print("ok: karaoke pipeline compiled on \(r.device.name)")

default:
    usage()
}
