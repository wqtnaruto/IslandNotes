import AppKit
import SwiftUI

@MainActor
final class EditorActions: ObservableObject {
    weak var textView: NSTextView?
    var urlPasteboard: NSPasteboard? = .general

    func focusEditor() {
        guard let textView, let window = textView.window else { return }
        if window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    func surroundSelection(prefix: String, suffix: String? = nil, placeholder: String? = nil) {
        guard let textView else { return }
        focusEditor()

        let resolvedSuffix = suffix ?? Self.defaultSuffix(for: prefix)
        let selectedRange = textView.selectedRange()
        let fullText = textView.string
        let source = fullText as NSString
        let targetKind = Self.inlineKind(forPrefix: prefix, suffix: resolvedSuffix)

        let analysis = MarkdownPresentation.analyzeLine(in: fullText, source: source, at: selectedRange.location)

        if selectedRange.length > 0 {
            if let span = analysis.inlineSpans.first(where: {
                ($0.innerRange == selectedRange || $0.fullRange == selectedRange)
                    && Self.matchesToggle(spanKind: $0.kind, targetKind: targetKind)
            }) {
                unwrapSpan(span, forTarget: targetKind, in: textView, source: source, keepInnerSelected: true)
                return
            }

            let selectedText = source.substring(with: selectedRange)
            if selectedText.hasPrefix(prefix), selectedText.hasSuffix(resolvedSuffix),
               selectedText.utf16.count > prefix.utf16.count + resolvedSuffix.utf16.count {
                let innerLen = selectedText.utf16.count - prefix.utf16.count - resolvedSuffix.utf16.count
                let inner = (selectedText as NSString).substring(with: NSRange(location: prefix.utf16.count, length: innerLen))
                replaceText(in: textView, range: selectedRange, with: inner, newSelection: NSRange(location: selectedRange.location, length: inner.utf16.count))
                return
            }

            let pLen = prefix.utf16.count
            let sLen = resolvedSuffix.utf16.count
            if selectedRange.location >= pLen, NSMaxRange(selectedRange) + sLen <= source.length {
                let beforeRange = NSRange(location: selectedRange.location - pLen, length: pLen)
                let afterRange = NSRange(location: NSMaxRange(selectedRange), length: sLen)
                let isPartOfBoldPair = prefix == "*"
                    && analysis.inlineSpans.contains(where: { $0.kind == .bold && $0.innerRange == selectedRange })
                if !isPartOfBoldPair,
                   source.substring(with: beforeRange) == prefix,
                   source.substring(with: afterRange) == resolvedSuffix {
                    let fullRange = NSRange(location: beforeRange.location, length: pLen + selectedRange.length + sLen)
                    replaceText(in: textView, range: fullRange, with: selectedText, newSelection: NSRange(location: beforeRange.location, length: selectedRange.length))
                    return
                }
            }

            let effectiveSuffix = prefix == "[" ? linkSuffix() : resolvedSuffix
            let replacement = prefix + selectedText + effectiveSuffix
            replaceText(
                in: textView,
                range: selectedRange,
                with: replacement,
                newSelection: NSRange(location: selectedRange.location + prefix.utf16.count, length: selectedText.utf16.count)
            )
            return
        }

        // Empty selection: if caret sits inside or on the boundary of an existing matching span, toggle it off.
        if let span = analysis.inlineSpans.first(where: {
            $0.innerRange.location <= selectedRange.location
                && selectedRange.location <= NSMaxRange($0.innerRange)
                && Self.matchesToggle(spanKind: $0.kind, targetKind: targetKind)
        }) {
            unwrapSpan(span, forTarget: targetKind, in: textView, source: source, keepInnerSelected: false)
            return
        }

        let resolvedPlaceholder = placeholder ?? Self.defaultPlaceholder(for: targetKind)
        let effectiveSuffix = prefix == "[" ? linkSuffix() : resolvedSuffix
        let replacement = prefix + resolvedPlaceholder + effectiveSuffix
        replaceText(
            in: textView,
            range: selectedRange,
            with: replacement,
            newSelection: NSRange(location: selectedRange.location + prefix.utf16.count, length: resolvedPlaceholder.utf16.count)
        )
    }

    func insertLinePrefix(_ prefix: String) {
        guard let textView else { return }
        focusEditor()

        let range = textView.selectedRange()
        let source = textView.string as NSString
        let lineRange = source.lineRange(for: range)
        let rawSlice = source.substring(with: lineRange)

        let trailingNewline: String
        let body: String
        if rawSlice.hasSuffix("\r\n") {
            trailingNewline = "\r\n"
            body = String(rawSlice.dropLast(2))
        } else if rawSlice.hasSuffix("\n") {
            trailingNewline = "\n"
            body = String(rawSlice.dropLast())
        } else {
            trailingNewline = ""
            body = rawSlice
        }

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let transformedLines: [String]

        if prefix == "- [ ] " {
            let allHaveTask = !lines.isEmpty && lines.allSatisfy { MarkdownPresentation.taskInfo(in: $0) != nil }
            if allHaveTask {
                transformedLines = lines.map { Self.removingTaskMarker(from: $0) }
            } else {
                transformedLines = lines.map { Self.applyingTaskPrefix(to: $0) }
            }
        } else if let targetHeadingLevel = MarkdownPresentation.headingLevel(in: prefix + "x") {
            let allHaveTargetHeading = !lines.isEmpty && lines.allSatisfy { MarkdownPresentation.headingLevel(in: $0) == targetHeadingLevel }
            if allHaveTargetHeading {
                transformedLines = lines.map { String($0.dropFirst(targetHeadingLevel + 1)) }
            } else {
                transformedLines = lines.map { Self.applyingHeadingPrefix(prefix, to: $0) }
            }
        } else {
            let allHavePrefix = !lines.isEmpty && lines.allSatisfy { $0.hasPrefix(prefix) }
            if allHavePrefix {
                transformedLines = lines.map { String($0.dropFirst(prefix.count)) }
            } else {
                transformedLines = lines.map { $0.hasPrefix(prefix) ? $0 : prefix + $0 }
            }
        }

        let transformedBody = transformedLines.joined(separator: "\n")
        let replacement = transformedBody + trailingNewline
        guard replacement != rawSlice else { return }

        let bodyUTF16Count = transformedBody.utf16.count
        let newSelection: NSRange
        if range.length == 0, lines.count == 1 {
            let delta = bodyUTF16Count - body.utf16.count
            let newCursor = min(
                lineRange.location + bodyUTF16Count,
                max(lineRange.location, range.location + delta)
            )
            newSelection = NSRange(location: newCursor, length: 0)
        } else {
            newSelection = NSRange(location: lineRange.location, length: bodyUTF16Count)
        }

        replaceText(in: textView, range: lineRange, with: replacement, newSelection: newSelection)
    }

    private func replaceText(in textView: NSTextView, range: NSRange, with replacement: String, newSelection: NSRange) {
        (textView as? TaskTextView)?.performProgrammaticEdit {
            textView.insertText(replacement, replacementRange: range)
            textView.setSelectedRange(newSelection)
        } ?? {
            textView.insertText(replacement, replacementRange: range)
            textView.setSelectedRange(newSelection)
        }()
    }

    private func unwrapSpan(
        _ span: MarkdownPresentation.InlineSpan,
        forTarget targetKind: MarkdownPresentation.InlineKind,
        in textView: NSTextView,
        source: NSString,
        keepInnerSelected: Bool
    ) {
        let innerText = source.substring(with: span.innerRange)
        let remainingMarker: String
        switch (span.kind, targetKind) {
        case (.boldItalic, .bold):
            remainingMarker = "*"
        case (.boldItalic, .italic):
            remainingMarker = "**"
        default:
            remainingMarker = ""
        }

        let replacement = remainingMarker + innerText + remainingMarker
        let markerLen = remainingMarker.utf16.count
        let newSelection: NSRange
        if keepInnerSelected {
            newSelection = NSRange(location: span.fullRange.location + markerLen, length: innerText.utf16.count)
        } else {
            let caretOffsetInsideInner = max(0, min(innerText.utf16.count, textView.selectedRange().location - span.innerRange.location))
            newSelection = NSRange(location: span.fullRange.location + markerLen + caretOffsetInsideInner, length: 0)
        }
        replaceText(in: textView, range: span.fullRange, with: replacement, newSelection: newSelection)
    }

    private func linkSuffix() -> String {
        if let raw = urlPasteboard?.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           Self.isPasteableHTTPURL(raw) {
            return "](\(raw))"
        }
        return "](https://)"
    }

    static func isPasteableHTTPURL(_ candidate: String) -> Bool {
        guard !candidate.isEmpty,
              candidate.count <= 2_048,
              !candidate.contains(where: { $0.isWhitespace || $0 == ")" || $0 == "(" || $0.isNewline }),
              let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return false
        }
        return true
    }

    private static func defaultSuffix(for prefix: String) -> String {
        prefix == "[" ? "](https://)" : prefix
    }

    private static func inlineKind(forPrefix prefix: String, suffix: String) -> MarkdownPresentation.InlineKind {
        if prefix == "[" { return .link }
        if prefix == "**" || prefix == "__" { return .bold }
        if prefix == "*" || prefix == "_" { return .italic }
        if prefix == "`" { return .code }
        if prefix == "~~" { return .strikethrough }
        return .bold
    }

    private static func matchesToggle(spanKind: MarkdownPresentation.InlineKind, targetKind: MarkdownPresentation.InlineKind) -> Bool {
        if spanKind == targetKind { return true }
        if spanKind == .boldItalic && (targetKind == .bold || targetKind == .italic) { return true }
        return false
    }

    private static func defaultPlaceholder(for kind: MarkdownPresentation.InlineKind) -> String {
        switch kind {
        case .bold, .boldItalic:
            return L10n.string("Bold")
        case .italic:
            return L10n.string("Italic")
        case .code:
            return L10n.string("Code")
        case .link:
            return L10n.string("Link")
        case .strikethrough:
            return L10n.string("Delete")
        }
    }

    private static func removingTaskMarker(from line: String) -> String {
        guard let info = MarkdownPresentation.taskInfo(in: line) else { return line }
        let nsLine = line as NSString
        let indent = nsLine.substring(to: info.indentLength)
        let rest = nsLine.substring(from: info.contentOffset)
        return indent + rest
    }

    private static func applyingTaskPrefix(to line: String) -> String {
        if MarkdownPresentation.taskInfo(in: line) != nil {
            return line
        }
        let nsLine = line as NSString
        if let bullet = MarkdownPresentation.bulletInfo(in: line) {
            let indent = nsLine.substring(to: bullet.indentLength)
            let rest = nsLine.substring(from: bullet.contentOffset)
            return indent + "- [ ] " + rest
        }
        if let heading = MarkdownPresentation.headingLevel(in: line) {
            let rest = String(line.dropFirst(heading + 1))
            return "- [ ] " + rest
        }
        let indentLen = MarkdownPresentation.leadingIndentLength(in: line)
        let indent = nsLine.substring(to: indentLen)
        let rest = nsLine.substring(from: indentLen)
        return indent + "- [ ] " + rest
    }

    private static func applyingHeadingPrefix(_ headingPrefix: String, to line: String) -> String {
        if let existingLevel = MarkdownPresentation.headingLevel(in: line) {
            return headingPrefix + String(line.dropFirst(existingLevel + 1))
        }
        let nsLine = line as NSString
        if let task = MarkdownPresentation.taskInfo(in: line) {
            return headingPrefix + nsLine.substring(from: task.contentOffset)
        }
        if let bullet = MarkdownPresentation.bulletInfo(in: line) {
            return headingPrefix + nsLine.substring(from: bullet.contentOffset)
        }
        if let quote = MarkdownPresentation.quoteInfo(in: line) {
            return headingPrefix + nsLine.substring(from: quote.contentOffset)
        }
        let trimmedIndent = nsLine.substring(from: MarkdownPresentation.leadingIndentLength(in: line))
        return headingPrefix + trimmedIndent
    }
}

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let noteID: UUID
    let actions: EditorActions
    let theme: VisualTheme
    var onFilesDropped: (([URL]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, noteID: noteID, theme: theme) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.findBarPosition = .aboveContent

        let textView = TaskTextView()
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.editorActions = actions
        textView.placeholderText = L10n.string("Editor placeholder")
        textView.onFileURLsDropped = onFilesDropped
        textView.onMouseDownCompleted = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.handleSelectionChange(in: textView)
        }
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.allowsUndo = true
        textView.usesFindPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
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
        context.coordinator.attach(textView: textView)
        context.coordinator.applyFull(to: textView)
        context.coordinator.snapCaretToVisibleContentIfNeeded(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.attach(textView: textView)
        actions.textView = textView
        if let taskTextView = textView as? TaskTextView {
            taskTextView.editorActions = actions
            taskTextView.onFileURLsDropped = onFilesDropped
        }

        if coordinator.noteID != noteID {
            coordinator.saveViewState(from: textView, in: scrollView)
            coordinator.noteID = noteID
            coordinator.theme = theme
            coordinator.isEditing = false
            coordinator.resetTracking()

            coordinator.performInternalMutation {
                textView.string = text
            }

            let restored = coordinator.restoredViewState(for: noteID, maxLength: (text as NSString).length)
            coordinator.performInternalMutation {
                textView.setSelectedRange(restored.selectedRange)
            }
            coordinator.applyFull(to: textView)
            coordinator.snapCaretToVisibleContentIfNeeded(in: textView)

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
            coordinator.performInternalMutation {
                textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
            }
            coordinator.applyFull(to: textView)
            coordinator.snapCaretToVisibleContentIfNeeded(in: textView)
        } else if themeChanged {
            if textView.hasMarkedText() {
                coordinator.markNeedsFullRestyle()
                coordinator.updateEditorChrome(on: textView)
            } else {
                coordinator.applyFull(to: textView)
            }
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
        static let concealedTaskMarkerFont = NSFont.monospacedSystemFont(ofSize: 4.5, weight: .regular)
        static let headingFonts: [Int: NSFont] = Dictionary(uniqueKeysWithValues: (1...6).map { level in
            (level, NSFont.systemFont(ofSize: CGFloat(max(16, 22 - (level - 1) * 2)), weight: .semibold))
        })

        var text: Binding<String>
        var noteID: UUID
        var theme: VisualTheme
        var isEditing = false
        private(set) var isSyncingFromEditor = false

        private weak var attachedTextView: NSTextView?
        private var isApplying = false
        private var needsFullRestyle = false
        private var pendingDirtyRange: NSRange?
        private var hasStyledOnce = false
        private var savedViewStates: [UUID: SavedNoteViewState] = [:]
        private var undoManagers: [UUID: UndoManager] = [:]
        private var undoObservers: [NSObjectProtocol] = []

        init(text: Binding<String>, noteID: UUID, theme: VisualTheme) {
            self.text = text
            self.noteID = noteID
            self.theme = theme
            super.init()
            installUndoObservers()
        }

        deinit {
            for observer in undoObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(textView: NSTextView) {
            attachedTextView = textView
        }

        private func installUndoObservers() {
            let names: [Notification.Name] = [
                .NSUndoManagerDidUndoChange,
                .NSUndoManagerDidRedoChange
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    guard let self,
                          let manager = note.object as? UndoManager,
                          manager === self.undoManagers[self.noteID],
                          let view = self.attachedTextView,
                          !view.hasMarkedText() else { return }
                    self.syncBinding(from: view)
                    self.applyIncremental(to: view)
                    self.snapCaretToVisibleContentIfNeeded(in: view)
                }
                undoObservers.append(token)
            }
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            attachedTextView = view
            if let existing = undoManagers[noteID] {
                return existing
            }
            if undoManagers.count > 64 {
                undoManagers.removeAll(keepingCapacity: true)
            }
            let created = UndoManager()
            undoManagers[noteID] = created
            return created
        }

        func markNeedsFullRestyle() {
            needsFullRestyle = true
        }

        func performInternalMutation(_ body: () -> Void) {
            let wasApplying = isApplying
            isApplying = true
            defer { isApplying = wasApplying }
            body()
        }

        func resetTracking() {
            pendingDirtyRange = nil
            hasStyledOnce = false
            needsFullRestyle = false
        }

        func saveViewState(from textView: NSTextView, in scrollView: NSScrollView) {
            if savedViewStates.count > 64 {
                savedViewStates.removeAll(keepingCapacity: true)
            }
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

        func snapCaretToVisibleContentIfNeeded(in view: NSTextView) {
            guard !isApplying, !view.hasMarkedText() else { return }
            let current = view.selectedRange()
            guard current.length == 0 else { return }
            let snapped = adjustedCaretRange(from: current, to: current, in: view)
            if snapped != current {
                performInternalMutation {
                    view.setSelectedRange(snapped)
                }
                updateTypingAttributes(on: view)
            }
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
        }

        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
            toCharacterRange newSelectedCharRange: NSRange
        ) -> NSRange {
            attachedTextView = textView
            guard !isApplying,
                  !textView.hasMarkedText(),
                  (textView as? TaskTextView)?.isPerformingProgrammaticEdit != true,
                  newSelectedCharRange.length == 0 else {
                return newSelectedCharRange
            }
            return adjustedCaretRange(from: oldSelectedCharRange, to: newSelectedCharRange, in: textView)
        }

        private func adjustedCaretRange(from oldRange: NSRange, to newRange: NSRange, in textView: NSTextView) -> NSRange {
            let fullText = textView.string
            let source = fullText as NSString
            guard source.length > 0, newRange.location <= source.length else { return newRange }

            let taskView = textView as? TaskTextView
            let navDir = taskView?.navigationDirection ?? .none
            let isMouseDown = taskView?.isHandlingMouseDown == true
            let movingLeft = navDir == .left || (!isMouseDown && navDir == .none && oldRange.length == 0 && newRange.location < oldRange.location)
            let movingRight = navDir == .right || (!isMouseDown && navDir == .none && oldRange.length == 0 && newRange.location > oldRange.location)

            let analysis = MarkdownPresentation.analyzeLine(in: fullText, source: source, at: newRange.location)
            var loc = newRange.location

            if let prefix = analysis.linePrefixes.first(where: {
                $0.lineRange.location <= loc && loc <= NSMaxRange($0.lineRange)
            }) {
                let markerStart = prefix.prefixRange.location
                let contentStart = min(prefix.contentStart, source.length)
                if loc >= markerStart && loc < contentStart {
                    if !isMouseDown && movingLeft && oldRange.length == 0 && oldRange.location == contentStart && navDir == .left {
                        if prefix.lineRange.location > 0 {
                            loc = prefix.lineRange.location - 1
                            return NSRange(location: loc, length: 0)
                        }
                    } else if !isMouseDown && movingLeft && oldRange.length == 0 && oldRange.location == contentStart && loc == contentStart - 1 {
                        if prefix.lineRange.location > 0 {
                            loc = prefix.lineRange.location - 1
                            return NSRange(location: loc, length: 0)
                        }
                    }
                    loc = contentStart
                }
            }

            for span in analysis.inlineSpans {
                if loc > span.openRange.location && loc < NSMaxRange(span.openRange) {
                    loc = movingLeft ? span.openRange.location : NSMaxRange(span.openRange)
                    break
                }
                if loc > span.closeRange.location && loc < NSMaxRange(span.closeRange) {
                    loc = movingLeft ? span.closeRange.location : NSMaxRange(span.closeRange)
                    break
                }
                if movingRight && oldRange.length == 0 && oldRange.location == span.openRange.location && loc == span.openRange.location {
                    loc = NSMaxRange(span.openRange)
                    break
                }
            }

            return NSRange(location: min(max(0, loc), source.length), length: 0)
        }

        func textDidBeginEditing(_ notification: Notification) { isEditing = true }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            attachedTextView = view
            if view.string.isEmpty {
                view.needsDisplay = true
            }
            // Preserve native macOS IME marked-text attributes (e.g. Chinese Pinyin pre-edit underline)
            // until composition finishes.
            guard !view.hasMarkedText() else { return }
            syncBinding(from: view)
            applyIncremental(to: view)
            snapCaretToVisibleContentIfNeeded(in: view)
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
            if pendingDirtyRange == nil, !needsFullRestyle, hasStyledOnce {
                updateTypingAttributes(on: view)
                return
            }
            applyIncremental(to: view)
        }

        func handleUnmarkText(in view: NSTextView) {
            attachedTextView = view
            guard !isApplying, !view.hasMarkedText() else { return }
            syncBinding(from: view)
            applyIncremental(to: view)
            snapCaretToVisibleContentIfNeeded(in: view)
        }

        func applyFull(to view: NSTextView) {
            guard !isApplying, !view.hasMarkedText(), let storage = view.textStorage else { return }
            isApplying = true
            defer { isApplying = false }

            let fullText = view.string
            let source = fullText as NSString
            let all = NSRange(location: 0, length: source.length)

            if all.length > 0 {
                storage.beginEditing()
                styleSpan(all, in: storage, fullText: fullText, source: source)
                storage.endEditing()
            }

            pendingDirtyRange = nil
            needsFullRestyle = false
            hasStyledOnce = true
            updateEditorChrome(on: view)
            view.needsDisplay = true
        }

        func applyIncremental(to view: NSTextView) {
            guard !isApplying, !view.hasMarkedText(), let storage = view.textStorage else { return }
            guard hasStyledOnce, !needsFullRestyle else {
                applyFull(to: view)
                return
            }

            let fullText = view.string
            let source = fullText as NSString
            let totalLength = source.length

            guard totalLength > 0 else {
                pendingDirtyRange = nil
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

            let mergedSpans = Self.mergeRanges(candidateSpans)
            guard !mergedSpans.isEmpty else {
                updateEditorChrome(on: view)
                return
            }

            isApplying = true
            defer { isApplying = false }

            storage.beginEditing()
            for span in mergedSpans where span.length > 0 {
                styleSpan(span, in: storage, fullText: fullText, source: source)
            }
            storage.endEditing()

            updateEditorChrome(on: view)
            invalidateGutter(in: view, for: mergedSpans)
        }

        private func syncBinding(from view: NSTextView) {
            guard text.wrappedValue != view.string else { return }
            isSyncingFromEditor = true
            text.wrappedValue = view.string
            isSyncingFromEditor = false
        }

        private func styleSpan(_ span: NSRange, in storage: NSTextStorage, fullText: String, source: NSString) {
            guard span.length > 0, NSMaxRange(span) <= storage.length else { return }
            // Reset font, foregroundColor, backgroundColor, strikethrough, obliqueness, and any residual IME pre-edit underline.
            storage.removeAttribute(.backgroundColor, range: span)
            storage.removeAttribute(.strikethroughStyle, range: span)
            storage.removeAttribute(.obliqueness, range: span)
            storage.removeAttribute(.underlineStyle, range: span)
            storage.removeAttribute(.underlineColor, range: span)
            storage.addAttributes([.font: Self.bodyFont, .foregroundColor: theme.nsForeground], range: span)

            let analysis = MarkdownPresentation.analyze(in: fullText, source: source, range: span)
            for heading in analysis.headings {
                if let font = Self.headingFonts[heading.level] {
                    storage.addAttribute(.font, value: font, range: heading.range)
                }
            }
            for range in analysis.boldRanges {
                applyBoldTrait(in: range, to: storage)
            }
            for range in analysis.italicRanges {
                applyItalicTrait(in: range, to: storage)
            }
            for range in analysis.codeRanges {
                applyCodeFont(in: range, to: storage)
            }
            for spanInfo in analysis.inlineSpans where spanInfo.kind == .code {
                if spanInfo.innerRange.length > 0, NSMaxRange(spanInfo.innerRange) <= storage.length {
                    storage.addAttribute(
                        .backgroundColor,
                        value: theme.nsForeground.withAlphaComponent(0.08),
                        range: spanInfo.innerRange
                    )
                }
            }
            for range in analysis.strikethroughRanges {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            for labelRange in analysis.linkLabelRanges {
                storage.addAttribute(.foregroundColor, value: theme.nsAccent, range: labelRange)
            }

            // Substitute CJK / non-Latin fallback fonts (e.g. PingFang SC) across `span`!
            // Without `fixFontAttribute`, attribute-only edits leave `.AppleSystemUIFont` on Chinese characters,
            // which lacks CJK glyphs and lays them out as zero-width invisible `.notdef` glyphs.
            storage.fixFontAttribute(in: span)

            // CJK fallback fonts such as PingFang SC have no native italic face; apply subtle obliqueness so `*中文*` visibly slants.
            for range in analysis.italicRanges {
                storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                    if let font = value as? NSFont,
                       !NSFontManager.shared.traits(of: font).contains(.italicFontMask) {
                        storage.addAttribute(.obliqueness, value: 0.16, range: subrange)
                    }
                }
            }

            // Conceal Markdown markers AFTER `fixFontAttribute` so preserved-width ASCII markers (`- [ ]`)
            // keep compact Latin metrics instead of widening to full-width CJK punctuation.
            for marker in analysis.markers {
                conceal(marker.range, in: storage, preserveWidth: marker.preserveWidth)
            }
        }

        private func applyBoldTrait(in range: NSRange, to storage: NSTextStorage) {
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let baseFont = (value as? NSFont) ?? Self.bodyFont
                let updated: NSFont
                if baseFont === Self.bodyFont {
                    updated = Self.boldFont
                } else {
                    updated = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
                }
                storage.addAttribute(.font, value: updated, range: subrange)
            }
        }

        private func applyItalicTrait(in range: NSRange, to storage: NSTextStorage) {
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let baseFont = (value as? NSFont) ?? Self.bodyFont
                let updated: NSFont
                if baseFont === Self.bodyFont {
                    updated = Self.italicFont
                } else {
                    updated = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: updated, range: subrange)
            }
        }

        private func applyCodeFont(in range: NSRange, to storage: NSTextStorage) {
            storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
                let baseFont = (value as? NSFont) ?? Self.bodyFont
                let updated: NSFont
                if baseFont === Self.bodyFont {
                    updated = Self.codeFont
                } else {
                    updated = NSFont.monospacedSystemFont(ofSize: max(13, baseFont.pointSize - 1), weight: .regular)
                }
                storage.addAttribute(.font, value: updated, range: subrange)
            }
        }

        private func conceal(_ range: NSRange, in storage: NSTextStorage, preserveWidth: Bool) {
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return }
            storage.removeAttribute(.obliqueness, range: range)
            storage.removeAttribute(.strikethroughStyle, range: range)
            storage.removeAttribute(.backgroundColor, range: range)
            storage.removeAttribute(.underlineStyle, range: range)
            storage.removeAttribute(.underlineColor, range: range)
            let concealedFont: NSFont
            if preserveWidth {
                concealedFont = range.length == 5 ? Self.concealedTaskMarkerFont : Self.bodyFont
            } else {
                concealedFont = Self.concealedZeroFont
            }
            storage.addAttributes([
                .font: concealedFont,
                .foregroundColor: NSColor.clear
            ], range: range)
            if !preserveWidth {
                storage.fixFontAttribute(in: range)
            }
        }

        func updateEditorChrome(on view: NSTextView) {
            if let taskView = view as? TaskTextView {
                taskView.checkboxColor = theme.nsForeground
                taskView.accentColor = theme.nsAccent
            }
            if view.insertionPointColor != theme.nsAccent {
                view.insertionPointColor = theme.nsAccent
            }
            updateTypingAttributes(on: view)
        }

        func updateTypingAttributes(on view: NSTextView) {
            let fullText = view.string
            let source = fullText as NSString
            let selection = view.selectedRange()
            var font: NSFont = Self.bodyFont
            var color: NSColor = theme.nsForeground
            var extra: [NSAttributedString.Key: Any] = [:]

            if source.length > 0 {
                let analysis = MarkdownPresentation.analyzeLine(in: fullText, source: source, at: selection.location)
                if let heading = analysis.headings.first, let hFont = Self.headingFonts[heading.level] {
                    font = hFont
                }
                if selection.length == 0 {
                    for span in analysis.inlineSpans where span.innerRange.location <= selection.location && selection.location <= NSMaxRange(span.innerRange) {
                        switch span.kind {
                        case .bold:
                            font = font === Self.bodyFont ? Self.boldFont : NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                        case .italic:
                            font = font === Self.bodyFont ? Self.italicFont : NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                        case .boldItalic:
                            let bolded = font === Self.bodyFont ? Self.boldFont : NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                            font = NSFontManager.shared.convert(bolded, toHaveTrait: .italicFontMask)
                        case .code:
                            font = font === Self.bodyFont ? Self.codeFont : NSFont.monospacedSystemFont(ofSize: max(13, font.pointSize - 1), weight: .regular)
                            extra[.backgroundColor] = theme.nsForeground.withAlphaComponent(0.08)
                        case .link:
                            color = theme.nsAccent
                        case .strikethrough:
                            extra[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                        }
                    }
                }
            }

            extra[.font] = font
            extra[.foregroundColor] = color
            view.typingAttributes = extra
        }

        private func invalidateGutter(in view: NSTextView, for spans: [NSRange]) {
            guard let manager = view.layoutManager, let container = view.textContainer else {
                view.needsDisplay = true
                return
            }
            let gutterWidth = max(view.bounds.width, view.textContainerOrigin.x + 96)
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
    enum NavigationDirection {
        case none
        case left
        case right
    }

    var checkboxColor: NSColor = .labelColor
    var accentColor: NSColor = .controlAccentColor
    var placeholderText: String = ""
    weak var editorActions: EditorActions?
    private(set) var isHandlingMouseDown = false
    private(set) var isPerformingProgrammaticEdit = false
    private(set) var navigationDirection: NavigationDirection = .none
    var onMouseDownCompleted: (() -> Void)?
    var onFileURLsDropped: (([URL]) -> Void)?

    func performProgrammaticEdit(_ body: () -> Void) {
        let previous = isPerformingProgrammaticEdit
        isPerformingProgrammaticEdit = true
        defer { isPerformingProgrammaticEdit = previous }
        body()
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        return objects.compactMap { object in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        }
    }

    @discardableResult
    func acceptFileDrop(from pasteboard: NSPasteboard) -> Bool {
        let urls = Self.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        onFileURLsDropped?(urls)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty
            ? super.draggingEntered(sender)
            : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty
            ? super.draggingUpdated(sender)
            : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty
            ? super.prepareForDragOperation(sender)
            : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if acceptFileDrop(from: sender.draggingPasteboard) {
            return true
        }
        return super.performDragOperation(sender)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let wasEmpty = self.string.isEmpty
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if wasEmpty || self.string.isEmpty {
            needsDisplay = true
        }
    }

    override func unmarkText() {
        let hadMarked = hasMarkedText()
        super.unmarkText()
        if string.isEmpty {
            needsDisplay = true
        }
        if hadMarked, !hasMarkedText() {
            (delegate as? MarkdownEditor.Coordinator)?.handleUnmarkText(in: self)
        }
    }

    override func moveLeft(_ sender: Any?) {
        navigationDirection = .left
        defer { navigationDirection = .none }
        super.moveLeft(sender)
    }

    override func moveBackward(_ sender: Any?) {
        navigationDirection = .left
        defer { navigationDirection = .none }
        super.moveBackward(sender)
    }

    override func moveRight(_ sender: Any?) {
        navigationDirection = .right
        defer { navigationDirection = .none }
        super.moveRight(sender)
    }

    override func moveForward(_ sender: Any?) {
        navigationDirection = .right
        defer { navigationDirection = .none }
        super.moveForward(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }

        let currentSelection = selectedRange()
        let fullText = string
        let source = fullText as NSString
        guard source.length > 0 else {
            super.deleteBackward(sender)
            return
        }

        let analysis = MarkdownPresentation.analyzeLine(in: fullText, source: source, at: currentSelection.location)

        if currentSelection.length > 0 {
            if let span = analysis.inlineSpans.first(where: { $0.innerRange == currentSelection }) {
                applyUndoableReplacement("", in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
                return
            }
            super.deleteBackward(sender)
            return
        }

        let loc = currentSelection.location

        // 1. At start of visible content on a heading, task, bullet, or quote line: strip the hidden prefix cleanly.
        if let prefix = analysis.linePrefixes.first(where: { $0.contentStart == loc }) {
            applyUndoableReplacement("", in: prefix.prefixRange, newSelection: NSRange(location: prefix.prefixRange.location, length: 0))
            return
        }

        // 2. Immediately after a concealed closing inline marker (`**word**|` or `[label](url)|`):
        if let span = analysis.inlineSpans.first(where: { NSMaxRange($0.fullRange) == loc }) {
            let lastCharRange = source.rangeOfComposedCharacterSequence(at: max(0, NSMaxRange(span.innerRange) - 1))
            if lastCharRange == span.innerRange {
                applyUndoableReplacement("", in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
            } else {
                applyUndoableReplacement("", in: lastCharRange, newSelection: NSRange(location: lastCharRange.location, length: 0))
            }
            return
        }

        // 3. Deleting the sole remaining character inside an inline span (`**w|**`): remove markers together with it.
        if loc > 0 {
            let prevCharRange = source.rangeOfComposedCharacterSequence(at: loc - 1)
            if let span = analysis.inlineSpans.first(where: { $0.innerRange == prevCharRange }) {
                applyUndoableReplacement("", in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
                return
            }
        }

        // 4. Immediately after a concealed opening inline marker (`Hello **|world**`): delete before opening marker.
        if let span = analysis.inlineSpans.first(where: { $0.innerRange.location == loc }) {
            if span.openRange.location > 0 {
                let beforeOpen = source.rangeOfComposedCharacterSequence(at: span.openRange.location - 1)
                let newCaret = loc - beforeOpen.length
                applyUndoableReplacement("", in: beforeOpen, newSelection: NSRange(location: newCaret, length: 0))
            } else {
                let innerText = source.substring(with: span.innerRange)
                applyUndoableReplacement(innerText, in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
            }
            return
        }

        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.deleteForward(sender)
            return
        }

        let currentSelection = selectedRange()
        let fullText = string
        let source = fullText as NSString
        guard source.length > 0 else {
            super.deleteForward(sender)
            return
        }

        let analysis = MarkdownPresentation.analyzeLine(in: fullText, source: source, at: currentSelection.location)

        if currentSelection.length > 0 {
            if let span = analysis.inlineSpans.first(where: { $0.innerRange == currentSelection }) {
                applyUndoableReplacement("", in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
                return
            }
            super.deleteForward(sender)
            return
        }

        let loc = currentSelection.location
        guard loc < source.length else { return }

        if let span = analysis.inlineSpans.first(where: { $0.openRange.location == loc }) {
            let firstCharRange = source.rangeOfComposedCharacterSequence(at: span.innerRange.location)
            if firstCharRange == span.innerRange {
                applyUndoableReplacement("", in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
            } else {
                applyUndoableReplacement("", in: firstCharRange, newSelection: NSRange(location: span.innerRange.location, length: 0))
            }
            return
        }

        let nextCharRange = source.rangeOfComposedCharacterSequence(at: loc)
        if let span = analysis.inlineSpans.first(where: { $0.innerRange == nextCharRange }) {
            applyUndoableReplacement("", in: span.fullRange, newSelection: NSRange(location: span.fullRange.location, length: 0))
            return
        }

        if let span = analysis.inlineSpans.first(where: { NSMaxRange($0.innerRange) == loc }) {
            let afterSpan = NSMaxRange(span.fullRange)
            if afterSpan < source.length {
                let afterCharRange = source.rangeOfComposedCharacterSequence(at: afterSpan)
                applyUndoableReplacement("", in: afterCharRange, newSelection: NSRange(location: loc, length: 0))
            } else {
                let innerText = source.substring(with: span.innerRange)
                applyUndoableReplacement(innerText, in: span.fullRange, newSelection: NSRange(location: span.fullRange.location + innerText.utf16.count, length: 0))
            }
            return
        }

        super.deleteForward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else {
            super.insertNewline(sender)
            return
        }

        let loc = selectedRange().location
        let source = string as NSString
        let lineRange = source.lineRange(for: NSRange(location: loc, length: 0))
        let rawLine = source.substring(with: lineRange)
        let lineBody = Self.strippingLineBreak(rawLine)
        let nsBody = lineBody as NSString

        if let task = MarkdownPresentation.taskInfo(in: lineBody) {
            let prefixEndInDoc = lineRange.location + task.contentOffset
            let content = nsBody.substring(from: task.contentOffset)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                let removeRange = NSRange(location: lineRange.location, length: nsBody.length)
                applyUndoableReplacement("", in: removeRange, newSelection: NSRange(location: lineRange.location, length: 0))
                return
            }
            if loc >= prefixEndInDoc {
                let indent = nsBody.substring(to: task.indentLength)
                let insertion = "\n" + indent + "- [ ] "
                applyUndoableReplacement(insertion, in: NSRange(location: loc, length: 0), newSelection: NSRange(location: loc + insertion.utf16.count, length: 0))
                return
            }
        } else if let bullet = MarkdownPresentation.bulletInfo(in: lineBody) {
            let prefixEndInDoc = lineRange.location + bullet.contentOffset
            let content = nsBody.substring(from: bullet.contentOffset)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                let removeRange = NSRange(location: lineRange.location, length: nsBody.length)
                applyUndoableReplacement("", in: removeRange, newSelection: NSRange(location: lineRange.location, length: 0))
                return
            }
            if loc >= prefixEndInDoc {
                let indent = nsBody.substring(to: bullet.indentLength)
                let insertion = "\n\(indent)\(bullet.bullet) "
                applyUndoableReplacement(insertion, in: NSRange(location: loc, length: 0), newSelection: NSRange(location: loc + insertion.utf16.count, length: 0))
                return
            }
        } else if let ordered = MarkdownPresentation.orderedListInfo(in: lineBody) {
            let prefixEndInDoc = lineRange.location + ordered.contentOffset
            let content = nsBody.substring(from: ordered.contentOffset)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                let removeRange = NSRange(location: lineRange.location, length: nsBody.length)
                applyUndoableReplacement("", in: removeRange, newSelection: NSRange(location: lineRange.location, length: 0))
                return
            }
            if loc >= prefixEndInDoc {
                let indent = nsBody.substring(to: ordered.indentLength)
                let insertion = "\n\(indent)\(ordered.number + 1). "
                applyUndoableReplacement(insertion, in: NSRange(location: loc, length: 0), newSelection: NSRange(location: loc + insertion.utf16.count, length: 0))
                return
            }
        }

        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.insertTab(sender)
            return
        }
        let range = selectedRange()
        let source = string as NSString
        if range.length == 0 {
            let lineRange = source.lineRange(for: range)
            let lineBody = Self.strippingLineBreak(source.substring(with: lineRange))
            if Self.isIndentableListLine(lineBody) {
                let newCaret = range.location + 2
                applyUndoableReplacement("  ", in: NSRange(location: lineRange.location, length: 0), newSelection: NSRange(location: newCaret, length: 0))
                return
            }
            applyUndoableReplacement("  ", in: range, newSelection: NSRange(location: range.location + 2, length: 0))
            return
        }
        indentSelectedLines(outdent: false)
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.insertBacktab(sender)
            return
        }
        indentSelectedLines(outdent: true)
    }

    private func indentSelectedLines(outdent: Bool) {
        let range = selectedRange()
        let source = string as NSString
        guard source.length > 0 else { return }
        let lineRange = source.lineRange(for: range)
        let rawSlice = source.substring(with: lineRange)
        let (body, trailingNewline) = Self.splittingTrailingLineBreak(rawSlice)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var firstLineDelta = 0
        var totalDelta = 0
        let updatedLines: [String] = lines.enumerated().map { index, line in
            let transformed: String
            if outdent {
                if line.hasPrefix("  ") {
                    transformed = String(line.dropFirst(2))
                } else if line.hasPrefix(" ") || line.hasPrefix("\t") {
                    transformed = String(line.dropFirst(1))
                } else {
                    transformed = line
                }
            } else {
                transformed = "  " + line
            }
            let delta = transformed.utf16.count - line.utf16.count
            if index == 0 { firstLineDelta = delta }
            totalDelta += delta
            return transformed
        }

        guard totalDelta != 0 else { return }
        let replacement = updatedLines.joined(separator: "\n") + trailingNewline
        let newSelection: NSRange
        if range.length == 0 {
            let newLoc = max(lineRange.location, range.location + firstLineDelta)
            newSelection = NSRange(location: newLoc, length: 0)
        } else {
            newSelection = NSRange(location: lineRange.location, length: updatedLines.joined(separator: "\n").utf16.count)
        }
        applyUndoableReplacement(replacement, in: lineRange, newSelection: newSelection)
    }

    private func applyUndoableReplacement(_ replacement: String, in range: NSRange, newSelection: NSRange) {
        performProgrammaticEdit {
            insertText(replacement, replacementRange: range)
            setSelectedRange(newSelection)
        }
    }

    private static func isIndentableListLine(_ line: String) -> Bool {
        MarkdownPresentation.taskInfo(in: line) != nil
            || MarkdownPresentation.bulletInfo(in: line) != nil
            || MarkdownPresentation.orderedListInfo(in: line) != nil
    }

    private static func strippingLineBreak(_ raw: String) -> String {
        splittingTrailingLineBreak(raw).body
    }

    private static func splittingTrailingLineBreak(_ raw: String) -> (body: String, newline: String) {
        if raw.hasSuffix("\r\n") {
            return (String(raw.dropLast(2)), "\r\n")
        } else if raw.hasSuffix("\n") {
            return (String(raw.dropLast()), "\n")
        }
        return (raw, "")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if hasMarkedText() {
            return super.performKeyEquivalent(with: event)
        }
        if window?.firstResponder === self, let editorActions {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags == [.command] {
                switch key {
                case "b":
                    editorActions.surroundSelection(prefix: "**")
                    return true
                case "i":
                    editorActions.surroundSelection(prefix: "*")
                    return true
                case "k":
                    editorActions.surroundSelection(prefix: "[", suffix: "](https://)")
                    return true
                case "e":
                    editorActions.surroundSelection(prefix: "`")
                    return true
                default:
                    break
                }
            } else if flags == [.command, .shift] {
                switch key {
                case "h":
                    editorActions.insertLinePrefix("## ")
                    return true
                case "l":
                    editorActions.insertLinePrefix("- [ ] ")
                    return true
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let container = textContainer, let manager = layoutManager {
            let source = string as NSString
            if source.length > 0 {
                let local = NSPoint(x: max(0, point.x - textContainerOrigin.x), y: point.y - textContainerOrigin.y)
                if point.x >= textContainerOrigin.x - 6 {
                    let probe = NSPoint(x: 0, y: local.y)
                    let glyph = manager.glyphIndex(for: probe, in: container)
                    let index = min(manager.characterIndexForGlyph(at: glyph), source.length)
                    if let toggle = MarkdownPresentation.taskToggle(in: string, at: index) {
                        let hitBox = checkboxRect(
                            forLineAt: toggle.lineLocation,
                            indentLength: toggle.indentLength,
                            manager: manager
                        ).insetBy(dx: -5, dy: -4)
                        if hitBox.contains(point) {
                            toggleTaskWithoutMovingSelection(toggle)
                            return
                        }
                    }
                }
            }
        }

        isHandlingMouseDown = true
        super.mouseDown(with: event)
        isHandlingMouseDown = false
        onMouseDownCompleted?()
    }

    func toggleTaskWithoutMovingSelection(_ toggle: MarkdownPresentation.TaskToggle) {
        let previousSelection = selectedRange()
        guard shouldChangeText(in: toggle.range, replacementString: toggle.replacement) else { return }
        textStorage?.replaceCharacters(in: toggle.range, with: toggle.replacement)
        performProgrammaticEdit {
            setSelectedRange(previousSelection)
        }
        didChangeText()
    }

    func checkboxRect(forLineAt lineStartLocation: Int, indentLength: Int = 0, manager: NSLayoutManager) -> NSRect {
        let startGlyph = manager.glyphRange(
            forCharacterRange: NSRange(location: lineStartLocation, length: 1),
            actualCharacterRange: nil
        )
        let fragment = manager.lineFragmentRect(forGlyphAt: startGlyph.location, effectiveRange: nil)
        let indentAdvance = Self.indentAdvance(
            lineStartLocation: lineStartLocation,
            indentLength: indentLength,
            startGlyphIndex: startGlyph.location,
            manager: manager
        )
        return NSRect(
            x: textContainerOrigin.x + indentAdvance + 1,
            y: textContainerOrigin.y + fragment.minY + round((fragment.height - 13) / 2),
            width: 13,
            height: 13
        )
    }

    private static func indentAdvance(
        lineStartLocation: Int,
        indentLength: Int,
        startGlyphIndex: Int,
        manager: NSLayoutManager
    ) -> CGFloat {
        guard indentLength > 0 else { return 0 }
        let markerGlyph = manager.glyphRange(
            forCharacterRange: NSRange(location: lineStartLocation + indentLength, length: 1),
            actualCharacterRange: nil
        )
        let startX = manager.location(forGlyphAt: startGlyphIndex).x
        let markerX = manager.location(forGlyphAt: markerGlyph.location).x
        return max(0, markerX - startX)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let source = string as NSString
        if source.length == 0 {
            if !hasMarkedText(), !placeholderText.isEmpty {
                let padding = textContainer?.lineFragmentPadding ?? 5
                let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: MarkdownEditor.Coordinator.bodyFont,
                    .foregroundColor: checkboxColor.withAlphaComponent(0.36)
                ]
                (placeholderText as NSString).draw(at: origin, withAttributes: attrs)
            }
            return
        }

        guard let manager = layoutManager, let container = textContainer else { return }

        let containerRect = dirtyRect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphs = manager.glyphRange(forBoundingRectWithoutAdditionalLayout: containerRect, in: container)
        guard visibleGlyphs.length > 0 else { return }
        let visibleCharacters = manager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let scanRange = source.lineRange(for: visibleCharacters)
        guard scanRange.length > 0 else { return }

        let strokeColor = checkboxColor.withAlphaComponent(0.82)
        let bulletColor = checkboxColor.withAlphaComponent(0.68)
        let quoteBarColor = accentColor.withAlphaComponent(0.65)

        source.enumerateSubstrings(in: scanRange, options: .byLines) { line, range, _, _ in
            guard let line, range.length > 0 else { return }

            if let task = MarkdownPresentation.taskInfo(in: line) {
                let box = self.checkboxRect(forLineAt: range.location, indentLength: task.indentLength, manager: manager)
                guard dirtyRect.intersects(box) else { return }

                let shape = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
                strokeColor.setStroke()
                shape.lineWidth = 1.4
                shape.stroke()
                if task.isCompleted {
                    // NSTextView uses flipped coordinates (`minY` = top, `maxY` = bottom).
                    let check = NSBezierPath()
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    check.move(to: NSPoint(x: box.minX + 2.8, y: box.midY + 0.3))
                    check.line(to: NSPoint(x: box.minX + 5.4, y: box.maxY - 3.2))
                    check.line(to: NSPoint(x: box.maxX - 2.6, y: box.minY + 3.2))
                    check.lineWidth = 1.5
                    check.stroke()
                }
            } else if let bullet = MarkdownPresentation.bulletInfo(in: line) {
                let startGlyph = manager.glyphRange(
                    forCharacterRange: NSRange(location: range.location, length: 1),
                    actualCharacterRange: nil
                )
                let fragment = manager.lineFragmentRect(forGlyphAt: startGlyph.location, effectiveRange: nil)
                let indentAdvance = Self.indentAdvance(
                    lineStartLocation: range.location,
                    indentLength: bullet.indentLength,
                    startGlyphIndex: startGlyph.location,
                    manager: manager
                )
                let dotRect = NSRect(
                    x: self.textContainerOrigin.x + indentAdvance + 5,
                    y: self.textContainerOrigin.y + fragment.minY + round((fragment.height - 5) / 2),
                    width: 5,
                    height: 5
                )
                guard dirtyRect.intersects(dotRect) else { return }
                bulletColor.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            } else if let quote = MarkdownPresentation.quoteInfo(in: line) {
                let lineGlyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let bounds = manager.boundingRect(forGlyphRange: lineGlyphs, in: container)
                let startGlyph = manager.glyphRange(
                    forCharacterRange: NSRange(location: range.location, length: 1),
                    actualCharacterRange: nil
                )
                let indentAdvance = Self.indentAdvance(
                    lineStartLocation: range.location,
                    indentLength: quote.indentLength,
                    startGlyphIndex: startGlyph.location,
                    manager: manager
                )
                let barRect = NSRect(
                    x: self.textContainerOrigin.x + indentAdvance + 4,
                    y: self.textContainerOrigin.y + bounds.minY + 2,
                    width: 2.5,
                    height: max(12, bounds.height - 4)
                )
                guard dirtyRect.intersects(barRect) else { return }
                quoteBarColor.setFill()
                NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }
}
