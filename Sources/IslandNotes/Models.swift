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
    let id: UUID
    var displayName: String
    var originalPath: String
    var bookmark: Data?

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.displayName = url.lastPathComponent
        self.originalPath = url.path
        self.bookmark = (try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )) ?? (try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ))
    }

    func resolvedURL() -> URL? {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return resolved
            }
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return resolved
            }
        }
        guard !originalPath.isEmpty else { return nil }
        return URL(fileURLWithPath: originalPath)
    }
}

enum ActivationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case click
    case hover
    case menuBarOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .click: "Click"
        case .hover: "Hover"
        case .menuBarOnly: "Menu Bar Only"
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

    enum CodingKeys: String, CodingKey {
        case activationMode, keepAwake, breakReminderEnabled, breakIntervalMinutes, themeMode
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activationMode = try values.decodeIfPresent(ActivationMode.self, forKey: .activationMode) ?? .click
        keepAwake = try values.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        breakReminderEnabled = try values.decodeIfPresent(Bool.self, forKey: .breakReminderEnabled) ?? false
        breakIntervalMinutes = try values.decodeIfPresent(Int.self, forKey: .breakIntervalMinutes) ?? 45
        themeMode = try values.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .dark
    }
}

struct PersistedWorkspace: Codable, Equatable, Sendable {
    var notes: [NotePage]
    var activeNoteID: UUID
    var shelf: [ShelfReference]
    var preferences: AppPreferences

    static func fresh(now: Date = Date()) -> PersistedWorkspace {
        let welcome = L10n.defaultChineseString("Welcome")
        let first = NotePage(title: welcome, markdown: "# \(welcome)\n", createdAt: now, updatedAt: now)
        return PersistedWorkspace(
            notes: [first],
            activeNoteID: first.id,
            shelf: [],
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
