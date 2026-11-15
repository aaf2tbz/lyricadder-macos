import AppKit
import MetalKit

/// MTKView that draws the karaoke preview every display refresh using the audio clock.
public final class KaraokeView: MTKView, MTKViewDelegate {
    public let renderer: KaraokeRenderer
    /// Supplies the current song time each frame.
    public var timeSource: () -> Double = { 0 }
    public var onSeek: ((Double) -> Void)?
    public var onTogglePlay: (() -> Void)?

    public init?(karaokeFrame frame: CGRect = .zero) {
        guard let r = KaraokeRenderer() else { return nil }
        renderer = r
        super.init(frame: frame, device: r.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = false
        isPaused = false
        framebufferOnly = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let cb = renderer.queue.makeCommandBuffer() else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        renderer.encode(into: pass, commandBuffer: cb, size: drawableSize, scale: scale, time: timeSource())
        cb.present(drawable)
        cb.commit()
    }

    private func drawablePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let sx = drawableSize.width / max(bounds.width, 1), sy = drawableSize.height / max(bounds.height, 1)
        return CGPoint(x: p.x * sx, y: (bounds.height - p.y) * sy)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        seek(event)
    }

    public override func mouseDragged(with event: NSEvent) { seek(event) }

    private func seek(_ event: NSEvent) {
        let p = drawablePoint(event)
        if renderer.timelineRect.contains(p), let t = renderer.timeForTimeline(x: p.x) { onSeek?(t) }
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onTogglePlay?() } else { super.keyDown(with: event) }
    }
}
