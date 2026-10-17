// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentPersistentInputTests {
    static func run(_ suite: TestSuite) {
        let now = Date()
        func session(_ provider: AgentProvider, id: String = "session", prompt: String = "Continue?") -> AgentLiveSession {
            AgentLiveSession(id: id, provider: provider, started: now, lastActivity: now,
                             model: "", project: "example", tokens: AgentTokens(), cost: 0,
                             isWaitingForInput: true, inputPrompt: prompt)
        }
        defer {
            AgentCodexInputLogTests.NotchAgentSupport.input = true
            AgentCodexInputLogTests.AgentUsageService.shared.snapshot = AgentUsageSnapshot()
            NotchHoverTests.DispatchQueue.main = NotchScreenRefreshContract.Scheduler()
        }
        for provider: AgentProvider in [.codex, .claude, .gemini] {
            let island = AgentCodexInputLogTests.NoticeHost()
            let waiting = session(provider)
            island.syncAgentInputNotice([waiting])
            suite.expect(island.notice?.waitsForAgentInput == true && island.notice?.agent == provider,
                         "\(provider) waiting snapshots produce a persistent input notice")
            let count = island.notices.count
            island.syncAgentInputNotice([waiting])
            suite.expect(island.notices.count == count, "unchanged \(provider) waiting snapshots do not redraw the prompt")
            var active = waiting
            active.isWaitingForInput = false
            active.inputPrompt = nil
            island.syncAgentInputNotice([active])
            suite.expect(island.notice == nil, "\(provider) answering or resuming dismisses the persistent prompt while its task is still live")
            island.syncAgentInputNotice([waiting])
            island.syncAgentInputNotice([])
            suite.expect(island.notice == nil, "\(provider) ending or expiring the task also removes its input prompt")
        }

        let island = AgentCodexInputLogTests.NoticeHost()
        let codex = session(.codex)
        let claude = session(.claude, id: "other", prompt: "Which database?")
        island.syncAgentInputNotice([codex, claude])
        island.syncAgentInputNotice([claude])
        suite.expect(island.notice?.agent == .claude && island.notice?.detail == "Which database?",
                     "resolving one agent's question reveals another agent still waiting")
        let volume = NotchNotice(event: .volume, title: "Volume", detail: "50%", symbol: "speaker.wave.2.fill")
        island.notice = volume
        island.syncAgentInputNotice([claude])
        suite.expect(island.notice == volume, "snapshot updates leave temporary system feedback visible")
        AgentCodexInputLogTests.AgentUsageService.shared.snapshot.live = [claude]
        island.notice = nil
        island.restoreAgentInputNotice()
        suite.expect(island.notice?.agent == .claude && island.notice?.waitsForAgentInput == true,
                     "after temporary feedback the current snapshot restores an unanswered prompt")
        AgentCodexInputLogTests.NotchAgentSupport.input = false
        island.syncAgentInputNotice([claude])
        suite.expect(island.notice == nil, "disabling input alerts removes the persistent prompt")
        island.syncAgentInputNotice([codex])
        suite.expect(island.notice == nil, "disabled input alerts do not resurface from snapshots")

        // Exercise the production show/dismissal scheduler with virtual time.
        NotchHoverTests.DispatchQueue.main = NotchScreenRefreshContract.Scheduler()
        let timed = NotchHoverTests.Service()
        let sticky = NotchNotice(event: .agents, title: "Codex needs input", detail: "Continue?",
                                 symbol: "questionmark.bubble.fill", agent: .codex, waitsForAgentInput: true)
        timed.show(NotchNotice(event: .clipboard, title: "Copied", detail: "", symbol: "doc.on.clipboard"))
        timed.show(sticky)
        NotchHoverTests.DispatchQueue.main.advance(3_600)
        suite.expect(timed.notice == sticky && timed.noticeWork == nil && timed.inputNoticeRestorations == 0,
                     "input prompts survive an hour and cancel the previous notice's dismissal timer")
        timed.pendingInputNotice = sticky
        timed.show(volume)
        NotchHoverTests.DispatchQueue.main.advance(volume.event.duration + 0.01)
        suite.expect(timed.notice == sticky && timed.inputNoticeRestorations == 1,
                     "temporary notices still expire on schedule and then restore the pending input prompt")
    }
}
