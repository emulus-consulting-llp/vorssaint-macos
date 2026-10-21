// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

struct TeamsTranscriptTurn: Codable {
    let start: Double
    let end: Double
    let source: RecorderAudioSource
    var speaker: String
    var attribution: String
    let text: String

    private struct WhisperOutput: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { let from: Double; let to: Double }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Segment]
    }

    static func decodeWhisper(_ data: Data, source: RecorderAudioSource,
                              offset: Double, duration: Double,
                              audibleRanges: [ClosedRange<Double>]) throws -> [TeamsTranscriptTurn] {
        // Older -ojf output can contain incomplete UTF-8 bytes in token
        // diagnostics (multilingual tokens may split a scalar). They are not
        // speech text. Decode those unused fields tolerantly, but never publish
        // repaired/corrupt sentence text as a successful transcript.
        let normalized = Data(String(decoding: data, as: UTF8.self).utf8)
        let output = try JSONDecoder().decode(WhisperOutput.self, from: normalized)
        guard !output.transcription.contains(where: { $0.text.contains("\u{FFFD}") }) else {
            throw TeamsTranscriptionService.Failure.output
        }
        return output.transcription.compactMap { segment in
            let start = segment.offsets.from / 1_000
            let end = min(duration, segment.offsets.to / 1_000)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard start.isFinite, end.isFinite, start >= 0, end > start,
                  !text.isEmpty, !["[BLANK_AUDIO]", "[ Silence ]"].contains(text),
                  audibleRanges.contains(where: { min($0.upperBound, end) - max($0.lowerBound, start) > 0 }) else { return nil }
            return .init(start: start + offset, end: end + offset, source: source,
                speaker: source == .microphone ? "You" : "Remote",
                attribution: source == .microphone ? "localMicrophoneSource" : "unknownRemote",
                text: text)
        }
    }

    static func markdown(_ turns: [TeamsTranscriptTurn], model: String, warnings: [String]) -> String {
        var result = "# Meeting transcript\n\nLocal ASR: whisper.cpp (\(escape(model))). Review recognition errors.\n\n"
        result += "You identifies the local microphone source. Remote names marked † are matched to locally observed Teams caption text; they are not verified voice identities. Unmatched remote speech stays Remote. Caption display time is not used as speech time.\n\n"
        for warning in warnings { result += "- \(escape(warning))\n" }
        if !warnings.isEmpty { result += "\n" }
        if turns.isEmpty { result += "No speech was recognized in the saved audio.\n" }
        for turn in turns.sorted(by: { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }) {
            let seconds = Int(max(0, turn.start))
            let time = String(format: "%02d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
            let marker = turn.attribution == "captionTextMatch" ? "†" : ""
            result += "[\(time)] **\(escape(turn.speaker))\(marker):** \(escape(turn.text))\n\n"
        }
        return result
    }

    static func escape(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        for character in ["\\", "`", "*", "_", "[", "]", "!", "#", "|"] {
            text = text.replacingOccurrences(of: character, with: "\\" + character)
        }
        return text.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct TeamsCaptionEvidence {
    private struct Entry {
        let name: String
        let firstObserved: Double
        let tokens: [String]
    }
    private var entries: [Entry] = []

    init(journal: Data) throws {
        struct Event: Decodable { let scanEnded: Double; let observation: TeamsCallObservation? }
        var seen = Set<String>()
        for line in journal.split(separator: 0x0a) {
            let event = try JSONDecoder().decode(Event.self, from: Data(line))
            guard event.scanEnded.isFinite else { continue }
            for caption in event.observation?.captionLines ?? [] {
                let tokens = Self.tokens(caption.text)
                let key = caption.speakerDisplayName + "\n" + tokens.joined(separator: " ")
                guard tokens.count >= 4, seen.insert(key).inserted else { continue }
                entries.append(.init(name: caption.speakerDisplayName, firstObserved: event.scanEnded, tokens: tokens))
                if entries.count >= 20_000 { return }
            }
        }
    }

    func attribute(_ turn: TeamsTranscriptTurn) -> TeamsTranscriptTurn {
        guard turn.source == .system else { return turn }
        let words = Self.tokens(turn.text)
        guard words.count >= 4 else { return turn }
        var scores: [String: Double] = [:]
        for entry in entries where entry.firstObserved >= turn.start - 2 && entry.firstObserved <= turn.end + 15 {
            var available = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
            var common = 0
            for word in entry.tokens where available[word, default: 0] > 0 {
                common += 1
                available[word, default: 0] -= 1
            }
            let coverage = Double(common) / Double(words.count)
            guard coverage >= 0.85, Double(common) / Double(entry.tokens.count) >= 0.25,
                  Self.hasCommonPhrase(words, entry.tokens) else { continue }
            scores[entry.name] = max(scores[entry.name] ?? 0, coverage)
        }
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, ranked.count == 1 || best.value - ranked[1].value >= 0.15 else { return turn }
        var result = turn
        result.speaker = best.key
        result.attribution = "captionTextMatch"
        return result
    }

    private static func tokens(_ value: String) -> [String] {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func hasCommonPhrase(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count >= 3, rhs.count >= 3 else { return false }
        let phrases = Set((0...(rhs.count - 3)).map { rhs[$0...($0 + 2)].joined(separator: " ") })
        return (0...(lhs.count - 3)).contains { phrases.contains(lhs[$0...($0 + 2)].joined(separator: " ")) }
    }
}
