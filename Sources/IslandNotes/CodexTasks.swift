import Foundation

struct CodexTask: Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String?
    let project: String?
    let startedAt: Date

    var conversationURL: URL {
        URL(string: "codex://threads/\(id.uuidString.lowercased())")!
    }
}

enum CodexActivity: Equatable, Sendable {
    case loading
    case available([CodexTask])
    case unavailable

    var tasks: [CodexTask] {
        guard case let .available(tasks) = self else { return [] }
        return tasks
    }
}

struct CodexTaskReader {
    private let home: URL
    private var sessions: [URL: CodexSession] = [:]

    init(home: URL? = nil) {
        let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        self.home = (home ?? configuredHome.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).resolvingSymlinksInPath()
    }

    mutating func refresh() -> CodexActivity {
        do {
            return try refresh(openFiles: Self.openCodexFiles())
        } catch {
            return .unavailable
        }
    }

    mutating func refresh(openFiles: Set<URL>) throws -> CodexActivity {
        // A session left on disk after a crash may have a start without a completion.
        // Only sessions still open for writing in a Codex process can be active.
        let sessionsDirectory = home.appendingPathComponent("sessions").resolvingSymlinksInPath()
        let paths = Set(openFiles.map(\.standardizedFileURL).filter {
            $0.path.hasPrefix(sessionsDirectory.path + "/")
                && $0.lastPathComponent.hasPrefix("rollout-")
                && $0.pathExtension == "jsonl"
        })
        sessions = sessions.filter { paths.contains($0.key) }

        var active: [UUID: CodexSession] = [:]
        for path in paths {
            var session = sessions[path] ?? CodexSession()
            do {
                try session.readAppendedRecords(at: path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                sessions.removeValue(forKey: path)
                continue
            }
            sessions[path] = session
            guard let id = session.id, let turn = session.turn else { continue }
            if let previous = active[id]?.turn, previous.startedAt >= turn.startedAt { continue }
            active[id] = session
        }

        guard !active.isEmpty else { return .available([]) }
        let titles = try readTitles(for: Set(active.keys))
        let tasks = active.compactMap { id, session in
            session.turn.map { turn in
                CodexTask(id: id, title: titles[id], project: session.project, startedAt: turn.startedAt)
            }
        }
        return .available(tasks.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        })
    }

    private func readTitles(for ids: Set<UUID>) throws -> [UUID: String] {
        struct Title: Decodable {
            let id: UUID
            let thread_name: String
        }

        let data: Data
        do {
            data = try Data(contentsOf: home.appendingPathComponent("session_index.jsonl"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        let decoder = JSONDecoder()
        var titles: [UUID: String] = [:]
        for line in data.split(separator: 10).reversed() {
            guard let entry = try? decoder.decode(Title.self, from: line),
                  ids.contains(entry.id), titles[entry.id] == nil else { continue }
            let name = entry.thread_name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { titles[entry.id] = name }
            if titles.count == ids.count { break }
        }
        return titles
    }

    private static func openCodexFiles() throws -> Set<URL> {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-u", String(getuid()), "-c", "/^codex$/", "-F0fatn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof returns 1 with no output when there are no matching processes.
        if process.terminationStatus == 1 && data.isEmpty { return [] }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }

        var paths: Set<URL> = []
        var canWrite = false
        var isRegular = false
        for field in data.split(separator: 0) {
            let value = field.drop(while: { $0 == 10 })
            switch value.first {
            case 102: // f: file descriptor
                canWrite = false
                isRegular = false
            case 97: // a: access
                canWrite = value.dropFirst().elementsEqual("w".utf8) || value.dropFirst().elementsEqual("u".utf8)
            case 116: // t: file type
                isRegular = value.dropFirst().elementsEqual("REG".utf8)
            case 110 where canWrite && isRegular: // n: path
                let path = String(decoding: value.dropFirst(), as: UTF8.self)
                if path.hasPrefix("/") && path.hasSuffix(".jsonl") {
                    paths.insert(URL(fileURLWithPath: path))
                }
            default:
                break
            }
        }
        return paths
    }
}

private struct CodexSession {
    struct Turn {
        let id: String
        let startedAt: Date
    }

    private struct Record: Decodable {
        struct Payload: Decodable {
            let type: String?
            let id: UUID?
            let thread_source: String?
            let source: String?
            let cwd: String?
            let turn_id: String?
            let root_turn_id: String?
            let started_at: Double?
        }

        let type: String
        let payload: Payload
    }

    private static let recordTypes = [
        "session_meta", "task_started", "task_complete", "turn_aborted"
    ].map { Data("\"\($0)\"".utf8) }

    private var offset: UInt64 = 0
    private(set) var id: UUID?
    private(set) var project: String?
    private(set) var turn: Turn?

    mutating func readAppendedRecords(at url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let end = try file.seekToEnd()
        if end < offset { self = CodexSession() }
        guard end > offset else { return }
        try file.seek(toOffset: offset)

        var pending = Data()
        var remaining = end - offset
        let decoder = JSONDecoder()
        while remaining > 0, let chunk = try file.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty {
            remaining -= UInt64(chunk.count)
            let lines = chunk.split(separator: 10, omittingEmptySubsequences: false)
            if lines.count == 1 {
                pending.append(chunk)
                continue
            }
            pending.append(lines[0])
            consume(pending, decoder: decoder)
            offset += UInt64(pending.count + 1)
            for line in lines.dropFirst().dropLast() {
                consume(line, decoder: decoder)
                offset += UInt64(line.count + 1)
            }
            pending = lines.last ?? Data()
        }
        // Keep the offset at the last newline so an incomplete write is read again.
    }

    private mutating func consume(_ line: Data, decoder: JSONDecoder) {
        guard Self.recordTypes.contains(where: { line.range(of: $0) != nil }),
              let record = try? decoder.decode(Record.self, from: line) else { return }
        let payload = record.payload
        if record.type == "session_meta" {
            guard payload.thread_source == "user"
                || (payload.thread_source == nil && ["vscode", "cli"].contains(payload.source ?? "")) else { return }
            id = payload.id
            if let directory = payload.cwd, !directory.isEmpty {
                project = URL(fileURLWithPath: directory).lastPathComponent
            }
            return
        }
        guard id != nil, record.type == "event_msg", let turnID = payload.turn_id,
              payload.root_turn_id == nil || payload.root_turn_id == turnID else { return }
        switch payload.type {
        case "task_started":
            if let start = payload.started_at {
                turn = Turn(id: turnID, startedAt: Date(timeIntervalSince1970: start))
            }
        case "task_complete", "turn_aborted":
            if turn?.id == turnID { turn = nil }
        default:
            break
        }
    }
}
