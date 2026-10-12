import Foundation

/// Fetches Gemini + Antigravity-3P quota from the Antigravity language server.
///
/// `language_server` exposes a Connect RPC on a loopback HTTPS port:
///
///   POST /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
///   x-codeium-csrf-token: <token>     (Antigravity descends from Codeium)
///
/// Both the port and the token are on the server's own command line, so we
/// discover them from the process table. The token is read locally and sent
/// only to 127.0.0.1 — never off the machine.
///
/// This is an internal RPC, not a public contract: it can change on any
/// Antigravity update, so every failure degrades to "unavailable" with the last
/// known reading rather than a wrong number.
final class GeminiSource {
    static let cacheURL = URL(fileURLWithPath: NSString(string: "~/.aiusage/gemini.json").expandingTildeInPath)
    static let endpointURL = URL(fileURLWithPath: NSString(string: "~/.aiusage/antigravity.json").expandingTildeInPath)
    static let stalenessThreshold: TimeInterval = 45 * 60

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        session = URLSession(
            configuration: config,
            delegate: LocalTrustDelegate(),
            delegateQueue: nil
        )
    }

    // MARK: - Discovery

    struct Endpoint {
        let pid: Int
        let port: Int
        let csrfToken: String
        let isHTTP: Bool

        init(pid: Int, port: Int, csrfToken: String, isHTTP: Bool = false) {
            self.pid = pid
            self.port = port
            self.csrfToken = csrfToken
            self.isHTTP = isHTTP
        }
    }

    private struct StoredEndpoint: Decodable {
        let address: String?
        let port: Int?
        let csrf_token: String?
        let pid: Int?
    }

    private func readStoredEndpoint() -> (pid: Int, port: Int, csrfToken: String)? {
        guard let data = try? Data(contentsOf: Self.endpointURL),
              let stored = try? JSONDecoder().decode(StoredEndpoint.self, from: data),
              let token = stored.csrf_token, !token.isEmpty else {
            return nil
        }
        let port = stored.port ?? stored.address.flatMap { addr -> Int? in
            let parts = addr.split(separator: ":")
            return parts.count > 1 ? Int(parts[1]) : nil
        }
        guard let validPort = port, validPort > 0 else { return nil }
        return (pid: stored.pid ?? 0, port: validPort, csrfToken: token)
    }

    /// Every running language server we can address, most recently started first.
    func discoverEndpoints() -> [Endpoint] {
        var declared: [Endpoint] = []
        var guessed: [Endpoint] = []

        // 1. Check endpoint saved by the agy hook
        if let stored = readStoredEndpoint() {
            if stored.pid <= 0 || kill(pid_t(stored.pid), 0) == 0 {
                declared.append(Endpoint(pid: stored.pid, port: stored.port, csrfToken: stored.csrfToken, isHTTP: true))
                declared.append(Endpoint(pid: stored.pid, port: stored.port, csrfToken: stored.csrfToken, isHTTP: false))
            }
        }
        // 2. Discover running language servers from the process table (Antigravity IDE)
        guard let output = run("/bin/ps", ["-axo", "pid=,args="]) else { return declared }

        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count > 1, let pid = Int(fields[0]) else { continue }

            // The binary was `language_server_macos_arm` up to Antigravity 2.14
            // and is plain `language_server` from 2.15. Match the executable's
            // own name, not the whole line, so other processes that merely
            // mention it in their arguments don't count.
            let executable = fields[1].split(separator: "/").last.map(String.init) ?? ""
            guard executable.hasPrefix("language_server") else { continue }
            guard let token = value(of: "--csrf_token", in: fields) else { continue }

            if let portString = value(of: "--https_server_port", in: fields),
               let port = Int(portString), port > 0 {
                declared.append(Endpoint(pid: pid, port: port, csrfToken: token))
            } else {
                // The CLI's server omits --https_server_port, and since 2.15 the
                // app passes `0` (OS-assigned). Either way, fall back to whatever
                // it has open and let the RPC itself decide.
                for port in listeningPorts(pid: pid) {
                    guessed.append(Endpoint(pid: pid, port: port, csrfToken: token))
                }
            }
        }

        // Servers that state their port answer immediately; guessed ports each
        // cost a full timeout when wrong, so they go last.
        return declared + guessed
    }

    /// Reads `--flag value` or `--flag=value`.
    private func value(of flag: String, in fields: [String]) -> String? {
        if let i = fields.firstIndex(of: flag), i + 1 < fields.count { return fields[i + 1] }
        let prefix = flag + "="
        return fields.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private func listeningPorts(pid: Int) -> [Int] {
        guard let out = run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"])
            ?? run("/usr/bin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"])
        else { return [] }

        var ports: [Int] = []
        for line in out.split(separator: "\n").dropFirst() {
            guard let colon = line.lastIndex(of: ":") else { continue }
            let tail = line[line.index(after: colon)...]
            let digits = tail.prefix { $0.isNumber }
            if let port = Int(digits) { ports.append(port) }
        }
        return ports
    }

    private func run(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - RPC

    // Left internal so `parse` can be exercised directly against a captured payload.
    struct Response: Decodable {
        struct Wrapper: Decodable { let groups: [Group]? }
        struct Group: Decodable {
            let displayName: String?
            let buckets: [BucketInfo]?
        }
        struct BucketInfo: Decodable {
            let bucketId: String?
            let window: String?
            let remainingFraction: Double?
            let remainingAmount: Double?
            let resetTime: String?
        }
        let response: Wrapper?
    }

    private struct CachedPayload: Decodable {
        let fetched_at: Double
        let raw_response: Response?
    }

    /// Reads the cached quota written by the agy status hook.
    func readCached() -> Snapshot? {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let payload = try? JSONDecoder().decode(CachedPayload.self, from: data),
              let groups = payload.raw_response?.response?.groups else {
            return nil
        }

        var snapshot = Snapshot()
        snapshot.buckets = Self.parse(groups)
        snapshot.fetchedAt = Date(timeIntervalSince1970: payload.fetched_at)
        if snapshot.buckets.isEmpty {
            snapshot.error = "No quota buckets reported"
            return snapshot
        }

        if Date().timeIntervalSince(snapshot.fetchedAt!) > Self.stalenessThreshold {
            snapshot.error = "stale — Antigravity idle"
        }
        return snapshot
    }

    /// Queries each discovered server until one answers. Multiple servers mean
    /// one account, so the first success is authoritative.
    func fetch(completion: @escaping (Snapshot) -> Void) {
        let endpoints = discoverEndpoints()
        guard !endpoints.isEmpty else {
            if let cached = readCached(), cached.hasData {
                completion(cached)
                return
            }
            var snapshot = Snapshot()
            snapshot.error = "Antigravity isn't running"
            completion(snapshot)
            return
        }
        attempt(endpoints, index: 0, completion: completion)
    }

    private func attempt(_ endpoints: [Endpoint], index: Int, completion: @escaping (Snapshot) -> Void) {
        guard index < endpoints.count else {
            if let cached = readCached(), cached.hasData {
                completion(cached)
                return
            }
            var snapshot = Snapshot()
            snapshot.error = "Language server didn't answer"
            completion(snapshot)
            return
        }

        let endpoint = endpoints[index]
        let scheme = endpoint.isHTTP ? "http" : "https"
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(endpoint.port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else {
            self.attempt(endpoints, index: index + 1, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = Data("{}".utf8)

        // Deliberately a strong capture: the request must outlive the caller's
        // reference to this object. `GeminiSource().fetch { }` otherwise
        // deallocates the source -- and its URLSession -- before the response
        // arrives, which surfaces as a bogus timeout rather than an error. The
        // closure is owned by the task, so it releases when the chain finishes.
        session.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            guard ok,
                  let data,
                  let decoded = try? JSONDecoder().decode(Response.self, from: data),
                  let groups = decoded.response?.groups
            else {
                self.attempt(endpoints, index: index + 1, completion: completion)
                return
            }

            var snapshot = Snapshot()
            snapshot.buckets = Self.parse(groups)
            snapshot.fetchedAt = Date()
            if snapshot.buckets.isEmpty { snapshot.error = "No quota buckets reported" }
            completion(snapshot)
        }.resume()
    }

    // MARK: - Parsing

    static func parse(_ groups: [Response.Group]) -> [Bucket] {
        var buckets: [Bucket] = []

        for group in groups {
            for info in group.buckets ?? [] {
                let id = info.bucketId ?? ""

                let provider: Provider
                if id.hasPrefix("gemini") {
                    provider = .gemini
                } else if id.hasPrefix("3p") {
                    provider = .antigravity3P
                } else if group.displayName?.localizedCaseInsensitiveContains("gemini") == true {
                    provider = .gemini
                } else {
                    provider = .antigravity3P
                }

                let window: LimitWindow
                switch info.window {
                case "5h": window = .fiveHour
                case "weekly": window = .weekly
                default:
                    if id.hasSuffix("5h") { window = .fiveHour }
                    else if id.hasSuffix("weekly") { window = .weekly }
                    else { continue }
                }

                // proto3 JSON omits default values, so an absent fraction is
                // ambiguous: either the oneof carries an amount instead, or the
                // value really is 0. We treat a bucket with neither key as
                // exhausted. For a tool whose job is predicting a cutoff, the
                // safe failure is to warn early, never to falsely reassure.
                let remaining: Double
                if let fraction = info.remainingFraction {
                    remaining = fraction
                } else if info.remainingAmount != nil {
                    // An absolute allowance with no denominator: not a headroom
                    // percentage, so it can't be shown on a 0-100 scale.
                    continue
                } else {
                    remaining = 0
                }

                buckets.append(Bucket(
                    provider: provider,
                    window: window,
                    // The RPC reports headroom; the UI speaks consumption.
                    // Inverted once here so nothing downstream has to remember.
                    usedFraction: 1 - max(0, min(1, remaining)),
                    resetTime: info.resetTime.flatMap(Self.parseDate)
                ))
            }
        }
        return buckets
    }

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
