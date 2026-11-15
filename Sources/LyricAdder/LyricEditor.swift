import AppKit
import LyricCore
import SwiftUI

/// Gutter info for one text line that holds a phrase.
struct LineStatus: Equatable {
    var phrase: Int
    var input: Int
    var file: Int?
    var ok: Bool { file == input }
}

/// Replacement for the jQuery lined-textarea plugin + `#lyrics-status` column of the original:
/// a plain-text editor whose gutter shows the phrase number and `syllables/lyric events` per line,
/// highlighted red when they don't match.
struct LyricEditor: NSViewRepresentable {
    @Binding var text: String
    var statuses: [Int: LineStatus]
    /// Lyric-event counts of file phrases that have no input line yet (shown as `-/n` under the text).
    var missing: [Int]
    var placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        let tv = scroll.documentView as! NSTextView
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        // No wrapping, like the original (`wrap="off"`), so one text line == one phrase.
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text

        let ph = NSTextField(wrappingLabelWithString: placeholder)
        ph.font = tv.font
        ph.textColor = .placeholderTextColor
        ph.isSelectable = false
        ph.frame = NSRect(x: tv.textContainerInset.width + 5, y: tv.textContainerInset.height, width: 600, height: 120)
        ph.isHidden = !text.isEmpty
        tv.addSubview(ph)
        context.coordinator.placeholder = ph

        let ruler = LyricGutter(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        context.coordinator.gutter = ruler
        context.coordinator.textView = tv
        ruler.statuses = statuses
        ruler.missing = missing
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView, let gutter = context.coordinator.gutter else { return }
        if tv.string != text {
            // External change (restore / read from file).
            tv.string = text
            tv.setSelectedRange(NSRange(location: 0, length: 0))
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
        if gutter.statuses != statuses || gutter.missing != missing {
            gutter.statuses = statuses
            gutter.missing = missing
            gutter.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LyricEditor
        weak var textView: NSTextView?
        weak var gutter: LyricGutter?
        weak var placeholder: NSTextField?
        init(_ p: LyricEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            placeholder?.isHidden = !tv.string.isEmpty
            parent.text = tv.string
            gutter?.needsDisplay = true
        }
    }
}

final class LyricGutter: NSRulerView {
    weak var textView: NSTextView?
    var statuses: [Int: LineStatus] = [:]
    var missing: [Int] = []

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 92
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSText.didChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func changed() { needsDisplay = true }

    /// UTF-16 offsets where each text line starts.
    private func lineStarts(_ s: NSString) -> [Int] {
        var starts = [0]
        let n = s.length
        var i = 0
        while i < n {
            if s.character(at: i) == 10 { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    private func line(forChar c: Int, starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= c { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let str = tv.string as NSString
        let starts = lineStarts(str)
        // Text-view y -> gutter y.
        let originY = convert(NSPoint(x: 0, y: tv.textContainerOrigin.y), from: tv).y

        func draw(line: Int, y: CGFloat, height: CGFloat) {
            guard let st = statuses[line] else { return }
            if !st.ok {
                NSColor.systemRed.withAlphaComponent(0.85).setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: height).fill()
            }
            let ty = y + (height - (font.ascender - font.descender)) / 2
            let numColor: NSColor = st.ok ? .secondaryLabelColor : .white
            (String(st.phrase) as NSString).draw(at: NSPoint(x: 6, y: ty), withAttributes: [.font: font, .foregroundColor: numColor])
            let counts = "\(st.input)/\(st.file.map(String.init) ?? "-")" as NSString
            let countColor: NSColor = st.ok ? .systemGreen : .white
            let ca: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: countColor]
            counts.draw(at: NSPoint(x: bounds.width - 8 - counts.size(withAttributes: ca).width, y: ty), withAttributes: ca)
        }

        let glyphRange = lm.glyphRange(forBoundingRect: tv.visibleRect, in: tc)
        var bottom = originY
        var lineHeight: CGFloat = (tv.font.map { lm.defaultLineHeight(for: $0) }) ?? 16
        lm.enumerateLineFragments(forGlyphRange: glyphRange) { r, _, _, gr, _ in
            let c = lm.characterIndexForGlyph(at: gr.location)
            draw(line: self.line(forChar: c, starts: starts), y: originY + r.minY, height: r.height)
            bottom = originY + r.maxY
            lineHeight = r.height
        }
        if lm.extraLineFragmentRect.height > 0 { bottom = originY + lm.extraLineFragmentRect.maxY }
        else if glyphRange.length == 0, str.length > 0 { bottom = originY + lm.usedRect(for: tc).maxY }

        // Phrases in the file with no input line yet: `-/n` like the original status column.
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemRed]
        for (k, n) in missing.enumerated() {
            let y = bottom + CGFloat(k) * lineHeight
            if y > bounds.maxY { break }
            let s = "-/\(n)" as NSString
            s.draw(at: NSPoint(x: bounds.width - 8 - s.size(withAttributes: attrs).width, y: y + 1), withAttributes: attrs)
        }
    }
}
