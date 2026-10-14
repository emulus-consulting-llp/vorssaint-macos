// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

final class UsageTimelineWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = UsageTimelineWindowController()
    @Published private(set) var visible = false
    @Published private(set) var refreshTick = 0
    @Published private(set) var requestedDate = Date()
    private var window: NSWindow?
    private var refreshTimer: Timer?

    func show(date: Date = Date()) {
        guard AppFeature.usageTimeline.isAvailable else { return }
        requestedDate = date
        UsageTimelineService.shared.syncWithPreferences()
        if window == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 680, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: UsageTimelineView())
            window.center()
            window.setFrameAutosaveName("UsageTimelineWindow")
            self.window = window
        }
        window?.title = UsageTimelineStrings(L10n.shared.language)[.title]
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        setVisible(true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close(); setVisible(false) }
    func windowWillClose(_ notification: Notification) { setVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { setVisible(true) }

    private func setVisible(_ value: Bool) {
        visible = value
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard value else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshTick += 1 }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}

struct UsageTimelineView: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = UsageTimelineService.shared
    @ObservedObject private var controller = UsageTimelineWindowController.shared
    @State private var selectedDate = Date()
    @State private var day: UsageDay?
    @State private var appFilter: String?
    @State private var selection: String?
    @State private var pageSize = 100
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var busy = false
    @State private var deleteAll = false
    @State private var confirmingDeletion = false

    private var strings: UsageTimelineStrings { UsageTimelineStrings(l10n.language) }
    private var filteredEntries: [UsageTimelineEntry] {
        day?.entries.filter { appFilter == nil || $0.appKey == appFilter } ?? []
    }
    private var selected: UsageTimelineEntry? { day?.entries.first { $0.id == selection } }
    private var hasRecordedHistory: Bool { day?.entries.contains { $0.state != .unrecorded } ?? false }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                header
                dateControls
                if service.hasError { errorBanner }
                if !service.enabled { firstUse }
                if let day {
                    summary(day)
                    UsageDayChart(day: day, appFilter: appFilter, selection: $selection)
                        .frame(height: 56)
                    if geometry.size.width >= 820 {
                        HStack(alignment: .top, spacing: 18) {
                            appTotals(day).frame(width: 180)
                            intervalList.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        compactAppFilter(day)
                        intervalList
                    }
                    if let selected { details(selected) }
                } else if loading {
                    ProgressView(strings[.loading]).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .panelGlassSurface()
        }
        .onAppear { refresh() }
        .onChange(of: controller.requestedDate, initial: true) { _, date in selectedDate = date }
        .onChange(of: controller.visible) { _, visible in if visible { refresh() } }
        .onChange(of: controller.refreshTick) { _, _ in refresh() }
        .onChange(of: selectedDate) { _, _ in
            requestID = UUID(); loading = false
            appFilter = nil; selection = nil; pageSize = 100; day = nil; refresh()
        }
        .onChange(of: appFilter) { _, _ in selection = nil; pageSize = 100 }
        .onChange(of: service.revision) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSCalendarDayChanged)) { _ in refresh() }
        .alert(strings[.deleteTitle], isPresented: $confirmingDeletion) {
            Button(strings[.cancel], role: .cancel) {}
            Button(strings[.delete], role: .destructive) { deleteHistory() }
        } message: { Text(strings[.deleteMessage]) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label(strings[.title], systemImage: "clock.arrow.circlepath").font(.title2.weight(.semibold))
            Spacer()
            Label(statusText, systemImage: service.enabled && !service.paused && !service.hasError ? "circle.fill" : "pause.circle")
                .font(.caption).foregroundStyle(.secondary)
            if service.enabled {
                Button(strings[service.paused ? .resume : .pause]) { service.setPaused(!service.paused) }
            }
            Button {
                SettingsRouter.shared.page = .usageTimeline
                appDelegate()?.openSettingsWindow()
            } label: { Image(systemName: "gearshape") }
            .help(strings[.settings]).accessibilityLabel(strings[.settings])
        }
        .disabled(busy)
    }

    private var statusText: String {
        if service.hasError { return strings[.disabled] }
        if !service.enabled { return strings[.disabled] }
        if service.paused { return strings[.paused] }
        if service.appOnly { return strings[.appOnly] }
        return service.state == .active ? strings[.tracking] : strings.state(service.state)
    }

    private var dateControls: some View {
        HStack(spacing: 12) {
            Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(SettingsNavigationStrings.localized(l10n.language).back)
            DatePicker("", selection: $selectedDate, in: ...Date(), displayedComponents: .date).labelsHidden()
            Button { moveDay(1) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(selectedDate))
                .accessibilityLabel(SettingsNavigationStrings.localized(l10n.language).forward)
            Button(strings[.today]) { selectedDate = Date() }
            Spacer()
            Menu {
                Button(strings[.deleteDay], role: .destructive) { deleteAll = false; confirmingDeletion = true }
                Button(strings[.deleteAll], role: .destructive) { deleteAll = true; confirmingDeletion = true }
            } label: { Image(systemName: "trash") }
            .help(strings[.delete]).accessibilityLabel(strings[.delete])
        }
        .disabled(busy)
    }

    private var firstUse: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(strings[.description]).font(.callout)
                Text(strings[.localHint]).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(strings[.start]) { service.startTracking() }.buttonStyle(.borderedProminent)
                .disabled(busy || service.hasError)
        }
        .panelCard()
    }

    private var errorBanner: some View {
        HStack {
            Label(strings[.storageError], systemImage: "exclamationmark.triangle").font(.callout)
            Spacer()
            Button(strings[.retry]) { service.retry(); refresh() }
        }
        .panelCard()
    }

    private func summary(_ day: UsageDay) -> some View {
        HStack(spacing: 24) {
            metric(strings[.active], duration: day.active)
            metric(strings[.away], duration: day.away)
            ForEach([UsagePresence.paused, .excluded, .unrecorded], id: \.self) { state in
                if let duration = day.other[state], duration > 0 { metric(strings.state(state), duration: duration) }
            }
            Spacer(minLength: 0)
        }
    }

    private func metric(_ name: String, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(UsageTimelineFormatting.duration(duration)).font(.title3.monospacedDigit())
        }
    }

    private func appTotals(_ day: UsageDay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button { appFilter = nil } label: {
                    Text(strings[.allApps]).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(appFilter == nil ? Color.accentColor : .primary)
                ForEach(day.totals.filter { appFilter == nil || $0.id == appFilter }) { total in
                    Button { appFilter = total.id } label: {
                        HStack(spacing: 8) {
                            UsageAppIcon(bundleID: total.bundleID).frame(width: 22, height: 22)
                            Text(total.name).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(UsageTimelineFormatting.duration(total.duration)).font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appFilter == total.id ? Color.accentColor : .primary)
                    .help(total.name)
                }
            }.font(.callout)
        }
    }

    private func compactAppFilter(_ day: UsageDay) -> some View {
        Picker(strings[.allApps], selection: $appFilter) {
            Text(strings[.allApps]).tag(String?.none)
            ForEach(day.totals) { total in
                Text("\(total.name) · \(UsageTimelineFormatting.duration(total.duration))").tag(Optional(total.id))
            }
        }.frame(maxWidth: 360)
    }

    private var intervalList: some View {
        ScrollView {
            if !hasRecordedHistory {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(strings[.empty]).font(.headline)
                    Text(strings[.emptyHint]).font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(filteredEntries.prefix(pageSize))) { entry in
                        Button { selection = entry.id } label: { intervalRow(entry) }
                            .buttonStyle(.plain)
                    }
                    if filteredEntries.count > pageSize {
                        Button(strings[.loadMore]) { pageSize += 100 }.padding(8)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func intervalRow(_ entry: UsageTimelineEntry) -> some View {
        HStack(spacing: 12) {
            Text("\(entry.start.formatted(date: .omitted, time: .shortened))–\(entry.end.formatted(date: .omitted, time: .shortened))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 136, alignment: .leading)
            if let focus = entry.foreground {
                UsageAppIcon(bundleID: focus.bundleID).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.appName).font(.callout.weight(.medium))
                    Text(focus.title ?? strings[.windowUnknown]).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.tertiary).frame(width: 26)
                Text(strings.state(entry.state)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(UsageTimelineFormatting.duration(entry.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selection == entry.id ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func details(_ entry: UsageTimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(strings[.details]).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(UsageTimelineFormatting.duration(entry.duration)).font(.caption.monospacedDigit())
            }
            if let focus = entry.foreground {
                Text(focus.appName).font(.callout.weight(.medium))
                if let title = focus.title {
                    HStack {
                        Text(title).font(.callout).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button(strings[.copyTitle]) { copy(title) }.controlSize(.small)
                    }
                }
                if let path = focus.documentPath {
                    HStack {
                        Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button(strings[.copyPath]) { copy(path) }.controlSize(.small)
                    }
                }
            } else { Text(strings.state(entry.state)).font(.callout) }
        }.panelCard()
    }

    private func moveDay(_ offset: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: offset, to: selectedDate) { selectedDate = min(next, Date()) }
    }

    private func refresh() {
        guard !busy, !loading, controller.visible else { return }
        loading = true
        let token = UUID()
        requestID = token
        service.loadDay(selectedDate) { result in
            guard token == requestID else { return }
            day = result
            loading = false
            if let appFilter, !(result?.totals.contains { $0.id == appFilter } ?? false) { self.appFilter = nil }
        }
    }

    private func deleteHistory() {
        busy = true
        requestID = UUID()
        loading = false
        selection = nil
        service.deleteHistory(day: deleteAll ? nil : selectedDate) { _ in
            busy = false
            day = nil
            refresh()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum UsageTimelineFormatting {
    static func duration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : duration >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, duration)) ?? "0"
    }

    static func color(for key: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .green, .pink, .cyan]
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private struct UsageAppIcon: View {
    let bundleID: String?
    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else { Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary) }
    }
}

private struct UsageDayChart: View {
    let day: UsageDay
    let appFilter: String?
    @Binding var selection: String?
    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.04)))
                for entry in day.entries {
                    let x = entry.start.timeIntervalSince(day.range.start) / day.range.duration * size.width
                    let width = entry.end.timeIntervalSince(entry.start) / day.range.duration * size.width
                    let rect = CGRect(x: x, y: 0, width: max(0.5, width), height: size.height)
                    let active = entry.state == .active
                    let color = active ? UsageTimelineFormatting.color(for: entry.appKey ?? "") : Color.secondary
                    let opacity = appFilter != nil && entry.appKey != appFilter ? 0.08 : active ? 0.75 : 0.15
                    context.fill(Path(rect), with: .color(color.opacity(opacity)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).onTapGesture { point in
                        let date = day.range.start.addingTimeInterval(point.x / max(1, geometry.size.width) * day.range.duration)
                        selection = day.entries.first { $0.start <= date && $0.end > date && (appFilter == nil || $0.appKey == appFilter) }?.id
                    }
                }
            }
            HStack {
                Text(day.range.start.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text(day.range.start.addingTimeInterval(day.range.duration / 2).formatted(date: .omitted, time: .shortened))
                Spacer()
                Text(day.range.end.formatted(date: .omitted, time: .shortened))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageTimelineStrings(L10n.shared.language)[.title])
        .accessibilityValue(UsageTimelineFormatting.duration(day.active))
    }
}
