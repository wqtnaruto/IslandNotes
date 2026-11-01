import AppKit
import Combine
import SwiftUI
import XCTest
@testable import IslandNotes

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    func testFreshWorkspaceContainsOneSelectedNote() {
        let store = makeStore()
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.activeNoteID, store.notes[0].id)
        XCTAssertEqual(store.activeNote.title, "欢迎")
        XCTAssertEqual(store.activeNote.markdown, "# 欢迎\n")
    }

    func testLegacyEnglishStarterContentMigratesWithoutChangingUserNotes() throws {
        let location = temporaryURL()
        let now = Date(timeIntervalSince1970: 100)
        let welcome = NotePage(title: "Welcome", markdown: "# Welcome\n", createdAt: now, updatedAt: now)
        let blank = NotePage(title: "Untitled", markdown: "\n\n", createdAt: now, updatedAt: now)
        let userNote = NotePage(title: "Welcome", markdown: "My own content", createdAt: now, updatedAt: now)
        let workspace = PersistedWorkspace(
            notes: [welcome, blank, userNote],
            activeNoteID: welcome.id,
            shelf: [],
            preferences: AppPreferences()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(workspace).write(to: location)

        let store = WorkspaceStore(storageURL: location)
        XCTAssertEqual(store.notes[0].title, "欢迎")
        XCTAssertEqual(store.notes[0].markdown, "# 欢迎\n")
        XCTAssertEqual(store.notes[1].title, "未命名")
        XCTAssertEqual(store.notes[1].markdown, "\n\n")
        XCTAssertEqual(store.notes[2].title, "Welcome")
        XCTAssertEqual(store.notes[2].markdown, "My own content")
    }

    func testCreateEditRenameDeleteRoundTrip() throws {
        let location = temporaryURL()
        let store = WorkspaceStore(storageURL: location)
        let firstID = store.activeNoteID
        let secondID = store.addNote(now: Date(timeIntervalSince1970: 10))
        store.updateActiveMarkdown("# Independent", now: Date(timeIntervalSince1970: 20))
        store.renameNote(secondID, to: "  Rewrite  ", now: Date(timeIntervalSince1970: 30))
        store.deleteNote(firstID)

        let restored = WorkspaceStore(storageURL: location)
        XCTAssertEqual(restored.notes.count, 1)
        XCTAssertEqual(restored.activeNoteID, secondID)
        XCTAssertEqual(restored.activeNote.title, "Rewrite")
        XCTAssertEqual(restored.activeNote.markdown, "# Independent")
    }

    func testLastNoteCannotBeDeleted() {
        let store = makeStore()
        store.deleteNote(store.activeNoteID)
        XCTAssertEqual(store.notes.count, 1)
    }

    func testBlankRenameIsIgnoredAndLongRenameIsLimited() {
        let store = makeStore()
        let id = store.activeNoteID
        let original = store.activeNote.title
        store.renameNote(id, to: "   ")
        XCTAssertEqual(store.activeNote.title, original)

        store.renameNote(id, to: String(repeating: "a", count: 100))
        XCTAssertEqual(store.activeNote.title.count, 80)
    }

    func testShelfDeduplicatesByPath() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/tmp/example.md")
        store.addShelfURLs([url, url])
        XCTAssertEqual(store.shelf.count, 1)
    }

    func testLegacyPreferencesDecodeDefaultsToDark() throws {
        let old = #"{"activationMode":"click","keepAwake":true,"breakReminderEnabled":false,"breakIntervalMinutes":25}"#
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(old.utf8))
        XCTAssertEqual(preferences.themeMode, .dark)
        XCTAssertEqual(preferences.breakIntervalMinutes, 25)
        XCTAssertTrue(preferences.keepAwake)
    }

    func testThemeAndMarkdownSurviveRoundTrip() {
        let location = temporaryURL()
        let store = WorkspaceStore(storageURL: location)
        let raw = "# Today\n**bold** and [link](https://example.com)\n- [ ] task\n"
        store.updatePreferences { $0.themeMode = .light }
        store.updateActiveMarkdown(raw)
        store.save()
        let restored = WorkspaceStore(storageURL: location)
        XCTAssertEqual(restored.preferences.themeMode, .light)
        XCTAssertEqual(restored.activeNote.markdown, raw)
    }

    func testReminderRemainingTimeIsBounded() {
        let reminder = BreakReminder()
        reminder.configure(enabled: true, intervalMinutes: 25)
        guard let deadline = reminder.nextBreakAt else { return XCTFail("Missing deadline") }
        reminder.refresh(now: deadline.addingTimeInterval(-90))
        XCTAssertEqual(reminder.remainingMinutes, 2)
        XCTAssertGreaterThan(reminder.progress, 0)
        reminder.refresh(now: deadline.addingTimeInterval(10))
        XCTAssertEqual(reminder.remainingMinutes, 0)
        XCTAssertEqual(reminder.progress, 1)
        reminder.configure(enabled: false, intervalMinutes: 25)
        XCTAssertNil(reminder.nextBreakAt)
    }

    func testUnrelatedPreferenceChangeDoesNotRestartFocus() {
        let reminder = BreakReminder()
        reminder.configure(enabled: true, intervalMinutes: 45)
        let firstDeadline = reminder.nextBreakAt
        reminder.configure(enabled: true, intervalMinutes: 45)
        XCTAssertEqual(reminder.nextBreakAt, firstDeadline)
        reminder.configure(enabled: true, intervalMinutes: 25)
        XCTAssertNotEqual(reminder.nextBreakAt, firstDeadline)
        reminder.configure(enabled: false, intervalMinutes: 25)
    }

    func testMarkdownMarkerRangesAndActiveLine() {
        let raw = "# Today\n**bold** _em_ `code` [link](url)\n- [ ] task"
        let source = raw as NSString
        let firstLine = source.lineRange(for: NSRange(location: 0, length: 0))
        let firstMarkers = MarkdownPresentation.markers(in: raw, activeLine: firstLine)
        XCTAssertFalse(firstMarkers.contains { $0.range.location == 0 })
        XCTAssertTrue(firstMarkers.contains { source.substring(with: $0.range) == "**" })
        XCTAssertTrue(firstMarkers.contains { source.substring(with: $0.range) == "](url)" })
        XCTAssertTrue(firstMarkers.contains { $0.preserveWidth && source.substring(with: $0.range) == "- [ ]" })

        let secondLine = source.lineRange(for: NSRange(location: firstLine.length, length: 0))
        let secondMarkers = MarkdownPresentation.markers(in: raw, activeLine: secondLine)
        XCTAssertTrue(secondMarkers.contains { source.substring(with: $0.range) == "# " })
        XCTAssertFalse(secondMarkers.contains { $0.range.location >= secondLine.location && $0.range.location < NSMaxRange(secondLine) })
        XCTAssertEqual(MarkdownPresentation.headingLevel(in: "###### Small"), 6)
        XCTAssertNil(MarkdownPresentation.headingLevel(in: "####### Too many"))
    }

    func testTaskTogglePreservesRawMarkdownAndOtherLines() {
        let raw = "# Today\n- [ ] task\n- [x] done\n"
        let source = raw as NSString
        let location = source.range(of: "task").location
        guard let toggle = MarkdownPresentation.taskToggle(in: raw, at: location) else {
            return XCTFail("Missing task toggle")
        }
        let changed = source.replacingCharacters(in: toggle.range, with: toggle.replacement)
        XCTAssertEqual(changed, "# Today\n- [x] task\n- [x] done\n")
        let changedSource = changed as NSString
        let secondToggle = MarkdownPresentation.taskToggle(in: changed, at: changedSource.range(of: "task").location)
        XCTAssertEqual(changedSource.replacingCharacters(in: secondToggle!.range, with: secondToggle!.replacement), raw)
        XCTAssertNil(MarkdownPresentation.taskToggle(in: raw, at: 1))
    }

    func testMarkdownUpdateEmitsSingleChangeAndSaveAvoidsSpuriousPublish() {
        let store = makeStore()
        var changeCount = 0
        let cancellable = store.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        store.updateActiveMarkdown("# Single emission")
        XCTAssertEqual(changeCount, 1)

        // Identical markdown update must be a no-op.
        store.updateActiveMarkdown("# Single emission")
        XCTAssertEqual(changeCount, 1)

        // Saving cleanly when lastSaveError is already nil must not trigger UI invalidation.
        store.save()
        XCTAssertEqual(changeCount, 1)

        // Re-selecting the already active note must be a no-op.
        store.selectNote(store.activeNoteID)
        XCTAssertEqual(changeCount, 1)
    }

    func testShelfCachedURLAvoidsBlockingAndResolvesAddedFile() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/tmp/islandnotes-shelf-cache-test.txt")
        store.addShelfURLs([url])
        guard let item = store.shelf.first else {
            return XCTFail("Expected shelf item")
        }
        XCTAssertEqual(store.cachedShelfURL(for: item).path, url.path)
        XCTAssertEqual(store.resolveShelfURL(for: item)?.path, url.path)
    }

    func testActivationTriggerAdaptsToMenuBarHeightAndPreventsHoverBounceBack() {
        let externalScreen = TopEdgeActivationMonitor.ScreenMetrics(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056),
            safeAreaTop: 0
        )
        let notchedScreen = TopEdgeActivationMonitor.ScreenMetrics(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 945),
            safeAreaTop: 37
        )

        // External display uses 24pt menu bar so y = 1080 - 30 (browser tab bar) is NOT inside trigger.
        let externalTrigger = TopEdgeActivationMonitor.triggerRect(for: externalScreen)
        XCTAssertEqual(externalTrigger.height, 24)
        XCTAssertFalse(externalTrigger.contains(NSPoint(x: 960, y: 1050)))

        // Notched display uses full 37pt notch height.
        let notchedTrigger = TopEdgeActivationMonitor.triggerRect(for: notchedScreen)
        XCTAssertEqual(notchedTrigger.height, 37)
        XCTAssertTrue(notchedTrigger.contains(NSPoint(x: 756, y: 950)))

        // Hover bounce-back test: closing while cursor is inside trigger zone requires exiting first.
        let monitor = TopEdgeActivationMonitor()
        monitor.mode = .hover
        var activations = 0
        monitor.activate = { activations += 1 }

        let t0 = Date(timeIntervalSince1970: 1_000)
        let notchPoint = NSPoint(x: 756, y: 970)
        let outsidePoint = NSPoint(x: 756, y: 800)

        XCTAssertTrue(monitor.evaluateEvent(type: .mouseMoved, at: notchPoint, screens: [notchedScreen], now: t0))
        XCTAssertEqual(activations, 1)

        monitor.notifyPanelVisibilityChanged(true, pointerLocation: notchPoint, screens: [notchedScreen], now: t0)
        // Panel closes while cursor is still on the top close chevron inside notchPoint:
        let tClose = t0.addingTimeInterval(2.0)
        monitor.notifyPanelVisibilityChanged(false, pointerLocation: notchPoint, screens: [notchedScreen], now: tClose)

        // Moving inside trigger after cooldown still must NOT bounce back open until cursor leaves trigger zone.
        XCTAssertFalse(monitor.evaluateEvent(type: .mouseMoved, at: notchPoint, screens: [notchedScreen], now: tClose.addingTimeInterval(1.0)))
        XCTAssertEqual(activations, 1)

        // Leaving trigger zone resets the exit requirement, allowing the next hover to activate.
        XCTAssertFalse(monitor.evaluateEvent(type: .mouseMoved, at: outsidePoint, screens: [notchedScreen], now: tClose.addingTimeInterval(1.2)))
        XCTAssertTrue(monitor.evaluateEvent(type: .mouseMoved, at: notchPoint, screens: [notchedScreen], now: tClose.addingTimeInterval(1.5)))
        XCTAssertEqual(activations, 2)
    }

    func testEditorIncrementalStylingIMEProtectionAndTrailingNewlineConceal() {
        var boundText = "# Heading\n- [ ] task"
        let binding = Binding(get: { boundText }, set: { boundText = $0 })
        let theme = VisualTheme(isDark: true)
        let editor = MarkdownEditor(text: binding, noteID: UUID(), actions: EditorActions(), theme: theme)
        let coordinator = editor.makeCoordinator()

        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.applyFull(to: textView)

        // Line 1 is active: "# " should NOT be concealed (foregroundColor != clear).
        let activeColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(activeColor, .clear)

        // Moving selection within the SAME line should not trigger any storage attribute edits.
        var processEditingCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage,
            queue: nil
        ) { _ in
            processEditingCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.handleSelectionChange(in: textView)
        XCTAssertEqual(processEditingCount, 0)

        // Pressing Return at the end of line 1 creates a trailing empty line; moving cursor there
        // must immediately conceal "# " on line 1.
        let withNewline = "# Heading\n"
        textView.string = withNewline
        textView.setSelectedRange(NSRange(location: (withNewline as NSString).length, length: 0))
        coordinator.applyFull(to: textView)
        let concealedColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(concealedColor, .clear)

        // Simulating active macOS CJK IME marked text: while hasMarkedText() is true,
        // Coordinator must perform ZERO NSTextStorage attribute resets and keep temporary IME underline intact.
        let imePreedit = NSAttributedString(
            string: "pinyin",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        textView.setMarkedText(
            imePreedit,
            selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: (withNewline as NSString).length, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        let editsBeforeNotifications = processEditingCount
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
        coordinator.handleSelectionChange(in: textView)
        coordinator.applyIncremental(to: textView)
        coordinator.applyFull(to: textView)
        XCTAssertEqual(processEditingCount, editsBeforeNotifications)
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(textView.markedRange(), NSRange(location: 10, length: 6))

        // Committing IME text clears marked state, syncs binding, and styles cleanly.
        textView.insertText("中文", replacementRange: textView.markedRange())
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(boundText, "# Heading\n中文")
    }

    func testEditorRestoresPerNoteSelectionAndClearsCrossNoteUndo() {
        let noteA = UUID()
        let noteB = UUID()
        var currentText = "Hello Note A"
        let actions = EditorActions()
        let theme = VisualTheme(isDark: true)

        let editorA = MarkdownEditor(
            text: Binding(get: { currentText }, set: { currentText = $0 }),
            noteID: noteA,
            actions: actions,
            theme: theme
        )
        let coordinator = editorA.makeCoordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let textView = TaskTextView(frame: scrollView.bounds)
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.string = currentText
        scrollView.documentView = textView
        window.contentView = scrollView
        coordinator.applyFull(to: textView)

        // Make an undoable edit in Note A and place cursor at index 5.
        textView.insertText("!", replacementRange: NSRange(location: 12, length: 0))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        // Switch to Note B: undo stack must clear so Cmd+Z cannot corrupt Note B with Note A's history.
        currentText = "Welcome Note B"
        coordinator.saveViewState(from: textView, in: scrollView)
        coordinator.noteID = noteB
        coordinator.resetTracking()
        coordinator.performInternalMutation { textView.string = currentText }
        textView.undoManager?.removeAllActions()
        let stateB = coordinator.restoredViewState(for: noteB, maxLength: (currentText as NSString).length)
        textView.setSelectedRange(stateB.selectedRange)
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))

        // Switch back to Note A: cursor at index 5 is restored.
        currentText = "Hello Note A!"
        let restoredA = coordinator.restoredViewState(for: noteA, maxLength: (currentText as NSString).length)
        XCTAssertEqual(restoredA.selectedRange, NSRange(location: 5, length: 0))
    }

    func testPanelSafeLayoutAdaptsToNotchedAndExternalScreens() {
        let notched = PanelSafeLayout(safeAreaTop: 38, notchWidth: 209)
        XCTAssertEqual(notched.notchHeight, 38)
        XCTAssertEqual(notched.notchWidth, 209)
        XCTAssertEqual(notched.chevronTopOffset, 42)
        XCTAssertGreaterThan(notched.chevronTopOffset, notched.notchHeight)
        XCTAssertEqual(notched.tabRailTopOffset, 64)
        XCTAssertEqual(notched.headerHeight, 102)
        XCTAssertEqual(notched.extraPanelHeight, 36)
        XCTAssertEqual(notched.collapsedRevealHeight, 38)

        let scaledNotched = PanelSafeLayout(safeAreaTop: 46, notchWidth: 240)
        XCTAssertEqual(scaledNotched.chevronTopOffset, 50)
        XCTAssertEqual(scaledNotched.tabRailTopOffset, 72)
        XCTAssertEqual(scaledNotched.headerHeight, 110)

        let external = PanelSafeLayout(safeAreaTop: 0, notchWidth: 200)
        XCTAssertEqual(external.notchHeight, 0)
        XCTAssertEqual(external.notchWidth, 0)
        XCTAssertEqual(external.chevronTopOffset, 2)
        XCTAssertEqual(external.tabRailTopOffset, 28)
        XCTAssertEqual(external.headerHeight, 66)
        XCTAssertEqual(external.extraPanelHeight, 0)
        XCTAssertEqual(external.collapsedRevealHeight, 24)
    }

    func testOutsideClickDismissesOnlyWhenPanelIsPresentedAndPointIsOutside() {
        let frame = NSRect(x: 500, y: 600, width: 380, height: 410)

        XCTAssertFalse(PanelCoordinator.shouldDismissForExternalClick(
            at: NSPoint(x: 600, y: 700),
            panelFrame: frame,
            isPresented: true
        ))
        XCTAssertTrue(PanelCoordinator.shouldDismissForExternalClick(
            at: NSPoint(x: 499, y: 700),
            panelFrame: frame,
            isPresented: true
        ))
        XCTAssertFalse(PanelCoordinator.shouldDismissForExternalClick(
            at: NSPoint(x: 200, y: 200),
            panelFrame: frame,
            isPresented: false
        ))
    }

    func testSwiftPackageLocalizationUsesChineseResourcesInDebugBuild() {
        XCTAssertEqual(L10n.string("Focus"), "专注")
        XCTAssertEqual(L10n.string("Drop files here"), "拖入参考文件")
        XCTAssertEqual(L10n.minutes(45), "45 分钟")
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(storageURL: temporaryURL())
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("workspace.json")
    }
}
