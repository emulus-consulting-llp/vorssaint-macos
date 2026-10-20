// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

/// The public activity feed: a derived, rebuildable copy of active usage that
/// other local apps read. Its layout is a versioned contract
/// (docs/ACTIVITY-FEED.md); private history never leaves `UsageTimelineStore`.
/// Called only by the Usage Timeline worker.
final class ActivityFeedStore {
    enum Failure: Error { case unavailable, database(String, Int32) }
    static let schemaVersion: Int32 = 1
    /// Outside the bundle container so Developer and release builds publish to
    /// the one path readers know.
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VorssaintFeed/feed.sqlite")
    }

    /// True when the tables were just created or reset; the caller rebuilds.
    private(set) var isEmpty = false
    private var database: OpaquePointer?
    private let url: URL
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        guard PrivateFileStore.createDirectory(at: directory, container: directory) else { throw Failure.unavailable }
        self.url = directory.resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        if (try? self.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.unavailable }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(self.url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw Failure.database("open", result)
        }
        database = handle
        do {
            sqlite3_busy_timeout(handle, 1000)
            // WAL keeps readers from ever blocking the writer, or the reverse.
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            let version = try scalar("PRAGMA user_version")
            try transaction {
                // Derived data: an unknown layout is replaced, not migrated.
                if version != 0 && version != Self.schemaVersion {
                    try execute("DROP TABLE IF EXISTS activity")
                    try execute("DROP TABLE IF EXISTS presence")
                    try execute("DROP TABLE IF EXISTS meta")
                }
                try execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try execute("CREATE TABLE IF NOT EXISTS activity (id TEXT PRIMARY KEY, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, bundle_id TEXT, app_name TEXT NOT NULL, title TEXT, document_path TEXT, open INTEGER NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS activity_time ON activity(start_ms, end_ms)")
                try execute("CREATE TABLE IF NOT EXISTS presence (id TEXT PRIMARY KEY, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL, state TEXT NOT NULL, open INTEGER NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS presence_time ON presence(start_ms, end_ms)")
                try execute("PRAGMA user_version=\(Self.schemaVersion)")
            }
            isEmpty = version != Self.schemaVersion
            try tightenPermissions()
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    /// Replaces each listed day's rows, and optionally everything else, in one
    /// transaction, so a reader never sees a half-written day.
    func write(_ days: [(range: DateInterval, rows: ActivityFeedDay)], replacingAll: Bool, meta: [String: String]) throws {
        try transaction {
            if replacingAll {
                try execute("DELETE FROM activity")
                try execute("DELETE FROM presence")
            }
            for (range, rows) in days {
                for table in ["activity", "presence"] {
                    try withStatement("DELETE FROM \(table) WHERE start_ms >= ? AND start_ms < ?") { statement in
                        sqlite3_bind_int64(statement, 1, ActivityFeedBuilder.milliseconds(range.start))
                        sqlite3_bind_int64(statement, 2, ActivityFeedBuilder.milliseconds(range.end))
                        try stepDone(statement)
                    }
                }
                for row in rows.activity { try insert(row) }
                for row in rows.presence { try insert(row) }
            }
            try writeMeta(meta)
        }
        isEmpty = false
        try tightenPermissions()
    }

    func writeMeta(_ values: [String: String]) throws {
        for (key, value) in values {
            try withStatement("INSERT INTO meta VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value") { statement in
                bind(key, at: 1, to: statement)
                bind(value, at: 2, to: statement)
                try stepDone(statement)
            }
        }
    }

    func meta() throws -> [String: String] {
        var result: [String: String] = [:]
        try withStatement("SELECT key, value FROM meta") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                result[text(statement, 0) ?? ""] = text(statement, 1) ?? ""
            }
        }
        return result
    }

    func activity() throws -> [ActivityFeedSegment] {
        var result: [ActivityFeedSegment] = []
        try withStatement("SELECT id, start_ms, end_ms, bundle_id, app_name, title, document_path, open FROM activity ORDER BY start_ms") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(ActivityFeedSegment(
                    id: text(statement, 0) ?? "", startMs: sqlite3_column_int64(statement, 1),
                    endMs: sqlite3_column_int64(statement, 2), bundleID: text(statement, 3),
                    appName: text(statement, 4) ?? "", title: text(statement, 5),
                    documentPath: text(statement, 6), open: sqlite3_column_int(statement, 7) != 0))
            }
        }
        return result
    }

    func presence() throws -> [ActivityFeedPresence] {
        var result: [ActivityFeedPresence] = []
        try withStatement("SELECT id, start_ms, end_ms, state, open FROM presence ORDER BY start_ms") { statement in
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let state = text(statement, 3).flatMap(UsagePresence.init(rawValue:)) else { continue }
                result.append(ActivityFeedPresence(
                    id: text(statement, 0) ?? "", startMs: sqlite3_column_int64(statement, 1),
                    endMs: sqlite3_column_int64(statement, 2), state: state,
                    open: sqlite3_column_int(statement, 4) != 0))
            }
        }
        return result
    }

    private func insert(_ row: ActivityFeedSegment) throws {
        try withStatement("INSERT OR REPLACE INTO activity VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { statement in
            bind(row.id, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, row.startMs)
            sqlite3_bind_int64(statement, 3, row.endMs)
            bind(row.bundleID, at: 4, to: statement)
            bind(row.appName, at: 5, to: statement)
            bind(row.title, at: 6, to: statement)
            bind(row.documentPath, at: 7, to: statement)
            sqlite3_bind_int(statement, 8, row.open ? 1 : 0)
            try stepDone(statement)
        }
    }

    private func insert(_ row: ActivityFeedPresence) throws {
        try withStatement("INSERT OR REPLACE INTO presence VALUES (?, ?, ?, ?, ?)") { statement in
            bind(row.id, at: 1, to: statement)
            sqlite3_bind_int64(statement, 2, row.startMs)
            sqlite3_bind_int64(statement, 3, row.endMs)
            bind(row.state.rawValue, at: 4, to: statement)
            sqlite3_bind_int(statement, 5, row.open ? 1 : 0)
            try stepDone(statement)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.database("execute", sqlite3_errcode(database)) }
    }

    private func scalar(_ sql: String) throws -> Int32 {
        var value: Int32 = 0
        try withStatement(sql) {
            guard sqlite3_step($0) == SQLITE_ROW else { throw Failure.database("scalar", sqlite3_errcode(database)) }
            value = sqlite3_column_int($0, 0)
        }
        return value
    }

    private func withStatement(_ sql: String, _ body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw Failure.database("prepare", sqlite3_errcode(database)) }
        defer { sqlite3_finalize(statement) }
        try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database("write", sqlite3_errcode(database)) }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private func tightenPermissions() throws {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] where manager.fileExists(atPath: path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
