// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The diagnostic reader deliberately has no knowledge of Teams selectors.
/// Absence in an incomplete snapshot is not evidence that a call has ended.
struct TeamsAXSnapshot: Codable {
    struct Node: Codable {
        let path: String
        let depth: Int
        let attributes: [String: String]
        let errors: [String: Int]
        var omissions: [String]
    }

    var nodes: [Node] = []
    var incompleteReasons: [String] = []
    var elapsedSeconds: TimeInterval = 0

    struct Limits {
        var maxDepth = 25
        var maxNodes = 1_500
        var maxChildren = 256
        var maxTextLength = 2_048
        var duration: TimeInterval = 5
        var messagingTimeout: TimeInterval = 0.5
    }
}

struct TeamsAXAttributes {
    var values: [String: String] = [:]
    var errors: [String: Int] = [:]
    var textTruncated = false
}

struct TeamsAXChildren<Element> {
    var elements: [Element] = []
    var error: Int?
    var truncated = false
}

protocol TeamsAXReading {
    associatedtype Element
    func sameElement(_ lhs: Element, _ rhs: Element) -> Bool
    func attributes(of element: Element, deadline: TimeInterval,
                    timeout: TimeInterval) -> TeamsAXAttributes
    func children(of element: Element, limit: Int, deadline: TimeInterval,
                  timeout: TimeInterval) -> TeamsAXChildren<Element>
}

enum TeamsAXTraversal {
    /// Breadth-first so a deep caption/history branch cannot starve the toolbar.
    /// The reader must also bound each IPC request by the shared deadline.
    static func collect<R: TeamsAXReading>(root: R.Element, reader: R,
                                          limits: TeamsAXSnapshot.Limits = .init(),
                                          now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime })
        -> TeamsAXSnapshot {
        let started = now()
        let deadline = started + max(0, limits.duration)
        var snapshot = TeamsAXSnapshot()
        var pending: [(R.Element, String, Int)] = [(root, "window", 0)]
        var discovered = [root]
        var cursor = 0
        let skippedRoles: Set<String> = ["AXImage", "AXScrollBar", "AXMenu"]

        while cursor < pending.count {
            guard now() < deadline else {
                snapshot.incompleteReasons.append("deadline")
                break
            }
            guard snapshot.nodes.count < limits.maxNodes else {
                snapshot.incompleteReasons.append("nodeLimit")
                break
            }
            let (element, path, depth) = pending[cursor]
            cursor += 1
            let attributes = reader.attributes(of: element, deadline: deadline,
                                               timeout: limits.messagingTimeout)
            var node = TeamsAXSnapshot.Node(path: path, depth: depth,
                attributes: attributes.values.mapValues { String($0.prefix(max(0, limits.maxTextLength))) },
                errors: attributes.errors, omissions: [])
            if attributes.textTruncated || attributes.values.values.contains(where: { $0.count > limits.maxTextLength }) {
                node.omissions.append("textLimit")
            }
            if !attributes.errors.isEmpty { snapshot.incompleteReasons.append("attributeErrors") }
            if attributes.values["AXSubrole"] == "AXSecureTextField" {
                node.omissions.append("secureSubtree")
            } else if skippedRoles.contains(attributes.values["AXRole"] ?? "") {
                node.omissions.append("irrelevantSubtree")
            } else if depth >= limits.maxDepth {
                node.omissions.append("depthLimit")
                snapshot.incompleteReasons.append("depthLimit")
            } else if now() < deadline {
                let remaining = max(0, limits.maxNodes - discovered.count)
                let children = reader.children(of: element, limit: min(limits.maxChildren, remaining),
                                               deadline: deadline, timeout: limits.messagingTimeout)
                if let error = children.error {
                    node.omissions.append("childrenError:\(error)")
                    snapshot.incompleteReasons.append("childrenError")
                }
                if children.truncated {
                    node.omissions.append("childrenLimit")
                    snapshot.incompleteReasons.append("childrenLimit")
                }
                for (index, child) in children.elements.enumerated() {
                    guard !discovered.contains(where: { reader.sameElement($0, child) }) else {
                        node.omissions.append("repeatedElement:\(index)")
                        continue
                    }
                    guard discovered.count < limits.maxNodes else {
                        snapshot.incompleteReasons.append("nodeLimit")
                        break
                    }
                    discovered.append(child)
                    pending.append((child, "\(path)/\(index)", depth + 1))
                }
            } else {
                snapshot.incompleteReasons.append("deadline")
            }
            snapshot.nodes.append(node)
        }
        snapshot.incompleteReasons = Array(Set(snapshot.incompleteReasons)).sorted()
        snapshot.elapsedSeconds = max(0, now() - started)
        return snapshot
    }
}
