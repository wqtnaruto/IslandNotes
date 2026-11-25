import Foundation
import XCTest
@testable import IslandNotes

final class CodexTaskReaderTests: XCTestCase {
    func testReadsOnlyOpenRootTasksAndOrdersParallelTurnsByStartTime() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("sessions/2026/11/25")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let first = UUID()
        let second = UUID()
        let orphan = UUID()
        let firstFile = try makeSession(first, at: directory, project: "/dev/IslandNotes", start: 10)
        let secondFile = try makeSession(second, at: directory, project: "/dev/个人项目", start: 20)
        _ = try makeSession(orphan, at: directory, project: "/dev/Orphan", start: 30)

        let index = home.appendingPathComponent("session_index.jsonl")
        try Data("""
        {"id":"\(first)","thread_name":"旧标题"}
        {"id":"\(second)","thread_name":"修复登录状态"}
        {"id":"\(first)","thread_name":"灵动岛任务卡片"}
        """.utf8).write(to: index)

        var reader = CodexTaskReader(home: home)
        let openFiles = Set([firstFile, secondFile])
        let initial = try reader.refresh(openFiles: openFiles).tasks
        XCTAssertEqual(initial.map(\.id), [second, first])
        XCTAssertEqual(initial.map(\.title), ["修复登录状态", "灵动岛任务卡片"])
        XCTAssertEqual(initial.map(\.project), ["个人项目", "IslandNotes"])
        XCTAssertEqual(initial.last?.conversationURL.absoluteString, "codex://threads/\(first.uuidString.lowercased())")

        let completion = #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"root","root_turn_id":"root"}}"#
        try append(completion, to: secondFile)
        XCTAssertEqual(try reader.refresh(openFiles: openFiles).tasks.count, 2, "Wait for a complete line")
        try append("\n", to: secondFile)
        XCTAssertEqual(try reader.refresh(openFiles: openFiles).tasks.map(\.id), [first])

        let abort = #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"root","root_turn_id":"root"}}"#
        try append(abort + "\n", to: firstFile)
        XCTAssertEqual(try reader.refresh(openFiles: openFiles), .available([]))

        try append(startRecord(turn: "next", root: "next", time: 40) + "\n", to: firstFile)
        XCTAssertEqual(try reader.refresh(openFiles: openFiles).tasks.map(\.id), [first])
        XCTAssertEqual(try reader.refresh(openFiles: [secondFile]), .available([]))
    }

    private func makeSession(_ id: UUID, at directory: URL, project: String, start: Int) throws -> URL {
        let file = directory.appendingPathComponent("rollout-\(id).jsonl")
        let meta = """
        {"type":"session_meta","payload":{"id":"\(id)","cwd":"\(project)","thread_source":"user","source":"vscode"}}
        """
        let unrelated = #"{"type":"response_item","payload":{"text":""#
            + String(repeating: "x", count: 135_000) + #""}}"#
        let records = [
            meta, unrelated, startRecord(turn: "root", root: "root", time: start),
            startRecord(turn: "child", root: "root", time: 100)
        ]
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }

    private func startRecord(turn: String, root: String, time: Int) -> String {
        """
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"\(turn)","root_turn_id":"\(root)","started_at":\(time)}}
        """
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
