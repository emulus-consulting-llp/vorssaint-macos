// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TeamsTranscriptionService {
    struct Configuration: Sendable {
        var executable: URL
        var model: URL
        var language = "auto"
        var cpuOnly = false

        static var installed: Configuration? {
            let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
            let model = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/com.vorssaint.utils/MeetingModels/ggml-small.bin")
            guard FileManager.default.isReadableFile(atPath: model.path) else { return nil }
            return .init(executable: URL(fileURLWithPath: executable), model: model)
        }
    }

    enum Failure: LocalizedError {
        case unavailable, invalidRecording, busy, existingTranscript, cancelled, engine, output
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Local whisper.cpp or its speech model is unavailable. Run Tools/setup-teams-transcription.sh first."
            case .invalidRecording: return "A finalized recording with identified PCM source tracks is required (maximum six hours)."
            case .busy: return "This recording is already being transcribed."
            case .existingTranscript: return "transcript.md already exists and was preserved. Move it aside before retrying."
            case .cancelled: return "Local transcription was cancelled. Saved audio is available for retry."
            case .engine: return "whisper.cpp failed or timed out. Saved audio is available for retry; try --cpu if GPU initialization failed."
            case .output: return "The local transcription output could not be read or saved. Saved audio was preserved."
            }
        }
    }

    struct Result: Sendable {
        let turns: Int
        let namedRemoteTurns: Int
        let folder: URL
    }

    /// A verified Metal allocation failure can be retried without changing the
    /// model or audio. Other failures and timeouts must remain explicit errors.
    static func canRetryOnCPU(_ result: BoundedProcessRunner.Result) -> Bool {
        guard result.status != 0, !result.timedOut else { return false }
        let diagnostic = String(decoding: result.output, as: UTF8.self).lowercased()
        return diagnostic.contains("ggml_metal_buffer_init: error: failed to allocate buffer")
            || diagnostic.contains("failed to allocate metal buffer")
    }

    /// Call off the main actor. Only this serial job owns the manifest after
    /// recording finalization; the advisory lock also protects offline retries.
    static func transcribe(folder: URL, configuration: Configuration,
                           cancellation: BoundedProcessCancellation,
                           progress: @Sendable (String) -> Void = { _ in }) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: configuration.executable.path),
              FileManager.default.isReadableFile(atPath: configuration.model.path),
              !configuration.language.isEmpty, configuration.language.count <= 16,
              configuration.language.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else {
            throw Failure.unavailable
        }
        let lock = open(folder.appendingPathComponent(".transcription.lock").path,
                        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.output }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { _ = flock(lock, LOCK_UN) }
        let transcript = folder.appendingPathComponent("transcript.md")
        guard !FileManager.default.fileExists(atPath: transcript.path) else { throw Failure.existingTranscript }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), data.count < 1_048_576,
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              ["complete", "completeWithWarnings"].contains(manifest["state"] as? String ?? "") else {
            throw Failure.invalidRecording
        }
        func save(_ state: String) throws {
            manifest["transcriptionState"] = state
            manifest["transcriptionEngine"] = "whisper.cpp"
            manifest["transcriptionModel"] = configuration.model.lastPathComponent
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            // A private temporary file is renamed only over our recording's manifest.
            let temporary = folder.appendingPathComponent(".manifest-\(UUID()).json")
            try TeamsAXDiagnostic.writePrivateReport(data, to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard rename(temporary.path, manifestURL.path) == 0 else { throw Failure.output }
        }
        try save("processing")
        do {
            if cancellation.isCancelled { throw Failure.cancelled }
            let job = folder.appendingPathComponent("transcription-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            progress("Preparing local speech audio…")
            let chunks = try await TeamsASRAudio.prepare(master: folder.appendingPathComponent("sources.mov"),
                directory: job, cancellation: cancellation)
            var warnings = manifest["warnings"] as? [String] ?? []
            var captions: TeamsCaptionEvidence?
            let journal = folder.appendingPathComponent("observations.jsonl")
            if let size = try? journal.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size <= 64 * 1_024 * 1_024,
               let journalData = try? Data(contentsOf: journal) {
                captions = try? TeamsCaptionEvidence(journal: journalData)
            }
            if captions == nil { warnings.append("Caption evidence was unavailable; remote voices are unnamed.") }
            if chunks.contains(where: { $0.offset > 0 }) {
                warnings.append("Audio was processed in ten-minute chunks; words crossing a chunk boundary may be incomplete.")
            }
            var turns: [TeamsTranscriptTurn] = []
            var cpuOnly = configuration.cpuOnly
            manifest["transcriptionBackend"] = cpuOnly ? "cpu" : "automatic"
            for (index, chunk) in chunks.enumerated() {
                if cancellation.isCancelled { throw Failure.cancelled }
                progress("Transcribing locally (\(index + 1)/\(chunks.count))…")
                let prefix = chunk.url.deletingPathExtension()
                var arguments = ["-m", configuration.model.path, "-f", chunk.url.path,
                    "-l", configuration.language, "-ojf", "-of", prefix.path, "-sns"]
                // Do not use -np: it also suppresses Metal's failure reason.
                // All output is bounded and captured privately by the runner.
                if cpuOnly { arguments.append("-ng") }
                func run() -> BoundedProcessRunner.Result {
                    BoundedProcessRunner.run(configuration.executable.path, arguments,
                    timeout: max(120, chunk.duration * 8), maxOutputBytes: 128 * 1_024,
                    environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()],
                    cancellation: cancellation)
                }
                var result = run()
                if !cancellation.isCancelled, !cpuOnly, canRetryOnCPU(result) {
                    try? TeamsAXDiagnostic.writePrivateReport(result.output,
                        to: prefix.appendingPathExtension("gpu-failure.log"))
                    cpuOnly = true
                    manifest["transcriptionBackend"] = "cpuFallback"
                    warnings.append("GPU buffer allocation failed; local transcription used the CPU fallback.")
                    progress("GPU allocation failed; retrying locally on CPU…")
                    arguments.append("-ng")
                    result = run()
                }
                if cancellation.isCancelled { throw Failure.cancelled }
                guard result.status == 0, !result.timedOut else {
                    // Bounded diagnostics may contain speech; retain only in
                    // the owner-only attempt folder, never console or logging.
                    try? TeamsAXDiagnostic.writePrivateReport(result.output,
                        to: prefix.appendingPathExtension("failure.log"))
                    throw Failure.engine
                }
                let output = prefix.appendingPathExtension("json")
                guard let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 128 * 1_024 * 1_024 else { throw Failure.output }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                let decoded = try TeamsTranscriptTurn.decodeWhisper(Data(contentsOf: output), source: chunk.source,
                    offset: chunk.offset, duration: chunk.duration, audibleRanges: chunk.audibleRanges)
                turns.append(contentsOf: decoded.map { captions?.attribute($0) ?? $0 })
                try FileManager.default.removeItem(at: chunk.url)
            }
            if cancellation.isCancelled { throw Failure.cancelled }
            turns.sort { $0.start < $1.start }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try TeamsAXDiagnostic.writePrivateReport(encoder.encode(turns), to: job.appendingPathComponent("turns.json"))
            let markdown = TeamsTranscriptTurn.markdown(turns, model: configuration.model.lastPathComponent, warnings: warnings)
            let draft = job.appendingPathComponent("transcript.md")
            try TeamsAXDiagnostic.writePrivateReport(Data(markdown.utf8), to: draft)
            // Publish only the complete file, exclusively, preserving any user transcript.
            guard link(draft.path, transcript.path) == 0 else { throw Failure.output }
            manifest["transcriptFile"] = "transcript.md"
            manifest["transcriptionTurns"] = turns.count
            try save("complete")
            return .init(turns: turns.count, namedRemoteTurns: turns.filter { $0.attribution == "captionTextMatch" }.count, folder: folder)
        } catch {
            try? save(cancellation.isCancelled ? "cancelled" : "failed")
            throw error
        }
    }
}
