import Foundation

struct NotePage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var markdown: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = L10n.defaultChineseString("Untitled"),
        markdown: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ShelfReference: Codable, Equatable, Identifiable, Sendable {
    struct BookmarkResolution: Sendable {
        let url: URL
        let isStale: Bool
    }

    let id: UUID
    var displayName: String
    var originalPath: String
    var bookmark: Data?
    var fileSizeBytes: Int64?

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.displayName = url.lastPathComponent
        self.originalPath = url.path
        self.bookmark = Self.makeBookmark(for: url)
        self.fileSizeBytes = Self.readFileSize(for: url)
    }

    static func readFileSize(for url: URL) -> Int64? {
        guard !url.hasDirectoryPath,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize else { return nil }
        return Int64(fileSize)
    }

    static func makeBookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? (try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))
    }

    func resolveBookmark() -> BookmarkResolution? {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return BookmarkResolution(url: resolved, isStale: stale)
            }
            stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return BookmarkResolution(url: resolved, isStale: stale)
            }
        }
        guard !originalPath.isEmpty else { return nil }
        return BookmarkResolution(url: URL(fileURLWithPath: originalPath), isStale: false)
    }

    func resolvedURL() -> URL? {
        resolveBookmark()?.url
    }
}

struct ScreenshotRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int

    init(
        id: UUID = UUID(),
        fileName: String,
        createdAt: Date = Date(),
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

enum ActivationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case click
    case menuBarOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .click: "Click"
        case .menuBarOnly: "Menu Bar Only"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        switch raw {
        case Self.menuBarOnly.rawValue:
            self = .menuBarOnly
        default:
            // Legacy `"hover"` or unknown values migrate cleanly to `.click`.
            self = .click
        }
    }
}

enum ThemeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case dark, light, system
    var id: String { rawValue }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var activationMode: ActivationMode = .click
    var keepAwake = false
    var breakReminderEnabled = false
    var breakIntervalMinutes = 45
    var themeMode: ThemeMode = .dark
    var notchIslandEnabled = true

    enum CodingKeys: String, CodingKey {
        case activationMode, keepAwake, breakReminderEnabled, breakIntervalMinutes, themeMode, notchIslandEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activationMode = try values.decodeIfPresent(ActivationMode.self, forKey: .activationMode) ?? .click
        keepAwake = try values.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        breakReminderEnabled = try values.decodeIfPresent(Bool.self, forKey: .breakReminderEnabled) ?? false
        breakIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .breakIntervalMinutes) ?? 45
        themeMode = try values.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .dark
        notchIslandEnabled = try values.decodeIfPresent(Bool.self, forKey: .notchIslandEnabled) ?? true
    }
}

struct PersistedWorkspace: Codable, Equatable, Sendable {
    var notes: [NotePage]
    var activeNoteID: UUID
    var shelf: [ShelfReference]
    var screenshots: [ScreenshotRecord]
    var preferences: AppPreferences

    enum CodingKeys: String, CodingKey {
        case notes, activeNoteID, shelf, screenshots, preferences
    }

    init(
        notes: [NotePage],
        activeNoteID: UUID,
        shelf: [ShelfReference],
        screenshots: [ScreenshotRecord] = [],
        preferences: AppPreferences
    ) {
        self.notes = notes
        self.activeNoteID = activeNoteID
        self.shelf = shelf
        self.screenshots = screenshots
        self.preferences = preferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        notes = try values.decode([NotePage].self, forKey: .notes)
        activeNoteID = try values.decode(UUID.self, forKey: .activeNoteID)
        shelf = try values.decodeIfPresent([ShelfReference].self, forKey: .shelf) ?? []
        screenshots = try values.decodeIfPresent([ScreenshotRecord].self, forKey: .screenshots) ?? []
        preferences = try values.decodeIfPresent(AppPreferences.self, forKey: .preferences) ?? AppPreferences()
    }

    static func fresh(now: Date = Date()) -> PersistedWorkspace {
        let welcome = L10n.defaultChineseString("Welcome")
        let first = NotePage(title: welcome, markdown: "# \(welcome)\n", createdAt: now, updatedAt: now)
        return PersistedWorkspace(
            notes: [first],
            activeNoteID: first.id,
            shelf: [],
            screenshots: [],
            preferences: AppPreferences()
        )
    }

    /// Translates only the exact untouched English starter content created by
    /// older builds. User-authored titles and note bodies are never rewritten.
    @discardableResult
    mutating func migrateLegacyEnglishStarterContent() -> Bool {
        let welcome = L10n.defaultChineseString("Welcome")
        let untitled = L10n.defaultChineseString("Untitled")
        var changed = false

        for index in notes.indices {
            if notes[index].title == "Welcome",
               notes[index].markdown == "# Welcome\n",
               notes[index].createdAt == notes[index].updatedAt {
                notes[index].title = welcome
                notes[index].markdown = "# \(welcome)\n"
                changed = true
            } else if notes[index].title == "Untitled",
                      notes[index].markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes[index].title = untitled
                changed = true
            }
        }
        return changed
    }
}
