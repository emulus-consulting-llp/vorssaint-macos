// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

enum TeamsAudioWriteQueueTests {
    static func run(_ suite: TestSuite) {
        retryAndFairness(suite)
        overflow(suite)
        overflow(suite, byteLimit: true)
        failure(suite, stalled: false)
        failure(suite, stalled: true)
    }

    private static func sample(_ index: Int) -> CMSampleBuffer {
        RecorderSampleTimingTests.audio(count: 480, time: CMTime(value: Int64(10_000 + index), timescale: 100))
    }

    private static func retryAndFairness(_ suite: TestSuite) {
        let queue = DispatchQueue(label: "test.teams.write-retry")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            var micAttempts = 0
            var remoteWritten = false
            var written: [Int] = []
            var failures = 0
            let writes = TeamsAudioWriteQueue(queue: queue, append: { _, source in
                if source == .microphone {
                    micAttempts += 1
                    if !remoteWritten || micAttempts <= 3 { return .notReady }
                }
                return .appended
            }, onWritten: { sample, source in
                if source == .system { remoteWritten = true }
                else {
                    written.append(Int(CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample),
                        timescale: 100, method: .roundHalfAwayFromZero).value - 10_000))
                }
            }, onFailure: { _ in failures += 1 })
            for index in 0..<100 { writes.enqueue(sample(index), source: .microphone) }
            writes.enqueue(sample(0), source: .system)
            writes.flush {
                suite.expect(written == Array(0..<100), "a released mic burst survives encoder stalls once, in source order")
                suite.expect(remoteWritten, "a blocked mic source does not starve Teams audio")
                suite.expect(writes.retries >= 3 && failures == 0, "temporary backpressure is retried without a capture failure")
                suite.expect(writes.peakBuffers == 101, "flush waits for the admitted burst to finish")
                done.signal()
            }
        }
        suite.expect(done.wait(timeout: .now() + 3) == .success, "write retries and flush finish within the test deadline")
    }

    private static func overflow(_ suite: TestSuite, byteLimit: Bool = false) {
        let queue = DispatchQueue(label: "test.teams.write-limit")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            var written = 0
            var failures = 0
            let writes = TeamsAudioWriteQueue(queue: queue, maxBuffers: byteLimit ? 100 : 2,
                maxBytes: byteLimit ? 3_840 : 8 * 1_024 * 1_024,
                append: { _, _ in .appended }, onWritten: { _, _ in written += 1 },
                onFailure: { _ in failures += 1 })
            for index in 0..<4 { writes.enqueue(sample(index), source: .microphone) }
            writes.flush {
                suite.expect(failures == 1 && writes.failure != nil, "backlog overflow reports one explicit capture failure")
                suite.expect(written == 2 && writes.peakBuffers == 2, "overflow stays bounded and preserves already admitted audio")
                done.signal()
            }
        }
        suite.expect(done.wait(timeout: .now() + 3) == .success, "overflow still permits finalization")
    }

    private static func failure(_ suite: TestSuite, stalled: Bool) {
        let queue = DispatchQueue(label: "test.teams.write-failure")
        let done = DispatchSemaphore(value: 0)
        queue.async {
            var attempts = 0
            var written = 0
            var failures = 0
            let writes = TeamsAudioWriteQueue(queue: queue, flushTimeout: 0.02,
                append: { _, _ in
                    attempts += 1
                    if stalled { return .notReady }
                    if attempts > 1 { throw NSError(domain: "SyntheticWriterFailure", code: 1) }
                    return .appended
                }, onWritten: { _, _ in written += 1 }, onFailure: { _ in failures += 1 })
            for index in 0..<5 { writes.enqueue(sample(index), source: .microphone) }
            writes.flush {
                suite.expect(failures == 1 && writes.failure != nil, "failed or permanently stalled writers report an error")
                suite.expect(written == (stalled ? 0 : 1), "failed writers do not report queued audio as written")
                done.signal()
            }
        }
        suite.expect(done.wait(timeout: .now() + 3) == .success, "writer failure cannot leave saving in an endless retry")
    }
}
