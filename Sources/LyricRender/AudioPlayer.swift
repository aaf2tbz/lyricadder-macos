import AVFoundation
import CStbVorbis
import Foundation

/// Decoded PCM, planar float.
public struct DecodedAudio: Sendable {
    public var sampleRate: Double
    public var channels: [[Float]]
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { Double(frameCount) / sampleRate }
}

public enum AudioDecodeError: LocalizedError {
    case unsupported(String)
    case failed(String)
    public var errorDescription: String? {
        switch self { case .unsupported(let s), .failed(let s): return s }
    }
}

public enum AudioDecoder {
    /// Ogg Vorbis through the vendored stb_vorbis (CoreAudio has no Ogg container support).
    public static func decodeVorbis(url: URL) throws -> DecodedAudio {
        let data = try Data(contentsOf: url)
        var err: Int32 = 0
        let handle: OpaquePointer? = data.withUnsafeBytes { raw in
            lav_vorbis_open_memory(raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), &err)
        }
        guard let v = handle else {
            throw AudioDecodeError.failed("\(url.lastPathComponent): not a Vorbis stream (stb_vorbis error \(err))")
        }
        defer { lav_vorbis_close(v) }
        let ch = Int(lav_vorbis_channels(v))
        let rate = Double(lav_vorbis_sample_rate(v))
        let total = Int(lav_vorbis_length_samples(v))
        var out = [[Float]](repeating: [], count: ch)
        for i in 0..<ch { out[i].reserveCapacity(total) }
        let block = 8192
        var scratch: [UnsafeMutablePointer<Float>?] = (0..<ch).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: block)
            p.initialize(repeating: 0, count: block)
            return p
        }
        defer { scratch.forEach { $0?.deallocate() } }
        while true {
            let n = Int(scratch.withUnsafeMutableBufferPointer { pb in
                lav_vorbis_read_planar(v, Int32(ch), pb.baseAddress, Int32(block))
            })
            if n <= 0 { break }
            for i in 0..<ch { out[i].append(contentsOf: UnsafeBufferPointer(start: scratch[i]!, count: n)) }
        }
        return DecodedAudio(sampleRate: rate, channels: out)
    }

    /// Anything CoreAudio understands (mp3, m4a/aac, wav, aiff, flac, caf …).
    public static func decodeCoreAudio(url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(1, frames)) else {
            throw AudioDecodeError.failed("Could not allocate audio buffer")
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        var out: [[Float]] = []
        if let fd = buf.floatChannelData {
            for c in 0..<Int(fmt.channelCount) { out.append(Array(UnsafeBufferPointer(start: fd[c], count: n))) }
        }
        return DecodedAudio(sampleRate: fmt.sampleRate, channels: out)
    }

    public static func decode(url: URL) throws -> DecodedAudio {
        let ext = url.pathExtension.lowercased()
        if ext == "ogg" || ext == "oga" { return try decodeVorbis(url: url) }
        if ext == "opus" { throw AudioDecodeError.unsupported("\(url.lastPathComponent): Ogg Opus is not supported yet") }
        return try decodeCoreAudio(url: url)
    }

    /// Clone Hero stem names (crowd/preview are left out of the mix).
    static let stemNames: Set<String> = [
        "song", "guitar", "bass", "rhythm", "keys", "vocals", "vocals_1", "vocals_2",
        "drums", "drums_1", "drums_2", "drums_3", "drums_4", "backing",
    ]
    static let audioExtensions: Set<String> = ["ogg", "oga", "mp3", "wav", "flac", "m4a", "aac", "aiff", "aif", "caf"]

    /// Audio files to play for a chart folder. The original picked `song.ogg` (or any .ogg/.mp3);
    /// this mixes every Clone Hero stem so the vocals stem is audible in the preview.
    public static func songFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let audio = items.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let stems = audio.filter { stemNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
        if !stems.isEmpty {
            // One file per stem name (prefer ogg like the original).
            var byName: [String: URL] = [:]
            for u in stems {
                let k = u.deletingPathExtension().lastPathComponent.lowercased()
                if byName[k] == nil || u.pathExtension.lowercased() == "ogg" { byName[k] = u }
            }
            return byName.keys.sorted().map { byName[$0]! }
        }
        let fallback = audio.filter { !["crowd", "preview"].contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
        return fallback.first.map { [$0] } ?? []
    }

    /// Decodes and sums several stems into one stereo track (stems at another sample rate are skipped).
    public static func mix(urls: [URL]) throws -> (audio: DecodedAudio, used: [URL], skipped: [String]) {
        var acc: DecodedAudio?
        var used: [URL] = [], skipped: [String] = []
        for u in urls {
            let d: DecodedAudio
            do { d = try decode(url: u) } catch { skipped.append(error.localizedDescription); continue }
            guard !d.channels.isEmpty else { continue }
            let stereo = d.channels.count == 1 ? [d.channels[0], d.channels[0]] : Array(d.channels.prefix(2))
            if acc == nil {
                acc = DecodedAudio(sampleRate: d.sampleRate, channels: stereo)
            } else if acc!.sampleRate == d.sampleRate {
                for c in 0..<2 {
                    if stereo[c].count > acc!.channels[c].count {
                        acc!.channels[c].append(contentsOf: [Float](repeating: 0, count: stereo[c].count - acc!.channels[c].count))
                    }
                    acc!.channels[c].withUnsafeMutableBufferPointer { dst in
                        stereo[c].withUnsafeBufferPointer { src in
                            for i in 0..<src.count { dst[i] += src[i] }
                        }
                    }
                }
            } else {
                skipped.append("\(u.lastPathComponent): different sample rate")
                continue
            }
            used.append(u)
        }
        guard var mixed = acc else { throw AudioDecodeError.failed("No playable audio found") }
        // Soft-limit the sum so many stems don't clip.
        if used.count > 1 {
            for c in mixed.channels.indices {
                mixed.channels[c].withUnsafeMutableBufferPointer { b in
                    for i in b.indices { let x = b[i]; b[i] = x / (1 + abs(x) * 0.5) * 1.2 }
                }
            }
        }
        return (mixed, used, skipped)
    }
}

/// AVAudioEngine player with seek and a clock suitable for driving a Metal render loop
/// (replaces the `<audio>` element + 1 ms setInterval polling in soundStuff.js).
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var audio: DecodedAudio?
    private var format: AVAudioFormat?
    private var startFrame: Int = 0
    private var generation = 0
    public private(set) var isPlaying = false
    public var onFinished: (() -> Void)?

    public init() {
        engine.attach(node)
    }

    public var duration: Double { audio?.duration ?? 0 }
    public var isLoaded: Bool { audio != nil }

    public func load(_ a: DecodedAudio) {
        stop()
        audio = a
        let fmt = AVAudioFormat(standardFormatWithSampleRate: a.sampleRate, channels: AVAudioChannelCount(a.channels.count))!
        format = fmt
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        startFrame = 0
    }

    /// Current playback position in seconds, compensated for output latency so visuals line up with what is heard.
    public var currentTime: Double {
        guard let a = audio else { return 0 }
        guard isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else {
            return Double(startFrame) / a.sampleRate
        }
        let latency = engine.outputNode.presentationLatency
        let t = Double(startFrame + Int(pt.sampleTime)) / a.sampleRate - latency
        return min(max(0, t), a.duration)
    }

    public func play() {
        guard let a = audio, let fmt = format, !isPlaying else { return }
        if startFrame >= a.frameCount { startFrame = 0 }
        let remaining = a.frameCount - startFrame
        guard remaining > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(remaining)) else { return }
        buf.frameLength = AVAudioFrameCount(remaining)
        for c in 0..<a.channels.count {
            a.channels[c].withUnsafeBufferPointer { src in
                buf.floatChannelData![c].update(from: src.baseAddress! + startFrame, count: remaining)
            }
        }
        do { if !engine.isRunning { try engine.start() } } catch { return }
        generation += 1
        let gen = generation
        node.scheduleBuffer(buf, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.isPlaying else { return }
                self.isPlaying = false
                self.startFrame = self.audio?.frameCount ?? 0
                self.node.stop()
                self.onFinished?()
            }
        }
        node.play()
        isPlaying = true
    }

    public func pause() {
        guard isPlaying, let a = audio else { return }
        let t = currentTime + engine.outputNode.presentationLatency
        startFrame = min(a.frameCount, max(0, Int(t * a.sampleRate)))
        isPlaying = false
        generation += 1
        node.stop()
    }

    public func stop() {
        isPlaying = false
        generation += 1
        node.stop()
        startFrame = 0
    }

    public func seek(to seconds: Double) {
        guard let a = audio else { return }
        let wasPlaying = isPlaying
        if wasPlaying { isPlaying = false; generation += 1; node.stop() }
        startFrame = min(a.frameCount, max(0, Int(seconds * a.sampleRate)))
        if wasPlaying { play() }
    }

    public func toggle() { isPlaying ? pause() : play() }
}
