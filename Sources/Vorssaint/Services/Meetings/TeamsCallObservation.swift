// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Evidence from one AX snapshot, not an audio gate or a meeting lifecycle.
/// Selectors were observed in English Teams 26261.303.5165.1465 on macOS.
/// Names are display labels supplied by Teams, not verified voice identities.
struct TeamsCallObservation: Codable {
    enum CallEvidence: String, Codable { case present, unknown }
    enum MicrophoneState: String, Codable { case muted, unmuted, unknown }

    struct Participant: Codable {
        let displayName: String
        let microphone: MicrophoneState
        let sourcePath: String
    }

    struct CaptionLine: Codable {
        let speakerDisplayName: String
        let text: String
        /// Snapshot-local only. Never use this path as a durable turn identity.
        let sourcePath: String
    }

    var callEvidence: CallEvidence = .unknown
    var microphone: MicrophoneState = .unknown
    var microphoneControlPath: String?
    var leaveControlPath: String?
    var captionPanelObserved = false
    var captionLines: [CaptionLine] = []
    var participantPanelObserved = false
    var participants: [Participant] = []
    // A visible roster may be virtualized, filtered or only partially traversed.
    var rosterCompleteness = "unknown"
    var limitations: [String] = []

    static func read(_ snapshot: TeamsAXSnapshot) -> TeamsCallObservation {
        let tree = Tree(nodes: snapshot.nodes)
        var result = TeamsCallObservation()
        result.limitations = snapshot.incompleteReasons.map { "snapshot:\($0)" }
        result.limitations.append("Caption observation order is not speech timing or a finalized transcript.")
        guard let web = tree.unique(where: { $0.attributes["AXRole"] == "AXWebArea" }) else {
            result.limitations.append("Missing or ambiguous web area.")
            return result
        }
        guard let toolbar = tree.unique(identifier: "horizontalMiddleEnd", role: "AXToolbar", below: web.path),
              let controls = tree.unique(identifier: "horizontalEnd", role: "AXGroup", below: web.path),
              let mic = tree.unique(identifier: "microphone-button", role: "AXButton", below: toolbar.path),
              let leave = tree.unique(identifier: "hangup-button", role: "AXButton", below: controls.path),
              mic.attributes["AXEnabled"] == "true", leave.attributes["AXEnabled"] == "true" else {
            result.limitations.append("Missing, disabled or ambiguous call controls; call end is not inferred.")
            return result
        }
        result.callEvidence = .present
        result.microphoneControlPath = mic.path
        result.leaveControlPath = leave.path
        result.microphone = state(from: mic, action: true)
        if result.microphone == .unknown {
            result.limitations.append("Unrecognized or conflicting microphone action labels.")
        }

        // Anchor captions to the observed dismiss/overflow controls, never to
        // arbitrary speaker-looking text elsewhere in the Teams window.
        if let dismiss = tree.unique(identifier: "captions-panel-dismiss-button", role: "AXButton", below: web.path),
           let overflow = tree.unique(identifier: "closed-captions-overflow-menu-button", role: "AXPopUpButton", below: web.path),
           Tree.parent(dismiss.path) == Tree.parent(overflow.path),
           let controlsPath = Tree.parent(dismiss.path), let panelPath = Tree.parent(controlsPath),
           let panel = tree.at(panelPath), Tree.usable(panel) {
            result.captionPanelObserved = true
            for row in tree.nodes where Tree.isBelow(row.path, panelPath)
                && !Tree.isBelow(row.path, controlsPath) && row.path != controlsPath
                && row.attributes["AXRole"] == "AXGroup" && Tree.usable(row) {
                let children = tree.children(of: row.path)
                guard children.count == 2,
                      children.allSatisfy({ $0.attributes["AXRole"] == "AXStaticText" && Tree.usable($0) }),
                      let speaker = text(children[0]), let utterance = text(children[1]) else { continue }
                result.captionLines.append(.init(speakerDisplayName: speaker, text: utterance, sourcePath: row.path))
            }
        }

        if let search = tree.unique(identifier: "roster-participants-search-input", role: "AXTextField", below: web.path),
           let wrapper = Tree.parent(search.path), let panel = Tree.parent(wrapper),
           tree.unique(where: { $0.attributes["AXRole"] == "AXOutline" && Tree.isBelow($0.path, panel) }) != nil {
            result.participantPanelObserved = true
            for item in tree.nodes where Tree.isBelow(item.path, panel)
                && item.attributes["AXRole"] == "AXGroup" && Tree.usable(item) {
                guard let identifier = item.attributes["AXDOMIdentifier"],
                      identifier.hasPrefix("calling-roster-item-") else { continue }
                let suffix = String(identifier.dropFirst("calling-roster-item-".count))
                guard !suffix.isEmpty,
                      let avatar = tree.unique(identifier: "roster-avatar-img-" + suffix,
                                               role: "AXGroup", below: item.path) else { continue }
                let labels = tree.children(of: avatar.path)
                    .filter { $0.attributes["AXRole"] == "AXStaticText" && Tree.usable($0) }
                guard labels.count == 1, let name = text(labels[0]) else { continue }
                let indicator = tree.unique(identifier: "roster-mic-button-" + suffix, role: "AXImage", below: item.path)
                result.participants.append(.init(displayName: name,
                    microphone: indicator.map { state(from: $0, action: false) } ?? .unknown,
                    sourcePath: item.path))
            }
        }
        return result
    }

    private static func text(_ node: TeamsAXSnapshot.Node) -> String? {
        guard let value = node.attributes["AXValue"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func state(from node: TeamsAXSnapshot.Node, action: Bool) -> MicrophoneState {
        let labels = ["AXTitle", "AXDescription"].compactMap { node.attributes[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !labels.isEmpty else { return .unknown }
        let muted = action ? "unmute mic" : "muted"
        let unmuted = action ? "mute mic" : "unmuted"
        if labels.allSatisfy({ $0 == muted }) { return .muted }
        if labels.allSatisfy({ $0 == unmuted }) { return .unmuted }
        return .unknown
    }

    private struct Tree {
        let nodes: [TeamsAXSnapshot.Node]

        init(nodes: [TeamsAXSnapshot.Node]) {
            self.nodes = nodes.sorted { $0.path.compare($1.path, options: .numeric) == .orderedAscending }
        }

        static func usable(_ node: TeamsAXSnapshot.Node) -> Bool {
            node.errors.isEmpty && node.omissions.allSatisfy { $0 == "irrelevantSubtree" }
        }

        static func isBelow(_ path: String, _ ancestor: String) -> Bool { path.hasPrefix(ancestor + "/") }
        static func parent(_ path: String) -> String? {
            guard let slash = path.lastIndex(of: "/") else { return nil }
            return String(path[..<slash])
        }

        func at(_ path: String) -> TeamsAXSnapshot.Node? { unique { $0.path == path } }
        func children(of path: String) -> [TeamsAXSnapshot.Node] { nodes.filter { Self.parent($0.path) == path } }

        func unique(identifier: String, role: String, below path: String) -> TeamsAXSnapshot.Node? {
            unique { $0.attributes["AXDOMIdentifier"] == identifier && $0.attributes["AXRole"] == role
                && Self.isBelow($0.path, path) }
        }

        func unique(where predicate: (TeamsAXSnapshot.Node) -> Bool) -> TeamsAXSnapshot.Node? {
            let matches = nodes.filter(predicate)
            guard matches.count == 1, let match = matches.first, Self.usable(match) else { return nil }
            return match
        }
    }
}
