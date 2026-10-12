import Foundation

/// Accepts the Antigravity language server's self-signed certificate — and only
/// its certificate, on loopback.
///
/// The language server serves HTTPS on 127.0.0.1 with a cert no CA vouches for,
/// so a normal URLSession refuses it. The exemption is scoped to loopback hosts
/// so this can never widen into a general TLS bypass: any other host falls
/// through to default validation.
final class LocalTrustDelegate: NSObject, URLSessionDelegate {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              Self.loopbackHosts.contains(space.host),
              let trust = space.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
