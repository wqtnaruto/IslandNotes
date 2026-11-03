import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
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
        let addedIDs = store.addShelfURLs([url, url])
        XCTAssertEqual(store.shelf.count, 1)
        XCTAssertEqual(addedIDs, store.shelf.map(\.id))
    }

    func testShelfDragProviderExportsAFileURLInsteadOfPlainText() {
        let provider = ShelfFileDragProvider.makeItemProvider(
            for: URL(fileURLWithPath: "/tmp/example.pdf")
        )
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertFalse(provider.registeredTypeIdentifiers.contains(UTType.utf8PlainText.identifier))
    }

    func testEditorRoutesFileDropToShelfWithoutInsertingPathText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("islandnotes-file-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let fileURL = URL(fileURLWithPath: "/tmp/reference.pdf")
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = "Keep this note unchanged"
        var receivedURLs: [URL] = []
        textView.onFileURLsDropped = { receivedURLs = $0 }

        XCTAssertTrue(textView.acceptFileDrop(from: pasteboard))
        XCTAssertEqual(receivedURLs, [fileURL])
        XCTAssertEqual(textView.string, "Keep this note unchanged")

        pasteboard.clearContents()
        pasteboard.setString("ordinary dragged text", forType: .string)
        receivedURLs.removeAll()
        XCTAssertFalse(textView.acceptFileDrop(from: pasteboard))
        XCTAssertTrue(receivedURLs.isEmpty)
    }

    func testLegacyShelfReferenceWithoutFileSizeStillDecodes() throws {
        let raw = #"{"id":"00000000-0000-0000-0000-000000000001","displayName":"legacy.pdf","originalPath":"/tmp/legacy.pdf","bookmark":null}"#
        let reference = try JSONDecoder().decode(ShelfReference.self, from: Data(raw.utf8))
        XCTAssertEqual(reference.displayName, "legacy.pdf")
        XCTAssertNil(reference.fileSizeBytes)
    }

    func testRemovingShelfReferenceNeverDeletesOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let originalURL = root.appendingPathComponent("keep-me.txt")
        try Data("source".utf8).write(to: originalURL)
        let store = WorkspaceStore(storageURL: root.appendingPathComponent("workspace.json"))
        let addedIDs = store.addShelfURLs([originalURL])
        store.removeShelfItem(addedIDs[0])

        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(store.shelf.isEmpty)
    }

    func testPopulatedShelfRendersAtProductionPanelWidth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let referenceURL = root.appendingPathComponent("产品需求说明.pdf")
        try Data(repeating: 0x20, count: 2_400_000).write(to: referenceURL)
        let store = WorkspaceStore(storageURL: root.appendingPathComponent("workspace.json"))
        store.addShelfURLs([referenceURL])

        let rootView = ContentView(
            store: store,
            reminder: BreakReminder(),
            layoutState: PanelLayoutState(),
            onClose: {},
            preferencesChanged: {},
            captureScreenshot: {}
        )
        .frame(width: 380, height: 410)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 410)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Expected a populated shelf bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let horizontalScale = Double(bitmap.pixelsWide) / 380
        let verticalScale = Double(bitmap.pixelsHigh) / 410
        XCTAssertGreaterThanOrEqual(horizontalScale, 1)
        XCTAssertEqual(horizontalScale, verticalScale, accuracy: 0.01)

        if let snapshotPath = ProcessInfo.processInfo.environment["ISLANDNOTES_SNAPSHOT_PATH"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
        }
    }

    func testLegacyPreferencesDecodeDefaultsToDark() throws {
        let old = #"{"activationMode":"click","keepAwake":true,"breakReminderEnabled":false,"breakIntervalMinutes":25}"#
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(old.utf8))
        XCTAssertEqual(preferences.themeMode, .dark)
        XCTAssertEqual(preferences.breakIntervalMinutes, 25)
        XCTAssertTrue(preferences.keepAwake)

        // Legacy "hover" activation mode migrates cleanly to .click.
        let legacyHover = #"{"activationMode":"hover","keepAwake":false}"#
        let decodedHover = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyHover.utf8))
        XCTAssertEqual(decodedHover.activationMode, .click)
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
        // Markdown syntax symbols stay concealed on ALL lines, including the active line.
        XCTAssertTrue(firstMarkers.contains { source.substring(with: $0.range) == "# " })
        XCTAssertTrue(firstMarkers.contains { source.substring(with: $0.range) == "**" })
        XCTAssertTrue(firstMarkers.contains { source.substring(with: $0.range) == "](url)" })
        XCTAssertTrue(firstMarkers.contains { $0.preserveWidth && source.substring(with: $0.range) == "- [ ]" })

        let secondLine = source.lineRange(for: NSRange(location: firstLine.length, length: 0))
        let secondMarkers = MarkdownPresentation.markers(in: raw, activeLine: secondLine)
        XCTAssertEqual(firstMarkers, secondMarkers)
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

    func testLegacyWorkspaceWithoutScreenshotsDecodesAsEmpty() throws {
        let raw = ##"{"notes":[{"id":"00000000-0000-0000-0000-000000000001","title":"欢迎","markdown":"# 欢迎\n","createdAt":"2001-01-01T00:00:00Z","updatedAt":"2001-01-01T00:00:00Z"}],"activeNoteID":"00000000-0000-0000-0000-000000000001","shelf":[],"preferences":{}}"##
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let workspace = try decoder.decode(PersistedWorkspace.self, from: Data(raw.utf8))
        XCTAssertTrue(workspace.screenshots.isEmpty)
    }

    func testScreenshotHistoryKeepsNewestFiveAndPersistsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStore(
            storageURL: root.appendingPathComponent("workspace.json"),
            screenshotDirectoryURL: root.appendingPathComponent("Screenshots", isDirectory: true)
        )

        for index in 0..<6 {
            let temporary = try store.makeTemporaryScreenshotURL()
            try Data("capture-\(index)".utf8).write(to: temporary)
            try store.commitScreenshot(
                at: temporary,
                pixelWidth: 1_000 + index,
                pixelHeight: 700 + index,
                now: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(store.screenshots.count, 5)
        XCTAssertEqual(store.screenshots.map(\.pixelWidth), [1_005, 1_004, 1_003, 1_002, 1_001])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: store.screenshotDirectoryURL, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }.count,
            5
        )

        let restored = WorkspaceStore(
            storageURL: root.appendingPathComponent("workspace.json"),
            screenshotDirectoryURL: root.appendingPathComponent("Screenshots", isDirectory: true)
        )
        XCTAssertEqual(restored.screenshots, store.screenshots)
    }

    func testScreenshotCommitFailureKeepsWorkspaceUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalidStorageURL = root.appendingPathComponent("workspace-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidStorageURL, withIntermediateDirectories: true)
        let store = WorkspaceStore(
            storageURL: invalidStorageURL,
            screenshotDirectoryURL: root.appendingPathComponent("Screenshots", isDirectory: true)
        )
        let temporary = try store.makeTemporaryScreenshotURL()
        try Data("capture".utf8).write(to: temporary)

        XCTAssertThrowsError(try store.commitScreenshot(at: temporary, pixelWidth: 1200, pixelHeight: 800))
        XCTAssertTrue(store.screenshots.isEmpty)
        XCTAssertTrue(
            (try FileManager.default.contentsOfDirectory(at: store.screenshotDirectoryURL, includingPropertiesForKeys: nil))
                .filter { !$0.lastPathComponent.hasPrefix(".") }.isEmpty
        )
    }

    func testRemovingScreenshotDeletesRecordAndFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkspaceStore(
            storageURL: root.appendingPathComponent("workspace.json"),
            screenshotDirectoryURL: root.appendingPathComponent("Screenshots", isDirectory: true)
        )
        let temporary = try store.makeTemporaryScreenshotURL()
        try Data("capture".utf8).write(to: temporary)
        let record = try store.commitScreenshot(at: temporary, pixelWidth: 1200, pixelHeight: 800)
        let finalURL = store.screenshotURL(for: record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))

        store.removeScreenshot(record.id)
        XCTAssertTrue(store.screenshots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testActivationTriggerAdaptsToMenuBarHeightAndHandlesClickActivation() {
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

        // Click activation test: .leftMouseDown within trigger activates; .mouseMoved is ignored so hover never opens panel.
        let monitor = TopEdgeActivationMonitor()
        monitor.mode = .click
        var activations = 0
        monitor.activate = { activations += 1 }

        let t0 = Date(timeIntervalSince1970: 1_000)
        let notchPoint = NSPoint(x: 756, y: 970)
        let outsidePoint = NSPoint(x: 756, y: 800)

        // Mouse moved does not trigger panel opening (hovering expands the notch card, but does not open the full panel).
        XCTAssertFalse(monitor.evaluateEvent(type: .mouseMoved, at: notchPoint, screens: [notchedScreen], now: t0))
        XCTAssertEqual(activations, 0)

        // Left mouse click within notch trigger zone activates panel!
        XCTAssertTrue(monitor.evaluateEvent(type: .leftMouseDown, at: notchPoint, screens: [notchedScreen], now: t0))
        XCTAssertEqual(activations, 1)

        // Left mouse click outside trigger zone does not activate.
        XCTAssertFalse(monitor.evaluateEvent(type: .leftMouseDown, at: outsidePoint, screens: [notchedScreen], now: t0))
        XCTAssertEqual(activations, 1)

        // In .menuBarOnly mode, clicks at the notch are ignored.
        monitor.mode = .menuBarOnly
        XCTAssertFalse(monitor.evaluateEvent(type: .leftMouseDown, at: notchPoint, screens: [notchedScreen], now: t0))
        XCTAssertEqual(activations, 1)
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

        // Even when Line 1 is active, "# " stays concealed (foregroundColor == clear, 0.1pt font).
        let activeColor = textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(activeColor, .clear)

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

    func testEditorRestoresPerNoteSelectionAndIsolatesPerNoteUndo() {
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
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let renameField = NSTextField(frame: NSRect(x: 0, y: 170, width: 120, height: 24))
        renameField.stringValue = "标题"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let textView = TaskTextView(frame: scrollView.bounds)
        textView.allowsUndo = true
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.string = currentText
        scrollView.documentView = textView
        container.addSubview(renameField)
        container.addSubview(scrollView)
        window.contentView = container
        coordinator.attach(textView: textView)
        coordinator.applyFull(to: textView)

        // Make an undoable edit in Note A and place cursor at index 5.
        window.makeFirstResponder(textView)
        textView.insertText("!", replacementRange: NSRange(location: 12, length: 0))
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(currentText, "Hello Note A!")
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        // Focus rename field: window's shared UndoManager must be completely separate from Note A's UndoManager.
        window.makeFirstResponder(renameField)
        XCTAssertNotIdentical(window.undoManager, textView.undoManager)
        window.undoManager?.undo()
        XCTAssertEqual(currentText, "Hello Note A!")

        // Switch to Note B: Note B gets its own fresh UndoManager so Cmd+Z cannot undo Note A's edit.
        currentText = "Welcome Note B"
        coordinator.saveViewState(from: textView, in: scrollView)
        coordinator.noteID = noteB
        coordinator.resetTracking()
        coordinator.performInternalMutation { textView.string = currentText }
        let stateB = coordinator.restoredViewState(for: noteB, maxLength: (currentText as NSString).length)
        coordinator.performInternalMutation { textView.setSelectedRange(stateB.selectedRange) }
        XCTAssertFalse(textView.undoManager?.canUndo == true)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))

        // Switch back to Note A: both cursor at index 5 AND Note A's undo history are preserved!
        currentText = "Hello Note A!"
        coordinator.noteID = noteA
        coordinator.resetTracking()
        coordinator.performInternalMutation { textView.string = currentText }
        let restoredA = coordinator.restoredViewState(for: noteA, maxLength: (currentText as NSString).length)
        coordinator.performInternalMutation { textView.setSelectedRange(restoredA.selectedRange) }
        coordinator.applyFull(to: textView)
        XCTAssertEqual(restoredA.selectedRange, NSRange(location: 5, length: 0))
        XCTAssertTrue(textView.undoManager?.canUndo == true)

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "Hello Note A")
        XCTAssertEqual(currentText, "Hello Note A")
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
        XCTAssertEqual(L10n.string("Pin panel"), "固定面板")
        XCTAssertEqual(L10n.minutes(45), "45 分钟")
        XCTAssertNil(
            Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en")
        )
    }

    func testMainMenuAndKeyablePanelSupportStandardEditAndMarkdownShortcuts() {
        MainMenuBuilder.install()
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let actions = EditorActions()
        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        textView.string = "hello"
        textView.editorActions = actions
        actions.textView = textView
        panel.contentView = textView
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 5, length: 0))

        let cmdA = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdA))
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 5))

        let cmdB = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )!
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdB))
        XCTAssertEqual(textView.string, "**hello**")

        var createdPages = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .islandNotesCreatePage,
            object: nil,
            queue: nil
        ) { _ in
            createdPages += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let cmdShiftN = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "N",
            charactersIgnoringModifiers: "N",
            isARepeat: false,
            keyCode: 45
        )!
        _ = panel.performKeyEquivalent(with: cmdShiftN)
        XCTAssertEqual(createdPages, 0)

        let cmdN = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "n",
            charactersIgnoringModifiers: "n",
            isARepeat: false,
            keyCode: 45
        )!
        XCTAssertTrue(panel.performKeyEquivalent(with: cmdN))
        XCTAssertEqual(createdPages, 1)
    }

    func testInsertLinePrefixDoesNotMutateFollowingLineAndTogglesCleanly() {
        let actions = EditorActions()
        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        textView.string = "Line 1\nLine 2"
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        actions.textView = textView

        actions.insertLinePrefix("## ")
        XCTAssertEqual(textView.string, "## Line 1\nLine 2")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))

        // Clicking again toggles the prefix off cleanly.
        actions.insertLinePrefix("## ")
        XCTAssertEqual(textView.string, "Line 1\nLine 2")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))

        // Task prefix toggle also strips checked `- [x] ` without touching the next line.
        textView.string = "- [x] Done\nKeep me"
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        actions.insertLinePrefix("- [ ] ")
        XCTAssertEqual(textView.string, "Done\nKeep me")
    }

    func testTaskCheckboxToggleKeepsClickedLineInactiveAndConcealed() {
        var boundText = "# Today\n- [ ] task\n"
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

        let taskLoc = (boundText as NSString).range(of: "task").location
        guard let firstToggle = MarkdownPresentation.taskToggle(in: textView.string, at: taskLoc) else {
            return XCTFail("Expected task toggle")
        }
        textView.toggleTaskWithoutMovingSelection(firstToggle)

        XCTAssertEqual(boundText, "# Today\n- [x] task\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
        let markerColor = textView.textStorage?.attribute(.foregroundColor, at: firstToggle.lineLocation, effectiveRange: nil) as? NSColor
        XCTAssertEqual(markerColor, .clear)

        // Second click immediately unchecks back to `- [ ] task`.
        guard let secondToggle = MarkdownPresentation.taskToggle(in: textView.string, at: taskLoc) else {
            return XCTFail("Expected second task toggle")
        }
        textView.toggleTaskWithoutMovingSelection(secondToggle)
        XCTAssertEqual(boundText, "# Today\n- [ ] task\n")
    }

    func testMarkdownPresentationIgnoresSnakeCaseCodeSpansAndPreservesHeadingFontSize() {
        let raw = "# Release **v1.0**\nuser_profile_id `my_var_name` `**raw**` https://en.wikipedia.org/wiki/Mac_OS_X\n中文_斜体_测试"
        let source = raw as NSString
        let firstLine = source.lineRange(for: NSRange(location: 0, length: 0))
        let markers = MarkdownPresentation.markers(in: raw, activeLine: firstLine)
        let concealedStrings = markers.map { source.substring(with: $0.range) }

        // Only the two underscores around `斜体` are concealed; snake_case and URLs are untouched,
        // and `**raw**` inside backticks is ignored (only `**v1.0**` on line 1 has its 2 `**` markers concealed).
        let underscoreMarkers = markers.filter { source.substring(with: $0.range) == "_" }
        XCTAssertEqual(underscoreMarkers.count, 2)
        let boldMarkers = markers.filter { source.substring(with: $0.range) == "**" }
        XCTAssertEqual(boldMarkers.count, 2)
        XCTAssertEqual(concealedStrings.filter { $0 == "`" }.count, 4)

        // Verify bold inside H1 keeps 22pt heading size instead of shrinking to 14pt body bold.
        var boundText = raw
        let editor = MarkdownEditor(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            noteID: UUID(),
            actions: EditorActions(),
            theme: VisualTheme(isDark: true)
        )
        let coordinator = editor.makeCoordinator()
        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        textView.string = raw
        textView.setSelectedRange(NSRange(location: source.length, length: 0))
        coordinator.applyFull(to: textView)

        let versionLoc = source.range(of: "v1.0").location
        let font = textView.textStorage?.attribute(.font, at: versionLoc, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 22)
    }

    func testFileDragNearNotchActivatesPanelAndPinnedPanelIgnoresOutsideClicks() {
        let notchedScreen = TopEdgeActivationMonitor.ScreenMetrics(
            frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: NSRect(x: 0, y: 0, width: 1512, height: 945),
            safeAreaTop: 37
        )
        let monitor = TopEdgeActivationMonitor()
        monitor.mode = .click
        var dragActivations = 0
        monitor.activateForFileDrag = { dragActivations += 1 }

        let nearNotch = NSPoint(x: 756, y: 940)
        let farBelow = NSPoint(x: 756, y: 700)
        let t0 = Date(timeIntervalSince1970: 2_000)

        XCTAssertFalse(monitor.evaluateFileDrag(at: nearNotch, screens: [notchedScreen], hasDraggedFiles: false, now: t0))
        XCTAssertFalse(monitor.evaluateFileDrag(at: farBelow, screens: [notchedScreen], hasDraggedFiles: true, now: t0))
        XCTAssertTrue(monitor.evaluateFileDrag(at: nearNotch, screens: [notchedScreen], hasDraggedFiles: true, now: t0))
        XCTAssertEqual(dragActivations, 1)

        // Pin behavior check
        let frame = NSRect(x: 500, y: 600, width: 380, height: 410)
        let layoutState = PanelLayoutState()
        XCTAssertFalse(layoutState.isPinned)
        layoutState.togglePin()
        XCTAssertTrue(layoutState.isPinned)
        XCTAssertFalse(PanelCoordinator.shouldDismissForExternalClick(
            at: NSPoint(x: 100, y: 100),
            panelFrame: frame,
            isPresented: true,
            isPinned: layoutState.isPinned
        ))
    }

    func testBreakReminderAutoRevealsPanelOnDeadlineAndRecoversAfterWake() {
        let reminder = BreakReminder()
        var revealCount = 0
        reminder.onBreakTriggered = { revealCount += 1 }

        reminder.configure(enabled: true, intervalMinutes: 25)
        guard let firstDeadline = reminder.nextBreakAt else {
            return XCTFail("Expected deadline")
        }

        reminder.triggerIfDue(now: firstDeadline.addingTimeInterval(1), playSound: false)
        XCTAssertEqual(revealCount, 1)
        XCTAssertNotNil(reminder.message)
        XCTAssertGreaterThan(reminder.nextBreakAt ?? .distantPast, firstDeadline)

        // Simulate Mac sleeping past the next deadline and waking up: timer resets cleanly instead of sticking at 0 min.
        guard let secondDeadline = reminder.nextBreakAt else {
            return XCTFail("Expected second deadline")
        }
        let wakeTime = secondDeadline.addingTimeInterval(3_600)
        reminder.handleSystemWake(now: wakeTime)
        XCTAssertEqual(reminder.remainingMinutes, 25)
        XCTAssertEqual(reminder.progress, 0, accuracy: 0.001)
    }

    func testWorkspaceRepairsInvalidActiveNoteIDAndBacksUpCorruptedJSONAndCleansOrphanScreenshots() throws {
        // 1. Invalid activeNoteID repairs to first note instead of wiping user notes.
        let repairRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: repairRoot, withIntermediateDirectories: true)
        let repairStorage = repairRoot.appendingPathComponent("workspace.json")
        let noteA = NotePage(title: "重要笔记 A", markdown: "内容 A")
        let noteB = NotePage(title: "重要笔记 B", markdown: "内容 B")
        let mismatched = PersistedWorkspace(
            notes: [noteA, noteB],
            activeNoteID: UUID(),
            shelf: [],
            preferences: AppPreferences()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(mismatched).write(to: repairStorage)

        let repairedStore = WorkspaceStore(storageURL: repairStorage)
        XCTAssertEqual(repairedStore.notes.count, 2)
        XCTAssertEqual(repairedStore.activeNoteID, noteA.id)

        // 2. Corrupted workspace.json is backed up before initializing fresh workspace, and orphan screenshots are removed.
        let corruptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let screenshotsDir = corruptRoot.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        let corruptStorage = corruptRoot.appendingPathComponent("workspace.json")
        let rawCorrupt = Data("{broken json".utf8)
        try rawCorrupt.write(to: corruptStorage)

        let staleTemp = screenshotsDir.appendingPathComponent(".capture-\(UUID().uuidString).png")
        let orphanUUID = screenshotsDir.appendingPathComponent("\(UUID().uuidString).png")
        try Data("temp".utf8).write(to: staleTemp)
        try Data("orphan".utf8).write(to: orphanUUID)

        let recoveredStore = WorkspaceStore(storageURL: corruptStorage, screenshotDirectoryURL: screenshotsDir)
        XCTAssertNotNil(recoveredStore.lastSaveError)
        let rootFiles = try FileManager.default.contentsOfDirectory(at: corruptRoot, includingPropertiesForKeys: nil)
        let backups = rootFiles.filter { $0.lastPathComponent.hasPrefix("workspace.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), rawCorrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanUUID.path))
    }

    func testFormattingTogglesHeadingLevelsBulletTasksMidWordItalicAndClipboardLinks() {
        var boundText = "# 大标题"
        let actions = EditorActions()
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("islandnotes-link-\(UUID().uuidString)"))
        testPasteboard.clearContents()
        actions.urlPasteboard = testPasteboard

        let editor = MarkdownEditor(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            noteID: UUID(),
            actions: actions,
            theme: VisualTheme(isDark: true)
        )
        let coordinator = editor.makeCoordinator()
        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.editorActions = actions
        actions.textView = textView
        coordinator.attach(textView: textView)
        textView.string = boundText
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        coordinator.applyFull(to: textView)

        // 1. Heading button converts `# ` -> `## ` instead of stacking `## # `, then toggles off cleanly.
        actions.insertLinePrefix("## ")
        XCTAssertEqual(textView.string, "## 大标题")
        actions.insertLinePrefix("## ")
        XCTAssertEqual(textView.string, "大标题")

        // 2. Task button converts indented `* ` bullet into indented `- [ ] ` instead of `- [ ] * `, and toggles off preserving indent.
        textView.string = "  * 子任务"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        coordinator.applyFull(to: textView)
        actions.insertLinePrefix("- [ ] ")
        XCTAssertEqual(textView.string, "  - [ ] 子任务")
        XCTAssertEqual(MarkdownPresentation.taskCompleted(in: textView.string), false)
        actions.insertLinePrefix("- [ ] ")
        XCTAssertEqual(textView.string, "  子任务")

        // 3. Inline bold toggles on/off cleanly without stacking `****word****`, and supports `***boldItalic***`.
        textView.string = "重点"
        textView.setSelectedRange(NSRange(location: 0, length: 2))
        coordinator.applyFull(to: textView)
        actions.surroundSelection(prefix: "**")
        XCTAssertEqual(textView.string, "**重点**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 2))
        // Concealed `**` markers must have clear foregroundColor even on the active line!
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, .clear)

        // Adding italic on top of bold creates `***重点***` with all 6 asterisks concealed.
        actions.surroundSelection(prefix: "*")
        XCTAssertEqual(textView.string, "***重点***")
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? NSColor, .clear)

        // Toggling bold off leaves `*重点*`; toggling italic off leaves plain `重点`.
        actions.surroundSelection(prefix: "**")
        XCTAssertEqual(textView.string, "*重点*")
        actions.surroundSelection(prefix: "*")
        XCTAssertEqual(textView.string, "重点")

        // 4. Mid-word italic (`xabcx` -> `x*abc*x`) is styled and concealed properly.
        textView.string = "xabcx"
        textView.setSelectedRange(NSRange(location: 1, length: 3))
        coordinator.applyFull(to: textView)
        actions.surroundSelection(prefix: "*")
        XCTAssertEqual(textView.string, "x*abc*x")
        let analysis = MarkdownPresentation.analyze(
            in: textView.string,
            source: textView.string as NSString,
            range: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        XCTAssertEqual(analysis.italicRanges, [NSRange(location: 1, length: 5)])

        // 5. Empty selection uses localized Chinese placeholder ("粗体") and clipboard HTTP URL for links.
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFull(to: textView)
        actions.surroundSelection(prefix: "**")
        XCTAssertEqual(textView.string, "**粗体**")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 2))

        testPasteboard.setString("https://apple.com", forType: .string)
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.applyFull(to: textView)
        actions.surroundSelection(prefix: "[", suffix: "](https://)")
        XCTAssertEqual(textView.string, "[链接](https://apple.com)")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 1, length: 2))
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor, .clear)
    }

    func testSmartBackspaceCaretSnappingListContinuationAndIMEKeyEquivalentGuard() {
        var boundText = "## 标题"
        let actions = EditorActions()
        let editor = MarkdownEditor(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            noteID: UUID(),
            actions: actions,
            theme: VisualTheme(isDark: true)
        )
        let coordinator = editor.makeCoordinator()
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let textView = TaskTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 220))
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.editorActions = actions
        actions.textView = textView
        panel.contentView = textView
        panel.makeFirstResponder(textView)
        coordinator.attach(textView: textView)
        textView.string = boundText
        coordinator.performInternalMutation {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        coordinator.applyFull(to: textView)
        coordinator.snapCaretToVisibleContentIfNeeded(in: textView)

        // Caret snaps past concealed "## " to visible content start (index 3), and Backspace removes "## " in one step.
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "标题")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))

        // Backspace after `**ab**` deletes 'b' -> `**a**`, then deletes the entire `**a**` without leaving `****`!
        textView.string = "**ab**"
        coordinator.applyFull(to: textView)
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        coordinator.handleSelectionChange(in: textView)
        // Typing attributes right after `**ab**` must NOT inherit 0.1pt `.clear` from concealed `*`!
        XCTAssertNotEqual(textView.typingAttributes[.foregroundColor] as? NSColor, .clear)
        let typingFont = textView.typingAttributes[.font] as? NSFont
        XCTAssertEqual(typingFont?.pointSize, 14)

        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "**a**")
        textView.deleteBackward(nil)
        XCTAssertEqual(textView.string, "")

        // Moving right/left across `[官网](https://example.com)` skips the entire hidden `](https://example.com)` in 1 keystroke!
        textView.string = "[官网](https://example.com)!"
        coordinator.applyFull(to: textView)
        coordinator.performInternalMutation {
            textView.setSelectedRange(NSRange(location: 3, length: 0)) // end of "官网"
        }
        textView.moveRight(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 25, length: 0))
        textView.moveLeft(nil)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 0))

        // List / task auto-continuation on Return, indent/outdent on Tab / Backtab, and list exit on empty Return.
        textView.string = "- [x] 第一项"
        coordinator.applyFull(to: textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- [x] 第一项\n- [ ] ")

        // Tab indents the new task line by 2 spaces, and indented task toggle works.
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, "- [x] 第一项\n  - [ ] ")
        textView.insertText("子项", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "- [x] 第一项\n  - [ ] 子项")
        let subLoc = (textView.string as NSString).range(of: "子项").location
        let toggle = MarkdownPresentation.taskToggle(in: textView.string, at: subLoc)
        XCTAssertEqual(toggle?.indentLength, 2)
        textView.insertBacktab(nil)
        XCTAssertEqual(textView.string, "- [x] 第一项\n- [ ] 子项")

        // Pressing Return at end creates empty `- [ ] `, and pressing Return again exits the task list cleanly.
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- [x] 第一项\n- [ ] 子项\n- [ ] ")
        textView.insertNewline(nil)
        XCTAssertEqual(textView.string, "- [x] 第一项\n- [ ] 子项\n")

        // IME marked-text guard in performKeyEquivalent: Cmd+B must NOT wrap/corrupt active Pinyin composition.
        textView.string = ""
        coordinator.applyFull(to: textView)
        textView.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        let cmdB = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: "b",
            charactersIgnoringModifiers: "b",
            isARepeat: false,
            keyCode: 11
        )!
        _ = textView.performKeyEquivalent(with: cmdB)
        XCTAssertEqual(textView.string, "nihao")

        // Title draft sanitization strips pasted line breaks and clamps to 80 characters.
        XCTAssertEqual(ContentView.sanitizedTitleDraft("第一行\r\n第二行\n第三行"), "第一行 第二行 第三行")
        XCTAssertEqual(ContentView.sanitizedTitleDraft(String(repeating: "中", count: 95)).count, 80)
    }

    func testChineseThoughtsTodosAndIMEFontSubstitutionAndLayoutAdvances() throws {
        var boundText = """
        # 中文标题
        记录今天的产品想法
        - [ ] 完成中文待办
        - [x] 已完成待办
        - 普通列表中文
        > 引用中文思考
        **粗体中文** *斜体中文* `代码中文` [中文链接](https://example.com/文档)
        """
        let actions = EditorActions()
        let hosted = NSHostingView(
            rootView: MarkdownEditor(
                text: Binding(get: { boundText }, set: { boundText = $0 }),
                noteID: UUID(),
                actions: actions,
                theme: VisualTheme(isDark: true)
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 360, height: 340)
        window.contentView = hosted
        hosted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosted.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(actions.textView as? TaskTextView)
        XCTAssertTrue(textView.isRichText)
        XCTAssertFalse(textView.importsGraphics)
        XCTAssertFalse(textView.allowsImageEditing)

        let storage = try XCTUnwrap(textView.textStorage)
        let manager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        manager.ensureLayout(for: container)

        let source = textView.string as NSString
        let visibleSamples = ["中文标题", "记录今天的产品想法", "完成中文待办", "已完成待办", "普通列表中文", "引用中文思考", "粗体中文", "斜体中文", "代码中文", "中文链接"]
        for sample in visibleSamples {
            let sampleRange = source.range(of: sample)
            XCTAssertNotEqual(sampleRange.location, NSNotFound, "Missing sample: \(sample)")
            for offset in 0..<sampleRange.length {
                let charIndex = sampleRange.location + offset
                let font = try XCTUnwrap(storage.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont)
                XCTAssertFalse(
                    font.fontName.hasPrefix(".AppleSystemUIFont"),
                    "Chinese char in '\(sample)' still had Latin-only system font \(font.fontName)"
                )
                let glyphRange = manager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
                XCTAssertGreaterThan(rect.width, 10, "Chinese char in '\(sample)' collapsed to zero/tiny width (\(rect.width))")
            }
        }

        // Italic Chinese receives synthetic obliqueness since CJK fallback fonts lack a native italic face.
        let italicLoc = source.range(of: "斜体中文").location
        let obliqueness = storage.attribute(.obliqueness, at: italicLoc, effectiveRange: nil) as? Double ?? 0
        XCTAssertGreaterThan(obliqueness, 0.1)

        // Unchecked `- [ ] ` and checked `- [x] ` align visible Chinese task content at the exact same X offset.
        let uncheckedGlyph = manager.glyphIndexForCharacter(at: source.range(of: "完成中文待办").location)
        let checkedGlyph = manager.glyphIndexForCharacter(at: source.range(of: "已完成待办").location)
        XCTAssertEqual(manager.location(forGlyphAt: uncheckedGlyph).x, manager.location(forGlyphAt: checkedGlyph).x, accuracy: 0.05)

        // Live Chinese IME pre-edit (`setMarkedText`) lays out with CJK fallback font & non-zero width before commit,
        // and committing (`insertText`) syncs `boundText` and clears pre-edit underline.
        let appendPos = (textView.string as NSString).length
        textView.insertText("\n", replacementRange: NSRange(location: appendPos, length: 0))
        let marked = NSAttributedString(
            string: "实时拼音输入",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        textView.setMarkedText(marked, selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        manager.ensureLayout(for: container)

        let markedRange = (textView.string as NSString).range(of: "实时拼音输入")
        let markedGlyphs = manager.glyphRange(forCharacterRange: markedRange, actualCharacterRange: nil)
        XCTAssertGreaterThan(manager.boundingRect(forGlyphRange: markedGlyphs, in: container).width, 60)

        // Outside-click dismissal must ignore clicks on external IME candidate windows while `hasMarkedText` is true.
        let panelFrame = NSRect(x: 400, y: 500, width: 360, height: 380)
        XCTAssertFalse(
            PanelCoordinator.shouldDismissForExternalClick(
                at: NSPoint(x: 100, y: 100),
                panelFrame: panelFrame,
                isPresented: true,
                isPinned: false,
                hasMarkedText: true
            )
        )
        XCTAssertTrue(
            PanelCoordinator.shouldDismissForExternalClick(
                at: NSPoint(x: 100, y: 100),
                panelFrame: panelFrame,
                isPresented: true,
                isPinned: false,
                hasMarkedText: false
            )
        )

        // Commit Chinese IME text via `insertText`: syncs binding, keeps CJK glyphs > 60pt wide, and strips underline.
        textView.insertText("实时拼音输入", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertTrue(boundText.hasSuffix("实时拼音输入"))
        let committedRange = (textView.string as NSString).range(of: "实时拼音输入")
        XCTAssertNil(storage.attribute(.underlineStyle, at: committedRange.location, effectiveRange: nil))
        let committedGlyphs = manager.glyphRange(forCharacterRange: committedRange, actualCharacterRange: nil)
        manager.ensureLayout(for: container)
        XCTAssertGreaterThan(manager.boundingRect(forGlyphRange: committedGlyphs, in: container).width, 60)

        // Committing raw pre-edit Latin text via `unmarkText()` (Return in Pinyin IME) also syncs binding & strips underline.
        let preeditLatin = NSAttributedString(
            string: "rawime",
            attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        )
        textView.setMarkedText(preeditLatin, selectedRange: NSRange(location: 6, length: 0), replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        XCTAssertTrue(textView.hasMarkedText())
        textView.unmarkText()
        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertTrue(boundText.hasSuffix("rawime"))
        let rawLoc = (textView.string as NSString).range(of: "rawime").location
        XCTAssertNil(storage.attribute(.underlineStyle, at: rawLoc, effectiveRange: nil))
    }

    func testPinnedTaskOverviewExtractsFirstUncheckedSkipsFencesAndStripsInlineSyntax() {
        let markdown = """
        # 今日重点
        ```markdown
        - [ ] 代码块里的伪待办不应外露
        ```
        - [x] 已完成的晨会同步
        - [ ]    
        - [ ] 完成 **灵动岛** [微交互设计](https://example.com/spec) 与 `Notch_UI` 联调
          * [ ] 补充单元测试
        ~~~
        + [ ] 波浪线代码块里的伪任务
        ~~~
        """

        let overview = MarkdownPresentation.taskOverview(in: markdown)
        XCTAssertEqual(overview.completedCount, 1)
        XCTAssertEqual(overview.uncheckedCount, 2)
        XCTAssertEqual(overview.totalCount, 3)
        XCTAssertEqual(overview.firstUnchecked?.displayText, "完成 灵动岛 微交互设计 与 Notch_UI 联调")
    }

    func testCompletingPinnedTaskFromIslandAdvancesQueueAndPersists() async throws {
        let location = temporaryURL()
        let store = WorkspaceStore(storageURL: location)
        store.updateActiveMarkdown("- [ ] 第一项核心任务\n- [ ] 第二项跟进任务\n")
        store.save()

        let reminder = BreakReminder()
        let model = NotchIslandModel(store: store, reminder: reminder)
        XCTAssertEqual(model.snapshot.pinnedTask?.displayText, "第一项核心任务")
        XCTAssertTrue(model.snapshot.shouldPresent)

        model.completeCurrentPinnedTask()
        XCTAssertTrue(model.snapshot.isShowingCompletedFeedback)
        XCTAssertEqual(model.snapshot.effectiveTaskText, "第一项核心任务")
        XCTAssertEqual(store.activeNote.markdown, "- [x] 第一项核心任务\n- [ ] 第二项跟进任务\n")

        // Invalid or already-completed task locations are safely rejected.
        XCTAssertFalse(store.completeTask(atStateLocation: 3, in: store.activeNoteID))
        XCTAssertFalse(store.completeTask(atStateLocation: 999, in: store.activeNoteID))

        // After feedback window completes, the island advances to the second unchecked task.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(model.snapshot.isShowingCompletedFeedback)
        XCTAssertEqual(model.snapshot.pinnedTask?.displayText, "第二项跟进任务")
        XCTAssertEqual(model.snapshot.completedCount, 1)
        XCTAssertEqual(model.snapshot.uncheckedCount, 1)

        let restored = WorkspaceStore(storageURL: location)
        XCTAssertEqual(restored.activeNoteTaskOverview.firstUnchecked?.displayText, "第二项跟进任务")
    }

    func testNotchIslandPreferencesBackwardCompatibilityAndVisibilityRules() throws {
        let legacyJSON = #"{"activationMode":"click","keepAwake":false,"breakReminderEnabled":false,"breakIntervalMinutes":25}"#
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.notchIslandEnabled)
        XCTAssertEqual(L10n.string("Notch island"), "灵动岛状态")
        XCTAssertEqual(L10n.compactMinutes(25), "25分钟")

        let location = temporaryURL()
        let store = WorkspaceStore(storageURL: location)
        let reminder = BreakReminder()
        let model = NotchIslandModel(store: store, reminder: reminder)

        // Default welcome note has no tasks, no focus timer, and keepAwake == false -> island stays hidden.
        XCTAssertFalse(model.snapshot.shouldPresent)

        // Enabling keepAwake presents the island with breathing bar.
        store.updatePreferences { $0.keepAwake = true }
        model.refreshSnapshot()
        XCTAssertTrue(model.snapshot.shouldPresent)
        XCTAssertTrue(model.snapshot.hasProgressOrBreathingBar)

        // Opening the main panel or suppressing for screenshot capture hides the island.
        model.setMainPanelVisible(true)
        XCTAssertFalse(model.snapshot.shouldPresent)
        model.setMainPanelVisible(false)
        XCTAssertTrue(model.snapshot.shouldPresent)

        model.setSuppressed(true)
        XCTAssertFalse(model.snapshot.shouldPresent)
        model.setSuppressed(false)
        XCTAssertTrue(model.snapshot.shouldPresent)

        // Turning off notchIslandEnabled persists and hides the island.
        store.updatePreferences { $0.notchIslandEnabled = false }
        model.refreshSnapshot()
        XCTAssertFalse(model.snapshot.shouldPresent)

        let restored = WorkspaceStore(storageURL: location)
        XCTAssertFalse(restored.preferences.notchIslandEnabled)
    }

    func testNotchIslandGeometryAlignsHardwareNotchAndRestrictsHitTesting() {
        let store = makeStore()
        store.updateActiveMarkdown("- [ ] 完成灵动岛几何对齐校验")
        let reminder = BreakReminder()
        reminder.configure(enabled: true, intervalMinutes: 25)
        let model = NotchIslandModel(store: store, reminder: reminder)
        model.refreshSnapshot()

        let notchedSafe = PanelSafeLayout(safeAreaTop: 38, notchWidth: 210)
        let compact = NotchIslandLayout.compute(
            safeLayout: notchedSafe,
            snapshot: model.snapshot,
            isPeeking: false
        )
        // Even with asymmetric left (focus) and right (task) wings, the hardware notch cutout must stay
        // centered at exact canvas midpoint [300 - 105, 300 + 105] == [195, 405].
        let rect = compact.interactiveRect
        let notchStartX = rect.minX + NotchIslandLayout.topEarRadius + compact.leftWingWidth
        let notchEndX = notchStartX + compact.centerNotchWidth
        XCTAssertEqual(notchStartX, NotchIslandLayout.canvasWidth / 2 - 105, accuracy: 0.01)
        XCTAssertEqual(notchEndX, NotchIslandLayout.canvasWidth / 2 + 105, accuracy: 0.01)
        XCTAssertEqual(compact.bodyHeight, 41)

        // Hit-testing container passes clicks outside the visible island rect (e.g. menu bar sides & Chrome tabs below).
        let windowRect = NSRect(x: 0, y: 0, width: NotchIslandLayout.canvasWidth, height: compact.windowHeight)
        let panel = IslandPanel(
            contentRect: windowRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let container = IslandHitTestContainerView(frame: windowRect)
        let child = NSView(frame: windowRect)
        container.addSubview(child)
        panel.contentView = container
        container.interactiveRect = rect

        // Point inside right wing near top of window (flipped y = 18): hits child!
        let insideRightWing = NSPoint(x: notchEndX + 30, y: windowRect.height - 18)
        XCTAssertNotNil(container.hitTest(insideRightWing))

        // Point to the far left in menu bar (x = 30, flipped y = 12): passes through (nil)!
        let outsideLeftMenu = NSPoint(x: 30, y: windowRect.height - 12)
        XCTAssertNil(container.hitTest(outsideLeftMenu))

        // Point below compact island (flipped y = 60 > 41, e.g. browser tab bar): passes through (nil)!
        let belowCompactInCardRow = NSPoint(x: 350, y: windowRect.height - 60)
        XCTAssertNil(container.hitTest(belowCompactInCardRow))

        // Point just past the resting right wing is initially outside hit-testing.
        let extendedRightPoint = NSPoint(
            x: notchEndX + compact.rightWingWidth + NotchIslandLayout.topEarRadius + 3,
            y: windowRect.height - 18
        )
        XCTAssertNil(container.hitTest(extendedRightPoint))

        // On hover (`isPeeking == true`), windowHeight stays constant (zero NSWindow resize jump),
        // hardware notch cutout stays locked at [245, 455], both wings expand monotonically outward
        // (never shrinking inward away from the pointer!), and the two-line below-notch card (`80pt`)
        // becomes interactive while points below the card (`y = 86`) still pass through.
        let peek = NotchIslandLayout.compute(safeLayout: notchedSafe, snapshot: model.snapshot, isPeeking: true)
        container.interactiveRect = peek.interactiveRect
        XCTAssertEqual(peek.windowHeight, compact.windowHeight)
        XCTAssertEqual(peek.compactLeftWingWidth, compact.compactLeftWingWidth, accuracy: 0.01)
        XCTAssertEqual(peek.peekTotalBodyWidth, compact.peekTotalBodyWidth, accuracy: 0.01)
        XCTAssertGreaterThan(peek.leftWingWidth, compact.leftWingWidth)
        XCTAssertGreaterThan(peek.rightWingWidth, compact.rightWingWidth)
        XCTAssertEqual(peek.bodyHeight, 80, accuracy: 0.01)
        let peekNotchStartX = peek.interactiveRect.minX + NotchIslandLayout.topEarRadius + peek.leftWingWidth
        XCTAssertEqual(peekNotchStartX, notchStartX, accuracy: 0.01)
        XCTAssertNotNil(container.hitTest(extendedRightPoint))
        XCTAssertNotNil(container.hitTest(belowCompactInCardRow))
        let belowExpandedCard = NSPoint(x: 350, y: windowRect.height - 86)
        XCTAssertNil(container.hitTest(belowExpandedCard))

        // Retracted state tucks both wings cleanly behind the hardware notch with zero interactive hit area
        // while keeping both compact and peek internal layer widths constant.
        let retracted = NotchIslandLayout.compute(
            safeLayout: notchedSafe,
            snapshot: model.snapshot,
            isPeeking: false,
            isRetracted: true
        )
        XCTAssertEqual(retracted.leftWingWidth, 0, accuracy: 0.01)
        XCTAssertEqual(retracted.rightWingWidth, 0, accuracy: 0.01)
        XCTAssertEqual(retracted.peekTotalBodyWidth, compact.peekTotalBodyWidth, accuracy: 0.01)
        XCTAssertEqual(retracted.interactiveRect, .zero)
        reminder.configure(enabled: false, intervalMinutes: 25)
    }

    func testBreakReminderRefreshesProgressWhileCollapsedIslandIsVisible() {
        let reminder = BreakReminder()
        reminder.configure(enabled: true, intervalMinutes: 25)
        XCTAssertFalse(reminder.isUIRefreshTimerActive)

        reminder.setIslandVisible(true)
        XCTAssertTrue(reminder.isUIRefreshTimerActive)

        reminder.setPanelVisible(true)
        XCTAssertTrue(reminder.isUIRefreshTimerActive)

        reminder.setPanelVisible(false)
        XCTAssertTrue(reminder.isUIRefreshTimerActive)

        reminder.setIslandVisible(false)
        XCTAssertFalse(reminder.isUIRefreshTimerActive)
        reminder.configure(enabled: false, intervalMinutes: 25)
    }

    func testNotchIslandRendersCompactAndPeekStatesCleanly() throws {
        let store = makeStore()
        store.updateActiveMarkdown("# 迭代计划\n- [ ] 打磨刘海灵动岛专注进度与置顶待办\n- [ ] 验证外接显示器兼容\n")
        let reminder = BreakReminder()
        reminder.configure(enabled: true, intervalMinutes: 25)
        if let deadline = reminder.nextBreakAt {
            reminder.refresh(now: deadline.addingTimeInterval(-18 * 60))
        }
        let model = NotchIslandModel(store: store, reminder: reminder)
        model.refreshSnapshot()

        let snapshotDir = ProcessInfo.processInfo.environment["ISLANDNOTES_ISLAND_SNAPSHOT_DIR"]

        let cases: [(name: String, markdown: String, safeLayout: PanelSafeLayout, peeking: Bool)] = [
            ("notched-compact", "# 迭代计划\n- [ ] 打磨刘海灵动岛专注进度与置顶待办\n- [ ] 验证外接显示器兼容\n", PanelSafeLayout(safeAreaTop: 38, notchWidth: 209), false),
            ("notched-peek", "# 迭代计划\n- [ ] 打磨刘海灵动岛专注进度与置顶待办\n- [ ] 验证外接显示器兼容\n", PanelSafeLayout(safeAreaTop: 38, notchWidth: 209), true),
            ("notched-short-compact", "- [ ] 会话洞察需求\n", PanelSafeLayout(safeAreaTop: 38, notchWidth: 209), false),
            ("notched-short-peek", "- [ ] 会话洞察需求\n", PanelSafeLayout(safeAreaTop: 38, notchWidth: 209), true),
            ("external-compact", "# 迭代计划\n- [ ] 打磨刘海灵动岛专注进度与置顶待办\n- [ ] 验证外接显示器兼容\n", PanelSafeLayout(safeAreaTop: 0, notchWidth: 0), false),
            ("external-peek", "# 迭代计划\n- [ ] 打磨刘海灵动岛专注进度与置顶待办\n- [ ] 验证外接显示器兼容\n", PanelSafeLayout(safeAreaTop: 0, notchWidth: 0), true)
        ]

        for testCase in cases {
            store.updateActiveMarkdown(testCase.markdown)
            model.refreshSnapshot()
            model.isPeeking = testCase.peeking
            let layoutState = PanelLayoutState(safeLayout: testCase.safeLayout)
            let islandLayout = NotchIslandLayout.compute(
                safeLayout: testCase.safeLayout,
                snapshot: model.snapshot,
                isPeeking: testCase.peeking
            )
            let size = NSSize(width: NotchIslandLayout.canvasWidth, height: islandLayout.windowHeight)
            let view = NotchIslandView(
                model: model,
                layoutState: layoutState,
                onExpandPanel: {},
                onFilesDropped: { _ in false }
            )
            .frame(width: size.width, height: size.height)

            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()

            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(size.width))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(size.height))

            if let snapshotDir, let png = bitmap.representation(using: .png, properties: [:]) {
                let dirURL = URL(fileURLWithPath: snapshotDir, isDirectory: true)
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
                try png.write(to: dirURL.appendingPathComponent("\(testCase.name).png"), options: .atomic)
            }
        }
        reminder.configure(enabled: false, intervalMinutes: 25)
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
