import CryptoKit
import Foundation
import StreamProtocol

/// Personal-fork credentials. The .p8 stays at a user-selected path outside the app bundle;
/// only this configuration is suitable for saving in the Mac's settings.
package struct APNsConfiguration: Codable, Equatable, Sendable {
    package var teamID: String
    package var keyID: String
    package var topic: String
    package var keyPath: String
    /// Explicitly "sandbox" or "production"; never inferred from a token or build mode.
    package var environment: String

    package init(teamID: String, keyID: String, topic: String, keyPath: String, environment: String) {
        self.teamID = teamID
        self.keyID = keyID
        self.topic = topic
        self.keyPath = keyPath
        self.environment = environment
    }

    /// A short, non-secret settings error. Validation is local and sends nothing to APNs.
    package var problem: String? {
        if !Self.isAppleIdentifier(teamID) { return String(localized: "APNs Team ID must be 10 letters or digits.") }
        if !Self.isAppleIdentifier(keyID) { return String(localized: "APNs Key ID must be 10 letters or digits.") }
        if topic.isEmpty || !topic.utf8.allSatisfy({ Self.isLetterOrDigit($0) || $0 == 45 || $0 == 46 }) {
            return String(localized: "APNs topic must be an app bundle identifier.")
        }
        if environment != "sandbox" && environment != "production" {
            return String(localized: "Choose the APNs sandbox or production environment.")
        }
        let path = expandedKeyPath
        if !path.hasPrefix("/") || URL(fileURLWithPath: path).pathExtension.lowercased() != "p8" {
            return String(localized: "Choose an absolute path to an APNs .p8 key.")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return String(localized: "The APNs .p8 key cannot be read.")
        }
        do {
            _ = try signingKey()
        } catch {
            return String(localized: "The APNs .p8 key is not a valid P-256 private key.")
        }
        return nil
    }

    fileprivate var expandedKeyPath: String { (keyPath as NSString).expandingTildeInPath }

    fileprivate func signingKey() throws -> P256.Signing.PrivateKey {
        let pem = try String(contentsOfFile: expandedKeyPath, encoding: .utf8)
        return try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    private static func isAppleIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy(isLetterOrDigit)
    }

    private static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

/// Sends directly from the Mac. The caller rechecks pairing, consent and subscription before
/// every call; this actor owns no device registry and never saves device tokens or payloads.
package actor APNsProvider {
    package enum SendResult: Equatable, Sendable {
        /// APNs accepted the request; this does not confirm presentation on the device.
        case accepted
        case invalidToken
        case failure(String)
    }

    private let configuration: APNsConfiguration
    private let session: URLSession
    private var authorization: (value: String, issuedAt: Date)?

    package init(configuration: APNsConfiguration) {
        self.configuration = configuration
        let transport = URLSessionConfiguration.ephemeral
        transport.urlCache = nil
        transport.urlCredentialStorage = nil
        transport.httpCookieStorage = nil
        transport.httpShouldSetCookies = false
        transport.requestCachePolicy = .reloadIgnoringLocalCacheData
        transport.timeoutIntervalForRequest = 15
        transport.timeoutIntervalForResource = 20
        transport.waitsForConnectivity = false
        transport.tlsMinimumSupportedProtocolVersion = .TLSv12
        // APNs requires HTTP/2 and TLS 1.2+. URLSession supports HTTP/2 through ALPN;
        // there is no switch here that forces HTTP/2. Negotiation is the system's, and an
        // actual connection's protocol can be verified with URLSessionTaskMetrics ("h2").
        // https://developer.apple.com/documentation/foundation/urlsession
        // https://developer.apple.com/documentation/usernotifications/establishing-a-connection-to-apns
        session = URLSession(configuration: transport, delegate: APNsTransportDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    package func send(_ event: MirroredNotification, macID: String, token: String) async -> SendResult {
        guard !Task.isCancelled else { return .failure("APNs request cancelled.") }
        if let problem = configuration.problem { return .failure(problem) }
        // Tokens are hexadecimal bytes, but Apple explicitly says not to assume a fixed size.
        guard !token.isEmpty, token.utf8.count.isMultiple(of: 2), token.utf8.allSatisfy(Self.isHexDigit) else {
            return .invalidToken
        }
        guard !macID.isEmpty else { return .failure("The Mac notification identity is missing.") }

        let now = Date()
        let payload: Data
        let jwt: String
        do {
            payload = try Self.encodedPayload(for: event, macID: macID)
            guard payload.count <= 4096 else { return .failure("APNs notification exceeds 4 KB.") }
            jwt = try providerToken(at: now)
        } catch {
            // Neither encoding errors nor key errors are interpolated: they can contain input.
            return .failure("The APNs notification could not be prepared.")
        }

        let host = configuration.environment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else {
            return .failure("The APNs endpoint could not be prepared.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue(configuration.topic, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // At most five minutes of APNs storage; no stale alert days after reconnecting.
        request.setValue(String(Int(now.timeIntervalSince1970) + 300), forHTTPHeaderField: "apns-expiration")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("APNs returned an invalid response.")
            }
            if http.statusCode == 200 { return .accepted }
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.reason
            if http.statusCode == 410 || (http.statusCode == 400 && reason == "BadDeviceToken") {
                return .invalidToken
            }
            // Only documented constants reach settings/logs. Never echo the raw response,
            // failing URL, payload, device token, provider token or private-key contents.
            let suffix = reason.flatMap { Self.responseReasons.contains($0) ? ": \($0)" : nil } ?? ""
            return .failure("APNs \(http.statusCode)\(suffix).")
        } catch let error as URLError {
            if error.code == .cancelled { return .failure("APNs request cancelled.") }
            return .failure("APNs network error (\(error.code.rawValue)).")
        } catch {
            return .failure("APNs request failed.")
        }
        // No automatic retries: the caller decides whether a later event is still relevant.
    }

    private func providerToken(at now: Date) throws -> String {
        if let authorization {
            let age = now.timeIntervalSince(authorization.issuedAt)
            if age >= 0 && age < 50 * 60 { return authorization.value }
        }
        // Apple requires ES256 with kid/iss/iat, reusing a token for 20–60 minutes.
        // https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns
        let encoder = JSONEncoder()
        let header = try encoder.encode(TokenHeader(alg: "ES256", kid: configuration.keyID))
        let claims = try encoder.encode(TokenClaims(iss: configuration.teamID, iat: Int(now.timeIntervalSince1970)))
        let message = Self.base64URL(header) + "." + Self.base64URL(claims)
        let signature = try configuration.signingKey().signature(for: Data(message.utf8))
        // JWS ES256 uses the fixed-width R || S representation, not ASN.1 DER.
        let token = message + "." + Self.base64URL(signature.rawRepresentation)
        authorization = (token, now)
        return token
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private struct TokenHeader: Encodable { let alg: String; let kid: String }
    private struct TokenClaims: Encodable { let iss: String; let iat: Int }
    private struct ErrorResponse: Decodable { let reason: String }

    /// Only the APNs copy is shortened; the live connection keeps the caller's full event.
    /// Count the final JSON because both copies of the body and JSON escaping use the budget.
    private static func encodedPayload(for event: MirroredNotification, macID: String) throws -> Data {
        var summary = event
        summary.title = abbreviated(event.title, maxUTF8Bytes: 240)
        summary.subtitle = event.subtitle.map { abbreviated($0, maxUTF8Bytes: 160) }
        let encoder = JSONEncoder()
        let full = try encoder.encode(Payload(event: summary, macID: macID))
        guard full.count > 4096, !summary.body.isEmpty else { return full }

        let characters = Array(summary.body)
        summary.body = "…"
        var best = try encoder.encode(Payload(event: summary, macID: macID))
        // Exceptionally large source/identity fields still fail the caller's size guard.
        guard best.count <= 4096 else { return best }
        var lower = 0
        var upper = characters.count - 1
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            summary.body = String(characters.prefix(middle)) + "…"
            let candidate = try encoder.encode(Payload(event: summary, macID: macID))
            if candidate.count <= 4096 {
                best = candidate
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        return best
    }

    /// Reserve the ellipsis inside the byte limit and never split an extended grapheme cluster.
    private static func abbreviated(_ text: String, maxUTF8Bytes: Int) -> String {
        guard text.utf8.count > maxUTF8Bytes else { return text }
        var prefix = ""
        var bytes = "…".utf8.count
        for character in text {
            let count = String(character).utf8.count
            guard bytes + count <= maxUTF8Bytes else { break }
            prefix.append(character)
            bytes += count
        }
        return prefix + "…"
    }

    private struct Payload: Encodable {
        let aps: APS
        let sill: Sill

        init(event: MirroredNotification, macID: String) {
            let parts = [event.appName, event.title].filter { !$0.isEmpty }
            let title = parts.isEmpty ? String(localized: "Mac notification") : parts.joined(separator: " · ")
            aps = APS(alert: Alert(title: title, subtitle: event.subtitle, body: event.body), threadID: macID)
            sill = Sill(macID: macID, event: event)
        }
    }

    private struct APS: Encodable {
        let alert: Alert
        let threadID: String
        enum CodingKeys: String, CodingKey { case alert; case threadID = "thread-id" }
    }
    private struct Alert: Encodable { let title: String; let subtitle: String?; let body: String }
    private struct Sill: Encodable { let macID: String; let event: MirroredNotification }

    // Apple: Handling notification responses from APNs. Unknown values are reduced to HTTP status.
    // https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns
    private static let responseReasons: Set<String> = [
        "BadCollapseId", "BadDeviceToken", "BadExpirationDate", "BadMessageId", "BadPriority", "BadTopic",
        "DeviceTokenNotForTopic", "DuplicateHeaders", "IdleTimeout", "InvalidPushType", "MissingDeviceToken",
        "MissingTopic", "PayloadEmpty", "TopicDisallowed", "BadCertificate", "BadCertificateEnvironment",
        "ExpiredProviderToken", "Forbidden", "InvalidProviderToken", "MissingProviderToken",
        "UnrelatedKeyIdInToken", "BadEnvironmentKeyIdInToken", "BadPath", "MethodNotAllowed", "ExpiredToken",
        "Unregistered", "PayloadTooLarge", "TooManyProviderTokenUpdates", "TooManyRequests",
        "InternalServerError", "ServiceUnavailable", "Shutdown",
    ]
}

/// APNs does not need HTTP redirection. Refuse it so credentials and the device path cannot
/// be forwarded to a different endpoint, even if a server/proxy returns a redirect.
private final class APNsTransportDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
