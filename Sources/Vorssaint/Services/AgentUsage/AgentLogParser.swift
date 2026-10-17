// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation

/// What one log line says, reduced to the few facts the island keeps. Only
/// usage counters, model names, times and folder names leave a line, besides
/// the identifiers of Claude's shell commands still running, held in memory
/// only. Pending question text is decoded for the live UI and never archived;
/// other prompts, replies and tool output are not retained.
enum AgentLogEntry: Equatable {
    /// `key` identifies the response across duplicate lines and files.
    case usage(key: String, record: AgentUsageRecord, billable: AgentBillable)
    /// A later chunk can identify the model of an already-counted request.
    case usageModel(key: String, model: String)
    case limits(AgentLimits)
    case plan(String, observedAt: Date)
    case turnBegan(Date)
    /// Model and folder context known before usage is reported.
    case turnContext(model: String, project: String)
    /// Work continues; nil when the line was not worth decoding for its time.
    case turnActive(Date?)
    /// A status message keeps the turn alive without answering its question.
    case turnHeartbeat(Date?)
    /// The agent paused expecting user input, approval, or response to a question.
    case turnWaitingInput(Date, prompt: String?)
    /// A step ended expecting the agent to go on; unless work follows soon,
    /// the agent stopped there and its turn is over.
    case turnSettled(Date)
    case turnEnded(Date?, completed: Bool, duration: TimeInterval?)
    case reset(Date)
}

/// Per-file context carried from line to line.
struct AgentLogState: Equatable {
    var session = ""
    var project = ""
    var model = ""
    var turnOpen = false
    /// Metadata only: question text stays in the live store, never in cursor progress.
    var inputRequestedAt: Date?
    var pendingQuestionIDs: Set<String> = []
    /// Newer logs write one usage record per response; older ones only carry
    /// running totals, which are the fallback until a record appears.
    var sawUsageRecords = false
    var lastTotal: AgentTokens?
    /// Codex runs the thread on the fast tier, which bills at a premium.
    var fast = false
    /// A Codex subagent, review or memory task owns no turn. Only the log's
    /// metadata says so: a reverted thread goes on in a log named after both
    /// the thread and a new rollout.
    var codexSubagent = false
    /// The first Codex metadata line describes the log's own thread; a later
    /// one is history copied from the thread it came from.
    var codexHeaderRead = false
    /// The thread a person started that a Codex subagent works for, whose
    /// turn its responses count toward.
    var codexRoot = ""
    /// The thread whose running totals the lines read now report: history
    /// copied from another thread keeps that thread's, as in its own log.
    var codexTotalsSession = ""
    /// Copilot shutdown counters are cumulative for the life of a session.
    var copilotTotals: [String: AgentTokens] = [:]
    /// Counted requests by model; the empty key holds unresolved attribution.
    var copilotRequests: [String: Int] = [:]
    var copilotRequestModels: [String: String] = [:]
    var copilotReportedRequests: [String: Int] = [:]
    var copilotTurnID: String?
    var copilotFinalResponse = false
    /// The parent session when a database row belongs to a subagent.
    var parentSession = ""
    /// OpenCode stores all sessions in one database, tracking per-session state.
    var openCodeSessions: [String: OpenCodeSessionState] = [:]
    /// Claude's shell commands still waiting for their result, by tool call.
    /// They run on the Mac, so the turn goes on without the network.
    var runningCommands: Set<String> = []
}

/// Per-session turn and model tracking for OpenCode databases.
struct OpenCodeSessionState: Equatable {
    var project = ""
    var model = ""
    var turnOpen = false
    var turnStarted: Date?
    var activeUserMessageID = ""
    /// The newest moment the session's rows tell of.
    var lastActivity: Date?
    /// When a step ended expecting the loop to go on, until a row follows.
    var settledAt: Date?
    /// The reply being written, until it completes.
    var writingReplyID = ""
    /// When the prompt the session answers now was written.
    var activePromptDate: Date?
    var seenUserMessageIDs: Set<String> = []
    var completedAssistantMessageIDs: Set<String> = []
    var completedUserMessageIDs: Set<String> = []
}

enum AgentLogParser {
    // MARK: Byte tests

    /// Structural keys are written without spaces and never appear unescaped
    /// inside a string value, so a byte match is a safe first filter.
    static func contains(_ line: Data, _ needle: StaticString) -> Bool {
        line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count >= needle.utf8CodeUnitCount else { return false }
            return memmem(base, bytes.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
        }
    }

    /// The first `"type":"…"` value at or after `start`, and where it ends.
    /// A Codex rollout line writes its own type before its payload, and an
    /// event's payload opens with the event's type, so the search stops
    /// within the first hundred bytes instead of crossing tool output or
    /// compacted history that can run to tens of megabytes per line.
    static func firstType(_ line: Data, from start: Int = 0) -> (name: String, end: Int)? {
        let key: StaticString = #""type":""#
        return line.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, start < bytes.count,
                  let found = memmem(base + start, bytes.count - start, key.utf8Start, key.utf8CodeUnitCount)
            else { return nil }
            let value = base.distance(to: found) + key.utf8CodeUnitCount
            // Type names are short identifiers.
            let limit = min(bytes.count, value + 64)
            guard value < limit, let quote = memchr(base + value, 0x22, limit - value) else { return nil }
            let end = base.distance(to: UnsafeRawPointer(quote))
            return (String(decoding: UnsafeRawBufferPointer(rebasing: bytes[value..<end]), as: UTF8.self), end + 1)
        }
    }

    static let codexEvents: Set<String> = [
        "token_count", "task_started", "task_complete", "turn_aborted", "thread_settings_applied",
        "approval_requested", "user_input_requested",
        "item_completed",
    ]

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: Claude Code

    static func parseClaude(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        ClaudeReader().parse(line, state: &state, now: now)
    }

    // MARK: Codex

    static func parseCodex(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        CodexReader().parse(line, state: &state, now: now)
    }

    /// Input counts include what came from the cache.
    static func codexTokens(_ usage: [String: Any]) -> AgentTokens {
        let input = int(usage["input_tokens"])
        let cached = min(input, int(usage["cached_input_tokens"]))
        let written = min(input - cached, int(usage["cache_write_input_tokens"]))
        return AgentTokens(input: input - cached - written, cacheWrite: written, cacheRead: cached,
                           output: int(usage["output_tokens"]), reasoning: int(usage["reasoning_output_tokens"]))
    }

    private static func codexResumed(_ entries: [AgentLogEntry], date: Date, state: inout AgentLogState) -> [AgentLogEntry] {
        guard state.pendingQuestionIDs.isEmpty, let requested = state.inputRequestedAt, date >= requested,
              entries.contains(where: { if case .usage(_, let record, _) = $0 { return record.tokens.total > 0 }; return false })
        else { return entries }
        state.inputRequestedAt = nil
        return [.turnActive(date)] + entries
    }

    /// Current Codex logs record questions and approvals as tool calls,
    /// including tools invoked through the JavaScript execution wrapper.
    private static func codexResponseItem(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let envelope = AgentLogObject(line), let payload = envelope.object("payload"),
              let type = payload.string("type") else { return [] }
        let date = timestamp(envelope.value("timestamp")) ?? now
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
               let args = object(data) {
                prompt = codexQuestionPrompt(args["questions"]) ?? "Question"
            } else { prompt = "Question" }
        } else if name == "exec_command" {
            if let arguments = payload.string("arguments"), let data = arguments.data(using: .utf8),
               let args = object(data), args["sandbox_permissions"] as? String == "require_escalated" {
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

    private static func codexCompletedItem(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let envelope = AgentLogObject(line), let payload = envelope.object("payload"),
              let item = payload.object("item") else { return [] }
        let date = seconds(payload.value("completed_at_ms")) ?? now
        if item.string("type") == "UserMessage" { return codexInputAnswered(date, state: &state) }
        guard item.string("type") == "AgentMessage", let prompt = codexQuestionPrompt(item.value("questions")) else { return [] }
        // This is the displayed counterpart of the async tool call, not a
        // second outstanding question. Some log versions write only this item.
        if state.pendingQuestionIDs.isEmpty, let id = item.string("id") { state.pendingQuestionIDs.insert("async:" + id) }
        state.turnOpen = true
        state.inputRequestedAt = date
        return [.turnWaitingInput(date, prompt: prompt)]
    }

    private static func codexQuestionPrompt(_ value: Any?) -> String? {
        let questions = (value as? [[String: Any]] ?? []).compactMap {
            ($0["question"] as? String ?? $0["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return questions.isEmpty ? nil : questions.joined(separator: "\n")
    }

    private static func codexInputAnswered(_ date: Date, state: inout AgentLogState) -> [AgentLogEntry] {
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
    private static func codexScriptApproval(_ source: String) -> String? {
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

    /// Fast mode, named priority before July 2026.
    static func fastTier(_ tier: String) -> Bool {
        ["fast", "priority"].contains(tier.lowercased())
    }

    // MARK: OpenCode

    /// OpenCode starts the next step the moment a step's tools return, so
    /// a turn that goes this long without one after a step ended has stopped,
    /// as when a permission was rejected or a question dismissed.
    static let openCodeSettle: TimeInterval = 30

    static func parseOpenCode(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        OpenCodeReader().parse(line, state: &state, now: now)
    }

    // MARK: GitHub Copilot

    /// Copilot CLI and the GitHub Copilot app share an append-only event log.
    /// Only session context, turn boundaries and cumulative model counters are
    /// decoded; prompts, replies, reasoning and tool arguments are ignored.
    static func parseCopilot(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        CopilotReader().parse(line, state: &state, now: now)
    }

    static func copilotEvent(_ type: String) -> Bool {
        ["user.message", "assistant.turn_start", "assistant.message", "assistant.turn_end",
         "session.start", "session.context_changed", "session.model_change", "session.shutdown", "abort"].contains(type)
    }

    /// Codex logs a reading for each allowance: the main one under "codex",
    /// which older logs leave unnamed, and one for each model that has its
    /// own. Only the main one is kept, so a model's windows never replace it
    /// or warn again.
    static func isMainBucket(_ limits: [String: Any]) -> Bool {
        let id = (limits["limit_id"] as? String ?? "").lowercased()
        return id.isEmpty || id == "codex"
    }

    /// The names a log gives a window's figures; Codex's server spells the
    /// same ones in camel case.
    typealias WindowKeys = (used: String, minutes: String, resets: String, individual: String, remaining: String)
    static let logWindowKeys: WindowKeys = ("used_percent", "window_minutes", "resets_at",
                                            "individual_limit", "remaining_percent")

    /// Windows are told apart by their length, never by their slot: an
    /// account can report only its weekly window, and in either slot. A
    /// Business account can leave both slots empty and report its allowance
    /// as the share left of its own limit instead.
    static func codexWindows(_ limits: [String: Any], observed: Date,
                             keys: WindowKeys = logWindowKeys) -> [AgentLimitWindow]? {
        var windows: [AgentLimitWindow] = []
        for slot in ["primary", "secondary"] {
            guard let window = limits[slot] as? [String: Any],
                  let used = (window[keys.used] as? NSNumber)?.doubleValue, used.isFinite else { continue }
            let minutes = (window[keys.minutes] as? NSNumber)?.intValue
            var resets = seconds(window[keys.resets])
            if resets == nil, let delay = (window["resets_in_seconds"] as? NSNumber)?.doubleValue, delay.isFinite {
                resets = observed.addingTimeInterval(max(0, delay))
            }
            windows.append(AgentLimitWindow(id: "codex.\(minutes.map(String.init) ?? slot)",
                                            kind: kind(minutes: minutes), minutes: minutes, scope: nil,
                                            usedPercent: min(100, max(0, used)), resetsAt: resets))
        }
        if windows.isEmpty, let individual = limits[keys.individual] as? [String: Any],
           let remaining = (individual[keys.remaining] as? NSNumber)?.doubleValue, remaining.isFinite {
            windows.append(AgentLimitWindow(id: "codex.individual", kind: .other, minutes: nil, scope: nil,
                                            usedPercent: min(100, max(0, 100 - remaining)),
                                            resetsAt: seconds(individual[keys.resets])))
        }
        return windows.sorted { ($0.minutes ?? .max) < ($1.minutes ?? .max) }
    }

    static func kind(minutes: Int?) -> AgentLimitWindow.Kind {
        guard let minutes, minutes > 0 else { return .other }
        if minutes <= 12 * 60 { return .session }
        if (6 * 1440...8 * 1440).contains(minutes) { return .weekly }
        return .other
    }

    // MARK: Gemini (Antigravity)

    static func parseGemini(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard contains(line, #""type":""#) else { return [] }
        guard let json = object(line), let type = json["type"] as? String else { return [] }
        let date = (json["created_at"] as? String).flatMap(timestamp) ?? now

        switch type {
        case "USER_INPUT":
            if let content = json["content"] as? String {
                if let project = extractAntigravityProject(content) {
                    state.project = project
                }
                if let model = extractAntigravityModel(content) {
                    state.model = model
                }
            }
            if state.model.isEmpty { state.model = "gemini-2.5-pro" }
            var entries: [AgentLogEntry] = []
            if state.turnOpen {
                entries.append(.turnEnded(date, completed: false, duration: nil))
            }
            state.turnOpen = true
            entries.append(.turnBegan(date))
            entries.append(.turnContext(model: state.model, project: state.project))
            return entries

        case "PLANNER_RESPONSE":
            let inputTokens = int(json["input_tokens"])
            let outputTokens = int(json["output_tokens"])
            let cacheReadTokens = int(json["cache_read_tokens"])
            let stepIndex = int(json["step_index"])
            let toolCalls = json["tool_calls"] as? [[String: Any]] ?? []

            if state.project.isEmpty {
                for call in toolCalls {
                    if let args = call["args"] as? [String: Any],
                       let cwd = args["Cwd"] as? String, !cwd.isEmpty {
                        state.project = projectName(cwd)
                        break
                    }
                }
            }

            if state.model.isEmpty { state.model = "gemini-2.5-pro" }
            var entries: [AgentLogEntry] = []

            if inputTokens > 0 || outputTokens > 0 || cacheReadTokens > 0 {
                var billable = AgentBillable()
                billable.tokens = AgentTokens(
                    input: inputTokens,
                    cacheWrite: 0,
                    cacheRead: cacheReadTokens,
                    output: outputTokens,
                    reasoning: 0
                )
                let key = "gemini:\(state.session):step:\(stepIndex)"
                let priced = AgentPricing.cost(billable, model: state.model)
                entries.append(.usage(key: key, record: AgentUsageRecord(
                    provider: .gemini, date: date, model: state.model, project: state.project,
                    session: state.session, tokens: billable.tokens, cost: priced.cost, savings: priced.savings
                ), billable: billable))
            }

            if !toolCalls.isEmpty {
                var waitingQuestion: String?
                for call in toolCalls {
                    let name = call["name"] as? String ?? call["tool_name"] as? String ?? ""
                    if name == "ask_question" {
                        let args = call["args"] as? [String: Any]
                        var questions = args?["questions"] as? [[String: Any]]
                        if let serialized = args?["questions"] as? String,
                           let data = serialized.data(using: .utf8) {
                            questions = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
                        }
                        let prompts = (questions ?? []).compactMap { ($0["question"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        waitingQuestion = prompts.isEmpty ? "Question" : prompts.joined(separator: "\n")
                        break
                    }
                }
                if !state.turnOpen {
                    state.turnOpen = true
                    entries.insert(.turnBegan(date), at: 0)
                }
                if let question = waitingQuestion {
                    entries.append(.turnWaitingInput(date, prompt: question))
                } else {
                    entries.append(.turnActive(date))
                }
            } else {
                if state.turnOpen {
                    state.turnOpen = false
                    entries.append(.turnEnded(date, completed: true, duration: nil))
                }
            }
            return entries

        case "GENERIC", "EPHEMERAL_MESSAGE":
            if state.turnOpen {
                return [.turnHeartbeat(date)]
            }
            return []

        default:
            return []
        }
    }

    private static func extractAntigravityProject(_ content: String) -> String? {
        let lines = content.split(separator: "\n")
        for line in lines {
            if line.hasPrefix("Command Working Directory:") {
                let path = line.dropFirst("Command Working Directory:".count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return projectName(path) }
            }
            if line.hasPrefix("- /") {
                let path = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty { return projectName(path) }
            }
        }
        return nil
    }

    private static func extractAntigravityModel(_ content: String) -> String? {
        guard let range = content.range(of: "Model Selection` from") ?? content.range(of: "Model Selection from") else {
            return nil
        }
        let after = content[range.upperBound...]
        if let toRange = after.range(of: "to ") {
            let modelText = after[toRange.upperBound...].prefix(while: { $0 != "\n" && $0 != "(" && $0 != "<" })
                .trimmingCharacters(in: .whitespaces).lowercased()
            if modelText.contains("flash") {
                if modelText.contains("3.8") { return "gemini-3.8-flash" }
                if modelText.contains("2.5") { return "gemini-2.5-flash" }
                if modelText.contains("1.5") { return "gemini-1.5-flash" }
                return "gemini-flash"
            }
            if modelText.contains("pro") {
                if modelText.contains("2.5") { return "gemini-2.5-pro" }
                if modelText.contains("1.5") { return "gemini-1.5-pro" }
                return "gemini-pro"
            }
        }
        return nil
    }

    // MARK: Shared values

    /// The folder an agent ran in names the project. A worktree kept inside
    /// the repository still belongs to that repository.
    static func projectName(_ path: String) -> String {
        var path = path
        if let range = path.range(of: "/.claude/worktrees/") { path = String(path[..<range.lowerBound]) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return native((path as NSString).lastPathComponent)
    }

    /// Text decoded from a line arrives bridged from Foundation, and every
    /// record keeps it. The summary hashes and compares these per response on
    /// each refresh, which bridged text does through Unicode normalization,
    /// many times slower than with Swift's own UTF-8 storage.
    static func native(_ text: String) -> String {
        String(decoding: text.utf8, as: UTF8.self)
    }

    static func int(_ value: Any?) -> Int {
        guard let number = value as? NSNumber else { return 0 }
        let double = number.doubleValue
        guard double.isFinite, double > 0 else { return 0 }
        // A damaged line must not overflow the sums it joins.
        return Int(min(double, 1e12))
    }

    /// Unix seconds, or milliseconds from agents that write those.
    static func seconds(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
    }

    static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return seconds(value) }
        return AgentTimestamp.parse(text)
    }
}

/// ISO 8601 times as both agents write them, "2026-09-21T23:42:45.078Z",
/// read without a formatter; anything else goes through one.
enum AgentTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()
    private static let lock = NSLock()

    static func parse(_ text: String) -> Date? {
        if let date = fast(Array(text.utf8)) { return date }
        return lock.withLock { fractional.date(from: text) ?? whole.date(from: text) }
    }

    private static func fast(_ b: [UInt8]) -> Date? {
        guard b.count >= 20, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(b[index]) - 0x30
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }
        var index = 19
        var fraction = 0.0
        if b[index] == 0x2E {
            var scale = 0.1
            index += 1
            while index < b.count, (0x30...0x39).contains(b[index]) {
                fraction += Double(b[index] - 0x30) * scale
                scale /= 10
                index += 1
            }
        }
        guard index < b.count else { return nil }
        var offset = 0
        if b[index] == 0x5A {
            guard index == b.count - 1 else { return nil }
        } else if b[index] == 0x2B || b[index] == 0x2D, b.count == index + 6, b[index + 3] == 0x3A,
                  let hours = number(index + 1..<index + 3), let minutes = number(index + 4..<index + 6) {
            offset = (hours * 3600 + minutes * 60) * (b[index] == 0x2B ? 1 : -1)
        } else {
            return nil
        }
        // Days since 1970 from the civil date, valid for every Gregorian year.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
        return Date(timeIntervalSince1970: seconds)
    }
}
