import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    let reminder: BreakReminder
    @ObservedObject var layoutState: PanelLayoutState
    @StateObject private var editorActions = EditorActions()
    @State private var renamingID: UUID?
    @State private var titleDraft = ""
    @FocusState private var focusedRenameID: UUID?
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var panelVisible = false
    @State private var screenshotHistoryPresented = false
    let onClose: () -> Void
    let preferencesChanged: () -> Void
    let captureScreenshot: () -> Void

    private var theme: VisualTheme {
        VisualTheme(isDark: store.preferences.themeMode == .dark ||
            (store.preferences.themeMode == .system && systemScheme == .dark))
    }

    private var tabSummaries: [NoteTabSummary] {
        store.notes.map { NoteTabSummary(id: $0.id, title: $0.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            statusRow
            ReminderBannerHost(reminder: reminder, theme: theme)
            VStack(spacing: 0) {
                MarkdownToolbarView(actions: editorActions).equatable()
                theme.edge.frame(height: 1)
                editor
            }
            .background(theme.editor)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.edge, lineWidth: 1))
            .padding(.horizontal, 10)
            shelf
            if let error = store.lastSaveError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.foreground)
        .background(theme.panel)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 18, bottomTrailingRadius: 18, topTrailingRadius: 0))
        .onReceive(NotificationCenter.default.publisher(for: .islandNotesPanelVisibility)) { note in
            let visible = (note.object as? Bool) ?? false
            if panelVisible != visible {
                panelVisible = visible
            }
            if !visible, let activeRename = renamingID {
                commitRename(activeRename)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandNotesCreatePage)) { _ in
            _ = store.addNote()
        }
        .onReceive(NotificationCenter.default.publisher(for: .islandNotesScreenshotCaptured)) { _ in
            screenshotHistoryPresented = true
        }
        .onChange(of: focusedRenameID) { _, focused in
            if focused == nil, let activeRename = renamingID {
                commitRename(activeRename)
            }
        }
    }

    private var header: some View {
        let safeLayout = layoutState.safeLayout
        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ParticleField(
                    accent: theme.accent,
                    focus: theme.focus,
                    safeLayout: safeLayout,
                    active: panelVisible && !reduceMotion
                )
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .frame(width: 40, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .padding(.top, safeLayout.chevronTopOffset)
            }
            .frame(height: safeLayout.topStripHeight)
            HStack(alignment: .bottom, spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(tabSummaries) { summary in
                            tab(for: summary)
                        }
                    }
                }
                Button { _ = store.addNote() } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .light))
                        .frame(width: 28, height: 28).background(theme.accent, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
                .help(L10n.string("New page"))
            }
            .frame(height: 38, alignment: .bottom)
            .padding(.horizontal, 12)
        }
        .frame(height: safeLayout.headerHeight)
        .overlay(alignment: .bottom) { theme.edge.frame(height: 1) }
    }

    private var statusRow: some View {
        HStack {
            FocusProgressRingView(reminder: reminder, theme: theme)
            Spacer()
            if panelVisible {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                        .font(.system(size: 12, weight: .light))
                }
            } else {
                Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                    .font(.system(size: 12, weight: .light))
            }
            Spacer()
            Button {
                screenshotHistoryPresented.toggle()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 30, height: 30)
                    if !store.screenshots.isEmpty {
                        Text("\(store.screenshots.count)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 13, minHeight: 13)
                            .background(theme.accent, in: Circle())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string("Recent screenshots"))
            .accessibilityLabel(L10n.string("Recent screenshots"))
            .popover(isPresented: $screenshotHistoryPresented, arrowEdge: .top) {
                ScreenshotHistoryPopover(
                    store: store,
                    theme: theme,
                    captureScreenshot: {
                        screenshotHistoryPresented = false
                        captureScreenshot()
                    }
                )
            }
            Menu {
                Picker(L10n.string("Open from"), selection: activationBinding) {
                    ForEach(ActivationMode.allCases) { mode in
                        Text(L10n.string(mode.label)).tag(mode)
                    }
                }
                Picker(L10n.string("Theme"), selection: themeBinding) {
                    Text(L10n.string("Dark")).tag(ThemeMode.dark)
                    Text(L10n.string("Light")).tag(ThemeMode.light)
                    Text(L10n.string("System")).tag(ThemeMode.system)
                }
                Toggle(L10n.string("Keep Mac awake"), isOn: keepAwakeBinding)
                Toggle(L10n.string("Break reminder"), isOn: reminderBinding)
                Picker(L10n.string("Break interval"), selection: breakIntervalBinding) {
                    Text(L10n.string("25 minutes")).tag(25)
                    Text(L10n.string("45 minutes")).tag(45)
                    Text(L10n.string("60 minutes")).tag(60)
                }
                Divider()
                Button(L10n.string("Close"), action: onClose).keyboardShortcut("w", modifiers: .command)
                Button(L10n.string("Quit")) { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 46)
    }

    private func tab(for note: NoteTabSummary) -> some View {
        let isActive = note.id == store.activeNoteID
        let isRenaming = renamingID == note.id

        return Group {
            if isRenaming {
                TextField(L10n.string("Title"), text: $titleDraft)
                    .textFieldStyle(.plain)
                    .focused($focusedRenameID, equals: note.id)
                    .frame(width: 84)
                    .padding(.horizontal, 11)
                    .onSubmit { commitRename(note.id) }
                    .onExitCommand { cancelRename() }
            } else {
                Button {
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                        beginRename(for: note)
                    } else {
                        store.selectNote(note.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isActive {
                            Circle().fill(theme.accent).frame(width: 6, height: 6)
                        }
                        Text(note.title).lineLimit(1).frame(maxWidth: 84)
                    }
                    // Keep exact horizontal width identical between active (11 + 6 + 6 + 11 = 34)
                    // and inactive (17 + 17 = 34) states so tabs never jump horizontally on switch.
                    .padding(.horizontal, isActive ? 11 : 17)
                    .frame(minWidth: 68, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(L10n.string("Rename")) {
                        beginRename(for: note)
                    }
                    Button(L10n.string("Delete"), role: .destructive) { store.deleteNote(note.id) }
                        .disabled(store.notes.count == 1)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(isActive ? theme.foreground : theme.secondary)
        .frame(height: 37)
        .background(isActive ? theme.activeTab : theme.inactiveTab,
                    in: UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
    }

    private var editor: some View {
        MarkdownEditor(text: Binding(
            get: { store.activeNote.markdown },
            set: { store.updateActiveMarkdown($0) }
        ), noteID: store.activeNoteID, actions: editorActions, theme: theme)
    }

    private var shelf: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(store.shelf) { item in
                        shelfItem(item)
                    }
                    if store.shelf.isEmpty {
                        Label(L10n.string("Drop files here"), systemImage: "tray")
                            .font(.system(size: 10)).foregroundStyle(theme.secondary)
                    }
                }
                .frame(minHeight: 28)
            }
            theme.edge.frame(width: 1, height: 20)
            FocusShelfButton(reminder: reminder, theme: theme) {
                store.updatePreferences { $0.breakReminderEnabled.toggle() }
                preferencesChanged()
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 54)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            store.addShelfURLs(files)
            return !files.isEmpty
        }
    }

    private func shelfItem(_ item: ShelfReference) -> some View {
        let dragURL = store.cachedShelfURL(for: item)
        return HStack(spacing: 4) {
            Image(systemName: item.displayName.lowercased().hasSuffix(".png") ? "photo" : "doc")
            Text(item.displayName).lineLimit(1).frame(maxWidth: 90)
            Button { store.removeShelfItem(item.id) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.edge, lineWidth: 1))
        .draggable(dragURL)
        .onTapGesture(count: 2) {
            guard let url = store.resolveShelfURL(for: item) else { return }
            NSWorkspace.shared.open(url)
        }
        .contextMenu {
            Button(L10n.string("Open")) {
                guard let url = store.resolveShelfURL(for: item) else { return }
                NSWorkspace.shared.open(url)
            }
            Button(L10n.string("Show in Finder")) {
                guard let url = store.resolveShelfURL(for: item) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button(L10n.string("Remove"), role: .destructive) { store.removeShelfItem(item.id) }
        }
    }

    private func beginRename(for note: NoteTabSummary) {
        titleDraft = note.title
        renamingID = note.id
        DispatchQueue.main.async {
            if renamingID == note.id {
                focusedRenameID = note.id
            }
        }
    }

    private func commitRename(_ id: UUID) {
        guard renamingID == id else { return }
        renamingID = nil
        focusedRenameID = nil
        store.renameNote(id, to: titleDraft)
    }

    private func cancelRename() {
        renamingID = nil
        focusedRenameID = nil
    }

    private var activationBinding: Binding<ActivationMode> {
        Binding(
            get: { store.preferences.activationMode },
            set: { value in
                store.updatePreferences { $0.activationMode = value }
                preferencesChanged()
            }
        )
    }

    private var themeBinding: Binding<ThemeMode> {
        Binding(get: { store.preferences.themeMode }, set: { value in
            store.updatePreferences { $0.themeMode = value }
        })
    }

    private var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { store.preferences.keepAwake },
            set: { value in
                store.updatePreferences { $0.keepAwake = value }
                preferencesChanged()
            }
        )
    }

    private var reminderBinding: Binding<Bool> {
        Binding(
            get: { store.preferences.breakReminderEnabled },
            set: { value in
                store.updatePreferences { $0.breakReminderEnabled = value }
                preferencesChanged()
            }
        )
    }

    private var breakIntervalBinding: Binding<Int> {
        Binding(
            get: { store.preferences.breakIntervalMinutes },
            set: { value in
                store.updatePreferences { $0.breakIntervalMinutes = value }
                preferencesChanged()
            }
        )
    }
}

private struct NoteTabSummary: Equatable, Identifiable {
    let id: UUID
    let title: String
}

private struct ScreenshotHistoryPopover: View {
    @ObservedObject var store: WorkspaceStore
    let theme: VisualTheme
    let captureScreenshot: () -> Void
    @State private var selectedID: UUID?
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("Recent screenshots"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(store.screenshots.count) / 5")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondary)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)

            Button(action: captureScreenshot) {
                HStack(spacing: 8) {
                    Image(systemName: "camera")
                    Text(L10n.string("Capture new screenshot"))
                    Spacer()
                    Text("⌥⌘2")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondary)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(theme.activeTab, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.edge, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 9)

            if store.screenshots.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.system(size: 24, weight: .light))
                    Text(L10n.string("Your five most recent screenshots appear here"))
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 116)
                .padding(.horizontal, 28)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.screenshots) { record in
                        screenshotRow(record)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 320)
        .foregroundStyle(theme.foreground)
        .background(theme.editor)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private func screenshotRow(_ record: ScreenshotRecord) -> some View {
        let url = store.screenshotURL(for: record)
        let selected = selectedID == record.id
        return HStack(spacing: 10) {
            ScreenshotThumbnail(url: url, theme: theme)
            VStack(alignment: .leading, spacing: 4) {
                Text(relativeTimestamp(for: record.createdAt))
                    .font(.system(size: 11, weight: .medium))
                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.secondary)
            }
            Spacer(minLength: 4)
            Button {
                copyScreenshot(record)
            } label: {
                Image(systemName: copiedID == record.id ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(copiedID == record.id ? theme.accent : theme.foreground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(copiedID == record.id ? "Copied" : "Copy screenshot"))
            .accessibilityLabel(L10n.string(copiedID == record.id ? "Copied" : "Copy screenshot"))
        }
        .padding(.horizontal, 8)
        .frame(height: 60)
        .background(selected ? theme.accent.opacity(0.14) : theme.inactiveTab,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? theme.accent : theme.edge, lineWidth: selected ? 1.2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onTapGesture { selectedID = record.id }
        .draggable(url)
        .contextMenu {
            Button(L10n.string("Copy screenshot")) { copyScreenshot(record) }
            Button(L10n.string("Open")) { NSWorkspace.shared.open(url) }
            Button(L10n.string("Show in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button(L10n.string("Delete"), role: .destructive) {
                store.removeScreenshot(record.id)
                if selectedID == record.id { selectedID = nil }
            }
        }
    }

    private func copyScreenshot(_ record: ScreenshotRecord) {
        guard let image = NSImage(contentsOf: store.screenshotURL(for: record)) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else { return }
        copiedID = record.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedID == record.id { copiedID = nil }
        }
    }

    private func relativeTimestamp(for date: Date) -> String {
        let elapsed = max(0, Date().timeIntervalSince(date))
        if elapsed < 60 { return L10n.string("Just now") }
        if elapsed < 3_600 {
            return String(format: L10n.string("Minutes ago format"), Int(elapsed / 60))
        }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.isDateInYesterday(date) {
            return String(format: L10n.string("Yesterday time format"), date.formatted(date: .omitted, time: .shortened))
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}

private struct ScreenshotThumbnail: View {
    let url: URL
    let theme: VisualTheme
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(theme.secondary)
            }
        }
        .frame(width: 76, height: 46)
        .background(theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.edge, lineWidth: 1))
        .task(id: url) {
            image = await Self.loadThumbnail(at: url)
        }
    }

    private static func loadThumbnail(at url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 240,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

private struct MarkdownToolbarView: View, Equatable {
    let actions: EditorActions

    static func == (lhs: MarkdownToolbarView, rhs: MarkdownToolbarView) -> Bool {
        lhs.actions === rhs.actions
    }

    var body: some View {
        HStack(spacing: 5) {
            Button { actions.insertLinePrefix("## ") } label: {
                Text("H").font(.system(size: 14, weight: .light)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Heading"))
            toolbarButton("bold", help: "Bold") { actions.surroundSelection(prefix: "**") }
            toolbarButton("italic", help: "Italic") { actions.surroundSelection(prefix: "_") }
            toolbarButton("chevron.left.forwardslash.chevron.right", help: "Inline code") {
                actions.surroundSelection(prefix: "`")
            }
            toolbarButton("link", help: "Link") {
                actions.surroundSelection(prefix: "[", suffix: "](https://)")
            }
            toolbarButton("checklist", help: "Task") { actions.insertLinePrefix("- [ ] ") }
            Spacer()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemName).frame(width: 28, height: 28) }
            .buttonStyle(.plain)
            .help(L10n.string(help))
    }
}

private struct FocusProgressRingView: View {
    @ObservedObject var reminder: BreakReminder
    let theme: VisualTheme

    var body: some View {
        Circle()
            .stroke(theme.edge, lineWidth: 2.5)
            .overlay(
                Circle()
                    .trim(from: 0, to: reminder.progress)
                    .stroke(theme.accent, lineWidth: 2.5)
                    .rotationEffect(.degrees(-90))
            )
            .frame(width: 22, height: 22)
    }
}

private struct ReminderBannerHost: View {
    @ObservedObject var reminder: BreakReminder
    let theme: VisualTheme

    var body: some View {
        if let message = reminder.message {
            HStack {
                Image(systemName: "figure.stand")
                Text(message).font(.callout)
                Spacer()
                Button(L10n.string("Done")) { reminder.dismiss() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.focus.opacity(0.12))
        }
    }
}

private struct FocusShelfButton: View {
    @ObservedObject var reminder: BreakReminder
    let theme: VisualTheme
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Circle().fill(theme.focus).frame(width: 7, height: 7)
                Text(L10n.string("Focus"))
                Text(L10n.minutes(reminder.remainingMinutes))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(reminder.nextBreakAt == nil ? theme.secondary : theme.foreground)
        }
        .buttonStyle(.plain)
        .help(L10n.string(reminder.nextBreakAt == nil ? "Start focus" : "Stop focus"))
    }
}

private struct ParticleField: View {
    let accent: Color
    let focus: Color
    let safeLayout: PanelSafeLayout
    let active: Bool

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                particleCanvas(phase: timeline.date.timeIntervalSinceReferenceDate, animated: true)
            }
        } else {
            particleCanvas(phase: 0, animated: false)
        }
    }

    private func particleCanvas(phase: TimeInterval, animated: Bool) -> some View {
        Canvas { context, size in
            let halfNotch = safeLayout.notchHeight > 0 ? Double(safeLayout.notchWidth / 2 + 8) : 0
            let centerX = Double(size.width) / 2
            for index in 0..<11 {
                let normalizedX = 0.14 + Double((index * 37) % 73) / 100
                let x = Double(size.width) * normalizedX
                let underNotch = safeLayout.notchHeight > 0 && abs(x + 2 - centerX) < halfNotch
                let minY: Double = underNotch ? Double(safeLayout.notchHeight + 5) : (safeLayout.notchHeight > 0 ? 10 : 3)
                let maxY: Double = max(minY + 4, Double(size.height) - 8)
                let spanY = max(1, maxY - minY)
                let baseY = minY + Double((index * 13) % Int(ceil(spanY)))
                let wave = animated ? sin(phase * 0.55 + Double(index)) * 2 : 0
                let y = min(maxY, max(minY - 1, baseY + wave))
                var triangle = Path()
                triangle.move(to: CGPoint(x: x, y: y))
                triangle.addLine(to: CGPoint(x: x + 4, y: y + 1))
                triangle.addLine(to: CGPoint(x: x + 1, y: y + 5))
                triangle.closeSubpath()
                context.stroke(triangle, with: .color(index % 5 == 0 ? focus.opacity(0.75) : accent.opacity(0.65)), lineWidth: 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}
