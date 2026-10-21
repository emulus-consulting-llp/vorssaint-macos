// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum TeamsAccessibilityTests {
    final class Element {
        var fields = TeamsAXAttributes(values: ["AXRole": "AXGroup"])
        var children: [Element] = []
        var childrenError: Int?
    }

    final class Reader: TeamsAXReading {
        var clock: TimeInterval = 0
        var readCost: TimeInterval = 0
        var attributesRead = 0
        var childrenRead = 0
        func sameElement(_ lhs: Element, _ rhs: Element) -> Bool { lhs === rhs }
        func attributes(of element: Element, deadline: TimeInterval, timeout: TimeInterval) -> TeamsAXAttributes {
            attributesRead += 1
            clock += min(readCost, max(0, deadline - clock))
            return element.fields
        }
        func children(of element: Element, limit: Int, deadline: TimeInterval,
                      timeout: TimeInterval) -> TeamsAXChildren<Element> {
            childrenRead += 1
            return .init(elements: Array(element.children.prefix(max(0, limit))),
                         error: element.childrenError, truncated: element.children.count > limit)
        }
    }

    static func run(_ suite: TestSuite) {
        let root = Element(), child = Element(), leaf = Element()
        root.fields.values["AXRole"] = "AXWindow"
        root.children = [child, leaf]
        child.children = [root, leaf]
        leaf.fields.values = ["AXRole": "AXStaticText", "AXValue": "Test caption"]
        let reader = Reader()
        let snapshot = TeamsAXTraversal.collect(root: root, reader: reader)
        suite.expect(snapshot.nodes.count == 3 && reader.attributesRead == 3,
                     "cycles and shared children are read only once")
        suite.expect(snapshot.nodes.last?.attributes["AXValue"] == "Test caption",
                     "static caption text survives diagnostic traversal")
        suite.expect(snapshot.nodes.map(\.path) == ["window", "window/0", "window/1"],
                     "breadth-first paths preserve sibling indices")
        suite.expect(snapshot.incompleteReasons.isEmpty, "a complete simulated tree reports no truncation")

        let image = Element(), secret = Element()
        image.fields.values["AXRole"] = "AXImage"
        secret.fields.values["AXSubrole"] = "AXSecureTextField"
        image.children = [leaf]
        secret.children = [leaf]
        let skipRoot = Element()
        skipRoot.children = [image, secret]
        let skipReader = Reader()
        let skipped = TeamsAXTraversal.collect(root: skipRoot, reader: skipReader)
        suite.expect(skipped.nodes.count == 3 && skipReader.childrenRead == 1,
                     "image and secure descendants are not traversed")

        var limits = TeamsAXSnapshot.Limits()
        limits.maxDepth = 0
        let shallow = TeamsAXTraversal.collect(root: root, reader: Reader(), limits: limits)
        suite.expect(shallow.nodes.count == 1 && shallow.incompleteReasons.contains("depthLimit"),
                     "depth-limited snapshots cannot masquerade as complete observations")
        limits = .init()
        limits.maxNodes = 2
        let bounded = TeamsAXTraversal.collect(root: root, reader: Reader(), limits: limits)
        suite.expect(bounded.nodes.count <= 2 && !bounded.incompleteReasons.isEmpty,
                     "node budget bounds discovered work as well as emitted nodes")
        limits = .init()
        limits.maxChildren = 1
        let narrow = TeamsAXTraversal.collect(root: root, reader: Reader(), limits: limits)
        suite.expect(narrow.nodes.count == 2 && narrow.incompleteReasons.contains("childrenLimit"),
                     "wide trees are truncated explicitly")
        limits = .init()
        limits.maxTextLength = 4
        let text = TeamsAXTraversal.collect(root: leaf, reader: Reader(), limits: limits)
        suite.expect(text.nodes.first?.attributes["AXValue"] == "Test"
                        && text.nodes.first?.omissions.contains("textLimit") == true,
                     "long text is bounded with an explicit omission")
        leaf.fields.textTruncated = true
        let alreadyTruncated = TeamsAXTraversal.collect(root: leaf, reader: Reader())
        suite.expect(alreadyTruncated.nodes.first?.omissions.contains("textLimit") == true,
                     "text truncated by the AX reader remains marked in the snapshot")
        leaf.fields.textTruncated = false

        limits = .init()
        limits.duration = 0.2
        let slow = Reader()
        slow.readCost = 0.2
        let timed = TeamsAXTraversal.collect(root: root, reader: slow, limits: limits, now: { slow.clock })
        suite.expect(slow.attributesRead == 1 && slow.childrenRead == 0
                        && timed.incompleteReasons.contains("deadline"),
                     "a slow attribute read prevents further IPC once the shared deadline is spent")
        child.childrenError = -25204
        child.fields.errors["AXRole"] = -25202
        let failed = TeamsAXTraversal.collect(root: child, reader: Reader())
        suite.expect(failed.incompleteReasons.contains("childrenError")
                        && failed.incompleteReasons.contains("attributeErrors"),
                     "AX failure is distinguishable from an empty window")

        let options = try? TeamsAXDiagnostic.Options(arguments: ["app", "--teams-ax-dump", "/tmp/report.json"])
        suite.expect(options != nil && options?.windowIndex == nil && options?.requestAccessibility == false,
                     "default inspection only lists windows and never prompts for permission")
        let selected = try? TeamsAXDiagnostic.Options(arguments: ["app", "--teams-ax-dump", "/tmp/report.json",
                                                                "--window-index", "2", "--enhanced-accessibility"])
        suite.expect(selected?.windowIndex == 2 && selected?.enhancedAccessibility == true,
                     "experimental activation requires an explicit flag")
        for arguments in [
            ["app", "--teams-ax-dump"],
            ["app", "--teams-ax-dump", "relative.json"],
            ["app", "--teams-ax-dump", "/tmp/report.json", "--window-index", "-1"],
            ["app", "--teams-ax-dump", "/tmp/report.json", "--window-index"],
            ["app", "--teams-ax-dump", "/tmp/report.json", "--typo"],
            ["app", "--teams-ax-dump", "/tmp/report.json", "--request-accessibility", "--request-accessibility"]
        ] {
            suite.expect((try? TeamsAXDiagnostic.Options(arguments: arguments)) == nil,
                         "invalid options are rejected before any AX work: \(arguments)")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("teams-ax-test-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("snapshot.json")
            let data = try JSONEncoder().encode(snapshot)
            try TeamsAXDiagnostic.writePrivateReport(data, to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            suite.expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                         "meeting diagnostics are owner-readable and owner-writable only")
            do {
                try TeamsAXDiagnostic.writePrivateReport(Data("replacement".utf8), to: url)
                suite.expect(false, "existing reports must never be overwritten")
            } catch {
                suite.expect(try Data(contentsOf: url) == data, "a refused overwrite preserves the original")
            }
            let decoded = try JSONDecoder().decode(TeamsAXSnapshot.self, from: data)
            suite.expect(decoded.nodes.count == 3, "reports round-trip as JSON")
        } catch { suite.expect(false, "diagnostic file fixture failed: \(error)") }
    }
}
