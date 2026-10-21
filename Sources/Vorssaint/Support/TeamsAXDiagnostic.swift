// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

enum TeamsAXDiagnostic {
    static let flag = "--teams-ax-dump"
    static let analyzeFlag = "--teams-ax-analyze"
    static let usage = """
    Usage: VorssaintDeveloper --teams-ax-dump /absolute/new-report.json
           [--window-index N] [--request-accessibility] [--enhanced-accessibility]
    Or: VorssaintDeveloper --teams-ax-analyze /absolute/existing-report.json /absolute/new-analysis.json
    Without --window-index, lists window metadata only. An index traverses that
    window, including any visible captions and names. Reports stay local; use a
    non-sensitive test call. Existing files are never overwritten.
    AXManualAccessibility is attempted; --enhanced-accessibility also attempts
    AXEnhancedUserInterface (may affect window managers). Readable prior flags
    are restored. No Teams controls are pressed and no media is recorded.
    """

    struct Options {
        let output: URL
        var input: URL?
        var windowIndex: Int?
        var requestAccessibility = false
        var enhancedAccessibility = false

        init(arguments: [String]) throws {
            if arguments.count == 4, arguments[1] == TeamsAXDiagnostic.analyzeFlag,
               arguments[2].hasPrefix("/"), arguments[3].hasPrefix("/"),
               !arguments[2].hasSuffix("/"), !arguments[3].hasSuffix("/") {
                input = URL(fileURLWithPath: arguments[2])
                output = URL(fileURLWithPath: arguments[3])
                return
            }
            guard arguments.count >= 3, arguments[1] == TeamsAXDiagnostic.flag,
                  arguments[2].hasPrefix("/"), !arguments[2].hasSuffix("/") else {
                throw DiagnosticError.invalidArguments
            }
            output = URL(fileURLWithPath: arguments[2])
            var index = 3
            var seen = Set<String>()
            while index < arguments.count {
                let argument = arguments[index]
                guard seen.insert(argument).inserted else { throw DiagnosticError.invalidArguments }
                switch argument {
                case "--window-index":
                    index += 1
                    guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                        throw DiagnosticError.invalidArguments
                    }
                    windowIndex = value
                case "--request-accessibility": requestAccessibility = true
                case "--enhanced-accessibility": enhancedAccessibility = true
                default: throw DiagnosticError.invalidArguments
                }
                index += 1
            }
        }
    }

    enum DiagnosticError: Error { case invalidArguments }

    static func runAndExit() -> Never {
        let options: Options
        do { options = try Options(arguments: CommandLine.arguments) }
        catch {
            fputs(usage + "\n", stderr)
            exit(2)
        }
        guard !FileManager.default.fileExists(atPath: options.output.path) else {
            fputs("The output file already exists. Choose a new path.\n", stderr)
            exit(2)
        }
        if let input = options.input {
            do {
                let data = try Data(contentsOf: input)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let report = try decoder.decode(TeamsAccessibilityMonitor.Report.self, from: data)
                guard let snapshot = report.snapshot else { throw DiagnosticError.invalidArguments }
                let observation = TeamsCallObservation.read(snapshot)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try writePrivateReport(encoder.encode(observation), to: options.output)
                print("Teams AX analysis: call=\(observation.callEvidence.rawValue), mic=\(observation.microphone.rawValue), captions=\(observation.captionLines.count), participants=\(observation.participants.count). Saved locally to \(options.output.path)")
                exit(0)
            } catch {
                fputs("Could not analyze the saved AX report: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if options.requestAccessibility {
            let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
        }
        let monitor = TeamsAccessibilityMonitor()
        monitor.inspect(windowIndex: options.windowIndex, enhancedAccessibility: options.enhancedAccessibility) { report in
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try writePrivateReport(encoder.encode(report), to: options.output)
                // Content is deliberately not sent to stdout or unified logging.
                print("Teams AX diagnostic: \(report.status). Saved local report to \(options.output.path)")
                if report.status == "accessibilityDenied" {
                    fputs("Grant Accessibility to the launching app in System Settings, then retry with a new path.\n", stderr)
                }
                exit(["captured", "windowsListed", "partial"].contains(report.status) ? 0 : 1)
            } catch {
                fputs("Could not write the diagnostic report: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        // Keep the main run loop responsive while the worker makes AX IPC calls.
        withExtendedLifetime(monitor) { RunLoop.main.run() }
        exit(1)
    }

    /// Exclusive creation prevents accidental replacement (including symlinks),
    /// and 0600 protects meeting text from other local users from the first byte.
    static func writePrivateReport(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
