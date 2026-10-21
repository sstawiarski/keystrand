import AppKit

/// Line-number gutter for a TextKit 1 `NSTextView`, with optional "command start" markers.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    var lineStarts: [Int] = [0] {
        didSet { updateThickness() }
    }

    var commandLines: Set<Int> = [] {
        didSet { if oldValue != commandLines { needsDisplay = true } }
    }

    var showsCommandMarkers = false {
        didSet { updateThickness() }
    }

    var font: NSFont = EditorAppearance.font(size: 11) {
        didSet { updateThickness() }
    }

    private let minimumDigits = 4

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private var markerWidth: CGFloat { showsCommandMarkers ? 12 : 0 }

    private func updateThickness() {
        let digits = max(minimumDigits, String(lineStarts.count).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = ceil(sample.size(withAttributes: [.font: font]).width) + 12 + markerWidth
        if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        EditorAppearance.nsBackground.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        let textLength = textView.textStorage?.length ?? 0
        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let caretLine = CodeEditorText.lineIndex(forOffset: textView.selectedRange().location, lineStarts: lineStarts)
        let originY = convert(NSPoint.zero, from: textView).y + textView.textContainerOrigin.y

        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: EditorAppearance.gutterText]
        let active: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: EditorAppearance.gutterActiveText]
        let markerColor = EditorAppearance.commandMarker

        var lineIndex = CodeEditorText.lineIndex(forOffset: charRange.location, lineStarts: lineStarts)
        while lineIndex < lineStarts.count {
            let start = lineStarts[lineIndex]
            if start > NSMaxRange(charRange) { break }
            var fragmentRect: NSRect
            if start >= textLength {
                fragmentRect = layoutManager.extraLineFragmentRect
                if fragmentRect.isEmpty && textLength > 0 { break }
            } else {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
                fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }

            let y = fragmentRect.minY + originY
            let label = "\(lineIndex + 1)" as NSString
            let attributes = lineIndex == caretLine ? active : normal
            let size = label.size(withAttributes: attributes)
            let lineHeight = fragmentRect.height > 0 ? fragmentRect.height : size.height
            let labelY = y + (lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6 - markerWidth, y: labelY), withAttributes: attributes)
            if showsCommandMarkers, commandLines.contains(lineIndex) {
                drawMarker(at: NSPoint(x: ruleThickness - markerWidth - 2, y: y + lineHeight / 2), color: markerColor)
            }

            lineIndex += 1
        }
    }

    private func drawMarker(at center: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + 2, y: center.y - 4))
        path.line(to: NSPoint(x: center.x + 9, y: center.y))
        path.line(to: NSPoint(x: center.x + 2, y: center.y + 4))
        path.close()
        color.withAlphaComponent(0.7).setFill()
        path.fill()
    }
}
