// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentCodexInputHookTests {
    static func run(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-hook-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let metadata = folder.appending(path: ".aiusage/codex-input.json")
            try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = folder.appending(path: "rollout.jsonl")
            let now = Date()
            let stamp = now.timeIntervalSince1970
            let initial = #"{"type":"session_meta","timestamp":\#(stamp),"payload":{"id":"session","cwd":"/tmp/example"}}"# + "\n"
                + #"{"type":"event_msg","timestamp":\#(stamp),"payload":{"type":"task_started"}}"# + "\n"
                + #"{"type":"response_item","timestamp":\#(stamp),"payload":{"type":"custom_tool_call","call_id":"wrapper","name":"exec","input":"await tools.apply_patch('invented patch');"}}"# + "\n"
            try Data(initial.utf8).write(to: file)
            let host = AgentUsageReadTests.Host()
            host.home = folder
            host.enabled = [.codex]
            host.read(file.path, provider: .codex)
            host.store.reportsTransitions = true
            let cursor = host.cursors[file.path]!
            func write(_ ids: [String], at date: Date = now) throws {
                let rows = ids.map { ["id": $0, "kind": "edit", "at": date.timeIntervalSince1970] as [String: Any] }
                try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": ["session": rows]])
                    .write(to: metadata, options: .atomic)
                host.readCodexInput(now: now)
            }
            suite.expect(host.store.live.first?.isWaitingForInput == false, "an ordinary edit does not invent an approval request")
            try write(["edit"])
            suite.expect(host.events == [.inputRequired(provider: .codex, project: "", prompt: "Approve file edits in Codex")]
                            && host.store.live.count == 1 && host.store.live.first?.id == file.path,
                         "explicit file-edit approval metadata announces Input on the original session")
            try write(["edit"])
            suite.expect(host.events.count == 1, "repeated hook reads do not repeat an input notice")
            let island = AgentCodexInputLogTests.NoticeHost()
            host.events.forEach(island.showAgentEvent)
            suite.expect(island.notice?.waitsForAgentInput == true, "hook approvals use persistent island notices")
            try Data("invalid JSON".utf8).write(to: metadata)
            host.readCodexInput(now: now)
            suite.expect(host.store.live.first?.isWaitingForInput == true, "an unreadable signal file does not answer an approval")
            try write(["edit", "second"])
            try write(["second"])
            suite.expect(host.store.live.first?.isWaitingForInput == true && host.events.count == 1,
                         "answering one permission request preserves another without another notice")
            let contents = AgentUsageArchive.Contents(providers: [.codex], store: host.store.saved, cursors: [cursor.saved])
            let restored = AgentUsageArchive.decode(AgentUsageArchive.encode(contents, build: "hook"), build: "hook")!
            let resumed = AgentUsageStore(saved: restored.store)
            let resumedCursor = AgentLogCursor(path: file.path, provider: .codex)
            resumedCursor.state = restored.cursors[0].state
            AgentCodexInputHook.apply([], cursor: resumedCursor, store: resumed, now: now)
            suite.expect(resumed.live.first?.isWaitingForInput == false, "a hook result clears saved input state after archive resume")
            try write([])
            island.syncAgentInputNotice(host.store.live)
            suite.expect(host.store.live.first?.isWaitingForInput == false && island.notice == nil,
                         "hook completion clears Input and dismisses its banner before the task ends")
            try write(["next"])
            suite.expect(host.events.count == 2, "a later approval in the same task produces a new notice")
            cursor.state.pendingQuestionIDs.insert("async:question")
            try write([])
            suite.expect(host.store.live.first?.isWaitingForInput == true && cursor.state.pendingQuestionIDs == ["async:question"],
                         "hook completion leaves a separate async question waiting")
            cursor.state.pendingQuestionIDs = []
            cursor.state.inputRequestedAt = nil
            host.store.apply([.turnActive(now)], file: file.path, provider: .codex, tracksTurns: true, modified: now)
            try write(["old"], at: now.addingTimeInterval(-1))
            suite.expect(host.store.live.first?.isWaitingForInput == false, "requests from before this task cannot pause it")
            try write(["expired"], at: now.addingTimeInterval(-6 * 3600))
            suite.expect(AgentCodexInputHook.load(home: folder, now: now)?["session"]?.isEmpty == true, "abandoned approvals expire")
            cursor.state.turnOpen = false
            host.store.apply([.turnEnded(now, completed: false, duration: nil)], file: file.path, provider: .codex, tracksTurns: true, modified: now)
            try write(["finished"])
            suite.expect(host.store.live.isEmpty, "stale hooks cannot resurrect a finished task")
        } catch { suite.expect(false, "Codex hook fixture runs: \(error)") }
    }
}
