import AppKit
import LyricCore
import Metal
import simd

/// GPU layout of one quad; must match `struct Quad` in the shader.
struct QuadInstance {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var color2: SIMD4<Float>
    var p0: SIMD4<Float>   // wipe px, corner radius, mode, opacity
    var p1: SIMD4<Float>   // wipe softness, glow, glow mip bias, unused
}

struct Globals {
    var viewport: SIMD2<Float>
    var time: Float
    var pad: Float = 0
}

/// Metal port of the "Lyric Preview" page (soundStuff.js): the previous phrase, the current phrase with a
/// per-syllable karaoke wipe, the next three phrases, and a song timeline. Replaces the DOM + 1 ms setInterval
/// polling with a frame-synchronized render driven by the audio clock.
public final class KaraokeRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let blank: MTLTexture
    let rasterizer: TextRasterizer

    public private(set) var track = KaraokeTrack(phrases: [])
    public var title: String = ""
    public var songDuration: Double = 0
    public var emptyMessage = "Open a .chart or .mid on the Lyric Input page"

    // Theme (taken from the original dark-mode palette: orange highlight on a dark background).
    public var highlight = SIMD4<Float>(1.0, 0.62, 0.12, 1)
    public var baseText = SIMD4<Float>(0.93, 0.93, 0.96, 1)
    public var bgTop = SIMD4<Float>(0.07, 0.07, 0.10, 1)
    public var bgBottom = SIMD4<Float>(0.02, 0.02, 0.035, 1)

    private var phraseTextures: [Int: TextTexture] = [:]
    private var textCache: [String: TextTexture] = [:]
    private var textCacheOrder: [String] = []
    private var cachedScale: CGFloat = 0

    private var scroll: Double = 0
    private var lastFrameTime: CFTimeInterval = 0

    /// Pixel rect of the timeline from the last frame (for hit testing clicks).
    public private(set) var timelineRect: CGRect = .zero
    public var timelineDuration: Double { max(songDuration, track.duration + 2, 1) }

    static let mainPointSize: CGFloat = 54

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: karaokeShaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.label = "Karaoke quads"
            d.vertexFunction = lib.makeFunction(name: "quad_vertex")
            d.fragmentFunction = lib.makeFunction(name: "quad_fragment")
            let ca = d.colorAttachments[0]!
            ca.pixelFormat = pixelFormat
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("Karaoke shader compile failed: \(error)")
            return nil
        }
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.sAddressMode = .clampToZero
        sd.tAddressMode = .clampToZero
        guard let s = device.makeSamplerState(descriptor: sd) else { return nil }
        sampler = s
        let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        guard let b = device.makeTexture(descriptor: bd) else { return nil }
        var zero: UInt8 = 0
        b.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        blank = b
        rasterizer = TextRasterizer(device: device, queue: queue)
    }

    public func setTrack(_ t: KaraokeTrack) {
        if t != track {
            track = t
            phraseTextures.removeAll()
        }
    }

    // MARK: - Text

    private func phraseTexture(_ i: Int, scale: CGFloat) -> TextTexture? {
        if let t = phraseTextures[i] { return t }
        let pieces = track.phrases[i].syllables.map(\.display)
        guard let t = rasterizer.make(pieces: pieces, pointSize: Self.mainPointSize, weight: .bold, scale: scale) else { return nil }
        phraseTextures[i] = t
        // Keep memory bounded on very long songs.
        if phraseTextures.count > 48 {
            for k in phraseTextures.keys where abs(k - i) > 12 { phraseTextures.removeValue(forKey: k) }
        }
        return t
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight, scale: CGFloat) -> TextTexture? {
        let key = "\(size)|\(weight.rawValue)|\(s)"
        if let t = textCache[key] { return t }
        guard let t = rasterizer.make(pieces: [s], pointSize: size, weight: weight, scale: scale) else { return nil }
        textCache[key] = t
        textCacheOrder.append(key)
        if textCacheOrder.count > 32 { textCache.removeValue(forKey: textCacheOrder.removeFirst()) }
        return t
    }

    static func clock(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: - Frame

    /// Encodes one frame. `time` is the song position; `size` the drawable size in pixels.
    public func encode(into pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, size: CGSize, scale: CGFloat, time: Double, animate: Bool = true) {
        if scale != cachedScale {
            phraseTextures.removeAll(); textCache.removeAll(); textCacheOrder.removeAll()
            cachedScale = scale
        }
        let W = Float(size.width), H = Float(size.height), S = Float(scale)
        var solids: [QuadInstance] = []
        var texts: [(QuadInstance, MTLTexture)] = []

        // Background.
        solids.append(QuadInstance(rect: [0, 0, W, H], color: bgTop, color2: bgBottom, p0: [0, 0, 2, 1], p1: .zero))

        func addText(_ t: TextTexture, x: Float, y: Float, scaleBy k: Float, base: SIMD4<Float>, hi: SIMD4<Float>,
                     wipePx: Float, opacity: Float, glow: Float) {
            let w = Float(t.width) * k, h = Float(t.height) * k
            let q = QuadInstance(rect: [x, y, w, h], color: base, color2: hi,
                                 p0: [wipePx * k, 0, 1, opacity], p1: [max(1.5 * S * k, 1), glow, 2.5, 0])
            texts.append((q, t.texture))
        }

        // Title and clock.
        let margin = 24 * S
        if !title.isEmpty, let t = label(title, size: 15, weight: .semibold, scale: scale) {
            addText(t, x: margin - Float(t.padding), y: margin - Float(t.padding), scaleBy: 1, base: [0.75, 0.75, 0.8, 1], hi: .zero, wipePx: 0, opacity: 1, glow: 0)
        }
        let clock = "\(Self.clock(time)) / \(Self.clock(timelineDuration))"
        if let t = label(clock, size: 13, weight: .medium, scale: scale) {
            addText(t, x: W - margin - Float(t.width) + Float(t.padding), y: margin - Float(t.padding), scaleBy: 1, base: [0.6, 0.6, 0.66, 1], hi: .zero, wipePx: 0, opacity: 1, glow: 0)
        }

        let phrases = track.phrases
        if phrases.isEmpty {
            if let t = label(emptyMessage, size: 18, weight: .medium, scale: scale) {
                addText(t, x: (W - Float(t.width)) / 2, y: (H - Float(t.height)) / 2, scaleBy: 1, base: [0.6, 0.6, 0.66, 1], hi: .zero, wipePx: 0, opacity: 1, glow: 0)
            }
        } else {
            // Which phrase is in focus; animate the scroll toward it.
            let idx = track.phraseIndex(at: time)
            var target = Double(max(0, idx))
            if idx >= 0, idx + 1 < phrases.count {
                // Glide toward the next phrase during the last moments before it starts.
                let next = phrases[idx + 1].start
                let lead = 0.35
                if time > phrases[idx].end, time > next - lead { target += min(1, (time - (next - lead)) / lead) * 0.999 }
            }
            let now = CACurrentMediaTime()
            let dt = lastFrameTime == 0 ? 1 : min(0.25, now - lastFrameTime)
            lastFrameTime = now
            if !animate || abs(target - scroll) > 3 { scroll = target } else { scroll += (target - scroll) * (1 - exp(-dt * 14)) }

            let centerY = H * 0.42
            let mainGap = Float(Self.mainPointSize) * 1.25 * S
            let smallGap = Float(Self.mainPointSize) * 0.78 * S
            let maxWidth = W - 2 * 56 * S
            let lo = max(0, Int(floor(scroll - 1.6))), hi = min(phrases.count - 1, Int(ceil(scroll + 3.6)))
            if lo <= hi {
                for i in lo...hi {
                    let d = Float(Double(i) - scroll)
                    guard d > -1.6, d < 3.6, let t = phraseTexture(i, scale: scale) else { continue }
                    let ad = abs(d)
                    var k: Float = 0.52 + 0.48 * max(0, 1 - ad)
                    let fit = maxWidth / max(1, Float(t.width) - 2 * Float(t.padding))
                    k = min(k, fit)
                    let offset = (d < 0 ? -1 : 1) * (min(ad, 1) * mainGap + max(ad - 1, 0) * smallGap)
                    let h = Float(t.height) * k
                    let y = centerY + offset - h / 2
                    let x = (W - Float(t.width) * k) / 2
                    // Previous phrase stays visible but dim (the original's `oldLyrics`), the next three fade out.
                    var opacity: Float
                    if d < 0 {
                        opacity = ad < 1 ? 1 - 0.55 * ad : 0.45 * max(0, (1.6 - ad) / 0.6)
                    } else {
                        opacity = ad < 1 ? 1 - 0.4 * ad : max(0, 0.6 - 0.13 * (ad - 1))
                        if d > 2.6 { opacity *= max(0, 3.6 - d) }
                    }
                    // Wipe position from the syllable timing.
                    let prog = track.progress(phrase: i, at: time)
                    let n = phrases[i].syllables.count
                    let whole = min(n, Int(prog))
                    var wipe: Float
                    if prog >= Double(n) {
                        wipe = Float(t.ends[n - 1]) + Float(t.padding)
                    } else if prog <= 0 {
                        wipe = Float(t.starts[0]) - 4
                    } else {
                        let frac = CGFloat(prog - Double(whole))
                        wipe = frac <= 0 && whole > 0
                            ? Float(t.ends[whole - 1])
                            : Float(t.starts[whole] + (t.ends[whole] - t.starts[whole]) * frac)
                    }
                    let focus = max(0, 1 - ad)
                    let base = SIMD4<Float>(baseText.x, baseText.y, baseText.z, 0.55 + 0.45 * focus)
                    let hiColor = d < -0.5 ? SIMD4<Float>(highlight.x * 0.8, highlight.y * 0.8, highlight.z * 0.8, 0.9) : highlight
                    addText(t, x: x, y: y, scaleBy: k, base: base, hi: hiColor, wipePx: wipe, opacity: opacity, glow: 0.55 * focus)
                }
            }

            // Lead-in dots when the next phrase is coming up after a gap (count-in, 3 → 1).
            let upcoming = idx + 1
            if upcoming < phrases.count {
                let gapStart = idx >= 0 ? phrases[idx].end : 0
                let untilNext = phrases[upcoming].start - time
                if untilNext > 0, untilNext <= 3, phrases[upcoming].start - gapStart > 3.5 {
                    let dots = Int(ceil(untilNext))
                    for k in 0..<3 {
                        let on = k < dots
                        let r = 7 * S
                        let x = W / 2 + Float(k - 1) * 22 * S - r
                        solids.append(QuadInstance(rect: [x, centerY - mainGap * 0.95 - r, r * 2, r * 2],
                                                   color: on ? highlight : [1, 1, 1, 0.12], color2: .zero, p0: [0, r, 0, 1], p1: .zero))
                    }
                }
            }
        }

        // Timeline: one segment per phrase, playhead, progress.
        let tlX = 40 * S, tlW = W - 80 * S, tlY = H - 44 * S, tlH = 6 * S
        timelineRect = CGRect(x: CGFloat(tlX), y: CGFloat(tlY - 14 * S), width: CGFloat(tlW), height: CGFloat(tlH + 28 * S))
        let dur = timelineDuration
        solids.append(QuadInstance(rect: [tlX, tlY, tlW, tlH], color: [1, 1, 1, 0.07], color2: .zero, p0: [0, tlH / 2, 0, 1], p1: .zero))
        let cur = track.phraseIndex(at: time)
        for (i, p) in phrases.enumerated() {
            let x0 = tlX + tlW * Float(p.start / dur), x1 = tlX + tlW * Float(min(p.end, dur) / dur)
            let col: SIMD4<Float>
            if i == cur && time <= p.end + 0.01 { col = highlight }
            else if p.end < time { col = SIMD4<Float>(highlight.x, highlight.y, highlight.z, 0.45) }
            else { col = [1, 1, 1, 0.28] }
            solids.append(QuadInstance(rect: [x0, tlY, max(x1 - x0, 2 * S), tlH], color: col, color2: .zero, p0: [0, tlH / 2, 0, 1], p1: .zero))
        }
        let px = tlX + tlW * Float(min(max(time / dur, 0), 1))
        let r = 7 * S
        solids.append(QuadInstance(rect: [px - r, tlY + tlH / 2 - r, r * 2, r * 2], color: [1, 1, 1, 0.95], color2: .zero, p0: [0, r, 0, 1], p1: .zero))

        // Upload & draw: all solids in one instanced call, then one call per text texture.
        let all = solids + texts.map(\.0)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let buf = device.makeBuffer(bytes: all, length: MemoryLayout<QuadInstance>.stride * all.count, options: .storageModeShared)
        else { return }
        var g = Globals(viewport: [W, H], time: Float(time))
        enc.label = "Karaoke"
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 0)
        enc.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 0)
        enc.setVertexBuffer(buf, offset: 0, index: 1)
        enc.setFragmentBuffer(buf, offset: 0, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentTexture(blank, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: solids.count, baseInstance: 0)
        for (n, item) in texts.enumerated() {
            enc.setFragmentTexture(item.1, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1, baseInstance: solids.count + n)
        }
        enc.endEncoding()
    }

    /// Converts a click x position (pixels) on the timeline to a song time.
    public func timeForTimeline(x: CGFloat) -> Double? {
        guard timelineRect.width > 0 else { return nil }
        let f = (x - timelineRect.minX) / timelineRect.width
        return Double(min(max(f, 0), 1)) * timelineDuration
    }

    // MARK: - Offscreen (CLI verification / thumbnails)

    /// Renders one frame offscreen and returns it as a CGImage.
    public func renderImage(width: Int, height: Int, scale: CGFloat, time: Double) -> CGImage? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        encode(into: pass, commandBuffer: cb, size: CGSize(width: width, height: height), scale: scale, time: time, animate: false)
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
