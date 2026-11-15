import AppKit
import LyricCore
import LyricRender
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("darkMode") private var darkMode = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.page) {
                ForEach(Page.allCases) { p in
                    Label(p.title, systemImage: p.icon).tag(p)
                }
            }
            .safeAreaInset(edge: .top) {
                Label("Lyrics", systemImage: "captions.bubble.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Dark mode", isOn: $darkMode).toggleStyle(.checkbox)
                    Text("Created by DarkAngel2096\nv\(AppConfig.appVersion) · native Metal port")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.page {
            case .welcome: WelcomeView()
            case .input: LyricInputView()
            case .preview: PreviewView()
            }
        }
        .preferredColorScheme(darkMode ? .dark : nil)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.open(url) } }
            }
            return true
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Welcome to the Lyric Adder").font(.largeTitle.bold())
                Text("A simple program created by DarkAngel2096 — now a native macOS app").foregroundStyle(.secondary)
                Divider()
                Text("Start by reading the text below, then go to **Lyric Input** in the sidebar.")
                Text("This program makes adding lyrics to a .chart file (as created by Moonscraper) a lot easier by automating the insertion of syllables into lyric events.")
                Text("No more selecting the lyric textbox in Moonscraper and removing the text \"lyric \" from it (by complete mistake of course…) or messing up the .chart file itself in a text editor.")
                Text("Write the song's full lyrics into the text box on Lyric Input and select the .chart (or notes.mid) file. You still place the `phrase_start`, `phrase_end` and `lyric` events yourself in the charting program.")
                Text("Every write first stores a backup of the untouched file in the backups folder.")
                HStack {
                    Button("Open .chart or .mid…") { model.showOpenPanel() }.keyboardShortcut("o")
                    Button("Show backups folder") { model.revealBackups() }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(28)
        }
    }
}

struct LyricInputView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Input the lyrics").font(.title.bold())
                Spacer()
                Button("Open .chart / .mid…") { model.showOpenPanel() }
                Button(model.isMidi ? "Read .mid for lyrics" : "Read .chart for lyrics") { model.readLyricsFromFile() }
                    .disabled(model.document == nil)
            }

            if let doc = model.document, let cmp = model.comparison {
                InfoPanel(doc: doc, cmp: cmp)
            } else {
                Text(model.document == nil ? "No .chart or .mid file selected" : "")
                    .foregroundStyle(.red)
            }
            if model.lyrics.isEmpty {
                Text("No lyrics written in the text box below").foregroundStyle(.red).font(.callout)
            }
            if let m = model.message { MessageBanner(message: m) }

            Text("One phrase per line. Separate syllables with spaces, or end a syllable with `-` (joined) or `=` (shown as a hyphen). Empty lines don't matter.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LyricEditor(text: $model.lyrics, statuses: lineStatuses, missing: missingCounts,
                        placeholder: "First phrase on the first line\nSec-ond phrase on sec-ond line\nAnd syl-lab-les get sep-a-rat-ed with dash-es\n\nAl-so an emp-ty line does-n't mat-ter")
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

            HStack {
                Button("Restore lyrics") { model.restoreLyrics() }
                    .help("Last stored lyrics (saved every time the input area changes)")
                Spacer()
                Button(model.isMidi ? "Write new MIDI" : "Write new chart") { model.write() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canWrite)
            }
        }
        .padding(20)
    }

    private var lineStatuses: [Int: LineStatus] {
        guard let cmp = model.comparison else {
            return Dictionary(uniqueKeysWithValues: model.parsedInput.enumerated().map { i, l in
                (l.textLine, LineStatus(phrase: i + 1, input: l.syllables.count, file: l.syllables.count))
            })
        }
        var out: [Int: LineStatus] = [:]
        for r in cmp.rows {
            guard let line = r.textLine else { continue }
            out[line] = LineStatus(phrase: r.phrase, input: r.inputCount ?? 0, file: r.fileCount)
        }
        return out
    }

    private var missingCounts: [Int] {
        model.comparison?.rows.filter { $0.inputCount == nil }.compactMap(\.fileCount) ?? []
    }
}

struct InfoPanel: View {
    @EnvironmentObject var model: AppModel
    let doc: any LyricDocument
    let cmp: LyricComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Selected \(model.isMidi ? "MIDI" : "chart"):", doc.displayName)
                row("Phrases in the file:", "\(cmp.filePhraseCount) phrases found")
                row("Lyric events in the file:", "\(cmp.fileLyricCount) lyric events found")
                row("Syllables in the input area:", "\(cmp.inputSyllableCount) syllables found")
            }
            DisclosureGroup("{phrase number, lyric event count - syllable count}", isExpanded: $model.showPhraseGrid) {
                PhraseGrid(rows: cmp.rows).padding(.top, 4)
            }
            .font(.callout)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.85)).textSelection(.enabled)
        }
    }
}

struct PhraseGrid: View {
    let rows: [LyricComparison.Row]
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 60), spacing: 6), count: 10), alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.phrase) { r in
                Text("{\(r.phrase), \(r.fileCount ?? 0)-\(r.inputCount ?? 0)}")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(r.matches ? Color.green : Color.red)
            }
        }
    }
}

struct MessageBanner: View {
    let message: StatusMessage
    var body: some View {
        let (prefix, color, icon): (String, Color, String) = {
            switch message.kind {
            case .error: return ("Error: ", .red, "exclamationmark.triangle.fill")
            case .notice: return ("Notice: ", .orange, "info.circle.fill")
            case .completed: return ("Completed: ", .green, "checkmark.circle.fill")
            }
        }()
        Label {
            Text(prefix).bold() + Text(message.text)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundStyle(color)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
    }
}

struct PreviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.togglePlay() } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.player.isLoaded)
                Button { model.resetSong() } label: { Label("Reset", systemImage: "backward.end.fill") }
                    .disabled(!model.player.isLoaded)
                Menu("Jump to phrase") {
                    ForEach(Array(model.track.phrases.enumerated()), id: \.offset) { i, p in
                        Button("\(i + 1): \(p.text)") { model.seek(phrase: i) }
                    }
                }
                .frame(maxWidth: 220)
                .disabled(model.track.phrases.isEmpty)
                Toggle("Preview the input box", isOn: $model.previewUsesInput)
                    .help("Show the lyrics typed on Lyric Input for every phrase whose syllable count already matches the file")
                Spacer()
            }
            .padding(10)
            Text(model.audioStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            KaraokeContainer(track: model.track, title: model.document?.displayName ?? "", duration: model.audioDuration)
        }
    }
}

/// Hosts the Metal karaoke view.
struct KaraokeContainer: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    var track: KaraokeTrack
    var title: String
    var duration: Double

    func makeNSView(context: Context) -> NSView {
        guard let v = KaraokeView(karaokeFrame: .zero) else {
            let label = NSTextField(labelWithString: "Metal is not available on this Mac")
            label.alignment = .center
            return label
        }
        let player = model.player
        v.timeSource = { player.currentTime }
        v.onSeek = { [weak model] t in model?.seek(to: t) }
        v.onTogglePlay = { [weak model] in model?.togglePlay() }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let v = view as? KaraokeView else { return }
        v.renderer.setTrack(track)
        v.renderer.title = title
        v.renderer.songDuration = duration
    }
}
