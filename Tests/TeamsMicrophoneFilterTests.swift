// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

enum TeamsMicrophoneFilterTests {
    static func run(_ suite: TestSuite) {
        var filter = TeamsMicrophoneFilter()
        _ = filter.observe(.unmuted, scanStarted: 100, scanEnded: 100.1)
        let invalidDuration = microphone(at: 100.2, duration: .invalid)
        suite.expect(!CMSampleBufferGetDuration(invalidDuration).isNumeric,
                     "capture-style fixture has an unknown reported buffer duration")
        filter.append(invalidDuration, receivedAt: 100.22)
        let released = filter.observe(.unmuted, scanStarted: 101, scanEnded: 101.1)
        suite.expect(released.count == 1 && filter.diagnostics.inferredDurations == 1,
                     "PCM frame count and sample rate recover a missing capture duration")
        suite.expect(filter.diagnostics.received == 1 && filter.diagnostics.released == 1
                        && filter.diagnostics.discardedCount == 0,
                     "real buffer metadata passes the bracketed mute filter")
        let delay = filter.diagnostics.minimumArrivalDelay ?? -1
        suite.expect(abs(delay - 0.02) < 0.0001, "numeric arrival-delay diagnostics expose clock mismatch without saving speech")

        filter.append(microphone(at: 101.2, duration: .invalid), receivedAt: 101.22)
        suite.expect(filter.observe(.muted, scanStarted: 102, scanEnded: 102.1).isEmpty,
                     "inferred duration never bypasses a muted observation")
        filter.append(microphone(at: 102.2, duration: .invalid), receivedAt: 102.22)
        suite.expect(filter.observe(.unmuted, scanStarted: 103, scanEnded: 103.1).isEmpty,
                     "an unmute cannot release earlier unconfirmed audio")
        filter.append(microphone(at: 103.2, duration: CMTime(value: 1, timescale: 48_000)), receivedAt: 103.22)
        suite.expect(filter.observe(.unknown, scanStarted: 104, scanEnded: 104.1).isEmpty,
                     "unknown state also discards valid-duration audio")
        suite.expect(filter.diagnostics.discarded["noApprovedInterval"] == 3,
                     "discard reasons separate mute evidence from malformed metadata")

        var future = TeamsMicrophoneFilter()
        _ = future.observe(.unmuted, scanStarted: 100, scanEnded: 100.1)
        future.append(microphone(at: 101.2, duration: .invalid), receivedAt: 101.22)
        suite.expect(future.observe(.unmuted, scanStarted: 101, scanEnded: 101.1).isEmpty,
                     "audio after a scan stays pending rather than receiving premature authorization")
        suite.expect(future.observe(.unmuted, scanStarted: 102, scanEnded: 102.1).count == 1,
                     "a later observation can release the pending future buffer")
        future.append(microphone(at: 102.2, duration: .invalid), receivedAt: 102.22)
        future.discardPending()
        suite.expect(future.diagnostics.discarded["unconfirmedTail"] == 1,
                     "stopping discards the unconfirmed microphone tail")

        var bounded = TeamsMicrophoneFilter()
        _ = bounded.observe(.unmuted, scanStarted: 100, scanEnded: 100.1)
        for _ in 0..<1_025 { bounded.append(invalidDuration, receivedAt: 100.22) }
        suite.expect(bounded.diagnostics.discarded["bufferLimit"] == 1_024
                        && bounded.observe(.unmuted, scanStarted: 101, scanEnded: 101.1).isEmpty,
                     "bounded backlog discards buffered audio and closes stale authorization")
    }

    static func microphone(at seconds: Double, duration: CMTime) -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                  channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        pcm.frameLength = 480
        pcm.floatChannelData![0].initialize(repeating: 0, count: 480)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: 480, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(sample!) == noErr)
        if !duration.isNumeric {
            timing.duration = duration
            var copy: CMSampleBuffer?
            precondition(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                sampleBuffer: sample!, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &copy) == noErr)
            return copy!
        }
        return sample!
    }
}
