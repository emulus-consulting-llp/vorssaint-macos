// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct UsageTimelineSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = UsageTimelineService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.usageTimelineEnabled) private var enabled = false
    @AppStorage(DefaultsKey.usageTimelineIdleMinutes) private var idleMinutes = 5
    @AppStorage(DefaultsKey.usageTimelineTitles) private var titles = true
    @AppStorage(DefaultsKey.usageTimelinePaths) private var paths = true
    @AppStorage(DefaultsKey.panelUtilityUsageTimeline) private var showInPanel = true
    @State private var excluded: [String] = []
    private var strings: UsageTimelineStrings { UsageTimelineStrings(l10n.language) }

    var body: some View {
        Form {
            Section(strings[.title]) {
                Text(strings[.description]).foregroundStyle(.secondary)
                Toggle(strings[.enable], isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        if value { service.startTracking() } else { service.syncWithPreferences() }
                    }
                HStack {
                    Button(strings[.open]) { UsageTimelineWindowController.shared.show() }
                    if service.enabled {
                        Button(strings[service.paused ? .resume : .pause]) { service.setPaused(!service.paused) }
                    }
                }
                Text(strings[.localHint]).font(.caption).foregroundStyle(.secondary)
                if service.hasError {
                    Text(strings[.storageError]).foregroundStyle(.red)
                    Button(strings[.retry]) { service.retry() }
                }
            }
            Section(strings[.settings]) {
                Picker(strings[.idleThreshold], selection: $idleMinutes) {
                    Text(strings[.off]).tag(0)
                    ForEach([1, 3, 5, 10], id: \.self) { minutes in
                        Text(String(format: strings[.minutes], minutes)).tag(minutes)
                    }
                }
                Toggle(strings[.titles], isOn: $titles)
                Toggle(strings[.paths], isOn: $paths)
                Toggle(l10n.s.monitorShowInPanel, isOn: $showInPanel)
            }
            Section(strings[.accessibility]) {
                Text(strings[.permissionHelp]).font(.caption).foregroundStyle(.secondary)
                if !permissions.accessibility {
                    Button(strings[.accessibility]) { permissions.requestAccessibility() }
                }
            }
            Section(strings[.exclusions]) {
                ForEach(excluded, id: \.self) { bundle in
                    HStack {
                        Text(bundle).textSelection(.enabled)
                        Spacer()
                        Button(strings[.remove]) {
                            excluded.removeAll { $0 == bundle }
                            saveExclusions()
                        }
                    }
                }
                Button(strings[.exclude]) { chooseExcludedApp() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            excluded = UserDefaults.standard.stringArray(forKey: DefaultsKey.usageTimelineExcludedApps) ?? []
            service.syncWithPreferences()
        }
    }

    private func saveExclusions() {
        UserDefaults.standard.set(excluded.sorted(), forKey: DefaultsKey.usageTimelineExcludedApps)
        service.syncWithPreferences()
    }

    private func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundle = Bundle(url: url)?.bundleIdentifier, !excluded.contains(bundle) { excluded.append(bundle) }
        }
        saveExclusions()
    }
}
