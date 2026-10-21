// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

/// Confined to the sink's serial queue. Mic mute filtering releases a burst at
/// each observation; a temporary encoder stall must not discard that speech.
/// Sources are retried independently so one cannot starve the other.
final class TeamsAudioWriteQueue {
    private struct Pending { let sample: CMSampleBuffer; let bytes: Int }
    private let queue: DispatchQueue
    private let maxBuffers: Int
    private let maxBytes: Int
    private let flushTimeout: TimeInterval
    private let append: (CMSampleBuffer, RecorderAudioSource) throws -> TeamsAudioWriter.AppendOutcome
    private let onWritten: (CMSampleBuffer, RecorderAudioSource) -> Void
    private let onFailure: (String) -> Void
    private var pending: [RecorderAudioSource: [Pending]] = [:]
    private var count = 0
    private var bytes = 0
    private var scheduled = false
    private var writerFailed = false
    private var flushing = false
    private var flushDeadline: TimeInterval?
    private var completions: [() -> Void] = []
    private(set) var failure: String?
    private(set) var retries = 0
    private(set) var peakBuffers = 0
    private(set) var peakBytes = 0

    init(queue: DispatchQueue, maxBuffers: Int = 2_048, maxBytes: Int = 8 * 1_024 * 1_024,
         flushTimeout: TimeInterval = 10,
         append: @escaping (CMSampleBuffer, RecorderAudioSource) throws -> TeamsAudioWriter.AppendOutcome,
         onWritten: @escaping (CMSampleBuffer, RecorderAudioSource) -> Void = { _, _ in },
         onFailure: @escaping (String) -> Void) {
        self.queue = queue
        self.maxBuffers = maxBuffers
        self.maxBytes = maxBytes
        self.flushTimeout = flushTimeout
        self.append = append
        self.onWritten = onWritten
        self.onFailure = onFailure
    }

    func enqueue(_ sample: CMSampleBuffer, source: RecorderAudioSource) {
        guard !flushing, failure == nil else { return }
        let size = CMSampleBufferGetDataBuffer(sample).map(CMBlockBufferGetDataLength)
            ?? CMSampleBufferGetTotalSampleSize(sample)
        guard size > 0, count < maxBuffers, size <= maxBytes - bytes else {
            fail("Audio write backlog exceeded its limit; capture stopped.")
            return
        }
        pending[source, default: []].append(.init(sample: sample, bytes: size))
        count += 1
        bytes += size
        peakBuffers = max(peakBuffers, count)
        peakBytes = max(peakBytes, bytes)
        schedule(after: 0)
    }

    /// Call after both sources stopped. No writer.finish until all admitted
    /// samples have been written (or a bounded, explicitly reported failure).
    func flush(completion: @escaping () -> Void) {
        flushing = true
        if flushDeadline == nil { flushDeadline = ProcessInfo.processInfo.systemUptime + flushTimeout }
        completions.append(completion)
        if count == 0 || writerFailed { completeFlush() }
        else { schedule(after: 0) }
    }

    private func schedule(after delay: TimeInterval) {
        guard !scheduled, !writerFailed, count > 0 else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            scheduled = false
            drain()
        }
    }

    private func drain() {
        guard !writerFailed else { completeFlush(); return }
        if let flushDeadline, ProcessInfo.processInfo.systemUptime > flushDeadline {
            fail("Audio writer stalled while saving queued audio.", fatal: true)
            completeFlush()
            return
        }
        for source in RecorderAudioSource.allCases {
            // Bound each pass even when the writer keeps accepting data.
            for _ in 0..<64 {
                guard let next = pending[source]?.first else { break }
                do {
                    let outcome = try append(next.sample, source)
                    if outcome == .notReady { retries += 1; break }
                    pending[source]?.removeFirst()
                    count -= 1
                    bytes -= next.bytes
                    if outcome == .appended { onWritten(next.sample, source) }
                } catch {
                    fail("Could not write queued audio; capture stopped.", fatal: true)
                    completeFlush()
                    return
                }
            }
        }
        if count > 0 { schedule(after: 0.002) }
        else { completeFlush() }
    }

    private func fail(_ message: String, fatal: Bool = false) {
        if fatal {
            writerFailed = true
            pending.removeAll()
            count = 0
            bytes = 0
        }
        if failure == nil {
            failure = message
            onFailure(message)
        }
    }

    private func completeFlush() {
        guard flushing, count == 0 || writerFailed else { return }
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks { callback() }
    }
}
