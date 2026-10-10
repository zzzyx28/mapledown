import AppKit
import MarkdownEditorKit

/// Pins a source line to the top of the raw editor.
///
/// `MarkdownSourceEditor`'s outline jump reuses the lint-pill path, which calls
/// `scrollRangeToVisible`. That scrolls the minimum distance, so a heading below the
/// fold lands at the bottom of the viewport. The outline's current section is the
/// top visible line, so the bold highlight stays on the previous heading and the
/// jump doesn't read as a jump. This runs after that reveal and puts the line at
/// the top, matching View mode.
enum EditorOutlineJump {
    static func pinLineToTop(_ line: Int, attempt: Int = 0) {
        guard let tv = textView() else {
            if attempt < 2 {
                DispatchQueue.main.async { pinLineToTop(line, attempt: attempt + 1) }
            }
            return
        }
        let source = tv.string as NSString
        let loc = charIndex(forLine: max(0, line), in: source)
        tv.setSelectedRange(NSRange(location: loc, length: 0))
        guard let layout = tv.layoutManager, let container = tv.textContainer,
              let scroll = tv.enclosingScrollView else { return }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: loc, length: 0),
                                        actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let clip = scroll.contentView
        let targetY = max(0, rect.origin.y + tv.textContainerInset.height)
        clip.scroll(to: NSPoint(x: 0, y: targetY))
        scroll.reflectScrolledClipView(clip)
        tv.window?.makeFirstResponder(tv)
    }

    private static func textView() -> MarkdownTextView? {
        if let tv = NSApp.keyWindow?.firstResponder as? MarkdownTextView { return tv }
        for window in NSApp.windows where window.isVisible {
            if let tv = find(in: window.contentView) { return tv }
        }
        return nil
    }

    private static func find(in view: NSView?) -> MarkdownTextView? {
        guard let view else { return nil }
        if let tv = view as? MarkdownTextView { return tv }
        for sub in view.subviews {
            if let found = find(in: sub) { return found }
        }
        return nil
    }

    private static func charIndex(forLine line: Int, in source: NSString) -> Int {
        var index = 0
        var current = 0
        while current < line && index < source.length {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            let next = NSMaxRange(range)
            if next <= index { break }
            index = next
            current += 1
        }
        return min(index, source.length)
    }
}
