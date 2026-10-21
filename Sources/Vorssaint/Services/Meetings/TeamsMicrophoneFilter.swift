// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

/// Serialized by the audio sink. Keeps real capture buffers in bounded memory;
/// only explicit, timely AX evidence can release them for writing.
struct TeamsMicrophoneFilter {
    struct Diagnostics: Codable {
        var received = 0
        var released = 0
        var inferredDurations = 0
        var inferredByteCounts = 0
        var discarded: [String: Int] = [:]
        var minimumArrivalDelay: Double?
        var maximumArrivalDelay: Double?
        var discardedCount: Int { discarded.values.reduce(0, +) }
    }

    private struct Buffer {
        let sample: CMSampleBuffer
        let bytes: Int
        let start: Double
        let end: Double
    }

    private var gate = TeamsMicrophoneGate()
    private var pending: [Buffer] = []
    private var pendingBytes = 0
    private(set) var diagnostics = Diagnostics()

    mutating func append(_ sample: CMSampleBuffer, receivedAt: TimeInterval) {
        diagnostics.received += 1
        let reportedBytes = CMSampleBufferGetTotalSampleSize(sample)
        let bytes = CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength) ?? reportedBytes
        if reportedBytes == 0 && bytes > 0 { diagnostics.inferredByteCounts += 1 }
        guard bytes > 0, bytes <= 8 * 1_024 * 1_024 else { discard("invalidSize"); return }
        let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard start.isFinite, receivedAt.isFinite else { discard("invalidTimestamp"); return }
        let delay = receivedAt - start
        diagnostics.minimumArrivalDelay = min(diagnostics.minimumArrivalDelay ?? delay, delay)
        diagnostics.maximumArrivalDelay = max(diagnostics.maximumArrivalDelay ?? delay, delay)

        // AVCapture PCM may have an invalid CMSampleBuffer duration. Its frame
        // count and ASBD rate still give an exact duration; rejecting it would
        // discard every microphone buffer independently of the mute state.
        var duration = CMSampleBufferGetDuration(sample).seconds
        if !duration.isFinite || duration <= 0 {
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mSampleRate.isFinite, format.mSampleRate > 0,
                  CMSampleBufferGetNumSamples(sample) > 0 else { discard("invalidDuration"); return }
            duration = Double(CMSampleBufferGetNumSamples(sample)) / format.mSampleRate
            diagnostics.inferredDurations += 1
        }
        guard duration > 0, duration < 1 else { discard("invalidDuration"); return }
        if pendingBytes + bytes > 8 * 1_024 * 1_024 || pending.count >= 1_024
            || pending.first.map({ start - $0.start > 5 }) == true {
            discardPending(reason: "bufferLimit")
            gate = TeamsMicrophoneGate()
        }
        pending.append(.init(sample: sample, bytes: bytes, start: start, end: start + duration))
        pendingBytes += bytes
    }

    mutating func observe(_ state: TeamsCallObservation.MicrophoneState,
                          scanStarted: TimeInterval, scanEnded: TimeInterval) -> [CMSampleBuffer] {
        let allowed = gate.advance(state, scanStarted: scanStarted, scanEnded: scanEnded)
        var released: [CMSampleBuffer] = []
        var retained: [Buffer] = []
        var retainedBytes = 0
        for buffer in pending {
            if buffer.start >= scanEnded {
                retained.append(buffer)
                retainedBytes += buffer.bytes
            } else if let allowed, allowed.contains(buffer.start), allowed.contains(buffer.end) {
                released.append(buffer.sample)
                diagnostics.released += 1
            } else { discard(allowed == nil ? "noApprovedInterval" : "outsideApprovedInterval") }
        }
        pending = retained
        pendingBytes = retainedBytes
        return released
    }

    mutating func discardPending(reason: String = "unconfirmedTail") {
        diagnostics.discarded[reason, default: 0] += pending.count
        pending.removeAll()
        pendingBytes = 0
    }

    private mutating func discard(_ reason: String) { diagnostics.discarded[reason, default: 0] += 1 }
}
