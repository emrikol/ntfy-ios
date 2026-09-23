import Foundation

/// Registers this app's APNs token and hashed ntfy subscriptions with a direct APNs relay
/// hosted alongside each self-hosted ntfy server.
final class DirectAPNSManager {
    static let shared = DirectAPNSManager()

    private static let registrationPath = "/_ntfy_apns/v1/registrations"
    private static let deviceTokenKey = "directAPNSDeviceToken"
    private let tag = "DirectAPNSManager"
    private let defaults = UserDefaults(suiteName: Store.appGroup)!
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func updateDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        defaults.set(token, forKey: Self.deviceTokenKey)
        Log.d(tag, "APNs token received: \(token.prefix(12))...")
        syncAll()
    }

    func syncAll() {
        guard let token = storedDeviceToken() else {
            Log.d(tag, "Skipping relay sync until APNs supplies a device token")
            return
        }
        let grouped = Dictionary(grouping: Store.shared.relaySubscriptionSnapshot()) { $0.baseUrl }
        grouped.forEach { baseUrl, subscriptions in
            sync(baseUrl: baseUrl, topics: subscriptions.map { $0.topic }, token: token)
        }
    }

    func sync(baseUrl: String) {
        guard let token = storedDeviceToken() else { return }
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        let topics = Store.shared.relaySubscriptionSnapshot()
            .filter { $0.baseUrl == normalizedBaseUrl }
            .map { $0.topic }
        sync(baseUrl: normalizedBaseUrl, topics: topics, token: token)
    }

    func unregister(baseUrl: String, user: BasicUser?) {
        guard let token = storedDeviceToken() else { return }
        sendRegistration(baseUrl: normalizeBaseUrl(baseUrl), topics: [], token: token, user: user)
    }

    private func sync(baseUrl: String, topics: [String], token: String) {
        let user = Store.shared.getBasicUser(baseUrl: baseUrl)
        sendRegistration(baseUrl: baseUrl, topics: topics, token: token, user: user)
    }

    private func sendRegistration(baseUrl: String, topics: [String], token: String, user: BasicUser?) {
        guard let user else {
            Log.w(tag, "Skipping direct APNs registration for \(baseUrl): authenticated ntfy user required")
            return
        }
        guard let url = URL(string: normalizeBaseUrl(baseUrl) + Self.registrationPath) else {
            Log.w(tag, "Skipping direct APNs registration for invalid URL \(baseUrl)")
            return
        }
        let hashedTopics = Array(Set(topics.map { topicHash(baseUrl: baseUrl, topic: $0) })).sorted()
        let registration = RelayRegistration(
            deviceToken: token,
            environment: Self.apnsEnvironment,
            bundleId: Bundle.main.bundleIdentifier ?? "",
            topics: hashedTopics
        )
        guard let body = try? JSONEncoder().encode(registration) else {
            Log.w(tag, "Unable to encode direct APNs registration")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(user.toHeader(), forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { _, response, error in
            if let error {
                Log.w(self.tag, "Direct APNs registration failed for \(baseUrl)", error)
                return
            }
            guard let response = response as? HTTPURLResponse, response.statusCode == 204 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                Log.w(self.tag, "Direct APNs registration failed for \(baseUrl), HTTP \(status)")
                return
            }
            Log.d(self.tag, "Direct APNs registration updated for \(baseUrl), topics=\(hashedTopics.count)")
        }.resume()
    }

    private func storedDeviceToken() -> String? {
        guard let token = defaults.string(forKey: Self.deviceTokenKey), !token.isEmpty else {
            return nil
        }
        return token
    }

    private static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }
}

private struct RelayRegistration: Encodable {
    let deviceToken: String
    let environment: String
    let bundleId: String
    let topics: [String]

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case environment
        case bundleId = "bundle_id"
        case topics
    }
}
