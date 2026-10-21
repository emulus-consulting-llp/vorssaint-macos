// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TeamsCallObservationTests {
    private static func node(_ path: String, _ role: String, _ id: String = "",
                             label: String = "", value: String = "") -> TeamsAXSnapshot.Node {
        .init(path: path, depth: path.split(separator: "/").count - 1,
              attributes: ["AXRole": role, "AXDOMIdentifier": id, "AXTitle": label,
                           "AXDescription": label, "AXValue": value, "AXEnabled": "true", "AXSelected": "false"],
              errors: [:], omissions: [])
    }

    private static func fixture(mic: String = "Unmute mic") -> TeamsAXSnapshot {
        // Synthetic text and identities; only roles/identifier prefixes come
        // from the live observations. No meeting content is committed.
        .init(nodes: [
            node("window", "AXWindow"),
            node("window/0", "AXWebArea"),
            node("window/0/0", "AXToolbar", "horizontalMiddleEnd"),
            node("window/0/0/0", "AXButton", "microphone-button", label: mic),
            node("window/0/1", "AXGroup", "horizontalEnd"),
            node("window/0/1/0", "AXButton", "hangup-button", label: "Leave"),
            node("window/0/3", "AXGroup"),
            node("window/0/3/0", "AXGroup"),
            node("window/0/3/0/9", "AXGroup"),
            node("window/0/3/0/9/0", "AXStaticText", value: "Test Speaker"),
            node("window/0/3/0/9/1", "AXStaticText", value: "I will write the test report."),
            node("window/0/3/0/11", "AXGroup"),
            node("window/0/3/0/11/0", "AXStaticText", value: "Another Speaker"),
            node("window/0/3/0/11/1", "AXStaticText", value: "Leave and Unmute mic are button labels."),
            node("window/0/3/1", "AXGroup"),
            node("window/0/3/1/0", "AXPopUpButton", "closed-captions-overflow-menu-button"),
            node("window/0/3/1/1", "AXButton", "captions-panel-dismiss-button", label: "Hide live captions"),
            node("window/0/4", "AXGroup"),
            node("window/0/4/0", "AXGroup"),
            node("window/0/4/0/0", "AXTextField", "roster-participants-search-input"),
            node("window/0/4/1", "AXOutline"),
            node("window/0/4/1/0", "AXRow"),
            node("window/0/4/1/0/0", "AXGroup", "calling-roster-item-fixture-a", label: "Speaker, A, Organiser, Muted"),
            node("window/0/4/1/0/0/0", "AXGroup", "roster-avatar-img-fixture-a"),
            node("window/0/4/1/0/0/0/0", "AXStaticText", value: "Speaker, A"),
            node("window/0/4/1/0/0/1", "AXImage", "roster-mic-button-fixture-a", label: "Muted")
        ])
    }

    static func run(_ suite: TestSuite) {
        let muted = TeamsCallObservation.read(fixture())
        suite.expect(muted.callEvidence == .present && muted.microphone == .muted,
                     "Unmute mic action establishes muted state, not unmuted")
        let unmuted = TeamsCallObservation.read(fixture(mic: "Mute mic"))
        suite.expect(unmuted.microphone == .unmuted,
                     "Mute mic action establishes unmuted state even when AXSelected is false")
        let translated = TeamsCallObservation.read(fixture(mic: "Microphone désactivé"))
        suite.expect(translated.callEvidence == .present && translated.microphone == .unknown,
                     "unknown language retains call evidence without guessing a microphone state")
        var conflicting = fixture()
        var attributes = conflicting.nodes[3].attributes
        attributes["AXDescription"] = "Mute mic"
        conflicting.nodes[3] = .init(path: "window/0/0/0", depth: 3, attributes: attributes, errors: [:], omissions: [])
        suite.expect(TeamsCallObservation.read(conflicting).microphone == .unknown,
                     "disagreeing title and description never authorize mic capture")
        var missing = fixture()
        missing.nodes.removeAll { $0.attributes["AXDOMIdentifier"] == "hangup-button" }
        suite.expect(TeamsCallObservation.read(missing).callEvidence == .unknown,
                     "missing Leave control is unknown, never an inferred call end")
        var duplicate = fixture()
        duplicate.nodes.append(node("window/0/0/1", "AXButton", "microphone-button", label: "Mute mic"))
        suite.expect(TeamsCallObservation.read(duplicate).microphone == .unknown,
                     "duplicate microphone controls cannot be resolved by arbitrary first match")
        var failed = fixture()
        let old = failed.nodes[3]
        failed.nodes[3] = .init(path: old.path, depth: old.depth, attributes: old.attributes,
                                errors: ["AXTitle": -25204], omissions: [])
        suite.expect(TeamsCallObservation.read(failed).microphone == .unknown,
                     "an errored control is not trusted even when some labels were returned")
        var disabled = fixture()
        attributes = disabled.nodes[3].attributes
        attributes["AXEnabled"] = "false"
        disabled.nodes[3] = .init(path: old.path, depth: old.depth, attributes: attributes, errors: [:], omissions: [])
        suite.expect(TeamsCallObservation.read(disabled).microphone == .unknown, "disabled controls are not live evidence")

        suite.expect(muted.captionPanelObserved && muted.captionLines.count == 2,
                     "caption speaker and utterance pairs are extracted within the anchored panel")
        suite.expect(muted.captionLines.map(\.speakerDisplayName) == ["Test Speaker", "Another Speaker"],
                     "caption row order follows numeric sibling order, not lexical order")
        suite.expect(muted.participantPanelObserved && muted.participants.count == 1
                        && muted.participants[0].displayName == "Speaker, A"
                        && muted.participants[0].microphone == .muted,
                     "participant name comes from avatar text, preserving commas and avoiding role/status suffixes")
        suite.expect(muted.rosterCompleteness == "unknown", "a visible roster is never assumed complete")
        checkNonOverflowCaptions(suite)
        var unrelated = fixture()
        unrelated.nodes += [node("window/0/9", "AXGroup"),
                            node("window/0/9/0", "AXStaticText", value: "Not a speaker"),
                            node("window/0/9/1", "AXStaticText", value: "Not a caption")]
        suite.expect(TeamsCallObservation.read(unrelated).captionLines.count == 2,
                     "arbitrary adjacent text outside the caption panel cannot become transcript content")
        var noPanel = fixture()
        noPanel.nodes.removeAll { $0.attributes["AXDOMIdentifier"] == "captions-panel-dismiss-button" }
        suite.expect(TeamsCallObservation.read(noPanel).captionLines.isEmpty,
                     "without the caption anchor text is not guessed to be captions")
        var truncated = fixture()
        let lineIndex = truncated.nodes.firstIndex { $0.path == "window/0/3/0/9/1" }!
        truncated.nodes[lineIndex].omissions = ["textLimit"]
        truncated.incompleteReasons = ["depthLimit"]
        let partial = TeamsCallObservation.read(truncated)
        suite.expect(partial.captionLines.count == 1 && partial.microphone == .muted
                        && partial.limitations.contains("snapshot:depthLimit"),
                     "truncated captions are excluded while intact control evidence remains usable")
        let outerShell = TeamsAXSnapshot(nodes: [node("window", "AXWindow"), node("window/0", "AXGroup")])
        suite.expect(TeamsCallObservation.read(outerShell).callEvidence == .unknown,
                     "an unpopulated accessibility tree cannot establish an idle call")

        let offline = try? TeamsAXDiagnostic.Options(arguments: ["app", "--teams-ax-analyze", "/tmp/input.json", "/tmp/output.json"])
        suite.expect(offline?.input?.path == "/tmp/input.json" && offline?.windowIndex == nil,
                     "offline analysis has no live AX selection or permission prompt")
        suite.expect((try? TeamsAXDiagnostic.Options(arguments: ["app", "--teams-ax-analyze", "/tmp/input.json", "relative.json"])) == nil,
                     "offline analysis also requires an explicit absolute output path")
    }

    private static func checkNonOverflowCaptions(_ suite: TestSuite) {
        var wide = fixture()
        wide.nodes.removeAll { $0.attributes["AXDOMIdentifier"] == "closed-captions-overflow-menu-button" }
        wide.nodes += [
            node("window/0/3/1/0", "AXGroup"),
            node("window/0/3/1/0/0", "AXPopUpButton", "captions-settings-menu-trigger-button-non-overflow"),
            node("window/0/3/1/2", "AXGroup"),
            node("window/0/3/1/2/0", "AXButton", "closed-captions-pop-out-button")
        ]
        let observed = TeamsCallObservation.read(wide)
        suite.expect(observed.captionPanelObserved && observed.captionLines.count == 2,
                     "non-overflow caption settings and pop-out wrappers identify the observed wide layout")
        suite.expect(observed.captionLines.map(\.speakerDisplayName) == ["Test Speaker", "Another Speaker"],
                     "wide layout preserves observed speaker/text pairs")
        var ambiguous = wide
        ambiguous.nodes.append(node("window/0/3/1/4", "AXPopUpButton", "closed-captions-overflow-menu-button"))
        suite.expect(!TeamsCallObservation.read(ambiguous).captionPanelObserved,
                     "simultaneous old and new settings anchors remain ambiguous")
        var duplicate = wide
        duplicate.nodes.append(node("window/0/3/1/2/1", "AXPopUpButton", "captions-settings-menu-trigger-button-non-overflow"))
        suite.expect(TeamsCallObservation.read(duplicate).captionLines.isEmpty,
                     "duplicate wide settings anchors cannot authorize caption extraction")
        var noPopout = wide
        noPopout.nodes.removeAll { $0.attributes["AXDOMIdentifier"] == "closed-captions-pop-out-button" }
        suite.expect(!TeamsCallObservation.read(noPopout).captionPanelObserved,
                     "incomplete wide control evidence does not guess a caption panel")
        var unrelated = wide
        unrelated.nodes.removeAll { $0.attributes["AXDOMIdentifier"] == "captions-settings-menu-trigger-button-non-overflow" }
        unrelated.nodes.append(node("window/0/3/0/0", "AXPopUpButton", "captions-settings-menu-trigger-button-non-overflow"))
        suite.expect(!TeamsCallObservation.read(unrelated).captionPanelObserved,
                     "a settings control in the content branch cannot anchor the dismiss toolbar")
        var errored = wide
        let index = errored.nodes.firstIndex { $0.attributes["AXDOMIdentifier"] == "captions-settings-menu-trigger-button-non-overflow" }!
        errored.nodes[index] = .init(path: errored.nodes[index].path, depth: errored.nodes[index].depth,
            attributes: errored.nodes[index].attributes, errors: ["AXTitle": -25204], omissions: [])
        suite.expect(TeamsCallObservation.read(errored).captionLines.isEmpty,
                     "errored wide settings evidence remains unknown")
    }
}
