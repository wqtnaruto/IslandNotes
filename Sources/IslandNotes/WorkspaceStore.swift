import Foundation

enum ScreenshotStoreError: LocalizedError {
    case invalidCapture
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidCapture:
            L10n.string("The screenshot could not be saved")
        case let .persistence(message):
            message
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspace: PersistedWorkspace
    @Published private(set) var lastSaveError: String?

    let storageURL: URL
    let screenshotDirectoryURL: URL
    private let ioQueue = DispatchQueue(label: "dev.islandnotes.workspace-io", qos: .utility)
    private var pendingSaveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    private var shelfURLCache: [UUID: URL] = [:]
    private var resolvingShelfIDs: Set<UUID> = []

    init(storageURL: URL? = nil, screenshotDirectoryURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.screenshotDirectoryURL = screenshotDirectoryURL ?? self.storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("Screenshots", isDirectory: true)
        let resolvedScreenshotDirectory = self.screenshotDirectoryURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var shouldPersistMigration = false
        var initialError: String?
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: self.storageURL.path, isDirectory: &isDirectory)

        if exists, !isDirectory.boolValue, let data = try? Data(contentsOf: self.storageURL), !data.isEmpty {
            if var decoded = try? decoder.decode(PersistedWorkspace.self, from: data),
               !decoded.notes.isEmpty {
                if !decoded.notes.contains(where: { $0.id == decoded.activeNoteID }) {
                    decoded.activeNoteID = decoded.notes[0].id
                    shouldPersistMigration = true
                }
                if decoded.migrateLegacyEnglishStarterContent() {
                    shouldPersistMigration = true
                }
                let validScreenshots = decoded.screenshots
                    .prefix(5)
                    .filter { record in
                        record.fileName == URL(fileURLWithPath: record.fileName).lastPathComponent &&
                            FileManager.default.fileExists(
                                atPath: resolvedScreenshotDirectory.appendingPathComponent(record.fileName).path
                            )
                    }
                if Array(validScreenshots) != decoded.screenshots {
                    decoded.screenshots = Array(validScreenshots)
                    shouldPersistMigration = true
                }
                self.workspace = decoded
            } else {
                Self.backupCorruptedWorkspace(at: self.storageURL)
                self.workspace = .fresh()
                initialError = L10n.string("Workspace file could not be read and was backed up")
            }
        } else {
            self.workspace = .fresh()
        }

        Self.cleanupOrphanedScreenshots(
            in: resolvedScreenshotDirectory,
            keeping: Set(self.workspace.screenshots.map(\.fileName))
        )
        warmShelfCache(for: self.workspace.shelf)
        if shouldPersistMigration {
            save()
        } else if let initialError {
            self.lastSaveError = initialError
        }
    }

    var notes: [NotePage] { workspace.notes }
    var shelf: [ShelfReference] { workspace.shelf }
    var screenshots: [ScreenshotRecord] { workspace.screenshots }
    var preferences: AppPreferences { workspace.preferences }
    var activeNoteID: UUID { workspace.activeNoteID }

    var activeNote: NotePage {
        workspace.notes.first(where: { $0.id == workspace.activeNoteID }) ?? workspace.notes[0]
    }

    var activeNoteTaskOverview: MarkdownPresentation.NoteTaskOverview {
        MarkdownPresentation.taskOverview(in: activeNote.markdown)
    }

    func selectNote(_ id: UUID) {
        guard workspace.activeNoteID != id,
              workspace.notes.contains(where: { $0.id == id }) else { return }
        workspace.activeNoteID = id
        scheduleSave(delayNanoseconds: 150_000_000)
    }

    @discardableResult
    func addNote(now: Date = Date()) -> UUID {
        let note = NotePage(createdAt: now, updatedAt: now)
        var updated = workspace
        updated.notes.append(note)
        updated.activeNoteID = note.id
        workspace = updated
        save()
        return note.id
    }

    func deleteNote(_ id: UUID) {
        guard workspace.notes.count > 1,
              let index = workspace.notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = workspace
        updated.notes.remove(at: index)
        if updated.activeNoteID == id {
            updated.activeNoteID = updated.notes[min(index, updated.notes.count - 1)].id
        }
        workspace = updated
        save()
    }

    func renameNote(_ id: UUID, to proposedTitle: String, now: Date = Date()) {
        let cleaned = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              let index = workspace.notes.firstIndex(where: { $0.id == id }) else { return }
        let truncated = String(cleaned.prefix(80))
        guard workspace.notes[index].title != truncated else { return }
        var updatedNote = workspace.notes[index]
        updatedNote.title = truncated
        updatedNote.updatedAt = now
        workspace.notes[index] = updatedNote
        save()
    }

    func updateActiveMarkdown(_ markdown: String, now: Date = Date()) {
        guard let index = workspace.notes.firstIndex(where: { $0.id == workspace.activeNoteID }),
              workspace.notes[index].markdown != markdown else { return }
        var updatedNote = workspace.notes[index]
        updatedNote.markdown = markdown
        updatedNote.updatedAt = now
        workspace.notes[index] = updatedNote
        scheduleSave(delayNanoseconds: 350_000_000)
    }

    @discardableResult
    func completeTask(atStateLocation stateLocation: Int, in noteID: UUID, now: Date = Date()) -> Bool {
        guard let index = workspace.notes.firstIndex(where: { $0.id == noteID }) else { return false }
        let raw = workspace.notes[index].markdown
        let source = raw as NSString
        guard stateLocation >= 0,
              stateLocation < source.length,
              let toggle = MarkdownPresentation.taskToggle(in: raw, at: stateLocation),
              toggle.range.location == stateLocation,
              toggle.replacement == "x" else {
            return false
        }
        var updatedNote = workspace.notes[index]
        updatedNote.markdown = source.replacingCharacters(in: toggle.range, with: "x")
        updatedNote.updatedAt = now
        workspace.notes[index] = updatedNote
        save()
        return true
    }

    @discardableResult
    func addShelfURLs(_ urls: [URL]) -> [UUID] {
        var knownPaths = Set(workspace.shelf.map {
            (shelfURLCache[$0.id] ?? URL(fileURLWithPath: $0.originalPath)).standardizedFileURL.path
        })
        var additions: [ShelfReference] = []
        for rawURL in urls where rawURL.isFileURL {
            let url = rawURL.standardizedFileURL
            guard knownPaths.insert(url.path).inserted else { continue }
            let reference = ShelfReference(url: url)
            shelfURLCache[reference.id] = url
            additions.append(reference)
        }
        guard !additions.isEmpty else { return [] }
        workspace.shelf.append(contentsOf: additions)
        save()
        return additions.map(\.id)
    }

    func removeShelfItem(_ id: UUID) {
        let countBefore = workspace.shelf.count
        workspace.shelf.removeAll { $0.id == id }
        shelfURLCache.removeValue(forKey: id)
        resolvingShelfIDs.remove(id)
        guard workspace.shelf.count != countBefore else { return }
        save()
    }

    func makeTemporaryScreenshotURL() throws -> URL {
        try FileManager.default.createDirectory(
            at: screenshotDirectoryURL,
            withIntermediateDirectories: true
        )
        return screenshotDirectoryURL.appendingPathComponent(".capture-\(UUID().uuidString).png")
    }

    @discardableResult
    func commitScreenshot(
        at temporaryURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        now: Date = Date()
    ) throws -> ScreenshotRecord {
        guard temporaryURL.deletingLastPathComponent().standardizedFileURL == screenshotDirectoryURL.standardizedFileURL,
              FileManager.default.fileExists(atPath: temporaryURL.path),
              pixelWidth > 0,
              pixelHeight > 0 else {
            throw ScreenshotStoreError.invalidCapture
        }

        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let destination = screenshotDirectoryURL.appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        let record = ScreenshotRecord(
            id: id,
            fileName: fileName,
            createdAt: now,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        var updated = workspace
        updated.screenshots.insert(record, at: 0)
        let removed = Array(updated.screenshots.dropFirst(5))
        updated.screenshots = Array(updated.screenshots.prefix(5))

        if let message = writeSnapshotSerialized(updated) {
            try? FileManager.default.removeItem(at: destination)
            updateSaveError(message)
            throw ScreenshotStoreError.persistence(message)
        }

        workspace = updated
        updateSaveError(nil)
        for oldRecord in removed {
            try? FileManager.default.removeItem(at: screenshotURL(for: oldRecord))
        }
        return record
    }

    func discardTemporaryScreenshot(at url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == screenshotDirectoryURL.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func screenshotURL(for record: ScreenshotRecord) -> URL {
        screenshotDirectoryURL.appendingPathComponent(record.fileName)
    }

    func removeScreenshot(_ id: UUID) {
        guard let record = workspace.screenshots.first(where: { $0.id == id }) else { return }
        var updated = workspace
        updated.screenshots.removeAll { $0.id == id }

        if let message = writeSnapshotSerialized(updated) {
            updateSaveError(message)
            return
        }
        workspace = updated
        updateSaveError(nil)
        try? FileManager.default.removeItem(at: screenshotURL(for: record))
    }

    func reportExternalError(_ message: String?) {
        updateSaveError(message)
    }

    /// O(1) non-blocking URL lookup safe for SwiftUI view rendering and drag sources.
    func cachedShelfURL(for item: ShelfReference) -> URL {
        if let cached = shelfURLCache[item.id] {
            return cached
        }
        warmShelfCache(for: [item])
        return URL(fileURLWithPath: item.originalPath)
    }

    /// Resolves bookmark on user action (open / reveal in Finder) and updates stale bookmark metadata.
    func resolveShelfURL(for item: ShelfReference) -> URL? {
        if let resolution = item.resolveBookmark() {
            shelfURLCache[item.id] = resolution.url
            if (resolution.isStale || resolution.url.path != item.originalPath),
               let index = workspace.shelf.firstIndex(where: { $0.id == item.id }) {
                var refreshed = workspace.shelf[index]
                refreshed.displayName = resolution.url.lastPathComponent
                refreshed.originalPath = resolution.url.path
                refreshed.fileSizeBytes = ShelfReference.readFileSize(for: resolution.url)
                if let newBookmark = ShelfReference.makeBookmark(for: resolution.url) {
                    refreshed.bookmark = newBookmark
                }
                if refreshed != workspace.shelf[index] {
                    workspace.shelf[index] = refreshed
                    scheduleSave(delayNanoseconds: 150_000_000)
                }
            }
            return resolution.url
        }
        return shelfURLCache[item.id]
    }

    func updatePreferences(_ transform: (inout AppPreferences) -> Void) {
        var updated = workspace.preferences
        transform(&updated)
        guard updated != workspace.preferences else { return }
        workspace.preferences = updated
        save()
    }

    func save() {
        let errorMessage = writeSnapshotSerialized(workspace)
        updateSaveError(errorMessage)
    }

    private func writeSnapshotSerialized(_ snapshot: PersistedWorkspace) -> String? {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveGeneration &+= 1
        let destination = storageURL
        return ioQueue.sync {
            Self.writeSnapshot(snapshot, to: destination)
        }
    }

    private func scheduleSave(delayNanoseconds: UInt64) {
        pendingSaveTask?.cancel()
        saveGeneration &+= 1
        let generation = saveGeneration
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.enqueueAsyncWrite(generation: generation)
        }
    }

    private func enqueueAsyncWrite(generation: UInt64) {
        let snapshot = workspace
        let destination = storageURL
        ioQueue.async { [weak self] in
            let errorMessage = Self.writeSnapshot(snapshot, to: destination)
            Task { @MainActor [weak self] in
                guard let self, self.saveGeneration == generation else { return }
                self.updateSaveError(errorMessage)
            }
        }
    }

    private func updateSaveError(_ errorMessage: String?) {
        if lastSaveError != errorMessage {
            lastSaveError = errorMessage
        }
    }

    private func warmShelfCache(for items: [ShelfReference]) {
        let unresolved = items.filter { shelfURLCache[$0.id] == nil && !resolvingShelfIDs.contains($0.id) }
        guard !unresolved.isEmpty else { return }
        for item in unresolved {
            resolvingShelfIDs.insert(item.id)
        }
        Task.detached(priority: .utility) { [weak self] in
            var resolvedPairs: [(UUID, URL)] = []
            resolvedPairs.reserveCapacity(unresolved.count)
            for item in unresolved {
                if let url = item.resolvedURL() {
                    resolvedPairs.append((item.id, url))
                }
            }
            let finalPairs = resolvedPairs
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (id, url) in finalPairs where self.workspace.shelf.contains(where: { $0.id == id }) {
                    self.shelfURLCache[id] = url
                }
                for item in unresolved {
                    self.resolvingShelfIDs.remove(item.id)
                }
            }
        }
    }

    nonisolated private static func backupCorruptedWorkspace(at storageURL: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("workspace.corrupt-\(timestamp).json")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: storageURL, to: backupURL)
    }

    nonisolated private static func cleanupOrphanedScreenshots(in directoryURL: URL, keeping validFileNames: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls {
            let name = url.lastPathComponent
            if name.hasPrefix(".capture-"), name.hasSuffix(".png") {
                try? FileManager.default.removeItem(at: url)
            } else if name.hasSuffix(".png"),
                      !validFileNames.contains(name),
                      UUID(uuidString: String(name.dropLast(4))) != nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    nonisolated private static func writeSnapshot(_ snapshot: PersistedWorkspace, to storageURL: URL) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("IslandNotes", isDirectory: true)
            .appendingPathComponent("workspace.json")
    }
}
