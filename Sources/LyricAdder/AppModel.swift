import AppKit
import Combine
import LyricCore
import LyricRender
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case welcome, input, preview
    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .input: return "Lyric Input"
        case .preview: return "Lyric Preview"
        }
    }
    var icon: String {
        switch self {
        case .welcome: return "captions.bubble"
        case .input: return "music.note.list"
        case .preview: return "waveform"
        }
    }
}

struct StatusMessage: Equatable {
    enum Kind { case error, notice, completed }
    var kind: Kind
    var text: String
}

/// App state. Replaces the global variables + DOM updates of mainScripts.js / midiScripts.js / soundStuff.js.
@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page = .welcome
    @Published private(set) var loaded: LoadedDocument?
    @Published var lyrics: String = "" { didSet { if lyrics != oldValue { scheduleRefresh() } } }
    @Published private(set) var parsedInput: [LyricInput.Line] = []
    @Published private(set) var comparison: LyricComparison?
    @Published var message: StatusMessage?
    @Published var showPhraseGrid = false
    @Published var previewUsesInput = true { didSet { rebuildTrack() } }

    @Published private(set) var track = KaraokeTrack(phrases: [])
    @Published private(set) var isPlaying = false
    @Published private(set) var audioStatus = "No audio loaded"
    @Published private(set) var audioDuration: Double = 0

    let player = AudioPlayer()
    private(set) var config: AppConfig
    private var lastModified: Date?
    private var refreshTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        config = AppConfig.load()
        player.onFinished = { [weak self] in self?.isPlaying = false }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadIfModified() }
        })
        if !config.pathToChartFile.isEmpty, FileManager.default.fileExists(atPath: config.pathToChartFile) {
            open(URL(fileURLWithPath: config.pathToChartFile), switchPage: false)
        }
    }

    var document: (any LyricDocument)? { loaded?.document }
    var isMidi: Bool { loaded?.isMidi ?? false }

    // MARK: - Files

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Select the .chart or .mid to modify"
        panel.allowedContentTypes = [.init(filenameExtension: "chart"), .init(filenameExtension: "mid"), .midi].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Port of writePath() + changeFields(): select a file, remember it, load its audio.
    func open(_ url: URL, switchPage: Bool = true) {
        do {
            let doc = try LoadedDocument.load(url: url)
            loaded = doc
            lastModified = modificationDate(url)
            config.pathToChartFile = url.path
            config.save()
            message = doc.document.warnings.first.map { StatusMessage(kind: .error, text: $0) }
            if doc.document.phrases.isEmpty {
                message = StatusMessage(kind: .notice, text: doc.isMidi ? (doc.document.warnings.first ?? "No phrases with lyrics found in PART VOCALS") : "No lyric events found in the chart")
            }
            if switchPage { page = .input }
            refreshNow()
            loadAudio(folder: url.deletingLastPathComponent())
        } catch {
            message = StatusMessage(kind: .error, text: error.localizedDescription)
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The original re-read the chart whenever its mtime changed (e.g. after saving in Moonscraper).
    func reloadIfModified() {
        guard let doc = document, let m = modificationDate(doc.url), m != lastModified else { return }
        if let fresh = try? LoadedDocument.load(url: doc.url) {
            loaded = fresh
            lastModified = m
            refreshNow()
        }
    }

    // MARK: - Lyrics

    private func scheduleRefresh() {
        refreshTask?.cancel()
        // Same 500 ms debounce as the original input handler.
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshNow(saveLyrics: true)
        }
    }

    func refreshNow(saveLyrics: Bool = false) {
        reloadIfModified()
        parsedInput = LyricInput.parse(lyrics)
        if let doc = document {
            comparison = LyricComparison(phrases: doc.phrases, input: parsedInput)
        } else {
            comparison = nil
        }
        if saveLyrics, !lyrics.isEmpty {
            config.lyricsInput = lyrics
            config.save()
        }
        if message?.kind == .completed { message = nil }
        rebuildTrack()
    }

    /// "Read .chart / .mid for lyrics"
    func readLyricsFromFile() {
        guard let doc = document else { return }
        if doc.lyricEventCount == 0 { message = StatusMessage(kind: .notice, text: "No lyric events found in the file"); return }
        let text = doc.lyricsText
        if text.isEmpty { message = StatusMessage(kind: .notice, text: "The lyric events in the file are empty") }
        lyrics = text
        refreshNow()
    }

    /// "Restore lyrics" (last input saved in the config).
    func restoreLyrics() {
        lyrics = config.lyricsInput
        refreshNow()
    }

    var canWrite: Bool { comparison?.isWritable ?? false }

    /// Port of testAndWriteChart() / writeMidiFile().
    func write() {
        guard let loaded else { message = StatusMessage(kind: .error, text: "No .chart or .mid file selected"); return }
        do {
            let r = try loaded.write(lyrics: lyrics, backupFolder: URL(fileURLWithPath: config.pathToBackupFolder))
            self.loaded = r.reloaded
            lastModified = modificationDate(r.reloaded.document.url)
            config.lyricsInput = lyrics
            config.save()
            refreshNow()
            let what = loaded.isMidi ? "Wrote \(r.written.lastPathComponent) next to the original MIDI" : "The original chart has been modified, playtest to make sure everything works!"
            message = StatusMessage(kind: .completed, text: "\(what) (backup: \(r.backup.lastPathComponent))")
        } catch {
            message = StatusMessage(kind: .error, text: error.localizedDescription)
        }
    }

    func revealBackups() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config.pathToBackupFolder)])
    }

    // MARK: - Preview

    func rebuildTrack() {
        guard let doc = document else { track = KaraokeTrack(phrases: []); return }
        track = KaraokeTrack(document: doc, override: previewUsesInput ? parsedInput : nil)
    }

    /// Port of setSongFile(): find the song audio next to the chart.
    func loadAudio(folder: URL) {
        player.stop()
        isPlaying = false
        audioDuration = 0
        let files = AudioDecoder.songFiles(in: folder)
        guard !files.isEmpty else { audioStatus = "No audio (song.ogg / song.opus / *.mp3 …) found next to the file"; return }
        audioStatus = "Decoding \(files.map(\.lastPathComponent).joined(separator: ", "))…"
        audioTask?.cancel()
        audioTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try AudioDecoder.mix(urls: files) } }.value
            guard let model = self, !Task.isCancelled else { return }
            model.applyAudio(result)
        }
    }

    private func applyAudio(_ result: Result<(audio: DecodedAudio, used: [URL], skipped: [String]), Error>) {
        switch result {
        case .success(let r):
            player.load(r.audio)
            audioDuration = r.audio.duration
            var s = "Playing " + r.used.map(\.lastPathComponent).joined(separator: " + ")
            if !r.skipped.isEmpty { s += " (skipped: \(r.skipped.joined(separator: "; ")))" }
            audioStatus = s
        case .failure(let e):
            audioStatus = e.localizedDescription
        }
    }

    func togglePlay() {
        guard player.isLoaded else { return }
        player.toggle()
        isPlaying = player.isPlaying
    }

    func resetSong() {
        player.seek(to: 0)
    }

    func seek(to t: Double) { player.seek(to: t) }

    /// Phrase dropdown: start one second before the phrase like the original.
    func seek(phrase i: Int) {
        guard i >= 0, i < track.phrases.count else { return }
        player.seek(to: max(0, track.phrases[i].start - 1))
    }
}
