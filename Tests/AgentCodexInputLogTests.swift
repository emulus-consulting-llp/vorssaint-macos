// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Current desktop Codex logs, through the production incremental service reader.
enum AgentCodexInputLogTests {
    struct L10n {
        static let shared = L10n()
        let language = AppLanguage.enUS
    }
    enum NotchAgentSupport {
        static var input = true
        static func inputAlert() -> Bool { input }
        static func limitDisplay() -> NotchAgentLimitDisplay { .used }
    }
    class NoticeFixture {
        var notices: [NotchNotice] = []
        var notice: NotchNotice?
        @discardableResult func show(_ notice: NotchNotice) -> Bool { self.notice = notice; notices.append(notice); return true }
        func dismissNotice() { notice = nil }
        func reactMascot(_ reaction: NotchMascotReaction) {}
    }
    enum AgentUsageService {
        static let shared = Fixture()
        final class Fixture { var snapshot = AgentUsageSnapshot() }
    }

    static func run(_ suite: TestSuite) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "vorss-codex-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "rollout.jsonl")
        let now = Date()
        var offset = 0.0
        let host = AgentUsageReadTests.Host()
        func json(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        func append(_ kind: String, _ payload: [String: Any]) throws {
            offset += 1
            let line = #"{"type":"\#(kind)","timestamp":\#(now.addingTimeInterval(offset).timeIntervalSince1970),"payload":\#(json(payload))}"#
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            host.read(file.path, provider: .codex)
        }
        func function(_ name: String, _ id: String, _ args: [String: Any]) throws {
            try append("response_item", ["type": "function_call", "call_id": id, "name": name, "arguments": json(args)])
        }
        func custom(_ id: String, _ source: String) throws {
            try append("response_item", ["type": "custom_tool_call", "call_id": id, "name": "exec", "input": source])
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: file)
            try append("session_meta", ["id": "fixture", "cwd": "/tmp/project"])
            try append("event_msg", ["type": "task_started"])
            host.store.reportsTransitions = true
            let questions = [["title": "Which database?", "options": ["A", "B"]], ["title": "Keep backup?"]]
            try function("request_user_input_async", "async-q", ["questions": questions])
            suite.expect(host.events == [.inputRequired(provider: .codex, project: "", prompt: "Which database?\nKeep backup?")]
                            && host.store.live.first?.isWaitingForInput == true,
                         "the live Codex reader emits inputRequired from an actual async-question tool call")
            try append("response_item", ["type": "function_call_output", "call_id": "async-q", "output": "accepted"])
            try append("event_msg", ["type": "item_completed", "completed_at_ms": now.addingTimeInterval(offset).timeIntervalSince1970 * 1000,
                "item": ["type": "AgentMessage", "id": "displayed-q", "delivery": "async", "questions": questions]])
            try append("token_usage_record", ["response_id": "work", "usage": ["input_tokens": 100, "output_tokens": 2]])
            suite.expect(host.events.count == 1 && host.store.live.first?.isWaitingForInput == true,
                         "async acknowledgements, displayed-question echoes and parallel work do not dismiss or repeat a pending question")
            try append("event_msg", ["type": "item_completed", "item": ["type": "UserMessage", "id": "answer", "content": "A"]])
            suite.expect(host.store.live.first?.isWaitingForInput == false, "the actual user-message item clears the pending Codex question")

            try function("request_user_input", "blocking-q", ["questions": [["question": "Continue?"]]])
            try append("response_item", ["type": "function_call_output", "call_id": "unrelated", "output": "done"])
            suite.expect(host.store.live.first?.isWaitingForInput == true, "unrelated Codex tool results cannot answer a blocking question")
            try append("response_item", ["type": "function_call_output", "call_id": "blocking-q", "output": "Yes"])
            suite.expect(host.store.live.first?.isWaitingForInput == false, "a matching blocking-question result clears the input badge")

            try custom("approval", #"await tools.exec_command({cmd: "true", sandbox_permissions: "require_escalated", justification: "Allow the build?"});"#)
            suite.expect(host.events.last == .inputRequired(provider: .codex, project: "project", prompt: "Allow the build?")
                            && host.store.live.first?.isWaitingForInput == true,
                         "an actual escalated command inside the exec wrapper requests a notch input notice")
            try append("response_item", ["type": "custom_tool_call_output", "call_id": "approval", "output": "done"])
            suite.expect(host.store.live.first?.isWaitingForInput == false, "command completion clears its pending approval")
            let count = host.events.count
            try custom("docs", #"const example = 'tools.exec_command({sandbox_permissions: "require_escalated"})'; // tools.exec_command({sandbox_permissions: "require_escalated"})"#)
            try custom("comment", #"/* tools.exec_command({sandbox_permissions: "require_escalated"}) */ await tools.exec_command({cmd: "true"});"#)
            suite.expect(host.events.count == count && host.store.live.first?.isWaitingForInput == false,
                         "quoted examples, comments, and ordinary commands never invent an approval request")
            try function("exec_command", "direct-approval", ["sandbox_permissions": "require_escalated", "justification": "Allow access?"])
            suite.expect(host.events.last == .inputRequired(provider: .codex, project: "project", prompt: "Allow access?"),
                         "direct exec_command calls also announce explicit approval requests")
            let delivery = AgentUsageEventDeliveryTests.Host()
            for event in host.events { delivery.report(event) }
            var drained = false
            DispatchQueue.main.async { drained = true }
            let deadline = Date().addingTimeInterval(1)
            while !drained && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
            let island = NoticeHost()
            delivery.events.values.forEach(island.showAgentEvent)
            suite.expect(drained && island.notices.count == 4
                            && island.notices.allSatisfy { $0.event == .agents && $0.agent == .codex
                                && $0.symbol == "questionmark.bubble.fill" && $0.waitsForAgentInput },
                         "live Codex question and approval events reach the production island notice handler")
            suite.expect(island.notices.first?.detail == "Which database?\nKeep backup?"
                            && island.notices.last?.detail == "Allow access?",
                         "the island receives the actual question and approval prompt text")
        } catch { suite.expect(false, "the Codex live-input fixture runs: \(error)") }
    }
}
