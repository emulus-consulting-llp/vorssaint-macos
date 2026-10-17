// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Reads Codex usage, task activity, questions and approval requests without
/// executing tool contents or treating unrelated results as answers.
struct CodexReader: AgentHarnessReader {
    var provider: AgentProvider { .codex }

    func parse(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let kind = AgentLogParser.firstType(line) else { return [] }
        switch kind.name {
        case "response_item": return codexResponseItem(line, state: &state, now: now)
        case "token_usage_record", "turn_context", "session_meta": break
        case "event_msg":
            guard let event = AgentLogObject(line)?.object("payload")?.string("type"), AgentLogParser.codexEvents.contains(event) else { return [] }
            if event == "item_completed" { return codexCompletedItem(line, state: &state, now: now) }
        default: return []
        }
        guard let json = AgentLogParser.object(line), let payload = json["payload"] as? [String: Any] else { return [] }
        let date = AgentLogParser.timestamp(json["timestamp"]) ?? now
        switch json["type"] as? String {
        case "session_meta":
            // History copied from another thread repeats that thread's
            // metadata; only the first line describes this log's own thread.
            let id = payload["id"] as? String ?? ""
            if !id.isEmpty { state.codexTotalsSession = AgentLogParser.native(id) }
            guard !state.codexHeaderRead else { return [] }
            state.codexHeaderRead = true
            if !id.isEmpty { state.session = AgentLogParser.native(id) }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { state.project = AgentLogParser.projectName(cwd) }
            // Subagents, reviews and memory tasks Codex starts itself name
            // `subagent` or `internal`; a person's thread names its client.
            let source = payload["source"] as? [String: Any]
            state.codexSubagent = source?["subagent"] != nil || source?["internal"] != nil
            // A subagent's session is the thread a person started, however
            // deep it runs; its parent thread stands in when that is missing.
            let root = payload["session_id"] as? String ?? payload["parent_thread_id"] as? String ?? ""
            if state.codexSubagent, !root.isEmpty, root != state.session { state.codexRoot = AgentLogParser.native(root) }
            return []
        case "turn_context":
            if let model = payload["model"] as? String, !model.isEmpty { state.model = AgentLogParser.native(model) }
            if let cwd = payload["cwd"] as? String, !cwd.isEmpty { state.project = AgentLogParser.projectName(cwd) }
            if let tier = payload["service_tier"] as? String { state.fast = AgentLogParser.fastTier(tier) }
            return []
        case "token_usage_record":
            guard let usage = payload["usage"] as? [String: Any] else { return [] }
            state.sawUsageRecords = true
            if let session = payload["session_id"] as? String, !session.isEmpty, state.session.isEmpty {
                state.session = AgentLogParser.native(session)
            }
            let response = payload["response_id"] as? String ?? ""
            let key = response.isEmpty ? "codex:\(state.session):\(date.timeIntervalSince1970)" : "codex:\(response)"
            return codexResumed([codexUsage(AgentLogParser.codexTokens(usage), key: key, date: date, state: state)], date: date, state: &state)
        case "event_msg":
            return codexEvent(payload, date: date, state: &state)
        default:
            return []
        }
    }

    private func codexEvent(_ payload: [String: Any], date: Date, state: inout AgentLogState) -> [AgentLogEntry] {
        switch payload["type"] as? String {
        case "token_count":
            var entries: [AgentLogEntry] = []
            if let limits = payload["rate_limits"] as? [String: Any] {
                if AgentLogParser.isMainBucket(limits), let windows = AgentLogParser.codexWindows(limits, observed: date), !windows.isEmpty {
                    entries.append(.limits(AgentLimits(provider: .codex, windows: windows,
                                                       observedAt: date, source: .sessionLog)))
                }
                if let plan = limits["plan_type"] as? String, !plan.isEmpty {
                    entries.append(.plan(plan, observedAt: date))
                }
            }
            // Running totals repeat when only the limits changed; a response
            // is whatever the total grew by since the previous reading.
            if !state.sawUsageRecords, let info = payload["info"] as? [String: Any],
               let totalUsage = info["total_token_usage"] as? [String: Any] {
                let total = AgentLogParser.codexTokens(totalUsage)
                if total != state.lastTotal, total.total > (state.lastTotal?.total ?? 0) {
                    let delta: AgentTokens
                    if let last = info["last_token_usage"] as? [String: Any] {
                        delta = AgentLogParser.codexTokens(last)
                    } else {
                        let previous = state.lastTotal ?? AgentTokens()
                        delta = AgentTokens(input: max(0, total.input - previous.input),
                                            cacheWrite: max(0, total.cacheWrite - previous.cacheWrite),
                                            cacheRead: max(0, total.cacheRead - previous.cacheRead),
                                            output: max(0, total.output - previous.output),
                                            reasoning: max(0, total.reasoning - previous.reasoning))
                    }
                    let key = "codex:\(state.codexTotalsSession):total:\(total.total)"
                    entries.append(codexUsage(delta, key: key, date: date, state: state))
                }
                state.lastTotal = total
            }
            return codexResumed(entries, date: date, state: &state)
        case "thread_settings_applied":
            if let tier = (payload["thread_settings"] as? [String: Any])?["service_tier"] as? String {
                state.fast = AgentLogParser.fastTier(tier)
            }
            return []
        case "task_started":
            state.turnOpen = true
            state.inputRequestedAt = nil
            state.pendingQuestionIDs = []
            return [.turnBegan(AgentLogParser.seconds(payload["started_at"]) ?? date)]
        case "task_complete", "turn_aborted":
            let open = state.turnOpen
            state.turnOpen = false
            state.inputRequestedAt = nil
            state.pendingQuestionIDs = []
            guard open else { return [] }
            let duration = (payload["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
            return [.turnEnded(AgentLogParser.seconds(payload["completed_at"]) ?? date,
                               completed: payload["type"] as? String == "task_complete", duration: duration)]
        case "approval_requested", "user_input_requested":
            state.turnOpen = true
            state.inputRequestedAt = date
            let prompt = payload["prompt"] as? String ?? payload["message"] as? String ?? "Approval requested"
            return [.turnWaitingInput(date, prompt: prompt)]
        default:
            return []
        }
    }

    private func codexResumed(_ entries: [AgentLogEntry], date: Date, state: inout AgentLogState) -> [AgentLogEntry] {
        guard state.pendingQuestionIDs.isEmpty, let requested = state.inputRequestedAt, date >= requested,
              entries.contains(where: { if case .usage(_, let record, _) = $0 { return record.tokens.total > 0 }; return false })
        else { return entries }
        state.inputRequestedAt = nil
        return [.turnActive(date)] + entries
    }

    /// Current Codex logs record questions and approvals as tool calls,
    /// including tools invoked through the JavaScript execution wrapper.
    private func codexResponseItem(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let envelope = AgentLogObject(line), let payload = envelope.object("payload"),
              let type = payload.string("type") else { return [] }
        let date = AgentLogParser.timestamp(envelope.value("timestamp")) ?? now
        if type == "message", payload.string("role") == "user" {
            return codexInputAnswered(date, state: &state)
        }
        let call = payload.string("call_id") ?? ""
        if type == "function_call_output" || type == "custom_tool_call_output" {
            guard state.pendingQuestionIDs.remove(call) != nil else { return [] }
            return state.pendingQuestionIDs.isEmpty ? codexInputAnswered(date, state: &state) : [.turnHeartbeat(date)]
        }
        guard type == "function_call" || type == "custom_tool_call",
              let rawName = payload.string("name") else { return [] }
        let name = rawName.split(separator: ".").last.map(String.init) ?? rawName
        var prompt: String?
        let asynchronous = name == "request_user_input_async"
        if name == "request_user_input" || asynchronous {
            if let arguments = payload.string("arguments"), let data = arguments.data(using: .utf8),
               let args = AgentLogParser.object(data) {
                prompt = codexQuestionPrompt(args["questions"]) ?? "Question"
            } else { prompt = "Question" }
        } else if name == "exec_command" {
            if let arguments = payload.string("arguments"), let data = arguments.data(using: .utf8),
               let args = AgentLogParser.object(data), args["sandbox_permissions"] as? String == "require_escalated" {
                prompt = args["justification"] as? String ?? "Command approval requested"
            }
        } else if type == "custom_tool_call", name == "exec", let source = payload.string("input") {
            prompt = codexScriptApproval(source)
        }
        guard let prompt else { return [] }
        if !call.isEmpty { state.pendingQuestionIDs.insert((asynchronous ? "async:" : "") + call) }
        state.turnOpen = true
        state.inputRequestedAt = date
        return [.turnWaitingInput(date, prompt: prompt)]
    }

    private func codexCompletedItem(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let envelope = AgentLogObject(line), let payload = envelope.object("payload"),
              let item = payload.object("item") else { return [] }
        let date = AgentLogParser.seconds(payload.value("completed_at_ms")) ?? now
        if item.string("type") == "UserMessage" { return codexInputAnswered(date, state: &state) }
        guard item.string("type") == "AgentMessage", let prompt = codexQuestionPrompt(item.value("questions")) else { return [] }
        // This is the displayed counterpart of the async tool call, not a
        // second outstanding question. Some log versions write only this item.
        if state.pendingQuestionIDs.isEmpty, let id = item.string("id") { state.pendingQuestionIDs.insert("async:" + id) }
        state.turnOpen = true
        state.inputRequestedAt = date
        return [.turnWaitingInput(date, prompt: prompt)]
    }

    private func codexQuestionPrompt(_ value: Any?) -> String? {
        let questions = (value as? [[String: Any]] ?? []).compactMap {
            ($0["question"] as? String ?? $0["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return questions.isEmpty ? nil : questions.joined(separator: "\n")
    }

    private func codexInputAnswered(_ date: Date, state: inout AgentLogState) -> [AgentLogEntry] {
        guard state.inputRequestedAt != nil else { return [] }
        state.inputRequestedAt = nil
        state.pendingQuestionIDs = []
        return [.turnActive(date)]
    }

    private enum CodexScriptToken {
        case word(String), text(String), symbol(UInt8)
        var value: String? { switch self { case .word(let value), .text(let value): return value; default: return nil } }
        func isSymbol(_ value: UInt8) -> Bool { if case .symbol(let symbol) = self { return symbol == value }; return false }
    }

    /// Inspect calls without executing code or mistaking quoted examples and
    /// comments for a permission request. Command contents are never returned.
    private func codexScriptApproval(_ source: String) -> String? {
        guard source.utf8.count <= 512 * 1024 else { return nil }
        let bytes = Array(source.utf8)
        var tokens: [CodexScriptToken] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if [9, 10, 13, 32].contains(byte) { index += 1; continue }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                while index < bytes.count, bytes[index] != 10 { index += 1 }
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
                index = min(bytes.count, index + 2)
                continue
            }
            if [34, 39, 96].contains(byte) {
                let quote = byte
                index += 1
                var text: [UInt8] = []
                while index < bytes.count, bytes[index] != quote {
                    if bytes[index] == 92, index + 1 < bytes.count {
                        index += 1
                        text.append(bytes[index] == 110 ? 10 : bytes[index])
                    } else { text.append(bytes[index]) }
                    index += 1
                }
                index = min(bytes.count, index + 1)
                tokens.append(.text(String(decoding: text, as: UTF8.self)))
            } else if (65...90).contains(byte) || (97...122).contains(byte) || byte == 95 || byte == 36 {
                let start = index
                repeat { index += 1 } while index < bytes.count && ((65...90).contains(bytes[index])
                    || (97...122).contains(bytes[index]) || (48...57).contains(bytes[index]) || [95, 36].contains(bytes[index]))
                tokens.append(.word(String(decoding: bytes[start..<index], as: UTF8.self)))
            } else { tokens.append(.symbol(byte)); index += 1 }
        }
        guard tokens.count >= 5 else { return nil }
        for start in 0..<(tokens.count - 4) {
            guard case .word("tools") = tokens[start], tokens[start + 1].isSymbol(46),
                  case .word("exec_command") = tokens[start + 2], tokens[start + 3].isSymbol(40),
                  tokens[start + 4].isSymbol(123) else { continue }
            var cursor = start + 5
            var depth = 1
            var requested = false
            var justification: String?
            while cursor < tokens.count, depth > 0 {
                if depth == 1, cursor + 2 < tokens.count, tokens[cursor + 1].isSymbol(58) {
                    if tokens[cursor].value == "sandbox_permissions", case .text("require_escalated") = tokens[cursor + 2] { requested = true }
                    if tokens[cursor].value == "justification", case .text(let text) = tokens[cursor + 2] { justification = text }
                }
                if tokens[cursor].isSymbol(123) || tokens[cursor].isSymbol(91) || tokens[cursor].isSymbol(40) { depth += 1 }
                if tokens[cursor].isSymbol(125) || tokens[cursor].isSymbol(93) || tokens[cursor].isSymbol(41) { depth -= 1 }
                cursor += 1
            }
            if requested { return justification ?? "Command approval requested" }
        }
        return nil
    }

    private func codexUsage(_ tokens: AgentTokens, key: String, date: Date, state: AgentLogState) -> AgentLogEntry {
        var billable = AgentBillable(tokens: tokens)
        billable.fast = state.fast
        let priced = AgentPricing.cost(billable, model: state.model)
        return .usage(key: key, record: AgentUsageRecord(
            provider: .codex, date: date, model: state.model, project: state.project, session: state.session,
            tokens: tokens, cost: priced.cost, savings: priced.savings), billable: billable)
    }
}
