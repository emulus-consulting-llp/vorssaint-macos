// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

/// Audio-only master, with independently identifiable sources on one clock.
/// Confined to the recording's serial queue, then drained before finish/export.
/// Transferred between preparation, serialized writing and finalization; callers
/// must finish draining the queue before using the writer in the next phase.
final class TeamsAudioWriter: @unchecked Sendable {
    enum WriteError: Error { case setup, write, empty, export }
    enum AppendOutcome { case appended, notReady, dropped }
    private let writer: AVAssetWriter
    private let origin: CMTime
    private var inputs: [RecorderAudioSource: AVAssetWriterInput] = [:]
    private var converters: [RecorderAudioSource: AVAudioConverter] = [:]
    private var lastEnd: [RecorderAudioSource: Int64] = [:]
    private(set) var counts: [RecorderAudioSource: Int] = [:]
    private(set) var dropped = 0

    init(url: URL, origin: CMTime, includesMicrophone: Bool) throws {
        guard origin.isNumeric else { throw WriteError.setup }
        self.origin = origin
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
        for source in RecorderAudioSource.allCases where includesMicrophone || source == .system {
            // Keep an uncompressed ASR/recovery source independent of AAC.
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw WriteError.setup }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            input.metadata = source.trackMetadata
            guard writer.canAdd(input) else { throw WriteError.setup }
            writer.add(input)
            inputs[source] = input
        }
        guard writer.startWriting() else { throw writer.error ?? WriteError.setup }
        writer.startSession(atSourceTime: .zero)
    }

    /// Backpressure leaves the sample unconsumed so a bounded queue can retry.
    /// A failed encoder throws; invalid timing is an explicit drop.
    @discardableResult
    func append(_ sample: CMSampleBuffer, source: RecorderAudioSource) throws -> AppendOutcome {
        guard writer.status == .writing else { throw writer.error ?? WriteError.write }
        let time = CMSampleBufferGetPresentationTimeStamp(sample) - origin
        guard time.isNumeric, time >= .zero, let input = inputs[source] else {
            dropped += 1
            return .dropped
        }
        guard input.isReadyForMoreMediaData else { return .notReady }
        let frame = CMTimeConvertScale(time, timescale: 48_000, method: .roundHalfAwayFromZero).value
        // PCM MOV inputs concatenate their data across timestamp holes. Write
        // actual zeros for internal gaps so excluded mic audio stays silent in
        // BOTH the source master and every later export, rather than sliding
        // later speech into the hole. Keep the initial edit-list offset.
        var silenceBlocks = 0
        while let previous = lastEnd[source], frame > previous {
            // Yield to the other source while filling a long muted interval.
            guard silenceBlocks < 32, input.isReadyForMoreMediaData else { return .notReady }
            let count = Int(min(4_800, frame - previous))
            guard let silence = Self.silence(frames: count, start: previous), input.append(silence) else {
                throw writer.error ?? WriteError.write
            }
            lastEnd[source] = previous + Int64(count)
            silenceBlocks += 1
        }
        guard input.isReadyForMoreMediaData else { return .notReady }
        var converter = converters[source]
        let normalized = Self.normalizedPCM(sample, converter: &converter)
        converters[source] = converter
        let start = max(frame, lastEnd[source] ?? frame)
        guard let normalized, let retimed = RecorderSampleTiming.retimed(normalized,
            to: CMTime(value: start, timescale: 48_000)) else {
            throw WriteError.write
        }
        guard input.append(retimed) else { throw writer.error ?? WriteError.write }
        counts[source, default: 0] += 1
        lastEnd[source] = start + Int64(CMSampleBufferGetNumSamples(normalized))
        return .appended
    }

    private static func silence(frames: Int, start: Int64) -> CMSampleBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frames * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frames * 4, flags: 0, blockBufferOut: &block) == noErr,
            let block, CMBlockBufferFillDataBytes(with: 0, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: frames * 4) == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: start, timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format.formatDescription, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    func finish(at time: CMTime) async throws {
        guard counts.values.reduce(0, +) > 0 else {
            writer.cancelWriting()
            throw WriteError.empty
        }
        guard writer.status == .writing else { throw writer.error ?? WriteError.write }
        if time.isNumeric, time > origin { writer.endSession(atSourceTime: time - origin) }
        inputs.values.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WriteError.write }
    }

    /// Normalize device format changes before writing. The PCM master has
    /// one stable PCM format, even across float/int, channel and rate changes.
    private static func normalizedPCM(_ sample: CMSampleBuffer,
                                      converter: inout AVAudioConverter?) -> CMSampleBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate >= 1_000,
              asbd.mSampleRate <= 384_000, asbd.mChannelsPerFrame > 0 else { return nil }
        if asbd.mSampleRate == 48_000, asbd.mChannelsPerFrame == 2, asbd.mBitsPerChannel == 16,
           asbd.mBytesPerFrame == 4, asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
           asbd.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0 {
            return sample
        }
        let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)
            .map { AVAudioChannelLayout(layout: $0) }
            ?? AVAudioChannelLayout(layoutTag: asbd.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono
                : asbd.mChannelsPerFrame == 2 ? kAudioChannelLayoutTag_Stereo
                : kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd, channelLayout: layout),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000,
                                               channels: 2, interleaved: true) else { return nil }
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, Double(count) <= asbd.mSampleRate,
              let frames = AVAudioFrameCount(exactly: count), let signedFrames = Int32(exactly: count),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(count) * 48_000 / asbd.mSampleRate)) + 64),
              let converter else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: signedFrames,
                                                           into: input.mutableAudioBufferList) == noErr else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
        var normalized: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: outputFormat.formatDescription,
            sampleCount: Int(output.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &normalized) == noErr,
            let normalized,
            CMSampleBufferSetDataBufferFromAudioBufferList(normalized, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: output.audioBufferList) == noErr,
            CMSampleBufferSetDataReady(normalized) == noErr else { return nil }
        return normalized
    }

    /// Keep the source master if export fails. Both sources contribute to the
    /// one playback track, with headroom for simultaneous speech.
    static func exportMix(master: URL, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw WriteError.export }
        let asset = AVURLAsset(url: master)
        let sources = try await asset.loadTracks(withMediaType: .audio)
        guard !sources.isEmpty else { throw WriteError.empty }
        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        for source in sources {
            let range = try await source.load(.timeRange)
            guard range.duration > .zero else { continue }
            guard let target = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw WriteError.export
            }
            try target.insertTimeRange(range, of: source, at: range.start)
            let volume = AVMutableAudioMixInputParameters(track: target)
            volume.setVolume(sources.count > 1 ? 0.5 : 1, at: .zero)
            parameters.append(volume)
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw WriteError.export
        }
        export.audioMix = mix
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw export.error ?? WriteError.export }
    }

    /// PCM fallback without an AudioUnit mixer or encoder. Read the fixed PCM
    /// source format directly and mix in bounded blocks, preserving silent gaps.
    static func exportWave(master: URL, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw WriteError.export }
        let asset = AVURLAsset(url: master)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw WriteError.empty }
        let duration = try await asset.load(.duration).seconds
        // Standard RIFF/WAV has a 32-bit byte count (~6 hours of stereo PCM).
        guard duration.isFinite, duration > 0, duration * 48_000 < Double((UInt32.max - 36) / 4) else {
            throw WriteError.export
        }
        let frames = Int((duration * 48_000).rounded(.up))
        var cursors: [PCMReader] = []
        for track in tracks {
            let mappings = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping)
            cursors.append(try PCMReader(asset: asset, track: track, mappings: mappings))
        }
        var header = Data("RIFF".utf8)
        func word(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { header.append(contentsOf: $0) } }
        word(UInt32(frames * 4 + 36))
        header.append(Data("WAVEfmt ".utf8))
        word(16)
        header.append(contentsOf: [1, 0, 2, 0]) // PCM, stereo
        word(48_000)
        word(192_000)
        header.append(contentsOf: [4, 0, 16, 0]) // block alignment, bit depth
        header.append(Data("data".utf8))
        word(UInt32(frames * 4))
        try TeamsAXDiagnostic.writePrivateReport(header, to: output)
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        try file.seekToEnd()
        for first in stride(from: 0, to: frames, by: 4_800) {
            let count = min(4_800, frames - first)
            var sum = [Int32](repeating: 0, count: count * 2)
            for cursor in cursors { try cursor.add(to: &sum, firstFrame: first, frameCount: count) }
            var pcm = sum.map { Int16(clamping: $0 / Int32(cursors.count)).littleEndian }
            try pcm.withUnsafeMutableBytes { try file.write(contentsOf: Data($0)) }
        }
        try file.synchronize()
    }

    private final class PCMReader {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let mappings: [CMTimeMapping]
        private var packet: (first: Int, frameCount: Int, data: CMBlockBuffer)?
        private var exhausted = false

        init(asset: AVAsset, track: AVAssetTrack, mappings: [CMTimeMapping]) throws {
            self.mappings = mappings
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw WriteError.export }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? WriteError.export }
        }

        func add(to sum: inout [Int32], firstFrame: Int, frameCount: Int) throws {
            let end = firstFrame + frameCount
            while !exhausted {
                if packet == nil { try advance() }
                guard let packet else { break }
                let packetEnd = packet.first + packet.frameCount
                if packet.first >= end { break }
                let from = max(packet.first, firstFrame)
                let to = min(packetEnd, end)
                if from < to {
                    // A native PCM packet can span a long continuous source.
                    // Copy only this mix block, not the entire packet.
                    var samples = [Int16](repeating: 0, count: (to - from) * 2)
                    let status = samples.withUnsafeMutableBytes {
                        CMBlockBufferCopyDataBytes(packet.data, atOffset: (from - packet.first) * 4,
                            dataLength: (to - from) * 4, destination: $0.baseAddress!)
                    }
                    guard status == noErr else { throw WriteError.export }
                    for frame in from..<to {
                        for channel in 0..<2 {
                            sum[(frame - firstFrame) * 2 + channel] += Int32(samples[(frame - from) * 2 + channel])
                        }
                    }
                }
                if packetEnd <= end { self.packet = nil } else { break }
            }
        }

        private func advance() throws {
            while let sample = output.copyNextSampleBuffer() {
                // Empty-media samples represent edit-list gaps, hence silence.
                if CMSampleBufferGetFormatDescription(sample) == nil,
                   CMSampleBufferGetDataBuffer(sample) == nil,
                   CMSampleBufferGetTotalSampleSize(sample) == 0 { continue }
                guard let description = CMSampleBufferGetFormatDescription(sample),
                      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                    throw NSError(domain: "TeamsPCMDescription", code: 1)
                }
                guard format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 2,
                      format.mSampleRate == 48_000, format.mBitsPerChannel == 16,
                      format.mBytesPerFrame == 4, format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
                      format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0,
                      let block = CMSampleBufferGetDataBuffer(sample) else {
                    throw NSError(domain: "TeamsPCMFormat", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected PCM source format: \(format)"])
                }
                // Native PCM retains media timestamps. Apply each track edit
                // explicitly: the output timestamp alone does not represent
                // all internal gaps in a source with multiple kept intervals.
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                let length = CMBlockBufferGetDataLength(block)
                if length == 0 { continue }
                guard time.isFinite, time >= 0, time * 48_000 < Double(Int.max), length % 4 == 0 else {
                    throw NSError(domain: "TeamsPCMTiming", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected PCM timing/size: \(time), \(length)"])
                }
                guard let mapping = mappings.first(where: {
                    time >= $0.source.start.seconds - 0.000_001
                        && time < CMTimeRangeGetEnd($0.source).seconds - 0.000_001
                }), abs(mapping.source.duration.seconds - mapping.target.duration.seconds) < 0.000_001,
                time + Double(length / 4) / 48_000 <= CMTimeRangeGetEnd(mapping.source).seconds + 0.000_03 else {
                    throw WriteError.export
                }
                let target = mapping.target.start.seconds + time - mapping.source.start.seconds
                packet = (Int((target * 48_000).rounded()), length / 4, block)
                return
            }
            guard reader.status == .completed else { throw reader.error ?? WriteError.export }
            exhausted = true
        }
    }
}
