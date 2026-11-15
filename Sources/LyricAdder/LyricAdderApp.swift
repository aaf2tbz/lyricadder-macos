import AppKit
import SwiftUI

@main
struct LyricAdderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Port of main.js: one 1000x900 window, no menu clutter.
        Window("Lyric Adding Thingy", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 620)
        }
        .defaultSize(width: 1000, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open .chart or .mid…") { model.showOpenPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(model.isMidi ? "Write New MIDI" : "Write New Chart") { model.write() }
                    .keyboardShortcut("s")
                    .disabled(!model.canWrite)
            }
            CommandMenu("Lyrics") {
                Button("Read Lyrics From File") { model.readLyricsFromFile() }.keyboardShortcut("r")
                Button("Restore Lyrics") { model.restoreLyrics() }
                Divider()
                Button("Show Backups Folder") { model.revealBackups() }
            }
            CommandMenu("Playback") {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }.keyboardShortcut(.return, modifiers: .command)
                Button("Reset From Start") { model.resetSong() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` gives an accessory process; make it a regular app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
