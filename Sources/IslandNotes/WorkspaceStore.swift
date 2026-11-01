import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspace: PersistedWorkspace
    @Published private(set) var lastSaveError: String?

    let storageURL: URL
    private let ioQueue = DispatchQueue(label: "dev.islandnotes.workspace-io", qos: .utility)
    private var pendingSaveTask: Task<Void, Never>?
    private var saveGeneration: UInt64 = 0
    private var shelfURLCache: [UUID: URL] = [:]
    private var resolvingShelfIDs: Set<UUID> = []

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var shouldPersistMigration = false
        if let data = try? Data(contentsOf: self.storageURL),
           var decoded = try? decoder.decode(PersistedWorkspace.self, from: data),
           !decoded.notes.isEmpty,
           decoded.notes.contains(where: { $0.id == decoded.activeNoteID }) {
            shouldPersistMigration = decoded.migrateLegacyEnglishStarterContent()
            self.workspace = decoded
        } else {
            self.workspace = .fresh()
        }
        warmShelfCache(for: self.workspace.shelf)
        if shouldPersistMigration {
            save()
        }
    }

    var notes: [NotePage] { workspace.notes }
    var shelf: [ShelfReference] { workspace.shelf }
    var preferences: AppPreferences { workspace.preferences }
    var activeNoteID: UUID { workspace.activeNoteID }

    var activeNote: NotePage {
        workspace.notes.first(where: { $0.id == workspace.activeNoteID }) ?? workspace.notes[0]
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

    func addShelfURLs(_ urls: [URL]) {
        var knownPaths = Set(workspace.shelf.map(\.originalPath))
        var additions: [ShelfReference] = []
        for url in urls where knownPaths.insert(url.path).inserted {
            let reference = ShelfReference(url: url)
            shelfURLCache[reference.id] = url
            additions.append(reference)
        }
        guard !additions.isEmpty else { return }
        workspace.shelf.append(contentsOf: additions)
        save()
    }

    func removeShelfItem(_ id: UUID) {
        let countBefore = workspace.shelf.count
        workspace.shelf.removeAll { $0.id == id }
        shelfURLCache.removeValue(forKey: id)
        resolvingShelfIDs.remove(id)
        guard workspace.shelf.count != countBefore else { return }
        save()
    }

    /// O(1) non-blocking URL lookup safe for SwiftUI view rendering and drag sources.
    func cachedShelfURL(for item: ShelfReference) -> URL {
        if let cached = shelfURLCache[item.id] {
            return cached
        }
        warmShelfCache(for: [item])
        return URL(fileURLWithPath: item.originalPath)
    }

    /// Resolves bookmark on user action (open / reveal in Finder) and updates the cache.
    func resolveShelfURL(for item: ShelfReference) -> URL? {
        if let resolved = item.resolvedURL() {
            shelfURLCache[item.id] = resolved
            return resolved
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
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        saveGeneration &+= 1
        let snapshot = workspace
        let destination = storageURL
        let errorMessage = ioQueue.sync {
            Self.writeSnapshot(snapshot, to: destination)
        }
        updateSaveError(errorMessage)
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
