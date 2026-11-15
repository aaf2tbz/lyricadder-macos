import AppKit
import CoreText
import Metal

/// A line of text rasterized with Core Text into a mipmapped single-channel Metal texture.
public struct TextTexture {
    public var texture: MTLTexture
    /// Size in pixels.
    public var width: Int
    public var height: Int
    /// Pixels per point the texture was rendered at.
    public var scale: CGFloat
    /// Transparent padding around the glyphs, in pixels (room for the glow).
    public var padding: CGFloat
    /// Glyph extent (pixels, texture space) of each piece, trailing whitespace excluded.
    public var starts: [CGFloat]
    public var ends: [CGFloat]

    public var pointSize: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
}

public final class TextRasterizer {
    let device: MTLDevice
    let queue: MTLCommandQueue

    public init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    /// Rasterizes `pieces` (syllables) as one line and records where each piece starts and ends.
    public func make(pieces: [String], pointSize: CGFloat, weight: NSFont.Weight, scale: CGFloat) -> TextTexture? {
        let text = pieces.joined()
        guard !text.isEmpty else { return nil }
        let font = NSFont.systemFont(ofSize: pointSize, weight: weight) as CTFont
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let pad = ceil(pointSize * 0.28 * scale)
        let maxW = device.supportsFamily(.apple3) ? 16384 : 8192
        let pxW = min(maxW, Int(ceil(w * scale + pad * 2)))
        let pxH = Int(ceil((ascent + descent) * scale + pad * 2))
        guard pxW > 0, pxH > 0 else { return nil }

        guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldAntialias(true)
        ctx.textMatrix = .identity
        ctx.scaleBy(x: scale, y: scale)
        ctx.textPosition = CGPoint(x: pad / scale, y: pad / scale + descent)
        CTLineDraw(line, ctx)

        // Where each syllable's glyphs start and end, in texture pixels (trailing spaces excluded so the
        // karaoke wipe doesn't spend time crossing the gap between words).
        var starts: [CGFloat] = [], ends: [CGFloat] = []
        var offset = 0
        for p in pieces {
            let trimmedCount = p.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).utf16.count
            starts.append(pad + CTLineGetOffsetForStringIndex(line, offset, nil) * scale)
            ends.append(pad + CTLineGetOffsetForStringIndex(line, offset + max(trimmedCount, 0), nil) * scale)
            offset += p.utf16.count
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: pxW, height: pxH, mipmapped: true)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, pxW, pxH), mipmapLevel: 0, withBytes: data, bytesPerRow: pxW)
        if tex.mipmapLevelCount > 1, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        return TextTexture(texture: tex, width: pxW, height: pxH, scale: scale, padding: pad, starts: starts, ends: ends)
    }
}
