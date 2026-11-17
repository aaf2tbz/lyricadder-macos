# Reverse engineering lyricadder v1.2.2

## What was shipped

`lyricadder-public-v.1.2.2/` is a Windows (ia32) **Electron 3.0.2** build: `lyricadder.exe`, Chromium/Node DLLs,
`resources/electron.asar` and the app itself in `resources/app.asar`. No native code of its own: everything
interesting is JavaScript in the ASAR.

## Tools used

```bash
# Unpack the ASAR safely
rea extract-artifact "$PWD/resources/app.asar" --output-root <dir>
# Static reconstruction of the Electron application graph
rea analyze-javascript-application resources/app.asar --detail summary --evidence_output app-evidence.json
```

rea evidence (sha256 of app.asar `fb67444434ecad62ba9e23dddb30ff9b8792caf63f4446359a94fe731cb8c817`):

| Fact | Result |
| --- | --- |
| Files / parsed JS | 155 / 145 (one parse failure: `mainJS/tests.js`, dead code) |
| BrowserWindows | 1 (`main.js`, 1000×900, menu removed) |
| Preload / contextBridge / IPC | none — `nodeIntegration` renderer calling `fs` directly |
| Native addons, protocols, child processes, network requests | none |
| Dependencies | `jquery` 3.4.1, `dataurl` (unused); jQuery UI + Font Awesome from CDNs in `index.html` |

So the whole app is a single renderer page; porting it means porting the renderer scripts.

## Module map

| File | Live? | Role | Native port |
| --- | --- | --- | --- |
| `main.js` | yes | window, creates `../lyricAdder_backups/config.json` relative to CWD, version bump | `AppConfig` (Application Support), `LyricAdderApp` |
| `index.html`, `css/*.css`, `js/ui.js` | yes | sidebar pages, dark-mode toggle (localStorage) | SwiftUI `ContentView` & pages, `@AppStorage("darkMode")` |
| `js/lined.js` | yes | jQuery lined-textarea plugin + mismatch highlight | `LyricEditor` (NSTextView + `LyricGutter` ruler) |
| `mainScripts.js` | yes | .chart read / phrase grouping / syllable parsing / compare / backup / write | `LyricCore/ChartDocument`, `LyricInput`, `LyricModel`, `Workflow` |
| `midiScripts.js` | yes | SMF parser, `PART VOCALS` lyrics, MIDI writer | `LyricCore/MidiDocument` |
| `soundStuff.js` | yes | `<audio>` + 1 ms `setInterval` karaoke preview | `LyricRender` (AVAudioEngine + Metal) |
| `difficultyReducer.js`, `mainJS/*`, `dataGather.js`, `dataSift.js`, `fileFormat.js`, `old*.js` | no (UI commented out / unreferenced) | WIP experiments | not ported |

## Recovered behaviour

* **.chart**: split into `[Section] { … }` blocks. In `[Events]`, keep `phrase_start`, `phrase_end`, `lyric …` and
  `Default` (Moonscraper placeholder = empty lyric). A phrase runs from `phrase_start` to the next `phrase_end` or
  `phrase_start`. A lyric on the same tick as a `phrase_start` but listed before it is moved into that phrase.
  Consecutive phrase markers produce the "Multiple phrase events after one another" error.
* **Input syntax**: one phrase per non-empty line; `-` → `"- "`, `=` → `"= "`, split on spaces, drop `""`, `-`, `=`.
* **Write**: requires equal phrase counts and equal per-phrase counts; writes a backup, replaces
  `E "Default"`/`E "lyric …"` with `E "lyric <syllable>"` in order, overwrites the chart.
* **MIDI**: track named `PART VOCALS`; note 105 on/off = phrase; meta 0x05 = lyric; `#`/`^` = pitchless;
  notes 34–84 = pitches. Output goes to `lyricAdderOutput.mid` beside the source plus a backup.
* **Preview**: merge `B` tempo events with lyric ticks, ticks→seconds, show previous/current/next 3 phrases,
  highlight syllables as their time passes; dropdown seeks to 1 s before a phrase.

## Bugs found in the original (fixed in the port)

| Original | Effect | Port |
| --- | --- | --- |
| Tick→seconds hard-codes 192 ticks/beat | wrong preview timing for any `Resolution ≠ 192` | uses `Resolution` / MIDI division |
| `split("\r\n")` only; trims file | LF charts unreadable; trailing newline lost | detects line ending, keeps BOM + trailing newline |
| MIDI meta/sysex length read as one byte; lyric length written as `text.length` | lyrics > 127 bytes or non-ASCII corrupt the file | VLQ lengths, UTF-8 byte counts |
| Running status mis-parsed | real-world MIDIs lose phrases (fixture: 1 of 2 phrases found) | proper running status |
| Note-off `0x8n` read as phrase *start* | phrases split wrongly | `0x8n` or velocity 0 ends a phrase |
| MIDI writer rebuilds `PART VOCALS` from phrases+lyrics+pitches | overdrive, percussion, text events dropped | in-place splice of lyric events only |
| `+` slide events counted as syllables | users had to type `+` | kept untouched, not counted |
| Backup file name fixed per song | 2nd write overwrites the real original | timestamped backups |
| Windows `\\` path handling, config relative to CWD | breaks outside Windows | `URL`s, Application Support |
| `song.ogg` or last `.ogg/.mp3` only | no vocals stem in preview | mixes all Clone Hero stems |
| Chromium `<audio>` only; `.opus` not looked for | Opus charts (most Clone Hero charts today) have no preview audio | Ogg Opus demuxed and decoded with CoreAudio's Opus codec, also when named `.ogg` |

## Verification

* `scripts/parity_original.js` runs the **original** `mainScripts.js` / `midiScripts.js` in Node's `vm` with DOM shims.
  - chart fixture: original output == port output byte-for-byte (port additionally keeps BOM + final CRLF).
  - MIDI fixture without running status: identical phrases/lyrics; with running status the original fails (bug above).
* `swift test`: 19 tests (syntax, same-tick rules, tempo maps, VLQ, MIDI preservation, note-off, slides, long UTF-8 lyrics,
  Ogg Opus decoding and stem discovery).
* GUI: wrote a chart from the app; backup == original bytes, written chart == CLI == original JS.
* `lyricadder-cli render-frame` renders the Metal preview offscreen; `decode-audio` decodes Vorbis (duration matches CoreAudio)
  and Opus (`--wav` output matches `opusdec --float` within 6e-8, same length, at 2.5–60 ms frame sizes, mono and stereo).
