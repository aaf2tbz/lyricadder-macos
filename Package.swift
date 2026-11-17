// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyricAdderMetal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LyricAdder", targets: ["LyricAdder"]),
        .executable(name: "lyricadder-cli", targets: ["lyricadder-cli"]),
        .library(name: "LyricCore", targets: ["LyricCore"]),
    ],
    targets: [
        // Pure-Swift port of the original mainScripts.js / midiScripts.js / soundStuff.js logic.
        .target(name: "LyricCore"),

        // Vendored stb_vorbis (public domain / MIT) so Clone Hero .ogg stems play natively.
        // (.opus stems go through CoreAudio's Opus codec; see LyricRender/OpusDecoder.swift.)
        .target(
            name: "CStbVorbis",
            cSettings: [.unsafeFlags(["-O3", "-w"])]
        ),

        // Shared Metal renderer + audio engine (used by the app and by the CLI's offscreen renderer).
        .target(
            name: "LyricRender",
            dependencies: ["LyricCore", "CStbVorbis"]
        ),

        .executableTarget(
            name: "LyricAdder",
            dependencies: ["LyricCore", "LyricRender"]
        ),
        .executableTarget(
            name: "lyricadder-cli",
            dependencies: ["LyricCore", "LyricRender"]
        ),
        .testTarget(
            name: "LyricCoreTests",
            dependencies: ["LyricCore"]
        ),
        .testTarget(
            name: "LyricRenderTests",
            dependencies: ["LyricRender"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
