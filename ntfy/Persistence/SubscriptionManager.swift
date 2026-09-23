import Foundation

/// Manager to combine persisting a subscription and updating the direct APNs relay.
/// This is to centralize the logic in one place.
struct SubscriptionManager {
    private let tag = "SubscriptionManager"
    var store: Store
    
    func subscribe(baseUrl: String, topic: String) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        Log.d(tag, "Subscribing to \(topicUrl(baseUrl: normalizedBaseUrl, topic: topic))")
        let subscription = store.saveSubscription(baseUrl: normalizedBaseUrl, topic: topic)
        DirectAPNSManager.shared.sync(baseUrl: normalizedBaseUrl)
        poll(subscription)
    }
    
    func unsubscribe(_ subscription: Subscription) {
        Log.d(tag, "Unsubscribing from \(subscription.urlString())")
        DispatchQueue.main.async {
            let baseUrl = subscription.baseUrl
            store.delete(subscription: subscription)
            if let baseUrl {
                DirectAPNSManager.shared.sync(baseUrl: baseUrl)
            }
        }
    }
    
    func poll(_ subscription: Subscription) {
        poll(subscription) { _ in }
    }
    
    func poll(_ subscription: Subscription, completionHandler: @escaping ([Message]) -> Void) {
        // This is a bit of a hack but it prevents us from polling dead subscriptions
        if (subscription.baseUrl == nil) {
            Log.d(tag, "Attempting to poll dead subscription failed")
            completionHandler([])
            return
        }
        
        let user = store.getBasicUser(baseUrl: subscription.baseUrl!)
        Log.d(tag, "Polling from \(subscription.urlString()) with user \(user?.displayName ?? "anonymous")")
        ApiService.shared.poll(subscription: subscription, user: user) { messages, error in
            guard let messages = messages else {
                Log.e(tag, "Polling failed", error)
                completionHandler([])
                return
            }
            Log.d(tag, "Polling success, \(messages.count) new message(s)", messages)
            if !messages.isEmpty {
                store.save(notificationsFromMessages: messages, withSubscription: subscription)
            }
            completionHandler(messages)
        }
    }
}
