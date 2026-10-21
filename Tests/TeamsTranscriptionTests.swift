// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

enum TeamsTranscriptionTests {
    static func run(_ suite: TestSuite) {
        do { try parsing(suite) } catch { suite.expect(false, "transcript parsing: \(error)") }
        do { try captions(suite) } catch { suite.expect(false, "caption export: \(error)") }
        do { try cachedResults(suite) } catch { suite.expect(false, "cached transcription: \(error)") }
        downsampling(suite)
        let allocation = BoundedProcessRunner.Result(status: 6,
            output: Data("ggml_metal_buffer_init: error: failed to allocate buffer".utf8), timedOut: false)
        suite.expect(TeamsTranscriptionService.canRetryOnCPU(allocation), "verified GPU allocation failure permits CPU retry")
        let timeout = BoundedProcessRunner.Result(status: -1, output: allocation.output, timedOut: true)
        suite.expect(!TeamsTranscriptionService.canRetryOnCPU(timeout), "inference timeouts cannot silently restart an expensive job")
        let other = BoundedProcessRunner.Result(status: 1, output: Data("model read failed".utf8), timedOut: false)
        suite.expect(!TeamsTranscriptionService.canRetryOnCPU(other), "unrelated engine failures do not trigger a CPU retry")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await pipeline(suite) }
            catch { suite.expect(false, "local transcription pipeline: \(error)") }
            done.signal()
        }
        suite.expect(done.wait(timeout: .now() + 40) == .success, "transcription pipeline finishes within deadline")
    }

    private static func parsing(_ suite: TestSuite) throws {
        var splitToken = Data("{\"transcription\":[{\"offsets\":{\"from\":0,\"to\":1000},\"text\":\"Hello नमस्ते\",\"tokens\":[{\"text\":\"".utf8)
        splitToken.append(contentsOf: [0xe0, 0xa4])
        splitToken.append(Data("\"}]}]}".utf8))
        let recovered = try TeamsTranscriptTurn.decodeWhisper(splitToken, source: .system,
            offset: 0, duration: 1, audibleRanges: [0...1])
        suite.expect(recovered.first?.text == "Hello नमस्ते", "split UTF-8 in unused full-output token diagnostics cannot destroy valid multilingual sentence text")
        let corruptSpeech = Data("{\"transcription\":[{\"offsets\":{\"from\":0,\"to\":1000},\"text\":\"bad � speech\"}]}".utf8)
        let repaired = try TeamsTranscriptTurn.decodeWhisper(corruptSpeech, source: .system,
            offset: 0, duration: 1, audibleRanges: [0...1])
        suite.expect(repaired.first?.textEncodingRepaired == true
                     && TeamsTranscriptTurn.markdown(repaired, model: "test", warnings: []).contains("[text encoding repaired]"),
                     "damaged sentence characters remain visibly marked without losing the rest of the transcript")
        let json = Data("""
        {"transcription":[
          {"offsets":{"from":100,"to":400},"text":"Please send the review tomorrow."},
          {"offsets":{"from":500,"to":700},"text":"hallucination in silence"},
          {"offsets":{"from":800,"to":1300},"text":" Final words. "},
          {"offsets":{"from":-10,"to":100},"text":"invalid timing"},
          {"offsets":{"from":100,"to":200},"text":"[BLANK_AUDIO]"}]}
        """.utf8)
        let turns = try TeamsTranscriptTurn.decodeWhisper(json, source: .system, offset: 600,
            duration: 1, audibleRanges: [0.1...0.4, 0.8...1])
        suite.expect(turns.count == 2 && turns[0].start == 600.1 && turns[1].end == 601,
                     "whisper millisecond offsets preserve chunk origin, clamp duration and exclude silence/invalid segments")
        var observation = TeamsCallObservation()
        observation.captionLines = [.init(speakerDisplayName: "Test Person", text: "Please send the review tomorrow.", sourcePath: "test")]
        func journal(_ name: String? = nil, time: Double = 600.5) throws -> Data {
            if let name { observation.captionLines[0] = .init(speakerDisplayName: name, text: "Please send the review tomorrow.", sourcePath: "test2") }
            let object: [String: Any] = ["scanEnded": time,
                "observation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))]
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            return data
        }
        let first = try journal()
        let evidence = try TeamsCaptionEvidence(journal: first)
        suite.expect(evidence.attribute(turns[0]).speaker == "Test Person", "nearby matching caption text supplies a qualified display label")
        let ambiguous = try TeamsCaptionEvidence(journal: first + journal("Other Person"))
        suite.expect(ambiguous.attribute(turns[0]).speaker == "Remote", "ambiguous caption labels remain unnamed")
        let stale = try TeamsCaptionEvidence(journal: journal(time: 900))
        suite.expect(stale.attribute(turns[0]).speaker == "Remote", "unrelated caption times cannot assign identity")
        let local = try TeamsTranscriptTurn.decodeWhisper(json, source: .microphone, offset: 600,
            duration: 1, audibleRanges: [0...1])
        suite.expect(evidence.attribute(local[0]).speaker == "You", "caption labels never override local source attribution")
        let html = TeamsTranscriptTurn(start: 2, end: 3, source: .system, speaker: "[Name]",
            attribution: "unknownRemote", text: "<script> **text**")
        let markdown = TeamsTranscriptTurn.markdown([turns[0], html], model: "test", warnings: [])
        suite.expect(markdown.contains("&lt;script&gt; \\*\\*text\\*\\*") && markdown.contains("\\[Name\\]"),
                     "meeting text cannot inject Markdown links or HTML")
        suite.expect(markdown.range(of: "[00:00:02]")!.lowerBound < markdown.range(of: "[00:10:00]")!.lowerBound,
                     "merged sources render chronologically")
    }

    private static func captions(_ suite: TestSuite) throws {
        var journal = Data()
        func event(_ time: Double, _ lines: [(String, String)]) throws {
            var observation = TeamsCallObservation()
            observation.captionLines = lines.enumerated().map { index, row in
                .init(speakerDisplayName: row.0, text: row.1, sourcePath: "slot/\(index)")
            }
            let object: [String: Any] = ["scanEnded": time,
                "observation": try JSONSerialization.jsonObject(with: JSONEncoder().encode(observation))]
            journal.append(try JSONSerialization.data(withJSONObject: object))
            journal.append(10)
        }
        try event(1, [("A", "Please send the draft")])
        try event(2, [("A", "Please send the draft tomorrow."), ("B", "Yes, thank you.")])
        try event(3, [("A", "Please send the draft tomorrow."), ("B", "Yes, thank you.")])
        try event(4, [])
        try event(5, [("B", "Yes, thank you.")])
        try event(40, [("A", "Please send the draft tomorrow.")])
        let rows = try TeamsCaptions.rows(journal: journal)
        suite.expect(rows.count == 3 && rows[0].text == "Please send the draft tomorrow.",
                     "caption revisions and repeated snapshots collapse while later repeated speech survives")
        suite.expect(rows[0].firstObserved == 1 && rows[0].lastObserved == 3 && rows[2].firstObserved == 40,
                     "caption times retain observation history rather than claiming speech timing")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teams captions \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        try journal.write(to: folder.appendingPathComponent("observations.jsonl"))
        let count = try TeamsCaptions.export(folder: folder)
        let markdown = folder.appendingPathComponent("captions.md")
        suite.expect(count == 3 && FileManager.default.fileExists(atPath: folder.appendingPathComponent("captions.json").path),
                     "caption export is available without ASR or a speech model")
        let permissions = try FileManager.default.attributesOfItem(atPath: markdown.path)[.posixPermissions] as? Int
        suite.expect(permissions == 0o600, "caption exports are owner-only")
        try Data("user notes".utf8).write(to: markdown)
        try TeamsCaptions.export(folder: folder)
        let preserved = try String(contentsOf: markdown, encoding: .utf8)
        suite.expect(preserved == "user notes", "caption retries preserve user-edited output")
    }

    private static func downsampling(_ suite: TestSuite) {
        func amplitude(_ frequency: Double) -> Double {
            var converter = TeamsASRAudio.Downsampler()
            let input = (0..<48_000).flatMap { frame -> [Int32] in
                let value = Int32((sin(Double(frame) / 48_000 * frequency * 2 * .pi) * 12_000).rounded())
                return [value, value]
            }
            let samples = converter.convert(input)
            suite.expect(samples.count == 16_000, "48 kHz conversion retains duration at 16 kHz")
            return sqrt(samples.dropFirst(100).reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count - 100))
        }
        suite.expect(amplitude(1_000) > 8_000, "speech-band audio survives mono downsampling")
        suite.expect(amplitude(12_000) < 100, "anti-alias filter rejects frequencies above target Nyquist")
        var converter = TeamsASRAudio.Downsampler()
        suite.expect(converter.convert([Int32](repeating: 0, count: 9_600)).allSatisfy { $0 == 0 },
                     "digital silence stays silent")
    }

    private static func cachedResults(_ suite: TestSuite) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teams recovery \(UUID())")
        let attempt = folder.appendingPathComponent("transcription-old")
        try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("engine"), model = folder.appendingPathComponent("model")
        for url in [executable, model] {
            try Data("original".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        }
        let configuration = TeamsTranscriptionService.Configuration(executable: executable, model: model)
        let input = folder.appendingPathComponent("system-0.wav")
        try Data("exact PCM".utf8).write(to: input)
        try FileManager.default.copyItem(at: input, to: attempt.appendingPathComponent(input.lastPathComponent))
        let output = attempt.appendingPathComponent("system-0.json")
        let data = try JSONSerialization.data(withJSONObject: ["params": ["model": model.path, "language": "auto", "translate": false],
            "transcription": [["offsets": ["from": 0, "to": 1000], "text": "Recovered speech."]]])
        try data.write(to: output)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: output.path)
        let chunk = TeamsASRAudio.Chunk(url: input, source: .system, offset: 0, duration: 1, audibleRanges: [0...1])
        func cached(_ config: TeamsTranscriptionService.Configuration) -> Data? {
            TeamsTranscriptionService.cachedOutput(chunk: chunk, attempts: [attempt], configuration: config)
        }
        suite.expect(cached(configuration) == data, "retry can recover a completed engine result with exactly matching audio and model")
        var language = configuration
        language.language = "en"
        suite.expect(cached(language) == nil, "changing recognition language invalidates a prior result")
        try Data("other PCM".utf8).write(to: input)
        suite.expect(cached(configuration) == nil, "different audio with the same chunk name and byte count cannot be reused")
        try Data("exact PCM".utf8).write(to: input)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: model.path)
        suite.expect(cached(configuration) == nil, "a replaced model invalidates old results")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: model.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: executable.path)
        suite.expect(cached(configuration) == nil, "an updated speech engine invalidates old results")
    }

    private static func pipeline(_ suite: TestSuite) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teams ASR \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let master = folder.appendingPathComponent("sources.mov")
        let writer = try TeamsAudioWriter(url: master, origin: .zero, includesMicrophone: true)
        for index in 0..<210 {
            let time = CMTime(value: Int64(index), timescale: 100)
            for source in RecorderAudioSource.allCases where source == .system || (20..<40).contains(index) || (120..<140).contains(index) {
                let sample = RecorderSampleTimingTests.audio(count: 480, time: time)
                _ = CMBlockBufferFillDataBytes(with: 0x20, blockBuffer: CMSampleBufferGetDataBuffer(sample)!,
                    offsetIntoDestination: 0, dataLength: 480 * 4)
                while try writer.append(sample, source: source) == .notReady { try await Task.sleep(nanoseconds: 1_000_000) }
            }
        }
        try await writer.finish(at: CMTime(value: 21, timescale: 10))
        let audio = folder.appendingPathComponent("prepared")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: false)
        let chunks = try await TeamsASRAudio.prepare(master: master, directory: audio,
            cancellation: BoundedProcessCancellation(), chunkSeconds: 1)
        suite.expect(chunks.filter { $0.source == .system }.count == 3 && chunks.filter { $0.source == .microphone }.count == 2,
                     "chunking skips an all-silent microphone tail while retaining remote audio")
        let mic = chunks.first { $0.source == .microphone }!
        let bytes = [UInt8](try Data(contentsOf: mic.url))
        func value(_ frame: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[44 + frame * 2]) | UInt16(bytes[45 + frame * 2]) << 8) }
        suite.expect(bytes.count == 32_044 && bytes[22] == 1 && bytes[24] == 0x80 && bytes[25] == 0x3e,
                     "ASR input is one second of 16 kHz mono 16-bit WAV")
        suite.expect(value(1_600) == 0 && abs(Int(value(4_800))) > 1_000 && value(9_600) == 0,
                     "delayed microphone onset and internal excluded intervals keep their original times")
        suite.expect(chunks.contains { $0.source == .microphone && $0.offset == 1 }, "later microphone chunks retain their global origin")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/teams-whisper-fixture.sh")
        let executable = folder.appendingPathComponent("fake whisper")
        try FileManager.default.copyItem(at: fixture, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = folder.appendingPathComponent("fake model.bin")
        try Data("ok".utf8).write(to: model)
        let configuration = TeamsTranscriptionService.Configuration(executable: executable, model: model)
        let manifest = folder.appendingPathComponent("manifest.json")
        try Data("{\"state\":\"recording\"}".utf8).write(to: manifest)
        do {
            _ = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration,
                cancellation: BoundedProcessCancellation())
            suite.expect(false, "active recording cannot be transcribed")
        } catch TeamsTranscriptionService.Failure.invalidRecording {
            suite.expect(true, "ASR refuses an unfinished recording before changing its manifest")
        }
        try Data("{\"state\":\"complete\",\"warnings\":[]}".utf8).write(to: manifest)
        let result = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration,
            cancellation: BoundedProcessCancellation())
        suite.expect(result.turns == 2 && result.namedRemoteTurns == 0, "separate sources pass through subprocess and merge without inventing names")
        let transcript = folder.appendingPathComponent("transcript.md")
        let original = try Data(contentsOf: transcript)
        let permissions = try FileManager.default.attributesOfItem(atPath: transcript.path)[.posixPermissions] as? Int
        suite.expect(permissions == 0o600, "published transcript is owner-only")
        do {
            _ = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration,
                cancellation: BoundedProcessCancellation())
            suite.expect(false, "existing transcript must not be replaced")
        } catch TeamsTranscriptionService.Failure.existingTranscript {
            let preserved = try Data(contentsOf: transcript)
            suite.expect(preserved == original, "retry preserves an existing transcript")
        }
        try FileManager.default.removeItem(at: transcript)
        try Data("fail".utf8).write(to: model)
        do {
            _ = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration,
                cancellation: BoundedProcessCancellation())
            suite.expect(false, "failed engine must not publish a transcript")
        } catch TeamsTranscriptionService.Failure.engine {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            suite.expect(saved["transcriptionState"] as? String == "failed" && saved["state"] as? String == "complete",
                         "ASR failure preserves the completed recording state and allows retry")
        }
        let cancellation = BoundedProcessCancellation()
        try Data("slow".utf8).write(to: model)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let started = Date()
        do {
            _ = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration, cancellation: cancellation)
            suite.expect(false, "cancelled engine must not publish a transcript")
        } catch TeamsTranscriptionService.Failure.cancelled {
            suite.expect(Date().timeIntervalSince(started) < 3 && !FileManager.default.fileExists(atPath: transcript.path),
                         "cancellation stops local inference promptly without publishing partial text")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
            suite.expect(saved["transcriptionState"] as? String == "cancelled" && saved["state"] as? String == "complete",
                         "cancellation leaves the completed audio intact and marks transcription retryable")
        }
        let descriptor = open(folder.appendingPathComponent(".transcription.lock").path, O_RDWR)
        defer { close(descriptor) }
        _ = flock(descriptor, LOCK_EX | LOCK_NB)
        do {
            _ = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration,
                cancellation: BoundedProcessCancellation())
            suite.expect(false, "concurrent transcription must be refused")
        } catch TeamsTranscriptionService.Failure.busy { suite.expect(true, "a second job cannot race the manifest or transcript") }
        _ = flock(descriptor, LOCK_UN)
        try Data("gpu".utf8).write(to: model)
        let fallback = try await TeamsTranscriptionService.transcribe(folder: folder, configuration: configuration,
            cancellation: BoundedProcessCancellation())
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
        suite.expect(fallback.turns == 2 && saved["transcriptionBackend"] as? String == "cpuFallback",
                     "GPU allocation failure retries on CPU and uses CPU for subsequent source chunks")
        let markdown = try String(contentsOf: transcript, encoding: .utf8)
        suite.expect(markdown.contains("CPU fallback"), "completed transcript discloses the fallback")
    }
}
