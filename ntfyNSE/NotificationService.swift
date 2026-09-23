import UserNotifications
import CoreData
import CryptoKit

/// This app extension is responsible for persisting the incoming notification to the data store (Core Data). It will eventually be the entity that
/// fetches notification content from selfhosted servers (when a "poll request" is received). This is not implemented yet.
///
/// Note that the app extension does not run as part of the main app, so log messages are not printed in the main Xcode window. To debug,
/// select Debug -> Attach to Process by PID or Name, and select the extension. Don't forget to set a breakpoint, or you're not gonna have a good time.
class NotificationService: UNNotificationServiceExtension {
    private let tag = "NotificationService"
    private var store: Store?
    
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.store = Store.shared
        self.contentHandler = contentHandler
        self.bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        if let bestAttemptContent = bestAttemptContent {
            let userInfo = bestAttemptContent.userInfo
            guard let message = Message.from(userInfo: userInfo) else {
                Log.w(tag, "Message cannot be parsed from userInfo", userInfo)
                contentHandler(request.content)
                return
            }
            Log.d(
                tag,
                "\(#function) event=\(message.event), topic=\(message.topic), pollId=\(message.pollId ?? "<nil>"), baseUrl=\(userInfo["base_url"] as? String ?? "<nil>")"
            )
            switch message.event {
            case "poll_request":
                handlePollRequest(request, bestAttemptContent, message, contentHandler)
            case "message":
                let baseUrl = userInfo["base_url"]  as? String ?? Config.appBaseUrl // messages only come for the main server
                handleMessage(request, bestAttemptContent, baseUrl, message, contentHandler)
            default:
                Log.w(tag, "Irrelevant message received", message)
                contentHandler(request.content)
            }
        }
    }
    
    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content,
        // otherwise the original push payload will be used.

        Log.w(tag, "\(#function): delivering best attempt content")
        if let contentHandler = contentHandler, let bestAttemptContent =  bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
    
    private func handleMessage(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ baseUrl: String, _ message: Message, _ contentHandler: @escaping (UNNotificationContent) -> Void) {
        // Save notification first so attachment downloads can update persistent state.
        guard store?.save(notificationFromMessage: message, baseUrl: baseUrl, topic: message.topic) == true else {
            Log.w(tag, "Subscription \(topicUrl(baseUrl: baseUrl, topic: message.topic)) unknown")
            contentHandler(request.content)
            return
        }
        let user = store?.getBasicUser(baseUrl: baseUrl)
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            contentHandler(content)
        }
    }
    
    private func handlePollRequest(_ request: UNNotificationRequest, _ content: UNMutableNotificationContent, _ pollRequest: Message, _ contentHandler: @escaping (UNNotificationContent) -> Void) {
        let pollId = pollRequest.pollId ?? pollRequest.id
        store?.hardRefresh()
        let preferredBaseUrl = bestAttemptContent?.userInfo["base_url"] as? String
        guard let subscription = store?.findSubscriptionMatch(
                forPollRequestTopic: pollRequest.topic,
                preferredBaseUrl: preferredBaseUrl
            )
        else {
            Log.w(tag, "Cannot find subscription for poll request topic=\(pollRequest.topic), pollId=\(pollRequest.pollId ?? "<nil>")")
            contentHandler(request.content)
            return
        }
        
        // Poll the entire backlog from the last persisted cursor. APNs may retain only the
        // newest push while a device is offline, so fetching only pollId can otherwise move
        // the cursor past every earlier cached notification (ntfy#868).
        let user = store?.getBasicUser(baseUrl: subscription.baseUrl)
        let since = store?.lastNotificationId(baseUrl: subscription.baseUrl, topic: subscription.topic) ?? "all"
        ApiService.shared.poll(baseUrl: subscription.baseUrl, topic: subscription.topic, since: since, user: user) { messages, error in
            guard let messages else {
                Log.w(self.tag, "Error fetching notification backlog topic=\(pollRequest.topic), since=\(since)", error)
                self.fetchSinglePollMessage(
                    request: request,
                    content: content,
                    baseUrl: subscription.baseUrl,
                    topic: subscription.topic,
                    pollId: pollId,
                    user: user,
                    contentHandler: contentHandler
                )
                return
            }

            if !messages.isEmpty {
                _ = self.store?.save(
                    notificationsFromMessages: messages,
                    baseUrl: subscription.baseUrl,
                    topic: subscription.topic
                )
            }
            if let requestedMessage = messages.first(where: { $0.id == pollId }) {
                self.presentPolledMessage(
                    request: request,
                    content: content,
                    baseUrl: subscription.baseUrl,
                    message: requestedMessage,
                    contentHandler: contentHandler
                )
            } else {
                // Another extension invocation may already have advanced the cursor. Fetch
                // the requested message directly so this push still has accurate content.
                self.fetchSinglePollMessage(
                    request: request,
                    content: content,
                    baseUrl: subscription.baseUrl,
                    topic: subscription.topic,
                    pollId: pollId,
                    user: user,
                    contentHandler: contentHandler
                )
            }
        }
    }

    private func fetchSinglePollMessage(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent,
        baseUrl: String,
        topic: String,
        pollId: String,
        user: BasicUser?,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        ApiService.shared.poll(baseUrl: baseUrl, topic: topic, messageId: pollId, user: user) { message, error in
            guard let message else {
                Log.w(self.tag, "Error fetching poll request message topic=\(topic), pollId=\(pollId)", error)
                contentHandler(request.content)
                return
            }
            _ = self.store?.save(notificationsFromMessages: [message], baseUrl: baseUrl, topic: topic)
            self.presentPolledMessage(
                request: request,
                content: content,
                baseUrl: baseUrl,
                message: message,
                contentHandler: contentHandler
            )
        }
    }

    private func presentPolledMessage(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent,
        baseUrl: String,
        message: Message,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard message.event == "message" else {
            handleControlEvent(request: request, content: content, baseUrl: baseUrl, message: message, contentHandler: contentHandler)
            return
        }
        let user = store?.getBasicUser(baseUrl: baseUrl)
        content.modify(message: message, baseUrl: baseUrl)
        content.attachImageIfNeeded(message: message, user: user) {
            contentHandler(content)
        }
    }

    private func handleControlEvent(
        request: UNNotificationRequest,
        content: UNMutableNotificationContent,
        baseUrl: String,
        message: Message,
        contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        if let sequenceId = message.sequenceId, !sequenceId.isEmpty {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { notifications in
                let identifiers = notifications.compactMap { delivered -> String? in
                    let userInfo = delivered.request.content.userInfo
                    let deliveredBaseUrl = userInfo["base_url"] as? String
                    let deliveredTopic = userInfo["topic"] as? String
                    let deliveredId = userInfo["id"] as? String
                    let deliveredSequenceId = userInfo["sequence_id"] as? String
                    guard
                        normalizeBaseUrl(deliveredBaseUrl ?? Config.appBaseUrl) == normalizeBaseUrl(baseUrl),
                        deliveredTopic == message.topic,
                        deliveredId == sequenceId || deliveredSequenceId == sequenceId
                    else {
                        return nil
                    }
                    return delivered.request.identifier
                }
                if !identifiers.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: identifiers)
                }
            }
        }

        // A service extension cannot cancel the incoming APNs notification. Make control
        // events passive and explicit instead of emitting a sounding, blank notification.
        content.title = topicShortUrl(baseUrl: baseUrl, topic: message.topic)
        content.body = message.event == "message_delete" ? "Notification deleted" : "Notification cleared"
        content.sound = nil
        content.interruptionLevel = .passive
        content.userInfo = message.toUserInfo()
        content.userInfo["base_url"] = baseUrl
        contentHandler(content)
    }
}
