// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

struct TeamsRecorderSettings: View {
    @ObservedObject private var service = TeamsRecorderService.shared
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(TeamsRecorderService.enabledKey) private var enabled = false
    @AppStorage(TeamsRecorderService.folderKey) private var folderPath = ""

    var body: some View {
        Section {
            Toggle("Detect Teams meetings", isOn: $enabled)
                .disabled(service.isBusy)
                .onChange(of: enabled) { _, value in
                    if value { service.requestAccessibility() }
                    service.syncWithPreferences()
                }
            Text("Vorssaint asks before recording each call. Audio and transcripts stay on this Mac. Turn on live captions in Teams to save its captions, even without local speech transcription.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if service.isTranscribing { ProgressView().controlSize(.small) }
                Text(service.stateText).textSelection(.enabled)
                Spacer()
                if service.canStop {
                    Button("Stop and Save") { service.stopRecording() }
                }
                if service.isTranscribing {
                    Button("Cancel Transcription") { service.cancelTranscription() }
                }
            }
            if enabled, !permissions.accessibility { PermissionRow(kind: .accessibility) }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Save meetings to")
                    Text(service.parent.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Choose Folder…") { chooseOutputFolder() }.disabled(service.isBusy)
            }
            if TeamsTranscriptionService.Configuration.installed == nil {
                Text("Local audio transcription needs whisper.cpp and its speech model. Teams caption export is available now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Export Saved Captions…") { chooseMeeting(transcribe: false) }
                Button("Transcribe Saved Meeting…") { chooseMeeting(transcribe: true) }
            }
            .disabled(service.isBusy)
            if let folder = service.lastFolder {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last meeting").font(.headline)
                    Text(folder.lastPathComponent).font(.caption).lineLimit(2).textSelection(.enabled)
                    HStack {
                        Button("Show Folder") { service.showLastFolder() }
                        outputButton("Teams Captions", file: "captions.md", folder: folder)
                        outputButton("Audio Transcript", file: "transcript.md", folder: folder)
                    }
                    if !service.lastResult.isEmpty {
                        Text(service.lastResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        } header: {
            Label("Teams Meeting Recorder", systemImage: "person.2.wave.2")
        }
    }

    @ViewBuilder
    private func outputButton(_ title: String, file: String, folder: URL) -> some View {
        let url = folder.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: url.path) {
            Button(title) { NSWorkspace.shared.open(url) }
        }
    }

    private func chooseOutputFolder() {
        let panel = directoryPanel()
        panel.message = "Choose where Vorssaint saves meeting audio and captions."
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private func chooseMeeting(transcribe: Bool) {
        let panel = directoryPanel()
        panel.message = "Choose a saved meeting folder containing manifest.json and observations.jsonl."
        if panel.runModal() == .OK, let url = panel.url {
            service.processSavedMeeting(url, transcribeAudio: transcribe)
        }
    }

    private func directoryPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel
    }
}
