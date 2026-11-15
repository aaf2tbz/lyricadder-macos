// Draws the app icon (a closed-caption badge with a karaoke-wipe "Ly") into an .iconset folder.
// Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.17, alpha: 1),
               ending: NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.06, alpha: 1))!.draw(in: path, angle: -90)
    let font = NSFont.systemFont(ofSize: s * 0.36, weight: .heavy)
    let text = NSAttributedString(string: "Ly", attributes: [.font: font, .foregroundColor: NSColor.white])
    let size = text.size()
    let origin = NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2 + s * 0.04)
    text.draw(at: origin)
    // Karaoke wipe: re-draw the left part in orange.
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: origin.x + size.width * 0.55, height: s)).addClip()
    NSAttributedString(string: "Ly", attributes: [.font: font, .foregroundColor: NSColor(calibratedRed: 1, green: 0.62, blue: 0.12, alpha: 1)]).draw(at: origin)
    NSGraphicsContext.current?.restoreGraphicsState()
    // Timeline bar.
    let bar = NSRect(x: s * 0.24, y: s * 0.24, width: s * 0.52, height: max(1, s * 0.035))
    NSColor(white: 1, alpha: 0.18).setFill()
    NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    NSColor(calibratedRed: 1, green: 0.62, blue: 0.12, alpha: 1).setFill()
    var done = bar; done.size.width *= 0.55
    NSBezierPath(roundedRect: done, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
