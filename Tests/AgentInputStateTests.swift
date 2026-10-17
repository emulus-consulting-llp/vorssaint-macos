// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentInputStateTests {
    static func run(_ suite: TestSuite) {
        codex(suite)
        claude(suite)
        openCode(suite)
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func data(_ json: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: json) }

    private static func codex(_ suite: TestSuite) {
        for counted in [false, true] {
            var state = AgentLogState()
            let store = AgentUsageStore()
            store.reportsTransitions = true
            @discardableResult func feed(_ type: String, _ payload: [String: Any], at offset: Double) -> [AgentUsageEvent] {
                let date = now.addingTimeInterval(offset)
                let body = String(decoding: data(payload), as: UTF8.self)
                let line = Data(#"{"type":"\#(type)","timestamp":\#(date.timeIntervalSince1970),"payload":\#(body)}"#.utf8)
                let entries = AgentLogParser.parseCodex(line, state: &state, now: date)
                return store.apply(entries, file: "codex", provider: .codex, tracksTurns: true, modified: date, now: date)
            }
            feed("event_msg", ["type": "task_started"], at: 0)
            feed("event_msg", ["type": "approval_requested", "prompt": "Proceed?"], at: 1)
            feed("event_msg", ["type": "token_count", "info": NSNull()], at: 2)
            suite.expect(store.live.first?.isWaitingForInput == true, "quota-only Codex updates do not answer an approval")
            if counted {
                feed("event_msg", ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 10]]], at: 3)
            } else {
                feed("token_usage_record", ["response_id": "r1", "usage": ["input_tokens": 10]], at: 3)
            }
            suite.expect(store.live.first?.isWaitingForInput == false && store.live.first?.inputPrompt == nil,
                         "new Codex work clears input state for both token log formats")
            let next = feed("event_msg", ["type": "user_input_requested", "prompt": "Next step?"], at: 4)
            suite.expect(next.count == 1 && store.live.first?.isWaitingForInput == true,
                         "a second Codex question in the same task produces a fresh alert")
            feed("event_msg", ["type": "task_complete"], at: 5)
            suite.expect(store.live.isEmpty && state.inputRequestedAt == nil, "Codex completion clears pending input metadata")
        }
    }

    private static func claude(_ suite: TestSuite) {
        var state = AgentLogState()
        let store = AgentUsageStore()
        func feed(_ json: [String: Any]) {
            let entries = AgentLogParser.parseClaude(data(json), state: &state, now: now)
            store.apply(entries, file: "claude", provider: .claude, tracksTurns: true, modified: now, now: now)
        }
        func result(_ id: String) -> [String: Any] {
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "done"]]]]
        }
        feed(["type": "user", "message": ["content": "Start"]])
        feed(["type": "assistant", "message": ["stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "bash", "name": "Bash", "input": ["command": "pwd"]],
            ["type": "tool_use", "id": "q1", "name": "AskUserQuestion", "input": ["questions": [
                ["question": "Keep the backup?"], ["question": "Which database?"]]]],
            ["type": "tool_use", "id": "q2", "name": "AskFollowupQuestion", "input": ["question": "Proceed?"]]
        ]]])
        suite.expect(store.live.first?.inputPrompt == "Keep the backup?\nWhich database?\nProceed?"
                        && state.pendingQuestionIDs == ["q1", "q2"],
                     "Claude decodes nested questions and tracks all outstanding question calls")
        feed(result("bash"))
        suite.expect(store.live.first?.isWaitingForInput == true, "unrelated Claude tool results preserve unanswered questions")
        feed(["type": "user", "isMeta": true, "message": ["content": "status"]])
        suite.expect(store.live.first?.isWaitingForInput == true, "Claude metadata messages cannot answer a question")
        feed(["type": "assistant", "message": ["stop_reason": "tool_use", "content": [["type": "text", "text": "Working"]]]])
        suite.expect(store.live.first?.isWaitingForInput == true, "other Claude assistant activity keeps outstanding questions visible")
        feed(result("q1"))
        suite.expect(store.live.first?.isWaitingForInput == true && state.pendingQuestionIDs == ["q2"],
                     "answering one of multiple Claude question tools keeps the remaining one pending")

        let cursor = AgentLogCursor(path: "/fixture/session.jsonl", provider: .claude)
        cursor.state = state
        let contents = AgentUsageArchive.Contents(providers: [.claude], store: store.saved, cursors: [cursor.saved])
        let encoded = AgentUsageArchive.encode(contents, build: "input-tests")
        let restored = AgentUsageArchive.decode(encoded, build: "input-tests")
        suite.expect(restored?.store.turns.first?.isWaitingForInput == true
                        && restored?.store.turns.first?.inputPrompt == nil
                        && restored?.cursors.first?.state.pendingQuestionIDs == ["q2"],
                     "archive keeps question lifecycle metadata while discarding question text")
        suite.expect(encoded.range(of: Data("Keep the backup?".utf8)) == nil
                        && encoded.range(of: Data("Which database?".utf8)) == nil,
                     "question contents never enter the binary archive or its string table")
        if let restored {
            var resumedState = restored.cursors[0].state
            let resumed = AgentUsageStore(saved: restored.store)
            let entries = AgentLogParser.parseClaude(data(result("q2")), state: &resumedState, now: now)
            resumed.apply(entries, file: "claude", provider: .claude, tracksTurns: true, modified: now, now: now)
            suite.expect(resumed.live.first?.isWaitingForInput == false, "matching question results clear input state after archive resume")
        }
        feed(["type": "user", "message": ["content": "Continue"]])
        suite.expect(store.live.first?.isWaitingForInput == false && state.pendingQuestionIDs.isEmpty,
                     "an actual user response clears all outstanding Claude questions")
    }

    private static func openCode(_ suite: TestSuite) {
        var state = AgentLogState()
        let store = AgentUsageStore()
        store.reportsTransitions = true
        @discardableResult func feed(_ json: [String: Any]) -> [AgentUsageEvent] {
            let entries = AgentLogParser.parseOpenCode(data(json), state: &state, now: now)
            return store.apply(entries, file: "opencode", provider: .opencode, tracksTurns: true, modified: now, now: now)
        }
        let question: [String: Any] = ["role": "assistant", "session_id": "s", "id": "q", "parentID": "u1",
            "finish": "question", "time": ["created": 1_800_000_001]]
        feed(["role": "user", "session_id": "s", "id": "u1", "time": ["created": 1_800_000_000]])
        feed(question)
        suite.expect(store.live.first?.isWaitingForInput == true, "a current OpenCode question requests input")
        feed(["role": "user", "session_id": "s", "id": "u2", "time": ["created": 1_800_000_002]])
        feed(["role": "assistant", "session_id": "s", "id": "a", "parentID": "u2", "finish": "stop",
            "time": ["created": 1_800_000_003, "completed": 1_800_000_004]])
        suite.expect(store.live.isEmpty && feed(question).isEmpty && store.live.isEmpty,
                     "replaying an old OpenCode question cannot resurrect a finished session")
        feed(["role": "user", "session_id": "s", "id": "u3", "time": ["created": 1_800_000_005]])
        suite.expect(feed(question).isEmpty && store.live.first?.isWaitingForInput == false,
                     "an old question cannot pause a newer OpenCode prompt")
        var failed = question
        failed["id"] = "failed"
        failed["parentID"] = "u3"
        failed["error"] = ["name": "Failure"]
        failed["time"] = ["created": 1_800_000_006]
        feed(failed)
        suite.expect(store.live.isEmpty && state.turnOpen == false, "an OpenCode question that failed ends the turn without requesting input")
    }
}
