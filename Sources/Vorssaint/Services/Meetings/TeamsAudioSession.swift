// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation

/// The main actor owns source lifetimes. Stop is called after start returns;
/// samples and evidence are serialized by Sink, never by the UI thread.
@MainActor
final class TeamsAudioSession {
    let folder: URL
    private let sink: TeamsAudioSink
    private var tap: RecorderSystemAudioTap?
    private var mic: RecorderMicrophoneCapture?
    private var finished = false
    var remoteHeard: Bool { sink.remoteHeard.value }

    static func prepare(parent: URL, title: String, includesMicrophone: Bool,
                        onFailure: @escaping () -> Void) async throws -> TeamsAudioSession {
        let sink = try await TeamsAudioSink.prepare(parent: parent, title: title,
            includesMicrophone: includesMicrophone, onFailure: onFailure)
        return TeamsAudioSession(sink: sink)
    }

    private init(sink: TeamsAudioSink) {
        self.sink = sink
        folder = sink.folder
    }

    func start(pid: Int32, includesMicrophone: Bool) async throws {
        guard let tap = await RecorderSystemAudioTap.make(hearing: pid) else { throw SessionError.tap }
        self.tap = tap
        let sink = self.sink
        tap.onSample = { sample in sink.enqueue(sample, source: .system) }
        tap.onReaderLost = { sink.fail("Teams audio reader was lost; capture stopped.") }
        guard await tap.start(synchronizingTo: CMClockGetHostTimeClock()) else { throw SessionError.tap }
        if includesMicrophone {
            let mic = RecorderMicrophoneCapture()
            self.mic = mic
            mic.onSample = { sample in sink.enqueue(sample, source: .microphone) }
            guard await mic.start(synchronizingTo: CMClockGetHostTimeClock()) else { throw SessionError.microphone }
        }
    }

    func observe(_ reading: TeamsCallScanner.Reading) { sink.observe(reading) }

    func stop(reason: String) async -> String {
        guard !finished else { return "Already saved." }
        finished = true
        await mic?.stop()
        await tap?.stop()
        mic = nil
        tap = nil
        return await sink.finish(reason: reason)
    }

    enum SessionError: LocalizedError {
        case tap, microphone
        var errorDescription: String? {
            switch self {
            case .tap: return "Could not start Teams audio capture. macOS 14.4+ and audio capture permission are required."
            case .microphone: return "Could not start the default microphone. Check microphone permission and the selected input."
            }
        }
    }
}

private final class TeamsAudioSink: @unchecked Sendable {
    private static let preparationQueue = DispatchQueue(label: "com.vorssaint.teams.prepare", qos: .userInitiated)

    static func prepare(parent: URL, title: String, includesMicrophone: Bool,
                        onFailure: @escaping () -> Void) async throws -> TeamsAudioSink {
        try await withCheckedThrowingContinuation { continuation in
            preparationQueue.async {
                do {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
                    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
                    let safe = title.unicodeScalars.prefix(48).map { allowed.contains($0) ? String($0) : "_" }.joined()
                    let folder = parent.appendingPathComponent("\(formatter.string(from: Date()))_\(safe)_\(UUID().uuidString.prefix(8))", isDirectory: true)
                    // Protect files AVFoundation creates from the first byte.
                    guard mkdir(folder.path, S_IRWXU) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    continuation.resume(returning: try TeamsAudioSink(folder: folder, title: title,
                        includesMicrophone: includesMicrophone, onFailure: onFailure))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    let remoteHeard = RecorderAudioFlag()
    private let queue = DispatchQueue(label: "com.vorssaint.teams.audio-writer", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 128)
    private let overflow = RecorderAudioFlag()
    let folder: URL
    private let origin = CMClockGetTime(CMClockGetHostTimeClock())
    private let writer: TeamsAudioWriter
    private lazy var writes = TeamsAudioWriteQueue(queue: queue,
        append: { [writer] sample, source in try writer.append(sample, source: source) },
        onWritten: { [weak self] sample, source in
            if source == .system, RecorderAudioProbe.containsSound(sample) { self?.remoteHeard.raise() }
        }, onFailure: { [weak self] message in self?.failOnQueue(message, duringFlush: true) })
    private let journal: FileHandle
    private let onFailure: () -> Void
    private var microphoneFilter = TeamsMicrophoneFilter()
    private var issue: String?
    private var closed = false
    private var lastContent: Data?
    private var manifest: [String: Any]

    init(folder: URL, title: String, includesMicrophone: Bool, onFailure: @escaping () -> Void) throws {
        self.folder = folder
        self.onFailure = onFailure
        let journalURL = folder.appendingPathComponent("observations.jsonl")
        try TeamsAXDiagnostic.writePrivateReport(Data(), to: journalURL)
        journal = try FileHandle(forWritingTo: journalURL)
        manifest = ["schemaVersion": 1, "title": title, "startedAt": ISO8601DateFormatter().string(from: Date()),
                    "state": "recording", "microphoneRequested": includesMicrophone,
                    "microphonePolicy": "Best-effort bracketed AX observations; brief mute changes may be missed. Default system input; use headphones to reduce echo.",
                    "captionTiming": "Observation times only; rows can revise or repeat. Not a transcript.",
                    "transcriptionState": "notImplemented", "actionItemsState": "notImplemented"]
        writer = try TeamsAudioWriter(url: folder.appendingPathComponent("sources.mov"),
                                      origin: origin, includesMicrophone: includesMicrophone)
        try saveManifest()
    }

    func enqueue(_ sample: CMSampleBuffer, source: RecorderAudioSource) {
        guard slots.wait(timeout: .now()) == .success else {
            // No unbounded sample backlog if storage cannot keep up.
            overflow.raise()
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            guard !closed, issue == nil else { return }
            if overflow.value {
                failOnQueue("Audio writer could not keep up; capture stopped.")
                return
            }
            if source == .microphone {
                microphoneFilter.append(sample, receivedAt: TeamsCallScanner.now)
            } else {
                append(sample, source: source)
            }
        }
    }

    func observe(_ reading: TeamsCallScanner.Reading) {
        queue.async { [self] in
            guard !closed, issue == nil else { return }
            let released = microphoneFilter.observe(reading.observation.microphone,
                scanStarted: reading.started, scanEnded: reading.ended)
            for sample in released { append(sample, source: .microphone) }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let content = try encoder.encode(reading.observation)
                // Repeated unchanged rows need not duplicate text on disk.
                // Every poll still records timing/state to expose gaps.
                var event: [String: Any] = ["scanStarted": reading.started - origin.seconds,
                    "scanEnded": reading.ended - origin.seconds,
                    "microphone": reading.observation.microphone.rawValue,
                    "issue": reading.issue ?? ""]
                if content != lastContent {
                    event["observation"] = try JSONSerialization.jsonObject(with: content)
                    lastContent = content
                }
                var data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                data.append(0x0a)
                try journal.write(contentsOf: data)
            } catch { failOnQueue("Could not save observation evidence; capture stopped.") }
        }
    }

    func fail(_ message: String) { queue.async { self.failOnQueue(message) } }

    private func failOnQueue(_ message: String, duringFlush: Bool = false) {
        guard issue == nil, !closed || duringFlush else { return }
        issue = message
        if !closed { DispatchQueue.main.async(execute: onFailure) }
    }

    private func append(_ sample: CMSampleBuffer, source: RecorderAudioSource) {
        writes.enqueue(sample, source: source)
    }

    func finish(reason: String) async -> String {
        let stoppedAt = CMClockGetTime(CMClockGetHostTimeClock())
        // Sources have stopped, so draining the writer queue also drains all
        // accepted callbacks. Unbracketed microphone tail is never archived.
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closed = true
                microphoneFilter.discardPending()
                try? journal.synchronize()
                try? journal.close()
                manifest["state"] = "finalizing"
                manifest["stopReason"] = reason
                try? saveManifest()
                writes.flush { continuation.resume() }
            }
        }
        var messages: [String] = issue.map { [$0] } ?? []
        var masterComplete = false
        var mixComplete = false
        do {
            try await writer.finish(at: stoppedAt)
            masterComplete = true
            let temporary = folder.appendingPathComponent("recording.partial.m4a")
            do {
                try await TeamsAudioWriter.exportMix(master: folder.appendingPathComponent("sources.mov"), output: temporary)
                try FileManager.default.moveItem(at: temporary, to: folder.appendingPathComponent("recording.m4a"))
                manifest["playbackFile"] = "recording.m4a"
            } catch {
                let wave = folder.appendingPathComponent("recording.partial.wav")
                try await TeamsAudioWriter.exportWave(master: folder.appendingPathComponent("sources.mov"), output: wave)
                try FileManager.default.moveItem(at: wave, to: folder.appendingPathComponent("recording.wav"))
                manifest["playbackFile"] = "recording.wav"
                messages.append("Compact audio export was unavailable; saved WAV playback instead.")
            }
            mixComplete = true
        } catch { messages.append(masterComplete ? "Playback export failed; source tracks were retained." : "Audio finalization failed; any partial files were retained.") }
        if !remoteHeard.value { messages.append("No non-silent Teams audio was verified. Check capture permission and playback before relying on this recording.") }
        if manifest["microphoneRequested"] as? Bool == true, writer.counts[.microphone, default: 0] == 0 {
            messages.append("No microphone audio passed the mute filter.")
        }
        if writer.dropped > 0 { messages.append("Some audio buffers were dropped (\(writer.dropped)).") }
        manifest["state"] = mixComplete ? (messages.isEmpty ? "complete" : "completeWithWarnings") : "incomplete"
        manifest["remoteAudioVerified"] = remoteHeard.value
        manifest["remoteBuffers"] = writer.counts[.system, default: 0]
        manifest["microphoneBuffers"] = writer.counts[.microphone, default: 0]
        manifest["discardedMicrophoneBuffers"] = microphoneFilter.diagnostics.discardedCount
        if let data = try? JSONEncoder().encode(microphoneFilter.diagnostics),
           let diagnostics = try? JSONSerialization.jsonObject(with: data) {
            manifest["microphoneDiagnostics"] = diagnostics
        }
        manifest["droppedAudioBuffers"] = writer.dropped
        manifest["writerRetries"] = writes.retries
        manifest["peakQueuedAudioBuffers"] = writes.peakBuffers
        manifest["peakQueuedAudioBytes"] = writes.peakBytes
        manifest["warnings"] = messages
        do { try saveManifest() } catch { messages.append("Could not update the recording manifest.") }
        return messages.isEmpty ? "Audio saved. Transcription and action items are not implemented yet." : messages.joined(separator: "\n")
    }

    private func saveManifest() throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let url = folder.appendingPathComponent("manifest.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
