// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Recorded Claude/Gemini envelope shapes, with invented contents, through the
/// production incremental reader, event delivery and island notice handler.
enum AgentProviderInputLogTests {
    private final class Log {
        let host = AgentUsageReadTests.Host()
        let provider: AgentProvider
        let folder: URL
        let file: URL
        let now = Date()
        var step = 0

        init(_ provider: AgentProvider) throws {
            self.provider = provider
            folder = FileManager.default.temporaryDirectory.appending(path: "vorss-input-\(UUID().uuidString)")
            file = folder.appending(path: "brain/session/transcript.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        deinit { try? FileManager.default.removeItem(at: folder) }

        func append(_ body: [String: Any]) throws {
            step += 1
            var row = body
            let date = now.addingTimeInterval(Double(step))
            if provider == .claude {
                row["timestamp"] = date.timeIntervalSince1970
                row["sessionId"] = "session"
            } else {
                row["created_at"] = ISO8601DateFormatter().string(from: date)
                row["step_index"] = step
            }
            var line = try JSONSerialization.data(withJSONObject: row)
            line.append(0x0a)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            host.read(file.path, provider: provider)
        }

        var waiting: Bool { host.store.live.first?.isWaitingForInput == true }

        func checkNotices(_ suite: TestSuite, prompts: [String]) {
            let delivery = AgentUsageEventDeliveryTests.Host()
            delivery.providers = [provider]
            for event in host.events { delivery.report(event) }
            var drained = false
            DispatchQueue.main.async { drained = true }
            let deadline = Date().addingTimeInterval(1)
            while !drained && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
            let island = AgentCodexInputLogTests.NoticeHost()
            for event in delivery.events.values {
                if case .inputRequired = event { island.showAgentEvent(event) }
            }
            suite.expect(drained && island.notices.map(\.detail) == prompts,
                         "\(provider) live questions reach the island with every question's text and no duplicate notices")
            suite.expect(island.notices.count == prompts.count && island.notices.allSatisfy {
                $0.event == .agents && $0.agent == provider && $0.symbol == "questionmark.bubble.fill" && $0.waitsForAgentInput
            }, "\(provider) input notices carry the correct provider, question glyph and persistent lifetime")
        }
    }

    static func run(_ suite: TestSuite) {
        do { try claude(suite) }
        catch { suite.expect(false, "Claude input log fixture runs: \(error)") }
        do { try gemini(suite) }
        catch { suite.expect(false, "Gemini input log fixture runs: \(error)") }
    }

    private static func claude(_ suite: TestSuite) throws {
        let log = try Log(.claude)
        try log.append(["type": "user", "message": ["content": "Start"]])
        log.host.store.reportsTransitions = true
        try log.append(["type": "assistant", "message": ["stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "shell", "name": "Bash", "input": ["command": "pwd"]]
        ]]])
        suite.expect(!log.waiting && log.host.events.isEmpty, "ordinary Claude tool calls do not invent input requests")
        let question: [String: Any] = ["type": "assistant", "message": ["stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "question", "name": "AskUserQuestion", "input": ["questions": [
                ["question": "Which database?", "header": "Database", "multiSelect": false,
                 "options": [["label": "A", "description": "First option"]]],
                ["question": "Keep the backup?", "header": "Backup", "multiSelect": false, "options": []]
            ]]]
        ]]]
        try log.append(question)
        suite.expect(log.waiting, "the live Claude reader marks nested AskUserQuestion calls as waiting")
        try log.append(question)
        try log.append(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "shell", "content": "done"]
        ]]])
        try log.append(["type": "user", "isMeta": true, "message": ["content": "status"]])
        try log.append(["type": "user", "isSidechain": true, "message": ["content": "subagent prompt"]])
        suite.expect(log.waiting && log.host.events.count == 1,
                     "Claude replays, unrelated results, metadata and subagent messages preserve the pending question without another notice")
        try log.append(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "question", "content": "A; yes"]
        ]]])
        suite.expect(!log.waiting, "Claude's matching question result clears the live Input badge")
        try log.append(["type": "assistant", "message": ["stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "next", "name": "AskUserQuestion", "input": ["questions": [["question": "Continue?"]]]]
        ]]])
        suite.expect(log.waiting && log.host.events.count == 2, "a second Claude question in the same turn produces a fresh notice")
        try log.append(["type": "user", "message": ["content": "Yes"]])
        suite.expect(!log.waiting, "a direct Claude user response also clears the Input badge")
        log.checkNotices(suite, prompts: ["Which database?\nKeep the backup?", "Continue?"])
    }

    private static func gemini(_ suite: TestSuite) throws {
        let log = try Log(.gemini)
        try log.append(["type": "USER_INPUT", "source": "USER_EXPLICIT", "status": "DONE", "content": "Start"])
        log.host.store.reportsTransitions = true
        try log.append(["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [
            ["name": "run_command", "args": ["Cwd": "/tmp/project"]]
        ]])
        suite.expect(!log.waiting && log.host.events.isEmpty, "ordinary Gemini tool calls do not invent input requests")
        // Antigravity writes questions as a serialized JSON string inside args.
        let questions = #"[{"question":"Which database?","is_multi_select":false,"options":["A","B"]},{"question":"Keep the backup?","options":["Yes","No"]}]"#
        let question: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [
            ["name": "ask_question", "args": ["questions": questions, "toolAction": "ask", "toolSummary": "Choose options"]]
        ]]
        try log.append(question)
        suite.expect(log.waiting, "the live Gemini reader decodes the actual serialized-question envelope")
        try log.append(question)
        for kind in ["GENERIC", "EPHEMERAL_MESSAGE"] {
            try log.append(["type": kind, "status": "DONE", "content": "status"])
        }
        suite.expect(log.waiting && log.host.events.count == 1, "Gemini replay and status updates preserve waiting without duplicate notices")
        try log.append(["type": "PLANNER_RESPONSE", "status": "DONE", "tool_calls": [
            ["name": "view_file", "args": [:]]
        ]])
        suite.expect(!log.waiting, "Gemini resumed planner work clears the live Input badge")
        try log.append(["type": "PLANNER_RESPONSE", "tool_calls": [
            ["name": "ask_question", "args": ["questions": [["question": "Continue?"]]]]
        ]])
        suite.expect(log.waiting && log.host.events.count == 2, "a second Gemini question produces a fresh notice")
        try log.append(["type": "USER_INPUT", "source": "USER_EXPLICIT", "content": "Yes"])
        suite.expect(!log.waiting, "a Gemini user response clears the live Input badge")
        log.checkNotices(suite, prompts: ["Which database?\nKeep the backup?", "Continue?"])
    }
}
