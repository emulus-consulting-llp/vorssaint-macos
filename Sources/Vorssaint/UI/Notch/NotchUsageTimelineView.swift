// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// A reader of the existing recorder. Its refresh task lives only as long as
/// this page is visible; Settings uses an illustrative, entirely local preview.
struct NotchUsageTimelineView: View {
    let size: CGSize
    @ObservedObject private var service = UsageTimelineService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.notchSettingsPreview) private var preview
    @State private var date = Date()
    @State private var day: UsageDay?
    @State private var loading = true
    @State private var calendarRevision = 0

    private struct Refresh: Equatable {
        let date: Date
        let revision: Int
        let preview: Bool
        let calendarRevision: Int
    }

    private var strings: UsageTimelineStrings { UsageTimelineStrings(l10n.language) }
    private var status: String {
        if preview { return strings[.tracking] }
        if service.hasError || !service.enabled { return strings[.disabled] }
        if service.paused { return strings[.paused] }
        if service.appOnly { return strings[.appOnly] }
        return service.state == .active ? strings[.tracking] : strings.state(service.state)
    }

    var body: some View {
        NotchUsageTimelineDashboard(
            day: preview ? NotchUsageTimelineSample.day : day, date: $date, strings: strings,
            language: l10n.language, status: status, loading: !preview && loading,
            enabled: preview || service.enabled, paused: !preview && service.paused,
            hasError: !preview && service.hasError,
            tracking: preview || (service.enabled && !service.paused && !service.hasError && service.state == .active),
            toggleTracking: {
                if service.enabled { service.setPaused(!service.paused) } else { service.startTracking() }
            }, retry: { service.retry(); calendarRevision += 1 }, open: {
                NotchService.shared.perform { UsageTimelineWindowController.shared.show(date: date) }
            })
        .frame(width: size.width, height: size.height)
        .task(id: Refresh(date: date, revision: service.revision, preview: preview, calendarRevision: calendarRevision)) {
            guard !preview, AppFeature.usageTimeline.isAvailable else { return }
            service.syncWithPreferences()
            if day?.range != UsageDay.range(for: date) { day = nil }
            loading = day == nil
            repeat {
                let result = await withCheckedContinuation { continuation in
                    service.loadDay(date) { continuation.resume(returning: $0) }
                }
                // Date changes, collapse and section changes cancel this task.
                // A late database response must not replace the next page/day.
                guard !Task.isCancelled else { return }
                day = result
                loading = false
                if !Calendar.current.isDateInToday(date) { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSCalendarDayChanged)) { _ in
            // Follow today across midnight, but leave a deliberately selected
            // historical day in place.
            if let range = day?.range, abs(range.end.timeIntervalSinceNow) < 60 { date = Date() }
            calendarRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in
            calendarRevision += 1
        }
    }
}

/// Kept separate from collection so every layout can be rendered with fixtures.
struct NotchUsageTimelineDashboard: View {
    let day: UsageDay?
    @Binding var date: Date
    let strings: UsageTimelineStrings
    let language: AppLanguage
    let status: String
    let loading: Bool
    let enabled: Bool
    let paused: Bool
    let hasError: Bool
    let tracking: Bool
    var toggleTracking: () -> Void
    var retry: () -> Void
    var open: () -> Void
    @State private var recent = false
    @State private var selected: String?

    private let mint = Color(red: 0.48, green: 0.90, blue: 0.76)
    private var entries: [UsageTimelineEntry] {
        Array((day?.entries ?? []).filter { $0.state != .unrecorded }.reversed())
    }
    private var selectedEntry: UsageTimelineEntry? { day?.entries.first { $0.id == selected } }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                toolbar
                if hasError {
                    message(strings[.storageError], symbol: "exclamationmark.triangle", action: strings[.retry], perform: retry)
                } else if loading && day == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(strings[.loading])
                } else if entries.isEmpty {
                    message(enabled ? strings[.emptyHint] : strings[.description], symbol: "clock.arrow.circlepath",
                            action: enabled ? nil : strings[.start], perform: toggleTracking)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        summary.frame(width: min(145, geometry.size.width * 0.34), alignment: .topLeading)
                        VStack(spacing: 4) {
                            tabs
                            activityList(compact: geometry.size.height < 170)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    timeline
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: date) { _, _ in selected = nil }
        .onChange(of: day?.range) { _, _ in selected = nil }
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            icon("chevron.left", label: SettingsNavigationStrings.localized(language).back) { moveDay(-1) }
            Button { date = Date() } label: {
                Text(Calendar.current.isDateInToday(date) ? strings[.today] : date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain).help(strings[.today])
            icon("chevron.right", label: SettingsNavigationStrings.localized(language).forward) { moveDay(1) }
                .disabled(Calendar.current.isDateInToday(date))
            Spacer(minLength: 2)
            Circle().fill(tracking ? mint : Color.white.opacity(0.3)).frame(width: 5, height: 5)
            Text(status).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                .lineLimit(1).help(status)
            icon(enabled && !paused ? "pause.fill" : "play.fill",
                 label: strings[enabled ? (paused ? .resume : .pause) : .start], action: toggleTracking)
                .disabled(hasError)
            icon("arrow.up.right", label: strings[.open], action: open)
        }
        .frame(height: 24)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(strings[.active]).font(.system(size: 10, weight: .medium)).foregroundStyle(mint)
            Text(UsageTimelineFormatting.duration(day?.active ?? 0))
                .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(-0.8).lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(.white)
            if let selectedEntry {
                Text(selectedEntry.foreground?.appName ?? strings.state(selectedEntry.state))
                    .font(.system(size: 10, weight: .medium)).lineLimit(1).foregroundStyle(mint)
                    .help(selectedEntry.start.formatted(date: .omitted, time: .shortened)
                          + " · " + UsageTimelineFormatting.duration(selectedEntry.duration))
            } else {
                HStack(spacing: 4) {
                    Circle().fill(.white.opacity(0.25)).frame(width: 4, height: 4)
                    Text(strings[.away])
                    Text(UsageTimelineFormatting.duration(day?.away ?? 0)).foregroundStyle(.white.opacity(0.8))
                }
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            tab(strings[.allApps], isRecent: false)
            tab(strings[.recentActivity], isRecent: true)
        }
        .padding(2)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func tab(_ title: String, isRecent: Bool) -> some View {
        Button { recent = isRecent } label: {
            Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: 18)
                .foregroundStyle(.white.opacity(recent == isRecent ? 0.95 : 0.4))
                .background(.white.opacity(recent == isRecent ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(recent == isRecent ? .isSelected : [])
    }

    private func activityList(compact: Bool) -> some View {
        GeometryReader { geometry in
            let rowHeight: CGFloat = recent ? 34 : compact ? 24 : 32
            let rows = max(1, floor((geometry.size.height + 2) / (rowHeight + 2)))
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if recent {
                            ForEach(entries) { entry in
                                Button { selected = entry.id } label: { recentRow(entry) }
                                    .buttonStyle(.plain)
                            }
                        } else {
                            ForEach(day?.totals ?? []) { total in appRow(total, compact: compact) }
                            if day?.totals.isEmpty == true {
                                Text(strings[.empty]).font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 12)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(geometry.size.height, rows * (rowHeight + 2) - 2))
                .onChange(of: selected) { _, value in
                    if let value { reader.scrollTo(value, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appRow(_ total: UsageAppTotal, compact: Bool) -> some View {
        HStack(spacing: 7) {
            NotchUsageAppIcon(name: total.name, bundleID: total.bundleID, tint: UsageTimelineFormatting.color(for: total.id))
                .frame(width: compact ? 18 : 22, height: compact ? 18 : 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                HStack(spacing: 4) {
                    Text(total.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(UsageTimelineFormatting.duration(total.duration)).font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                GeometryReader { geometry in
                    Capsule().fill(.white.opacity(0.05))
                    Capsule().fill(UsageTimelineFormatting.color(for: total.id).gradient)
                        .frame(width: geometry.size.width * min(1, total.duration / max(1, day?.active ?? 0)))
                }.frame(height: 3)
            }
        }
        .padding(.horizontal, 4).frame(height: compact ? 24 : 32)
        .accessibilityElement(children: .combine)
    }

    private func recentRow(_ entry: UsageTimelineEntry) -> some View {
        HStack(spacing: 7) {
            if let foreground = entry.foreground {
                NotchUsageAppIcon(name: foreground.appName, bundleID: foreground.bundleID,
                                  tint: UsageTimelineFormatting.color(for: entry.appKey ?? ""))
                    .frame(width: 22, height: 22).accessibilityHidden(true)
            } else {
                Image(systemName: "moon.zzz").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.foreground?.appName ?? strings.state(entry.state)).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(entry.foreground?.title ?? entry.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text(UsageTimelineFormatting.duration(entry.duration)).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .padding(.horizontal, 4).frame(height: 34)
        .background(.white.opacity(selected == entry.id ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var timeline: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                if let day {
                    Canvas { context, size in
                        for entry in day.entries where entry.state != .unrecorded {
                            let x = entry.start.timeIntervalSince(day.range.start) / day.range.duration * size.width
                            let width = entry.end.timeIntervalSince(entry.start) / day.range.duration * size.width
                            let rect = CGRect(x: x, y: 0, width: max(0.5, width - 0.5), height: size.height)
                            let color = entry.state == .active ? UsageTimelineFormatting.color(for: entry.appKey ?? "") : .white.opacity(0.18)
                            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                        }
                    }
                    .background(.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .leading) {
                        if let entry = selectedEntry {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(.white.opacity(0.9), lineWidth: 1)
                                .frame(width: max(2, entry.end.timeIntervalSince(entry.start) / day.range.duration * geometry.size.width))
                                .offset(x: entry.start.timeIntervalSince(day.range.start) / day.range.duration * geometry.size.width)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { point in
                        let time = day.range.start.addingTimeInterval(point.x / max(1, geometry.size.width) * day.range.duration)
                        selected = day.entries.first { $0.start <= time && $0.end > time && $0.state != .unrecorded }?.id
                        if selected != nil { recent = true }
                    }
                }
            }
            .frame(height: 16)
            HStack {
                if let day {
                    Text(day.range.start.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text(day.range.start.addingTimeInterval(day.range.duration / 2).formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text(day.range.end.formatted(date: .omitted, time: .shortened))
                }
            }
            .font(.system(size: 8).monospacedDigit()).foregroundStyle(.white.opacity(0.3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strings[.title])
        .accessibilityValue(UsageTimelineFormatting.duration(day?.active ?? 0))
    }

    private func message(_ text: String, symbol: String, action: String?, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(mint)
                .frame(width: 58, height: 66)
                .background(mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action, action: perform).font(.system(size: 11, weight: .semibold)).buttonStyle(.plain)
                        .foregroundStyle(mint)
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.6)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 7)).help(label).accessibilityLabel(label)
    }

    private func moveDay(_ offset: Int) {
        if let next = Calendar.current.date(byAdding: .day, value: offset, to: date) { date = min(next, Date()) }
    }
}

private struct NotchUsageAppIcon: View {
    let name: String
    let bundleID: String?
    let tint: Color

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        } else {
            Text(String(name.prefix(1))).font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(tint).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Sample app names only. The Settings caption identifies this as a preview;
/// no tracking, database reads, permissions or real window titles are involved.
enum NotchUsageTimelineSample {
    static var day: UsageDay {
        let range = UsageDay.range(for: Date())
        let apps = [("Xcode", "com.apple.dt.Xcode", 9.0, 1.6), ("Safari", "com.apple.Safari", 10.6, 0.7),
                    ("Notes", "com.apple.Notes", 11.3, 0.5), ("Xcode", "com.apple.dt.Xcode", 12.2, 1.2)]
        let entries = apps.enumerated().map { index, app in
            UsageTimelineEntry(id: String(index), start: range.start.addingTimeInterval(app.2 * 3600),
                end: range.start.addingTimeInterval((app.2 + app.3) * 3600), duration: app.3 * 3600, state: .active,
                foreground: UsageForeground(appName: app.0, bundleID: app.1, processID: String(index)))
        }
        return UsageDay(range: range, entries: entries, totals: [
            UsageAppTotal(id: "com.apple.dt.Xcode", name: "Xcode", duration: 10080, bundleID: "com.apple.dt.Xcode"),
            UsageAppTotal(id: "com.apple.Safari", name: "Safari", duration: 2520, bundleID: "com.apple.Safari"),
            UsageAppTotal(id: "com.apple.Notes", name: "Notes", duration: 1800, bundleID: "com.apple.Notes")
        ], active: 14400, away: 1440, other: [:])
    }
}
