// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Darwin
import Foundation

/// Optional local PermissionRequest hook metadata. The transcript does not say
/// whether an ordinary file edit needed approval, so tool calls alone cannot
/// supply this signal. No command, patch, path or question text enters this file.
enum AgentCodexInputHook {
    struct Request: Decodable, Equatable {
        enum Kind: String, Decodable { case edit, command, other }
        let id: String
        let kind: Kind
        let at: Double

        var prompt: String {
            switch kind {
            case .edit: return "Approve file edits in Codex"
            case .command: return "Approve a command in Codex"
            case .other: return "Approval requested in Codex"
            }
        }
    }

    private struct Contents: Decodable {
        let version: Int
        let sessions: [String: [Request]]
    }
    private static let prefix = "hook-approval:"

    /// Nil means unavailable, not an answer to a pending approval. Atomic
    /// replacement by the hook keeps a concurrent read from seeing half a write.
    static func load(home: URL, now: Date) -> [String: [Request]]? {
        let path = home.appending(path: ".aiusage/codex-input.json")
        var info = stat()
        guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 512 * 1024,
              let data = try? Data(contentsOf: path),
              let saved = try? JSONDecoder().decode(Contents.self, from: data), saved.version == 1,
              saved.sessions.count <= 64 else { return nil }
        var sessions: [String: [Request]] = [:]
        for (session, requests) in saved.sessions where !session.isEmpty && session.utf8.count <= 256 {
            guard requests.count <= 16 else { continue }
            sessions[session] = requests.filter {
                let age = now.timeIntervalSince1970 - $0.at
                return !$0.id.isEmpty && $0.id.utf8.count <= 256 && $0.at.isFinite
                    && age >= -60 && age < AgentUsageStore.resumeWindow(for: .codex)
            }
        }
        return sessions
    }

    /// Join the hook to the existing log's turn, rather than creating a second
    /// live session. Hook identifiers are metadata and survive archive resume.
    @discardableResult
    static func apply(_ requests: [Request], cursor: AgentLogCursor, store: AgentUsageStore,
                      now: Date) -> [AgentUsageEvent] {
        guard cursor.provider == .codex, cursor.tracksTurns else { return [] }
        let old = cursor.state.pendingQuestionIDs.filter { $0.hasPrefix(prefix) }
        cursor.state.pendingQuestionIDs.subtract(old)
        guard cursor.state.turnOpen,
              let turn = store.turns[cursor.path] ?? store.waiting[cursor.path] else { return [] }
        let current = requests.filter { $0.at >= turn.started.timeIntervalSince1970 }
        let ids = Set(current.map { prefix + $0.id })
        cursor.state.pendingQuestionIDs.formUnion(ids)
        let entries: [AgentLogEntry]
        if let request = current.first {
            guard Set(old) != ids || !turn.isWaitingForInput else { return [] }
            cursor.state.inputRequestedAt = cursor.state.inputRequestedAt ?? now
            // An async question may be pending alongside the approval; keep its
            // readable prompt until its own answer arrives.
            let prompt = turn.isWaitingForInput ? turn.inputPrompt : request.prompt
            entries = [.turnWaitingInput(now, prompt: prompt)]
        } else {
            guard !old.isEmpty, cursor.state.pendingQuestionIDs.isEmpty else { return [] }
            cursor.state.inputRequestedAt = nil
            entries = turn.isWaitingForInput ? [.turnActive(now)] : []
        }
        return store.apply(entries, file: cursor.path, provider: .codex, tracksTurns: true,
                           modified: now, now: now)
    }
}
