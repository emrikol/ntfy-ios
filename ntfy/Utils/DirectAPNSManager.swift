import Foundation

/// Registers this app's APNs token and hashed ntfy subscriptions with a direct APNs relay
/// hosted alongside each self-hosted ntfy server.
final class DirectAPNSManager {
    static let shared = DirectAPNSManager()

    private static let registrationPath = "/_ntfy_apns/v1/registrations"
    private static let deviceTokenKey = "directAPNSDeviceToken"
    private static let registeredBaseUrlsKey = "directAPNSRegisteredBaseUrls"
    private static let pendingCredentialDeletionKey = "directAPNSPendingCredentialDeletion"
    private let tag = "DirectAPNSManager"
    private let defaults = UserDefaults(suiteName: Store.appGroup)!
    private let defaultsLock = NSLock()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    func updateDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        defaultsLock.lock()
        defaults.set(token, forKey: Self.deviceTokenKey)
        defaultsLock.unlock()
        Log.d(tag, "APNs token received: \(token.prefix(12))...")
        syncAll()
    }

    func syncAll() {
        guard let token = storedDeviceToken() else {
            Log.d(tag, "Skipping relay sync until APNs supplies a device token")
            return
        }
        guard
            let subscriptions = Store.shared.relaySubscriptionSnapshot(),
            let credentialBaseUrls = Store.shared.relayCredentialBaseUrlsSnapshot()
        else {
            Log.w(tag, "Skipping relay sync because the local store is unavailable")
            return
        }
        let grouped = Dictionary(grouping: subscriptions) { $0.baseUrl }
        let allBaseUrls = Set(grouped.keys)
            .union(credentialBaseUrls)
            .union(registeredBaseUrls())
        allBaseUrls.forEach { baseUrl in
            sync(baseUrl: baseUrl, topics: grouped[baseUrl]?.map { $0.topic } ?? [], token: token)
        }
    }

    func sync(baseUrl: String) {
        guard let token = storedDeviceToken() else { return }
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        guard let snapshot = Store.shared.relaySubscriptionSnapshot() else {
            Log.w(tag, "Skipping relay sync for \(normalizedBaseUrl) because the local store is unavailable")
            return
        }
        let topics = snapshot
            .filter { $0.baseUrl == normalizedBaseUrl }
            .map { $0.topic }
        sync(baseUrl: normalizedBaseUrl, topics: topics, token: token)
    }

    func unregister(baseUrl: String, user: BasicUser?, removeCredentialAfterSuccess: Bool = false) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        if let user {
            do {
                try CredentialStore.shared.save(baseUrl: normalizedBaseUrl, user: user)
            } catch {
                Log.w(tag, "Unable to retain credentials for relay unregistration", error)
            }
        }
        if removeCredentialAfterSuccess {
            updateStoredBaseUrl(normalizedBaseUrl, key: Self.pendingCredentialDeletionKey, insert: true)
        }
        updateStoredBaseUrl(normalizedBaseUrl, key: Self.registeredBaseUrlsKey, insert: true)
        guard let token = storedDeviceToken() else {
            Log.d(tag, "Queued relay unregistration until APNs supplies a device token")
            return
        }
        sendRegistration(baseUrl: normalizedBaseUrl, topics: [], token: token, user: user)
    }

    private func sync(baseUrl: String, topics: [String], token: String) {
        let user = Store.shared.getBasicUser(baseUrl: baseUrl) ?? CredentialStore.shared.load(baseUrl: baseUrl)
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
        updateStoredBaseUrl(baseUrl, key: Self.registeredBaseUrlsKey, insert: true)
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
            if hashedTopics.isEmpty {
                self.updateStoredBaseUrl(baseUrl, key: Self.registeredBaseUrlsKey, insert: false)
                if self.storedBaseUrls(key: Self.pendingCredentialDeletionKey).contains(baseUrl) {
                    CredentialStore.shared.delete(baseUrl: baseUrl)
                    self.updateStoredBaseUrl(baseUrl, key: Self.pendingCredentialDeletionKey, insert: false)
                }
            } else {
                self.updateStoredBaseUrl(baseUrl, key: Self.pendingCredentialDeletionKey, insert: false)
            }
            Log.d(self.tag, "Direct APNs registration updated for \(baseUrl), topics=\(hashedTopics.count)")
        }.resume()
    }

    private func storedDeviceToken() -> String? {
        defaultsLock.lock()
        defer { defaultsLock.unlock() }
        guard let token = defaults.string(forKey: Self.deviceTokenKey), !token.isEmpty else {
            return nil
        }
        return token
    }

    private func registeredBaseUrls() -> Set<String> {
        storedBaseUrls(key: Self.registeredBaseUrlsKey)
    }

    private func storedBaseUrls(key: String) -> Set<String> {
        defaultsLock.lock()
        defer { defaultsLock.unlock() }
        return storedBaseUrlsWithoutLock(key: key)
    }

    private func updateStoredBaseUrl(_ baseUrl: String, key: String, insert: Bool) {
        defaultsLock.lock()
        defer { defaultsLock.unlock() }
        var values = storedBaseUrlsWithoutLock(key: key)
        if insert {
            values.insert(normalizeBaseUrl(baseUrl))
        } else {
            values.remove(normalizeBaseUrl(baseUrl))
        }
        defaults.set(Array(values).sorted(), forKey: key)
    }

    private func storedBaseUrlsWithoutLock(key: String) -> Set<String> {
        Set((defaults.stringArray(forKey: key) ?? []).map(normalizeBaseUrl))
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
