// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

/// Called only by the service's serial worker. No history lives in defaults.
final class UsageTimelineStore {
    enum Failure: Error { case unavailable, database(String, Int32), unsupportedVersion }
    private var database: OpaquePointer?
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard PrivateFileStore.createDirectory(at: url.deletingLastPathComponent()) else { throw Failure.unavailable }
        self.url = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        if (try? self.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.unavailable }
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(self.url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw Failure.database("open", result)
        }
        database = handle
        do {
            try tightenPermissions()
            sqlite3_busy_timeout(handle, 2000)
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA secure_delete=ON")
            let version = try scalar("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw Failure.unsupportedVersion }
            try transaction {
                try execute("CREATE TABLE IF NOT EXISTS intervals (id TEXT PRIMARY KEY, session TEXT NOT NULL, stream TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL, bundle TEXT, body BLOB NOT NULL)")
                try execute("CREATE INDEX IF NOT EXISTS interval_time ON intervals(start, end)")
                try execute("CREATE INDEX IF NOT EXISTS interval_app_time ON intervals(bundle, start)")
                try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, checkpoint REAL NOT NULL)")
                try execute("PRAGMA user_version=1")
            }
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func save(_ intervals: [UsageInterval], session: UUID, checkpoint: Date) throws {
        try transaction {
            for interval in intervals { try upsert(interval) }
            try withStatement("INSERT INTO sessions VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET checkpoint=excluded.checkpoint") { statement in
                bind(session.uuidString, at: 1, to: statement)
                sqlite3_bind_double(statement, 2, checkpoint.timeIntervalSince1970)
                try stepDone(statement)
            }
        }
        try tightenPermissions()
    }

    func intervals(in range: DateInterval) throws -> [UsageInterval] {
        var result: [UsageInterval] = []
        try withStatement("SELECT body FROM intervals WHERE start < ? AND end > ? ORDER BY start, rowid") { statement in
            sqlite3_bind_double(statement, 1, range.end.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, range.start.timeIntervalSince1970)
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW, let pointer = sqlite3_column_blob(statement, 0) else { throw Failure.database("read", code) }
                let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
                guard let value = try? decoder.decode(UsageInterval.self, from: data) else { throw Failure.database("decode", SQLITE_CORRUPT) }
                result.append(value)
            }
        }
        return result
    }

    func delete(in range: DateInterval?) throws {
        try transaction {
            guard let range else {
                try execute("DELETE FROM intervals")
                try execute("DELETE FROM sessions")
                return
            }
            let overlapping = try intervals(in: range)
            try withStatement("DELETE FROM intervals WHERE start < ? AND end > ?") { statement in
                sqlite3_bind_double(statement, 1, range.end.timeIntervalSince1970)
                sqlite3_bind_double(statement, 2, range.start.timeIntervalSince1970)
                try stepDone(statement)
            }
            for interval in overlapping {
                if interval.start < range.start,
                   var left = interval.clipped(to: DateInterval(start: interval.start, end: range.start)) {
                    left.id = UUID()
                    try upsert(left)
                }
                if interval.end > range.end,
                   var right = interval.clipped(to: DateInterval(start: range.end, end: interval.end)) {
                    right.id = UUID()
                    try upsert(right)
                }
            }
        }
        try tightenPermissions()
    }

    private func upsert(_ value: UsageInterval) throws {
        // Zero-length checkpoints still replace an earlier provisional span
        // when backdated idle lands exactly at the collection boundary.
        let data = try encoder.encode(value)
        try withStatement("INSERT INTO intervals VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET end=excluded.end, body=excluded.body") { statement in
            bind(value.id.uuidString, at: 1, to: statement)
            bind(value.sessionID.uuidString, at: 2, to: statement)
            bind(value.stream.rawValue, at: 3, to: statement)
            sqlite3_bind_double(statement, 4, value.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 5, value.end.timeIntervalSince1970)
            if let bundle = value.foreground?.bundleID { bind(bundle, at: 6, to: statement) }
            else { sqlite3_bind_null(statement, 6) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 7, $0.baseAddress, Int32($0.count), Self.transient) }
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

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func tightenPermissions() throws {
        let manager = FileManager.default
        for path in [url.path, url.path + "-journal", url.path + "-wal", url.path + "-shm"] where manager.fileExists(atPath: path) {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
