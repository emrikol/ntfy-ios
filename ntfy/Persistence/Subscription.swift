import Foundation

enum TopicAlertMode: String, Codable, CaseIterable, Identifiable {
    case publisher
    case silent
    case active
    case timeSensitive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .publisher: return "Follow publisher priority"
        case .silent: return "Deliver quietly"
        case .active: return "Standard alert"
        case .timeSensitive: return "Time Sensitive"
        }
    }

    var detail: String {
        switch self {
        case .publisher: return "Use the priority sent with each ntfy message."
        case .silent: return "Show notifications without a sound or interruption."
        case .active: return "Always use a standard notification alert."
        case .timeSensitive: return "Allow notifications through Focus when iOS permits it."
        }
    }
}

enum TopicSoundMode: String, Codable, CaseIterable, Identifiable {
    case systemDefault
    case silent
    case systemTone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemDefault: return "System Default"
        case .silent: return "Silent"
        case .systemTone: return "System Tone"
        }
    }
}

enum TopicPreviewMode: String, Codable, CaseIterable, Identifiable {
    case full
    case titleOnly
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full message"
        case .titleOnly: return "Title only"
        case .hidden: return "Hidden"
        }
    }
}

struct TopicPolicy: Codable, Equatable, Identifiable {
    let baseUrl: String
    let topic: String
    var alias: String = ""
    var symbolName: String = "bell"
    var alertMode: TopicAlertMode = .publisher
    var soundMode: TopicSoundMode = .systemDefault
    var systemToneFileName: String?
    var systemToneDisplayName: String?
    var previewMode: TopicPreviewMode = .full
    var mutedUntil: Date?
    var retentionDays: Int = 0
    var lastReadTime: Int64 = 0

    var id: String { topicHash(baseUrl: baseUrl, topic: topic) }

    var isMuted: Bool {
        guard let mutedUntil else { return false }
        return mutedUntil > Date()
    }

    var displayName: String {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedAlias.isEmpty ? topicShortUrl(baseUrl: baseUrl, topic: topic) : trimmedAlias
    }
}

final class TopicPolicyStore {
    static let shared = TopicPolicyStore()
    static let didChange = Foundation.Notification.Name("TopicPolicyStoreDidChange")

    private static let policiesKey = "topicPoliciesV1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = UserDefaults(suiteName: Store.appGroup) ?? .standard) {
        self.defaults = defaults
    }

    func policy(baseUrl: String, topic: String) -> TopicPolicy {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        let id = topicHash(baseUrl: normalizedBaseUrl, topic: topic)
        lock.lock()
        defer { lock.unlock() }
        return loadWithoutLock()[id] ?? TopicPolicy(baseUrl: normalizedBaseUrl, topic: topic)
    }

    func save(_ policy: TopicPolicy) {
        lock.lock()
        var policies = loadWithoutLock()
        policies[policy.id] = policy
        saveWithoutLock(policies)
        lock.unlock()
        notifyChange()
    }

    func ensure(baseUrl: String, topic: String) {
        let policy = policy(baseUrl: baseUrl, topic: topic)
        save(policy)
    }

    func remove(baseUrl: String, topic: String) {
        let id = topicHash(baseUrl: baseUrl, topic: topic)
        lock.lock()
        var policies = loadWithoutLock()
        policies.removeValue(forKey: id)
        saveWithoutLock(policies)
        lock.unlock()
        notifyChange()
    }

    func allPolicies() -> [TopicPolicy] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadWithoutLock().values)
    }

    func markRead(baseUrl: String, topic: String, through time: Int64) {
        var policy = policy(baseUrl: baseUrl, topic: topic)
        policy.lastReadTime = max(policy.lastReadTime, time)
        save(policy)
    }

    private func loadWithoutLock() -> [String: TopicPolicy] {
        guard
            let data = defaults.data(forKey: Self.policiesKey),
            let policies = try? JSONDecoder().decode([String: TopicPolicy].self, from: data)
        else {
            return [:]
        }
        return policies
    }

    private func saveWithoutLock(_ policies: [String: TopicPolicy]) {
        guard let data = try? JSONEncoder().encode(policies) else { return }
        defaults.set(data, forKey: Self.policiesKey)
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}

extension Subscription {
    func urlString() -> String {
        return topicUrl(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }
    
    func displayName() -> String {
        guard let baseUrl, let topic else { return "?" }
        return TopicPolicyStore.shared.policy(baseUrl: baseUrl, topic: topic).displayName
    }
    
    func topicName() -> String {
        return topic ?? "?"
    }
    
    func urlHash() -> String {
        return topicHash(baseUrl: baseUrl ?? "?", topic: topic ?? "?")
    }
    
    func notificationCount() -> Int {
        return notifications?.count ?? 0
    }

    func unreadNotificationCount() -> Int {
        guard let baseUrl, let topic else { return 0 }
        let lastReadTime = TopicPolicyStore.shared.policy(baseUrl: baseUrl, topic: topic).lastReadTime
        return (notifications?.allObjects as? [Notification] ?? []).filter { $0.time > lastReadTime }.count
    }
    
    func lastNotification() -> Notification? {
        guard let notifications else {
            return nil
        }
        return notifications
            .sortedArray(using: [NSSortDescriptor(keyPath: \Notification.time, ascending: false)])
            .first as? Notification
    }
}
