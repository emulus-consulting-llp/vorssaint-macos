// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TeamsTranscriptionCommand {
    static let flag = "--teams-transcribe"
    static let captionsFlag = "--teams-export-captions"

    static func runAndExit() -> Never {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == captionsFlag, arguments[2].hasPrefix("/") {
            do {
                let count = try TeamsCaptions.export(folder: URL(fileURLWithPath: arguments[2]))
                print("Saved captions.md and captions.json locally (\(count) caption rows).")
                exit(0)
            } catch {
                fputs("Caption export failed. The original journal was preserved.\n", stderr)
                exit(1)
            }
        }
        guard arguments.count >= 3, arguments[1] == flag, arguments[2].hasPrefix("/") else { usage() }
        var configuration = TeamsTranscriptionService.Configuration.installed
        var executable: URL?, model: URL?
        var language = "auto", cpu = false, index = 3
        var seen = Set<String>()
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { usage() }
            if option == "--cpu" { cpu = true; index += 1; continue }
            index += 1
            guard index < arguments.count else { usage() }
            let value = arguments[index]
            switch option {
            case "--whisper-cli": guard value.hasPrefix("/") else { usage() }; executable = URL(fileURLWithPath: value)
            case "--model": guard value.hasPrefix("/") else { usage() }; model = URL(fileURLWithPath: value)
            case "--language": language = value
            default: usage()
            }
            index += 1
        }
        if let executable, let model { configuration = .init(executable: executable, model: model) }
        if let executable { configuration?.executable = executable }
        if let model { configuration?.model = model }
        guard var resolved = configuration else {
            fputs("Local transcription dependencies are missing. Run /bin/zsh Tools/setup-teams-transcription.sh\n", stderr)
            exit(1)
        }
        resolved.language = language
        resolved.cpuOnly = cpu
        let cancellation = BoundedProcessCancellation()
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            sources.append(source)
        }
        let config = resolved
        Task.detached {
            do {
                let result = try await TeamsTranscriptionService.transcribe(folder: URL(fileURLWithPath: arguments[2]),
                    configuration: config, cancellation: cancellation, progress: { print($0) })
                print("Saved transcript.md locally (\(result.turns) turns; \(result.namedRemoteTurns) caption-matched remote turns).")
                exit(0)
            } catch {
                // Never print raw engine output or meeting text to the console.
                fputs((error as? TeamsTranscriptionService.Failure)?.localizedDescription ?? "Local transcription could not finish; saved audio was preserved.", stderr)
                fputs("\n", stderr)
                exit(1)
            }
        }
        withExtendedLifetime(sources) { RunLoop.main.run() }
        exit(1)
    }

    private static func usage() -> Never {
        fputs("Usage: VorssaintDeveloper --teams-transcribe /absolute/recording-folder [--cpu] [--language auto] [--whisper-cli /absolute/whisper-cli --model /absolute/model.bin]\n", stderr)
        exit(2)
    }
}
