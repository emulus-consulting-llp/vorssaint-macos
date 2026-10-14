// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum UsageFocusSupport {
    /// Office can expose a main document window without answering AXFocusedWindow.
    /// Never choose an arbitrary document from an app with several open windows.
    static func window<Window>(focused: () -> Window?, main: () -> Window?, windows: () -> [Window],
                               isFocused: (Window) -> Bool, isMain: (Window) -> Bool,
                               isMinimized: (Window) -> Bool) -> Window? {
        if let focused = focused() { return focused }
        if let main = main(), !isMinimized(main) { return main }
        let candidates = windows().filter { !isMinimized($0) }
        if let focused = candidates.first(where: isFocused) { return focused }
        if let main = candidates.first(where: isMain) { return main }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// AXDocument is usually a string; AXURL commonly bridges as URL/NSURL.
    /// Only explicit local document locations are accepted, never web URLs.
    static func documentPath(document: () -> Any?, url: () -> Any?) -> String? {
        UsageForeground.documentPath(from: document()) ?? UsageForeground.documentPath(from: url())
    }
}
