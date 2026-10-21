// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Readable Teams captions independent of audio recognition. Retain the raw
/// journal for revisions and gaps; these timestamps mean "first seen on screen".
enum TeamsCaptions {
    struct Row: Codable, Equatable {
        let firstObserved: Double
        var lastObserved: Double
        let speaker: String
        var text: String
    }

    static func rows(journal: Data) throws -> [Row] {
        struct Event: Decodable { let scanEnded: Double; let observation: TeamsCallObservation? }
        var rows: [Row] = []
        var visible: [Int] = []
        for line in journal.split(separator: 10) {
            let event = try JSONDecoder().decode(Event.self, from: Data(line))
            guard event.scanEnded.isFinite, event.scanEnded >= 0,
                  let observation = event.observation else { continue }
            // Unknown AX snapshots do not prove that the captions disappeared.
            guard !observation.captionLines.isEmpty else { continue }
            var remaining = visible
            var current: [Int] = []
            // Reserve exact matches first so a growing row cannot consume an
            // earlier, identical phrase that is still visible on screen.
            let exact = observation.captionLines.map { caption -> Int? in
                guard let position = remaining.firstIndex(where: {
                    rows[$0].speaker == caption.speakerDisplayName && rows[$0].text == caption.text
                }) else { return nil }
                return remaining.remove(at: position)
            }
            for (position, caption) in observation.captionLines.enumerated() {
                guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var index = exact[position]
                if index == nil, let revision = remaining.firstIndex(where: {
                    let row = rows[$0]
                    return row.speaker == caption.speakerDisplayName
                        && event.scanEnded - row.lastObserved <= 15
                        && isRevision(row.text, caption.text)
                }) { index = remaining.remove(at: revision) }
                if let index {
                    rows[index].text = caption.text
                    rows[index].lastObserved = event.scanEnded
                    current.append(index)
                } else {
                    current.append(rows.count)
                    rows.append(.init(firstObserved: event.scanEnded, lastObserved: event.scanEnded,
                                      speaker: caption.speakerDisplayName, text: caption.text))
                }
            }
            visible = current
        }
        return rows
    }

    private static func isRevision(_ previous: String, _ current: String) -> Bool {
        let a = previous.lowercased().split(whereSeparator: { $0.isWhitespace })
        let b = current.lowercased().split(whereSeparator: { $0.isWhitespace })
        let common = zip(a, b).prefix(while: { $0 == $1 }).count
        return common >= 2 && Double(common) / Double(max(1, min(a.count, b.count))) >= 0.6
    }

    @discardableResult
    static func export(folder: URL) throws -> Int {
        let journal = folder.appendingPathComponent("observations.jsonl")
        guard let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1_024 * 1_024 else { throw TeamsTranscriptionService.Failure.output }
        let rows = try rows(journal: Data(contentsOf: journal))
        var markdown = "# Teams captions\n\nCaptured directly from Teams live captions, without local audio transcription. Times are when captions were first observed, not precise speech timestamps. Consecutive revisions are combined where identifiable; some revisions or gaps may remain. Speaker names are Teams display labels.\n\n"
        if rows.isEmpty { markdown += "No Teams captions were observed. Enable live captions in Teams during recording.\n" }
        for row in rows {
            let seconds = Int(row.firstObserved)
            let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            markdown += "[\(time)] **\(TeamsTranscriptTurn.escape(row.speaker)):** \(TeamsTranscriptTurn.escape(row.text))\n\n"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Existing user exports are preserved, including on ASR retries.
        for (name, data) in [("captions.md", Data(markdown.utf8)), ("captions.json", try encoder.encode(rows))] {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try TeamsAXDiagnostic.writePrivateReport(data, to: url)
            }
        }
        return rows.count
    }
}
