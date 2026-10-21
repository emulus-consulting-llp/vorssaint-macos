// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

enum TeamsAudioWriterTests {
    static func run(_ suite: TestSuite) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await roundTrip(suite, microphone: true)
                try await roundTrip(suite, microphone: false)
                try await roundTrip(suite, microphone: true, deviceFormats: true)
                try await roundTrip(suite, microphone: true, emitMicrophone: false)
                try await filteredCapture(suite)
                try await queuedBurst(suite)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("teams-empty-\(UUID()).mov")
                defer { try? FileManager.default.removeItem(at: url) }
                let writer = try TeamsAudioWriter(url: url, origin: CMTime(value: 100, timescale: 1), includesMicrophone: true)
                do {
                    try await writer.finish(at: CMTime(value: 101, timescale: 1))
                    suite.expect(false, "an empty recording is never reported as a completed audio file")
                } catch { suite.expect(true, "empty recording fails explicitly") }
            } catch { suite.expect(false, "Teams audio round trip failed: \(error)") }
            done.signal()
        }
        suite.expect(done.wait(timeout: .now() + 45) == .success, "audio-only writer checks finish within deadline")
    }

    private static func queuedBurst(_ suite: TestSuite) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teams-queued-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let master = folder.appendingPathComponent("sources.mov")
        let writer = try TeamsAudioWriter(url: master, origin: CMTime(value: 100, timescale: 1), includesMicrophone: true)
        let queue = DispatchQueue(label: "test.teams.real-write-burst")
        let failed: Bool = await withCheckedContinuation { continuation in
            queue.async {
                let writes = TeamsAudioWriteQueue(queue: queue,
                    append: { sample, source in try writer.append(sample, source: source) }, onFailure: { _ in })
                for index in 0..<200 {
                    let sample = RecorderSampleTimingTests.audio(count: 480,
                        time: CMTime(value: Int64(10_000 + index), timescale: 100))
                    writes.enqueue(sample, source: .system)
                    if index < 40 || index >= 150 { writes.enqueue(sample, source: .microphone) }
                }
                writes.flush { continuation.resume(returning: writes.failure != nil) }
            }
        }
        suite.expect(!failed && writer.counts[.system] == 200 && writer.counts[.microphone] == 90,
                     "real encoder consumes an unpaced dual-source burst including a mic gap without losing buffers")
        suite.expect(writer.dropped == 0, "writer retries are not counted as dropped audio")
        try await writer.finish(at: CMTime(value: 102, timescale: 1))
        let output = folder.appendingPathComponent("recording.wav")
        try await TeamsAudioWriter.exportWave(master: master, output: output)
        let duration = try await AVURLAsset(url: output).load(.duration)
        suite.expect(abs(duration.seconds - 2) < 0.01, "queued writing preserves source time and the final playback duration")
    }

    private static func filteredCapture(_ suite: TestSuite) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("teams-filter-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TeamsAudioWriter(url: url, origin: CMTime(value: 100, timescale: 1), includesMicrophone: true)
        var filter = TeamsMicrophoneFilter()
        _ = filter.observe(.unmuted, scanStarted: 100, scanEnded: 100.1)
        let sample = TeamsMicrophoneFilterTests.microphone(at: 100.2, duration: .invalid)
        filter.append(sample, receivedAt: 100.22)
        let released = filter.observe(.unmuted, scanStarted: 101, scanEnded: 101.1)
        for sample in released { try writer.append(sample, source: .microphone) }
        suite.expect(writer.counts[.microphone] == 1,
                     "capture-style unknown-duration mic audio survives filter and PCM writer together")
        try await writer.finish(at: CMTime(value: 101, timescale: 1))
        let tracks = await RecorderAudioSource.tracks(in: AVURLAsset(url: url))
        suite.expect(tracks[.microphone] != nil, "filtered capture produces an identifiable microphone source track")
    }

    private static func roundTrip(_ suite: TestSuite, microphone: Bool,
                                  deviceFormats: Bool = false, emitMicrophone: Bool = true) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teams-writer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let master = folder.appendingPathComponent("sources.mov")
        let output = folder.appendingPathComponent("recording.wav")
        let origin = CMTime(value: 100, timescale: 1)
        let writer = try TeamsAudioWriter(url: master, origin: origin, includesMicrophone: microphone)
        let early = RecorderSampleTimingTests.audio(count: 480, time: origin - CMTime(value: 1, timescale: 1))
        let earlyAccepted = try writer.append(early, source: .system)
        suite.expect(earlyAccepted == .dropped, "audio preceding the shared origin is rejected")
        for index in 0..<150 {
            let time = origin + CMTime(value: Int64(index), timescale: 100)
            let remote = tone(at: time, offset: Double(index) / 100, frequency: 440,
                              floatingPoint: deviceFormats && index >= 60, interleaved: !deviceFormats)
            // Simulate real-time input pacing so encoder backpressure does not
            // turn a test flood into a dropped recording.
            while try writer.append(remote, source: .system) == .notReady {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if microphone && emitMicrophone, (40..<90).contains(index) || (120..<150).contains(index) {
                let local = tone(at: time, offset: Double(index) / 100, frequency: 880,
                                 rate: deviceFormats ? 44_100 : 48_000,
                                 channels: deviceFormats ? 1 : 2, floatingPoint: deviceFormats)
                while try writer.append(local, source: .microphone) == .notReady {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        }
        try await writer.finish(at: origin + CMTime(value: 3, timescale: 2))
        let asset = AVURLAsset(url: master)
        let video = try await asset.loadTracks(withMediaType: .video)
        let tracks = await RecorderAudioSource.tracks(in: asset)
        suite.expect(video.isEmpty && tracks[.system] != nil && (tracks[.microphone] != nil || !emitMicrophone || !microphone),
                     "audio-only master has source tracks and no dummy video")
        if microphone && emitMicrophone, let track = tracks[.microphone] {
            let segments = try await track.load(.segments)
            let first = segments.first { !$0.isEmpty }?.timeMapping.target.start.seconds ?? -1
            suite.expect(first > 0.35 && first < 0.45,
                         "a delayed microphone keeps its shared-clock offset")
        }
        do { try await TeamsAudioWriter.exportWave(master: master, output: output) }
        catch {
            suite.expect(false, "WAV export failed: \(error)")
            return
        }
        let playback = AVURLAsset(url: output)
        let duration = try await playback.load(.duration)
        suite.expect(abs(duration.seconds - 1.5) < 0.12, "mixed playback preserves the call duration")
        let audio = try await playback.loadTracks(withMediaType: .audio)
        suite.expect(audio.count == 1, "playback export is one mixed audio track")
        guard let track = audio.first else { return }
        let reader = try AVAssetReader(asset: playback)
        // The WAV already is signed stereo PCM. Read its native samples;
        // requesting conversion would introduce an unrelated codec dependency.
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(decoded)
        guard reader.startReading() else { throw reader.error ?? TeamsAudioWriter.WriteError.write }
        var remoteReal = 0.0, remoteImaginary = 0.0, localReal = 0.0, localImaginary = 0.0
        var gapReal = 0.0, gapImaginary = 0.0, gapFrames = 0
        var frames = 0
        while let sample = decoded.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            let byteCount = bytes.count * 2
            let copied = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
            }
            guard copied == noErr else { throw TeamsAudioWriter.WriteError.write }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            for frame in 0..<(bytes.count / 2) {
                let value = Double(bytes[frame * 2]) / 32_768
                let time = start + Double(frame) / 48_000
                remoteReal += value * cos(time * 440 * 2 * .pi)
                remoteImaginary += value * sin(time * 440 * 2 * .pi)
                localReal += value * cos(time * 880 * 2 * .pi)
                localImaginary += value * sin(time * 880 * 2 * .pi)
                if (0.1..<0.3).contains(time) || (1.0..<1.1).contains(time) {
                    gapReal += value * cos(time * 880 * 2 * .pi)
                    gapImaginary += value * sin(time * 880 * 2 * .pi)
                    gapFrames += 1
                }
                frames += 1
            }
        }
        suite.expect(reader.status == .completed && frames > 60_000, "playback decodes to a complete PCM stream")
        let remoteEnergy = hypot(remoteReal, remoteImaginary) / Double(max(1, frames))
        let localEnergy = hypot(localReal, localImaginary) / Double(max(1, frames))
        suite.expect(remoteEnergy > 0.025, "mixed export audibly contains remote source frequency")
        suite.expect(microphone && emitMicrophone ? localEnergy > 0.01 : localEnergy < 0.002,
                     "mixed export includes microphone only when requested")
        suite.expect(hypot(gapReal, gapImaginary) / Double(max(1, gapFrames)) < 0.003,
                     "microphone gaps remain silent while remote speech continues: \(hypot(gapReal, gapImaginary) / Double(max(1, gapFrames)))")
        do {
            try await TeamsAudioWriter.exportWave(master: master, output: output)
            suite.expect(false, "export must not replace an existing playback file")
        } catch { suite.expect(true, "existing playback is preserved") }
    }

    private static func tone(at time: CMTime, offset: Double, frequency: Double,
                             rate: Int = 48_000, channels: AVAudioChannelCount = 2,
                             floatingPoint: Bool = false, interleaved: Bool = true) -> CMSampleBuffer {
        let count = AVAudioFrameCount(rate / 100)
        let format = AVAudioFormat(commonFormat: floatingPoint ? .pcmFormatFloat32 : .pcmFormatInt16,
                                  sampleRate: Double(rate), channels: channels, interleaved: interleaved)!
        let device = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        device.frameLength = count
        for frame in 0..<Int(count) {
            let value = sin((offset + Double(frame) / Double(rate)) * frequency * 2 * .pi) * 0.244
            for channel in 0..<Int(channels) {
                let buffer = interleaved ? 0 : channel
                let index = interleaved ? frame * Int(channels) + channel : frame
                if floatingPoint { device.floatChannelData![buffer][index] = Float(value) }
                else { device.int16ChannelData![buffer][index] = Int16(value * 32_768) }
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                                       presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        precondition(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(count), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr)
        precondition(CMSampleBufferSetDataBufferFromAudioBufferList(result!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: device.audioBufferList) == noErr)
        precondition(CMSampleBufferSetDataReady(result!) == noErr)
        return result!
    }
}
