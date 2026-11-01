import AppKit
import SwiftUI

@MainActor
final class EditorActions: ObservableObject {
    weak var textView: NSTextView?

    func surroundSelection(prefix: String, suffix: String? = nil, placeholder: String = "text") {
        guard let textView else { return }
        let suffix = suffix ?? prefix
        let selectedRange = textView.selectedRange()
        let source = textView.string as NSString
        let selected = selectedRange.length > 0 ? source.substring(with: selectedRange) : placeholder
        let replacement = prefix + selected + suffix
        textView.insertText(replacement, replacementRange: selectedRange)
        textView.setSelectedRange(NSRange(location: selectedRange.location + prefix.utf16.count, length: selected.utf16.count))
    }

    func insertLinePrefix(_ prefix: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let source = textView.string as NSString
        let lineRange = source.lineRange(for: range)
        let text = source.substring(with: lineRange)
        let replacement = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + $0 }
            .joined(separator: "\n")
        textView.insertText(replacement, replacementRange: lineRange)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: replacement.utf16.count))
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let noteID: UUID
    let actions: EditorActions
    let theme: VisualTheme

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, noteID: noteID, theme: theme) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = TaskTextView()
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.onMouseDownCompleted = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.handleSelectionChange(in: textView)
        }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.backgroundColor = .clear
        textView.textColor = theme.nsForeground
        textView.insertionPointColor = theme.nsAccent
        textView.font = Coordinator.bodyFont
        textView.textContainerInset = NSSize(width: 14, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        scrollView.documentView = textView
        actions.textView = textView
        context.coordinator.applyFull(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        actions.textView = textView

        if coordinator.noteID != noteID {
            coordinator.saveViewState(from: textView, in: scrollView)
            coordinator.noteID = noteID
            coordinator.theme = theme
            coordinator.isEditing = false
            coordinator.resetTracking()

            coordinator.performInternalMutation {
                textView.string = text
            }
            textView.undoManager?.removeAllActions()

            let restored = coordinator.restoredViewState(for: noteID, maxLength: (text as NSString).length)
            textView.setSelectedRange(restored.selectedRange)
            coordinator.applyFull(to: textView)

            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, restored.scrollY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        let themeChanged = coordinator.theme != theme
        coordinator.theme = theme

        if !textView.hasMarkedText(), textView.string != text, !coordinator.isSyncingFromEditor {
            let previousSelection = textView.selectedRange()
            coordinator.resetTracking()
            coordinator.performInternalMutation {
                textView.string = text
            }
            let maxLen = (text as NSString).length
            let clampedLoc = min(previousSelection.location, maxLen)
            let clampedLen = min(previousSelection.length, maxLen - clampedLoc)
            textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
            coordinator.applyFull(to: textView)
        } else if themeChanged {
            coordinator.applyFull(to: textView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        struct SavedNoteViewState {
            var selectedRange: NSRange
            var scrollY: CGFloat
        }

        static let bodyFont = NSFont.systemFont(ofSize: 14, weight: .regular)
        static let boldFont = NSFont.boldSystemFont(ofSize: 14)
        static let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)
        static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        static let concealedZeroFont = NSFont.systemFont(ofSize: 0.1, weight: .regular)
        static let headingFonts: [Int: NSFont] = Dictionary(uniqueKeysWithValues: (1...6).map { level in
            (level, NSFont.systemFont(ofSize: CGFloat(max(16, 22 - (level - 1) * 2)), weight: .semibold))
        })

        var text: Binding<String>
        var noteID: UUID
        var theme: VisualTheme
        var isEditing = false
        private(set) var isSyncingFromEditor = false

        private var isApplying = false
        private var pendingDirtyRange: NSRange?
        private var lastActiveLine: NSRange?
        private var savedViewStates: [UUID: SavedNoteViewState] = [:]

        init(text: Binding<String>, noteID: UUID, theme: VisualTheme) {
            self.text = text
            self.noteID = noteID
            self.theme = theme
        }

        func performInternalMutation(_ body: () -> Void) {
            let wasApplying = isApplying
            isApplying = true
            defer { isApplying = wasApplying }
            body()
        }

        func resetTracking() {
            pendingDirtyRange = nil
            lastActiveLine = nil
        }

        func saveViewState(from textView: NSTextView, in scrollView: NSScrollView) {
            savedViewStates[noteID] = SavedNoteViewState(
                selectedRange: textView.selectedRange(),
                scrollY: scrollView.contentView.bounds.origin.y
            )
        }

        func restoredViewState(for id: UUID, maxLength: Int) -> SavedNoteViewState {
            guard let state = savedViewStates[id] else {
                return SavedNoteViewState(selectedRange: NSRange(location: 0, length: 0), scrollY: 0)
            }
            let loc = min(max(0, state.selectedRange.location), maxLength)
            let len = min(max(0, state.selectedRange.length), maxLength - loc)
            return SavedNoteViewState(selectedRange: NSRange(location: loc, length: len), scrollY: state.scrollY)
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard !isApplying, editedMask.contains(.editedCharacters) else { return }
            let totalLength = textStorage.length

            if let existing = pendingDirtyRange {
                let preEditEnd = editedRange.location + editedRange.length - delta
                let start = min(existing.location, editedRange.location)
                let shiftedExistingEnd = NSMaxRange(existing) >= preEditEnd
                    ? max(editedRange.location, NSMaxRange(existing) + delta)
                    : NSMaxRange(existing)
                let end = min(totalLength, max(NSMaxRange(editedRange), shiftedExistingEnd))
                let clampedStart = min(start, end)
                pendingDirtyRange = NSRange(location: clampedStart, length: max(0, end - clampedStart))
            } else {
                pendingDirtyRange = editedRange
            }

            if let oldActive = lastActiveLine {
                let preEditEnd = editedRange.location + editedRange.length - delta
                if preEditEnd <= oldActive.location {
                    let shiftedLoc = max(0, min(totalLength, oldActive.location + delta))
                    let shiftedLen = max(0, min(oldActive.length, totalLength - shiftedLoc))
                    lastActiveLine = NSRange(location: shiftedLoc, length: shiftedLen)
                } else if editedRange.location < NSMaxRange(oldActive) {
                    let mergedStart = min(oldActive.location, pendingDirtyRange?.location ?? oldActive.location)
                    let shiftedOldEnd = max(0, min(totalLength, NSMaxRange(oldActive) + delta))
                    let mergedEnd = max(shiftedOldEnd, pendingDirtyRange.map(NSMaxRange) ?? shiftedOldEnd)
                    pendingDirtyRange = NSRange(location: mergedStart, length: max(0, mergedEnd - mergedStart))
                }
            }
        }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // Preserve native macOS IME marked-text attributes (e.g. Chinese Pinyin pre-edit underline)
            // until composition finishes.
            guard !view.hasMarkedText() else { return }
            syncBinding(from: view)
            applyIncremental(to: view)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            guard let view = notification.object as? NSTextView else { return }
            if view.string != text.wrappedValue {
                syncBinding(from: view)
            }
            applyIncremental(to: view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if (view as? TaskTextView)?.isHandlingMouseDown == true {
                return
            }
            handleSelectionChange(in: view)
        }

        func handleSelectionChange(in view: NSTextView) {
            guard !isApplying, !view.hasMarkedText() else { return }
            let source = view.string as NSString
            let currentActive = MarkdownPresentation.activeLineRange(in: source, selection: view.selectedRange())
            if currentActive == lastActiveLine, pendingDirtyRange == nil {
                return
            }
            applyIncremental(to: view)
        }

        func applyFull(to view: NSTextView) {
            guard !isApplying, !view.hasMarkedText(), let storage = view.textStorage else { return }
            isApplying = true
            defer { isApplying = false }

            let fullText = view.string
            let source = fullText as NSString
            let all = NSRange(location: 0, length: source.length)
            let activeLine = MarkdownPresentation.activeLineRange(in: source, selection: view.selectedRange())

            if all.length > 0 {
                storage.beginEditing()
                styleSpan(all, in: storage, fullText: fullText, source: source, activeLine: activeLine)
                storage.endEditing()
            }

            pendingDirtyRange = nil
            lastActiveLine = activeLine
            updateEditorChrome(on: view)
            view.needsDisplay = true
        }

        func applyIncremental(to view: NSTextView) {
            guard !isApplying, !view.hasMarkedText(), let storage = view.textStorage else { return }
            guard lastActiveLine != nil else {
                applyFull(to: view)
                return
            }

            let fullText = view.string
            let source = fullText as NSString
            let totalLength = source.length
            let newActiveLine = MarkdownPresentation.activeLineRange(in: source, selection: view.selectedRange())

            guard totalLength > 0 else {
                pendingDirtyRange = nil
                lastActiveLine = newActiveLine
                updateEditorChrome(on: view)
                view.needsDisplay = true
                return
            }

            var candidateSpans: [NSRange] = []
            if let dirty = pendingDirtyRange {
                if let clamped = Self.clampedLineRange(for: dirty, in: source) {
                    candidateSpans.append(clamped)
                }
                pendingDirtyRange = nil
            }
            if let oldActive = lastActiveLine, oldActive != newActiveLine {
                if let clampedOld = Self.clampedLineRange(for: oldActive, in: source) {
                    candidateSpans.append(clampedOld)
                }
                if newActiveLine.length > 0 {
                    candidateSpans.append(newActiveLine)
                }
            }

            let mergedSpans = Self.mergeRanges(candidateSpans)
            guard !mergedSpans.isEmpty else {
                lastActiveLine = newActiveLine
                updateEditorChrome(on: view)
                return
            }

            isApplying = true
            defer { isApplying = false }

            storage.beginEditing()
            for span in mergedSpans where span.length > 0 {
                styleSpan(span, in: storage, fullText: fullText, source: source, activeLine: newActiveLine)
            }
            storage.endEditing()

            lastActiveLine = newActiveLine
            updateEditorChrome(on: view)
            invalidateCheckboxGutter(in: view, for: mergedSpans)
        }

        private func syncBinding(from view: NSTextView) {
            guard text.wrappedValue != view.string else { return }
            isSyncingFromEditor = true
            text.wrappedValue = view.string
            isSyncingFromEditor = false
        }

        private func styleSpan(_ span: NSRange, in storage: NSTextStorage, fullText: String, source: NSString, activeLine: NSRange) {
            guard span.length > 0, NSMaxRange(span) <= storage.length else { return }
            // Reset only font and foregroundColor so system IME marked-text underlines and Find indicators stay intact.
            storage.addAttributes([.font: Self.bodyFont, .foregroundColor: theme.nsForeground], range: span)

            let analysis = MarkdownPresentation.analyze(in: fullText, source: source, range: span, activeLine: activeLine)
            for heading in analysis.headings {
                if let font = Self.headingFonts[heading.level] {
                    storage.addAttribute(.font, value: font, range: heading.range)
                }
            }
            for range in analysis.boldRanges {
                storage.addAttribute(.font, value: Self.boldFont, range: range)
            }
            for range in analysis.italicRanges {
                storage.addAttribute(.font, value: Self.italicFont, range: range)
            }
            for range in analysis.codeRanges {
                storage.addAttribute(.font, value: Self.codeFont, range: range)
            }
            for labelRange in analysis.linkLabelRanges {
                storage.addAttribute(.foregroundColor, value: theme.nsAccent, range: labelRange)
            }
            for marker in analysis.markers {
                conceal(marker.range, in: storage, preserveWidth: marker.preserveWidth)
            }
        }

        private func conceal(_ range: NSRange, in storage: NSTextStorage, preserveWidth: Bool) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.addAttributes([
                .font: preserveWidth ? Self.bodyFont : Self.concealedZeroFont,
                .foregroundColor: NSColor.clear
            ], range: range)
        }

        private func updateEditorChrome(on view: NSTextView) {
            (view as? TaskTextView)?.checkboxColor = theme.nsForeground
            if view.insertionPointColor != theme.nsAccent {
                view.insertionPointColor = theme.nsAccent
            }
            view.typingAttributes = [.font: Self.bodyFont, .foregroundColor: theme.nsForeground]
        }

        private func invalidateCheckboxGutter(in view: NSTextView, for spans: [NSRange]) {
            guard let manager = view.layoutManager, let container = view.textContainer else {
                view.needsDisplay = true
                return
            }
            let gutterWidth = view.textContainerOrigin.x + 24
            for span in spans where span.length > 0 {
                let glyphs = manager.glyphRange(forCharacterRange: span, actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
                let gutterRect = NSRect(
                    x: 0,
                    y: view.textContainerOrigin.y + rect.minY - 4,
                    width: gutterWidth,
                    height: rect.height + 8
                )
                view.setNeedsDisplay(gutterRect)
            }
        }

        private static func clampedLineRange(for range: NSRange, in source: NSString) -> NSRange? {
            guard source.length > 0 else { return nil }
            let loc = min(max(0, range.location), source.length)
            let len = min(max(0, range.length), source.length - loc)
            let expanded = source.lineRange(for: NSRange(location: loc, length: len))
            return expanded.length > 0 ? expanded : nil
        }

        private static func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
            let nonEmpty = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
            guard var current = nonEmpty.first else { return [] }
            var merged: [NSRange] = []
            merged.reserveCapacity(nonEmpty.count)
            for next in nonEmpty.dropFirst() {
                if next.location <= NSMaxRange(current) {
                    let end = max(NSMaxRange(current), NSMaxRange(next))
                    current = NSRange(location: current.location, length: end - current.location)
                } else {
                    merged.append(current)
                    current = next
                }
            }
            merged.append(current)
            return merged
        }
    }
}

final class TaskTextView: NSTextView {
    var checkboxColor: NSColor = .labelColor
    private(set) var isHandlingMouseDown = false
    var onMouseDownCompleted: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let container = textContainer, let manager = layoutManager {
            let source = string as NSString
            if source.length > 0 {
                let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
                if local.x >= -2, local.x <= 24 {
                    let glyph = manager.glyphIndex(for: local, in: container)
                    let index = min(manager.characterIndexForGlyph(at: glyph), source.length)
                    let activeLine = MarkdownPresentation.activeLineRange(in: source, selection: selectedRange())
                    let clickedLine = MarkdownPresentation.activeLineRange(in: source, selection: NSRange(location: index, length: 0))
                    let isInactiveTaskLine = NSIntersectionRange(clickedLine, activeLine).length == 0
                        && clickedLine.location != activeLine.location
                    if isInactiveTaskLine, let toggle = MarkdownPresentation.taskToggle(in: string, at: index) {
                        insertText(toggle.replacement, replacementRange: toggle.range)
                        return
                    }
                }
            }
        }

        isHandlingMouseDown = true
        super.mouseDown(with: event)
        isHandlingMouseDown = false
        onMouseDownCompleted?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let checkboxMaxX = textContainerOrigin.x + 20
        guard dirtyRect.minX <= checkboxMaxX,
              let manager = layoutManager,
              let container = textContainer else { return }

        let source = string as NSString
        guard source.length > 0 else { return }

        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphs = manager.glyphRange(forBoundingRectWithoutAdditionalLayout: containerRect, in: container)
        guard visibleGlyphs.length > 0 else { return }
        let visibleCharacters = manager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let scanRange = source.lineRange(for: visibleCharacters)
        guard scanRange.length > 0 else { return }

        let activeLine = MarkdownPresentation.activeLineRange(in: source, selection: selectedRange())
        let strokeColor = checkboxColor.withAlphaComponent(0.8)

        source.enumerateSubstrings(in: scanRange, options: .byLines) { line, range, enclosingRange, _ in
            guard let line, let completed = MarkdownPresentation.taskCompleted(in: line) else { return }
            let isInactiveLine = NSIntersectionRange(enclosingRange, activeLine).length == 0
                && enclosingRange.location != activeLine.location
            guard isInactiveLine else { return }

            let glyph = manager.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
            let box = NSRect(
                x: self.textContainerOrigin.x + 1,
                y: self.textContainerOrigin.y + fragment.minY + 1,
                width: 13,
                height: 13
            )
            guard dirtyRect.intersects(box) else { return }

            let shape = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            strokeColor.setStroke()
            shape.lineWidth = 1.4
            shape.stroke()
            if completed {
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6, y: box.minY + 3))
                check.line(to: NSPoint(x: box.maxX - 2, y: box.maxY - 3))
                check.lineWidth = 1.4
                check.stroke()
            }
        }
    }
}
