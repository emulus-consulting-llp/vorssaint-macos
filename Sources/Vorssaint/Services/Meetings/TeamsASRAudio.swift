// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

/// Bounded native PCM preparation. Track edit mappings retain the recording
/// clock, including the silent intervals excluded by the microphone gate.
enum TeamsASRAudio {
    struct Chunk {
        let url: URL
        let source: RecorderAudioSource
        let offset: Double
        let duration: Double
        let audibleRanges: [ClosedRange<Double>]
    }

    /// Causal, windowed sinc low-pass before 3:1 decimation. Its 31-frame
    /// delay is under one millisecond; no samples are advanced across gaps.
    struct Downsampler {
        private static let coefficients: [Double] = {
            let values = (0..<63).map { index -> Double in
                let x = Double(index - 31)
                let sinc = x == 0 ? 2 * 7_000 / 48_000 : sin(2 * .pi * 7_000 / 48_000 * x) / (.pi * x)
                return sinc * (0.54 - 0.46 * cos(2 * .pi * Double(index) / 62))
            }
            let sum = values.reduce(0, +)
            return values.map { $0 / sum }
        }()
        private var history = [Double](repeating: 0, count: 63)
        private var cursor = 0
        private var phase = 0

        mutating func convert(_ stereo: [Int32]) -> [Int16] {
            var result: [Int16] = []
            result.reserveCapacity(stereo.count / 6 + 1)
            for frame in 0..<(stereo.count / 2) {
                history[cursor] = Double(stereo[frame * 2] + stereo[frame * 2 + 1]) / 2
                if phase == 0 {
                    var value = 0.0
                    for tap in 0..<63 { value += history[(cursor - tap + 63) % 63] * Self.coefficients[tap] }
                    result.append(Int16(clamping: Int(value.rounded())))
                }
                cursor = (cursor + 1) % 63
                phase = (phase + 1) % 3
            }
            return result
        }
    }

    static func prepare(master: URL, directory: URL, cancellation: BoundedProcessCancellation,
                        chunkSeconds: Int = 600) async throws -> [Chunk] {
        guard (1...600).contains(chunkSeconds) else { throw TeamsTranscriptionService.Failure.invalidRecording }
        let asset = AVURLAsset(url: master)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 21_600 else {
            throw TeamsTranscriptionService.Failure.invalidRecording
        }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var identified: [RecorderAudioSource: AVAssetTrack] = [:]
        // Never apply the editor's legacy track-order fallback to speaker labels.
        for track in tracks {
            for item in try await track.load(.metadata) where item.identifier == .quickTimeMetadataContentIdentifier {
                guard let value = try await item.load(.stringValue),
                      let source = RecorderAudioSource.allCases.first(where: {
                          value == "com.vorssaint.recorder.audio." + $0.rawValue
                      }), identified[source] == nil else { throw TeamsTranscriptionService.Failure.invalidRecording }
                identified[source] = track
            }
        }
        guard !identified.isEmpty, identified.count == tracks.count else {
            throw TeamsTranscriptionService.Failure.invalidRecording
        }
        let frames = Int((duration * 48_000).rounded(.up))
        let chunkFrames = chunkSeconds * 48_000
        var chunks: [Chunk] = []
        for source in RecorderAudioSource.allCases {
            guard let track = identified[source] else { continue }
            let mappings = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping)
            let reader = try TeamsAudioWriter.PCMReader(asset: asset, track: track, mappings: mappings)
            var converter = Downsampler()
            for firstChunk in stride(from: 0, to: frames, by: chunkFrames) {
                let chunkEnd = min(frames, firstChunk + chunkFrames)
                let url = directory.appendingPathComponent("\(source.rawValue)-\(firstChunk / chunkFrames).wav")
                try TeamsAXDiagnostic.writePrivateReport(waveHeader(frames: 0), to: url)
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                var outputFrames = 0
                var audible: [ClosedRange<Double>] = []
                for first in stride(from: firstChunk, to: chunkEnd, by: 4_800) {
                    if cancellation.isCancelled { throw TeamsTranscriptionService.Failure.cancelled }
                    let count = min(4_800, chunkEnd - first)
                    var input = [Int32](repeating: 0, count: count * 2)
                    try reader.add(to: &input, firstFrame: first, frameCount: count)
                    var output = converter.convert(input).map(\.littleEndian)
                    let start = Double(outputFrames) / 16_000
                    outputFrames += output.count
                    if output.contains(where: { $0 != 0 }) {
                        let end = Double(outputFrames) / 16_000
                        if let last = audible.last, abs(last.upperBound - start) < 0.0001 {
                            audible[audible.count - 1] = last.lowerBound...end
                        } else { audible.append(start...end) }
                    }
                    try output.withUnsafeMutableBytes { try file.write(contentsOf: Data($0)) }
                }
                try file.seek(toOffset: 0)
                try file.write(contentsOf: waveHeader(frames: outputFrames))
                try file.synchronize()
                try file.close()
                if audible.isEmpty { try FileManager.default.removeItem(at: url) }
                else {
                    chunks.append(.init(url: url, source: source, offset: Double(firstChunk) / 48_000,
                        duration: Double(outputFrames) / 16_000, audibleRanges: audible))
                }
            }
        }
        return chunks
    }

    private static func waveHeader(frames: Int) -> Data {
        var data = Data("RIFF".utf8)
        func word(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        word(UInt32(frames * 2 + 36))
        data.append(Data("WAVEfmt ".utf8))
        word(16)
        data.append(contentsOf: [1, 0, 1, 0])
        word(16_000)
        word(32_000)
        data.append(contentsOf: [2, 0, 16, 0])
        data.append(Data("data".utf8))
        word(UInt32(frames * 2))
        return data
    }
}
