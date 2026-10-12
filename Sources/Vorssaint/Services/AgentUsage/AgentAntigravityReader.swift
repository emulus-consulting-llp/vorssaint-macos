// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Best-effort, read-only quota requests to a running Antigravity server on this Mac.
/// One worker serves both pools. No credentials are read from disk or written back.
final class AgentAntigravityReader: @unchecked Sendable {
    private let worker = DispatchQueue(label: "com.vorssaint.antigravity-quota", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var active: URLSession?
    // Worker-confined; kept only in memory if a later refresh cannot reach the server.
    private var lastLive: [AgentProvider: AgentLimits] = [:]
    private let systemCommand: ((String, [String]) -> String?)?
    private let fetch: ((AgentAntigravityUsage.Listener, String, String, TimeInterval) -> Data?)?

    init(systemCommand: ((String, [String]) -> String?)? = nil,
         fetch: ((AgentAntigravityUsage.Listener, String, String, TimeInterval) -> Data?)? = nil) {
        self.systemCommand = systemCommand
        self.fetch = fetch
    }

    func cancel() {
        let session: URLSession? = lock.withLock {
            generation += 1
            let session = active
            active = nil
            return session
        }
        session?.invalidateAndCancel()
    }

    func read(home: URL, completion: @escaping (AgentAntigravityUsage.Reading) -> Void) {
        cancel()
        let ticket = lock.withLock { generation }
        worker.async { [self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            func available() -> Bool { current(ticket) && ProcessInfo.processInfo.systemUptime < deadline }
            guard available() else { return }
            let cache = cached(home: home)
            let output = command("/bin/ps", ["-ww", "-axo", "pid=,args="], ticket: ticket) ?? ""
            // Newest PID first, one responding server supplies the entire reading.
            // Never combine Gemini from one process/account with third-party quotas from another.
            for server in AgentAntigravityUsage.servers(output).prefix(3) {
                guard available() else { break }
                guard let actual = command("/bin/ps", ["-ww", "-p", String(server.pid), "-o", "comm="], ticket: ticket),
                      actual.trimmingCharacters(in: .whitespacesAndNewlines) == server.executable,
                      let listeners = command("/usr/sbin/lsof",
                          ["-nP", "-a", "-p", String(server.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], ticket: ticket) else { continue }
                for listener in AgentAntigravityUsage.listeners(listeners).prefix(3) {
                    for scheme in ["http", "https"] {
                        guard available() else { break }
                        let timeout = min(1.5, deadline - ProcessInfo.processInfo.systemUptime)
                        guard timeout > 0,
                              let data = request(listener: listener, scheme: scheme, token: server.token,
                                                 timeout: timeout, ticket: ticket) else { continue }
                        let limits = AgentAntigravityUsage.decode(data, observedAt: Date())
                        if !limits.isEmpty, current(ticket) {
                            lastLive = limits
                            completion(.init(limits: limits, state: .live))
                            return
                        }
                    }
                }
            }
            guard current(ticket) else { return }
            let saved = (lastLive.values.map(\.observedAt).max() ?? .distantPast)
                > (cache.values.map(\.observedAt).max() ?? .distantPast) ? lastLive : cache
            completion(.init(limits: saved, state: saved.isEmpty ? .unavailable : .cached))
        }
    }

    private func current(_ ticket: Int) -> Bool { lock.withLock { generation == ticket } }

    private func cached(home: URL) -> [AgentProvider: AgentLimits] {
        let path = home.appendingPathComponent(".aiusage/gemini.json")
        guard let file = try? FileHandle(forReadingFrom: path) else { return [:] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: AgentAntigravityUsage.maximumBytes + 1) else { return [:] }
        return AgentAntigravityUsage.cached(data, now: Date())
    }

    /// These system commands have no shell expansion. Their output stays in bounded memory.
    private func command(_ path: String, _ args: [String], ticket: Int) -> String? {
        guard current(ticket) else { return nil }
        if let systemCommand { return systemCommand(path, args) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: timeout)
        var data = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > AgentAntigravityUsage.maximumBytes || !current(ticket) {
                if process.isRunning { process.terminate() }
                break
            }
        }
        process.waitUntilExit()
        timeout.cancel()
        try? pipe.fileHandleForReading.close()
        guard current(ticket), process.terminationStatus == 0,
              data.count <= AgentAntigravityUsage.maximumBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func request(listener: AgentAntigravityUsage.Listener, scheme: String, token: String,
                         timeout: TimeInterval, ticket: Int) -> Data? {
        guard current(ticket),
              let url = URL(string: "\(scheme)://\(listener.host):\(listener.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { return nil }
        if let fetch { return fetch(listener, scheme, token, timeout) }
        let transfer = AgentAntigravityTransfer(host: listener.host, port: listener.port)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.connectionProxyDictionary = [:]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: transfer, delegateQueue: nil)
        guard lock.withLock({ () -> Bool in
            guard generation == ticket else { return false }
            active = session
            return true
        }) else { session.invalidateAndCancel(); return nil }
        defer {
            session.invalidateAndCancel()
            lock.withLock { if active === session { active = nil } }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-codeium-csrf-token")
        session.dataTask(with: request).resume()
        guard transfer.finished.wait(timeout: .now() + timeout) == .success, current(ticket) else { return nil }
        return transfer.result
    }
}

/// A per-endpoint delegate prevents redirects, limits response size, and accepts a local
/// self-signed certificate only for the exact loopback listener validated above.
private final class AgentAntigravityTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let host: String
    private let port: Int
    private let lock = NSLock()
    private var bytes = Data()
    private var valid = false
    private var answer: Data?
    var result: Data? { lock.withLock { answer } }

    init(host: String, port: Int) {
        self.host = host.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        self.port = port
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host, space.port == port, ["127.0.0.1", "::1"].contains(host),
              let trust = space.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        valid = (response as? HTTPURLResponse)?.statusCode == 200
            && response.expectedContentLength <= AgentAntigravityUsage.maximumBytes
        completionHandler(valid ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= AgentAntigravityUsage.maximumBytes else {
            valid = false
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { answer = error == nil && valid ? bytes : nil }
        finished.signal()
    }
}
