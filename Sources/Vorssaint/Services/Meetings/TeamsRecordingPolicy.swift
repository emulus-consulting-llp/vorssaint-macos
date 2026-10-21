// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Pure lifecycle policy. Only a successful, explicit absence observation can
/// end a call; permission loss, missing selectors and partial trees cannot.
struct TeamsRecordingPolicy {
    enum Evidence: Equatable { case present(String), absent, unknown }
    enum Phase: Equatable { case idle, offered, starting, recording, dismissed, finishing }
    enum Effect: Equatable { case offer(String), withdrawOffer, stop }

    private(set) var phase: Phase = .idle
    private(set) var callID: String?
    private var absentSince: TimeInterval?
    private var lastObservation: TimeInterval?
    private var lastPresent: TimeInterval?
    private var ended = false

    mutating func observe(_ evidence: Evidence, at time: TimeInterval) -> [Effect] {
        guard time.isFinite, lastObservation.map({ time > $0 }) ?? true else { return [] }
        lastObservation = time
        switch evidence {
        case .unknown:
            absentSince = nil
            lastPresent = nil
            return []
        case .absent:
            lastPresent = nil
            if let first = absentSince, time - first >= 2 { return endCall() }
            if absentSince == nil { absentSince = time }
            return []
        case .present(let id):
            absentSince = nil
            if let callID, callID != id {
                // Do not attach an in-flight recording to a different call.
                let effects = endCall()
                if phase != .idle { return effects }
                self.callID = id
                lastPresent = time
                phase = .offered
                return effects + [.offer(id)]
            }
            lastPresent = time
            guard phase == .idle else { return [] }
            callID = id
            ended = false
            phase = .offered
            return [.offer(id)]
        }
    }

    /// A stale prompt cannot start capture after observation was lost.
    mutating func accept(at time: TimeInterval) -> Bool {
        guard phase == .offered, let lastPresent, time.isFinite,
              time >= lastPresent, time - lastPresent <= 3 else { return false }
        phase = .starting
        return true
    }

    mutating func dismiss() {
        guard phase == .offered else { return }
        phase = .dismissed
    }

    mutating func didStart() {
        if phase == .starting { phase = .recording }
    }

    mutating func requestStop() -> [Effect] {
        guard phase == .starting || phase == .recording else { return [] }
        phase = .finishing
        return [.stop]
    }

    mutating func didFinish() {
        guard phase == .finishing || phase == .starting else { return }
        if ended { reset() } else { phase = .dismissed }
    }

    private mutating func endCall() -> [Effect] {
        ended = true
        switch phase {
        case .starting, .recording: return requestStop()
        case .finishing: return []
        case .offered: reset(); return [.withdrawOffer]
        case .idle, .dismissed: reset(); return []
        }
    }

    private mutating func reset() {
        phase = .idle
        callID = nil
        lastPresent = nil
        absentSince = nil
        ended = false
    }
}

/// Best-effort AX mute filtering, NOT a guarantee of Teams' transmitted audio.
/// Audio remains in bounded memory until two unmuted observations bracket it.
/// Unknown/muted/slow observations discard the interval, including from archive.
/// A quick mute/unmute between polls is inherently invisible to this policy.
struct TeamsMicrophoneGate {
    private var previousEnd: TimeInterval?

    mutating func advance(_ state: TeamsCallObservation.MicrophoneState,
                          scanStarted: TimeInterval, scanEnded: TimeInterval) -> ClosedRange<TimeInterval>? {
        guard scanStarted.isFinite, scanEnded.isFinite, scanEnded >= scanStarted,
              scanEnded - scanStarted <= 1,
              previousEnd.map({ scanStarted >= $0 }) ?? true else {
            previousEnd = nil
            return nil
        }
        let previous = previousEnd
        previousEnd = state == .unmuted ? scanEnded : nil
        guard state == .unmuted, let previous, scanStarted - previous <= 3 else { return nil }
        return previous...scanStarted
    }
}
