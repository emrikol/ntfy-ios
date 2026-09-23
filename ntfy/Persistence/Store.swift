import Foundation
import CoreData
import Combine

/// Handles all persistence in the app by storing/loading subscriptions and notifications using Core Data.
/// There are sadly a lot of hacks in here, because I don't quite understand this fully.
class Store: ObservableObject {
    private enum Constants {
        static let kilobyte: Int64 = 1024
        static let megabyte = kilobyte * 1024

        static let autoDownloadNever: Int64 = 0
        static let autoDownloadAlways: Int64 = 1
        static let autoDownload100KB = 100 * kilobyte
        static let autoDownload500KB = 500 * kilobyte
        static let autoDownloadDefault = megabyte
        static let autoDownload5MB = 5 * megabyte
        static let autoDownload10MB = 10 * megabyte
        static let autoDownload50MB = 50 * megabyte
    }

    static let shared = Store()
    static let tag = "Store"
    static let appGroup = "group.com.emrikol.ntfy" // Must match app group of ntfy = ntfyNSE targets
    static let modelName = "ntfy" // Must match .xdatamodeld folder
    static let prefKeyDefaultBaseUrl = "defaultBaseUrl"
    static let prefKeyAttachmentAutoDownloadMaxSize = "attachmentAutoDownloadMaxSize"
    static let prefKeyCriticalAlertsEnabled = "criticalAlertsEnabled"
    static let autoDownloadNever = Constants.autoDownloadNever
    static let autoDownloadAlways = Constants.autoDownloadAlways
    static let autoDownload100KB = Constants.autoDownload100KB
    static let autoDownload500KB = Constants.autoDownload500KB
    static let autoDownloadDefault = Constants.autoDownloadDefault
    static let autoDownload5MB = Constants.autoDownload5MB
    static let autoDownload10MB = Constants.autoDownload10MB
    static let autoDownload50MB = Constants.autoDownload50MB
    private static let sharedDefaults = UserDefaults(suiteName: Store.appGroup)!
    private static let sharedDefaultsKeyCriticalAlertsAuthorized = "criticalAlertsAuthorized"
    private let container: NSPersistentContainer
    var context: NSManagedObjectContext {
        return container.viewContext
    }
    private var cancellables: Set<AnyCancellable> = []

    init(inMemory: Bool = false) {
        let description: NSPersistentStoreDescription
        if inMemory {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        } else if let containerUrl = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Store.appGroup) {
            description = NSPersistentStoreDescription(url: containerUrl.appendingPathComponent("ntfy.sqlite"))
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        } else {
            Log.e(Store.tag, "App group \(Store.appGroup) unavailable, using a non-persistent store")
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
        }
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true

        // Set up container and observe changes from app extension
        container = NSPersistentContainer(name: Store.modelName)
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { description, error in
            if let error = error {
                Log.e(Store.tag, "Core Data failed to load: \(error.localizedDescription)", error)
            }
        }
        
        // Shortcut for context
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType) // https://stackoverflow.com/a/60362945/1440785
        context.transactionAuthor = Bundle.main.bundlePath.hasSuffix(".appex") ? "ntfy.appex" : "ntfy"
        
        // When a remote change comes in (= the app extension updated entities in Core Data),
        // we force refresh the view with horrible means. Please help me make this better!
        NotificationCenter.default
          .publisher(for: .NSPersistentStoreRemoteChange)
          .sink { value in
              // TODO: this could probably broadcast the name of the channel
              // so that only relevant views can update.
              Log.d(Store.tag, "Remote change detected, refreshing views", value)

              DispatchQueue.main.async {
                  self.hardRefresh()
              }
          }
          .store(in: &cancellables)
    }
    
    func rollbackAndRefresh() {
        // Hack: We refresh all objects, since failing to store a notification usually means
        // that the app extension stored the notification first. This is a way to update the
        // UI properly when it is in the foreground and the app extension stores a notification.
        
        context.rollback()
        hardRefresh()
    }

    func hardRefresh() {
        // `refreshAllObjects` only refreshes objects from which the cache is invalid. With a staleness intervall of -1 the cache never invalidates.
        // We set the `stalenessInterval` to 0 to make sure that changes in the app extension get processed correctly.
        // From: https://www.avanderlee.com/swift/core-data-app-extension-data-sharing/
        
        context.performAndWait {
            context.stalenessInterval = 0
            context.refreshAllObjects()
            context.stalenessInterval = -1
        }
    }

    // MARK: Subscriptions
    
    func saveSubscription(baseUrl: String, topic: String) -> Subscription {
        var savedSubscription: Subscription!
        context.performAndWait {
            let subscription = Subscription(context: context)
            subscription.baseUrl = normalizeBaseUrl(baseUrl)
            subscription.topic = topic
            Log.d(Store.tag, "Storing subscription baseUrl=\(subscription.baseUrl ?? "?"), topic=\(topic)")
            try? context.save()
            savedSubscription = subscription
        }
        return savedSubscription
    }
    
    func getSubscription(baseUrl: String, topic: String) -> Subscription? {
        var subscription: Subscription?
        context.performAndWait {
            subscription = try? fetchSubscription(baseUrl: baseUrl, topic: topic)
        }
        return subscription
    }
    
    func getSubscriptions() -> [Subscription]? {
        guard hasLoadedPersistentStore else {
            Log.w(Store.tag, "Cannot read subscriptions: no persistent store is loaded")
            return nil
        }
        var subscriptions: [Subscription]?
        context.performAndWait {
            subscriptions = try? context.fetch(Subscription.fetchRequest())
        }
        return subscriptions
    }

    func relaySubscriptionSnapshot() -> [(baseUrl: String, topic: String)]? {
        guard hasLoadedPersistentStore else {
            Log.w(Store.tag, "Cannot create relay subscription snapshot: no persistent store is loaded")
            return nil
        }
        var snapshot: [(baseUrl: String, topic: String)] = []
        var succeeded = false
        context.performAndWait {
            guard let subscriptions = try? context.fetch(Subscription.fetchRequest()) else {
                return
            }
            snapshot = subscriptions.compactMap { subscription in
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
                return (normalizeBaseUrl(baseUrl), topic)
            }
            succeeded = true
        }
        return succeeded ? snapshot : nil
    }

    func relayCredentialBaseUrlsSnapshot() -> Set<String>? {
        guard hasLoadedPersistentStore else {
            Log.w(Store.tag, "Cannot create relay credential snapshot: no persistent store is loaded")
            return nil
        }
        var snapshot = Set<String>()
        var succeeded = false
        context.performAndWait {
            guard let users = try? context.fetch(User.fetchRequest()) else {
                return
            }
            snapshot = Set(users.compactMap(\.baseUrl).map(normalizeBaseUrl))
            succeeded = true
        }
        return succeeded ? snapshot : nil
    }

    func lastNotificationId(baseUrl: String, topic: String) -> String? {
        var notificationId: String?
        context.performAndWait {
            notificationId = try? fetchSubscription(baseUrl: baseUrl, topic: topic)?.lastNotificationId
        }
        return notificationId
    }

    func completeAttachmentDownload(notificationID: String, localPath: String, resolvedType: String?, resolvedSize: Int64) {
        context.performAndWait {
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id = %@", notificationID)
            guard let notification = try? context.fetch(request).first else {
                return
            }

            notification.attachmentLocalPath = localPath
            notification.attachmentProgress = AttachmentProgressState.done.persistedValue
            if resolvedSize > 0 {
                notification.attachmentSize = resolvedSize
            }
            if let resolvedType, !resolvedType.isEmpty {
                notification.attachmentType = resolvedType
            }
            try? context.save()
        }
    }

    func delete(subscription: Subscription) {
        context.performAndWait {
            if let notifications = subscription.notifications {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                }
            }
            context.delete(subscription)
            try? context.save()
        }
    }
    
    // MARK: Notifications
    
    func save(notificationFromMessage message: Message, withSubscription subscription: Subscription) {
        save(notificationsFromMessages: [message], withSubscription: subscription)
    }

    func save(notificationFromMessage message: Message, baseUrl: String, topic: String) -> Bool {
        var didSave = false
        context.performAndWait {
            do {
                guard let subscription = try fetchSubscription(baseUrl: baseUrl, topic: topic) else {
                    return
                }
                try saveNotifications([message], withSubscription: subscription)
                didSave = true
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
        return didSave
    }

    func save(notificationsFromMessages messages: [Message], withSubscription subscription: Subscription) {
        guard !messages.isEmpty else { return }

        context.performAndWait {
            do {
                try saveNotifications(messages, withSubscription: subscription)
            } catch let error {
                Log.w(Store.tag, "Cannot store notifications (fromMessages)", error)
                rollbackAndRefresh()
            }
        }
    }

    @discardableResult
    func save(notificationsFromMessages messages: [Message], baseUrl: String, topic: String) -> Bool {
        guard !messages.isEmpty else { return true }

        var didSave = false
        context.performAndWait {
            do {
                guard let subscription = try fetchSubscription(baseUrl: baseUrl, topic: topic) else {
                    return
                }
                try saveNotifications(messages, withSubscription: subscription)
                didSave = true
            } catch let error {
                Log.w(Store.tag, "Cannot store notification backlog", error)
                context.rollback()
                hardRefresh()
            }
        }
        return didSave
    }
    
    func delete(notification: Notification) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting notification \(notification.id ?? "")")
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
            try? context.save()
        }
    }
    
    func delete(notifications: Set<Notification>) {
        context.performAndWait {
            Log.d(Store.tag, "Deleting \(notifications.count) notification(s)")
            do {
                notifications.forEach { notification in
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
    
    func delete(allNotificationsFor subscription: Subscription) {
        context.performAndWait {
            guard let notifications = subscription.notifications else { return }
            Log.d(Store.tag, "Deleting all \(notifications.count) notification(s) for subscription \(subscription.urlString())")
            do {
                notifications.forEach { notification in
                    guard let notification = notification as? Notification else { return }
                    deleteAttachmentLocalFile(for: notification)
                    context.delete(notification)
                }
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot delete notification(s)", error)
                rollbackAndRefresh()
            }
        }
    }
    
    // MARK: Users
    
    func saveUser(baseUrl: String, username: String, password: String) {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        context.performAndWait {
            do {
                let existingUser = try fetchUser(baseUrl: normalizedBaseUrl)
                let existingCredential = CredentialStore.shared.load(baseUrl: normalizedBaseUrl)
                let legacyPassword = existingUser?.password ?? ""
                let finalCredential: BasicUser
                if password.isEmpty, let existingCredential {
                    finalCredential = existingCredential
                } else if password.isEmpty, !legacyPassword.isEmpty {
                    finalCredential = BasicUser(username: existingUser?.username ?? username, password: legacyPassword)
                } else {
                    finalCredential = BasicUser(username: username, password: password)
                }
                try CredentialStore.shared.save(baseUrl: normalizedBaseUrl, user: finalCredential)

                let user = existingUser ?? User(context: context)
                user.baseUrl = normalizedBaseUrl
                user.username = finalCredential.username
                user.password = ""
                try context.save()
            } catch let error {
                Log.w(Store.tag, "Cannot store user", error)
                context.rollback()
                hardRefresh()
            }
        }
    }
    
    func getUser(baseUrl: String) -> User? {
        var user: User?
        context.performAndWait {
            user = try? fetchUser(baseUrl: baseUrl)
        }
        return user
    }

    func getBasicUser(baseUrl: String) -> BasicUser? {
        let normalizedBaseUrl = normalizeBaseUrl(baseUrl)
        if let credential = CredentialStore.shared.load(baseUrl: normalizedBaseUrl) {
            return credential
        }

        var basicUser: BasicUser?
        context.performAndWait {
            guard
                let user = try? fetchUser(baseUrl: normalizedBaseUrl),
                let legacyPassword = user.password,
                !legacyPassword.isEmpty
            else {
                return
            }
            let migrated = BasicUser(username: user.username ?? "", password: legacyPassword)
            do {
                try CredentialStore.shared.save(baseUrl: normalizedBaseUrl, user: migrated)
                user.password = ""
                try context.save()
                basicUser = migrated
                Log.d(Store.tag, "Migrated credentials for \(normalizedBaseUrl) to Keychain")
            } catch {
                Log.w(Store.tag, "Unable to migrate credentials for \(normalizedBaseUrl) to Keychain", error)
                basicUser = migrated
            }
        }
        return basicUser
    }

    func findSubscriptionMatch(forPollRequestTopic topic: String, preferredBaseUrl: String? = nil) -> (baseUrl: String, topic: String)? {
        var match: (baseUrl: String, topic: String)?
        context.performAndWait {
            guard let subscriptions = try? context.fetch(Subscription.fetchRequest()) else {
                Log.w(Store.tag, "\(#function): Can't find subscriptions with topic=\(topic)")
                return
            }
            let normalizedPreferredBaseUrl = preferredBaseUrl.map(normalizeBaseUrl)
            let normalizedDefaultBaseUrl = normalizeBaseUrl(Config.appBaseUrl)
            let matchingSubscriptions = subscriptions.filter {
                $0.urlHash() == topic || $0.topic == topic
            }
            Log.d(
                Store.tag,
                "\(#function) topic=\(topic) matched \(matchingSubscriptions.count) subscription(s)",
                matchingSubscriptions.compactMap { subscription -> String? in
                    guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else {
                        return nil
                    }
                    return topicUrl(baseUrl: baseUrl, topic: topic)
                }
            )

            let prioritizedMatch = matchingSubscriptions.first {
                guard let baseUrl = $0.baseUrl else {
                    return false
                }
                if let normalizedPreferredBaseUrl {
                    return normalizeBaseUrl(baseUrl) == normalizedPreferredBaseUrl
                }
                return false
            } ?? matchingSubscriptions.first {
                guard let baseUrl = $0.baseUrl, let subscriptionTopic = $0.topic else {
                    return false
                }
                return subscriptionTopic == topic && normalizeBaseUrl(baseUrl) == normalizedDefaultBaseUrl
            } ?? matchingSubscriptions.first

            match = prioritizedMatch.flatMap { subscription in
                guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else {
                    return nil
                }
                return (baseUrl, topic)
            }
            if match == nil {
                Log.w(
                    Store.tag,
                    "\(#function) No poll request subscription match topic=\(topic) and preferredBaseUrl=\(normalizedPreferredBaseUrl ?? "<nil>")"
                )
            }
        }
        return match
    }
    
    func delete(user: User, deleteCredential: Bool = true) {
        let baseUrl = user.baseUrl
        context.performAndWait {
            context.delete(user)
            try? context.save()
        }
        if deleteCredential, let baseUrl {
            CredentialStore.shared.delete(baseUrl: baseUrl)
        }
    }
    
    // MARK: Preferences
    
    func saveDefaultBaseUrl(baseUrl: String?) {
        do {
            let pref = getPreference(key: Store.prefKeyDefaultBaseUrl) ?? Preference(context: context)
            pref.key = Store.prefKeyDefaultBaseUrl
            pref.value = baseUrl.map(normalizeBaseUrl) ?? Config.appBaseUrl
            try context.save()
        } catch let error {
            Log.w(Store.tag, "Cannot store preference", error)
            rollbackAndRefresh()
        }
    }
    
    func getDefaultBaseUrl() -> String {
        let baseUrl = getPreference(key: Store.prefKeyDefaultBaseUrl)?.value
        if baseUrl == nil || baseUrl?.isEmpty == true {
            return Config.appBaseUrl
        }
        return normalizeBaseUrl(baseUrl!)
    }

    func getAttachmentAutoDownloadMaxSize() -> Int64 {
        guard
            let rawValue = getPreference(key: Store.prefKeyAttachmentAutoDownloadMaxSize)?.value,
            let maxSize = Int64(rawValue)
        else {
            return Store.autoDownloadDefault
        }
        return maxSize
    }

    func saveAttachmentAutoDownloadMaxSize(_ maxSize: Int64) {
        do {
            let pref = getPreference(key: Store.prefKeyAttachmentAutoDownloadMaxSize) ?? Preference(context: context)
            pref.key = Store.prefKeyAttachmentAutoDownloadMaxSize
            pref.value = String(maxSize)
            try context.save()
        } catch let error {
            Log.w(Store.tag, "Cannot store attachment auto-download preference", error)
            rollbackAndRefresh()
        }
    }

    func getCriticalAlertsEnabled() -> Bool {
        getPreference(key: Store.prefKeyCriticalAlertsEnabled)?.value == "true"
    }

    func saveCriticalAlertsEnabled(_ enabled: Bool) {
        do {
            let pref = getPreference(key: Store.prefKeyCriticalAlertsEnabled) ?? Preference(context: context)
            pref.key = Store.prefKeyCriticalAlertsEnabled
            pref.value = String(enabled)
            try context.save()
        } catch let error {
            Log.w(Store.tag, "Cannot store critical alerts preference", error)
            rollbackAndRefresh()
        }
    }

    static func getCriticalAlertsAuthorized() -> Bool {
        sharedDefaults.bool(forKey: sharedDefaultsKeyCriticalAlertsAuthorized)
    }

    static func saveCriticalAlertsAuthorized(_ enabled: Bool) {
        sharedDefaults.set(enabled, forKey: sharedDefaultsKeyCriticalAlertsAuthorized)
    }

    func shouldAutoDownloadAttachment(_ attachment: MessageAttachment) -> Bool {
        if attachment.isExpired() {
            return false
        }

        let maxSize = getAttachmentAutoDownloadMaxSize()
        if maxSize == Store.autoDownloadNever {
            return false
        }
        if maxSize == Store.autoDownloadAlways {
            return true
        }
        guard let size = attachment.size else {
            return true
        }
        return size <= maxSize
    }

    func resolvedAttachmentAutoDownloadMaxSize() -> Int64? {
        let maxSize = getAttachmentAutoDownloadMaxSize()
        if maxSize == Store.autoDownloadAlways {
            return nil
        }
        return maxSize
    }
    
    private func getPreference(key: String) -> Preference? {
        let request = Preference.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "key = %@", key)])
        return try? context.fetch(request).first
    }

    private func fetchSubscription(baseUrl: String, topic: String) throws -> Subscription? {
        let fetchRequest = Subscription.fetchRequest()
        let baseUrlPredicate = NSPredicate(format: "baseUrl = %@", normalizeBaseUrl(baseUrl))
        let topicPredicate = NSPredicate(format: "topic = %@", topic)
        fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [baseUrlPredicate, topicPredicate])
        return try context.fetch(fetchRequest).first
    }

    private func fetchUser(baseUrl: String) throws -> User? {
        let request = User.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: "baseUrl = %@", normalizeBaseUrl(baseUrl))])
        return try context.fetch(request).first
    }

    private func saveNotifications(_ messages: [Message], withSubscription subscription: Subscription) throws {
        for message in messages {
            switch message.event {
            case "message":
                try applyMessage(message, to: subscription)
            case "message_delete":
                try deleteMessage(sequenceId: message.sequenceId, from: subscription)
            case "message_clear":
                Log.d(Store.tag, "Ignoring message_clear event for sequence \(message.sequenceId ?? "<unknown>")")
            default:
                Log.d(Store.tag, "Ignoring non-message event \(message.event)")
            }
            subscription.lastNotificationId = message.id
        }
        try context.save()
    }

    private func applyMessage(_ message: Message, to subscription: Subscription) throws {
        let request = Notification.fetchRequest()
        let subscriptionPredicate = NSPredicate(format: "subscription == %@", subscription)
        let identityPredicate: NSPredicate
        if let sequenceId = message.sequenceId {
            identityPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "sequenceId = %@", sequenceId),
                NSPredicate(format: "id = %@", sequenceId),
                NSPredicate(format: "id = %@", message.id)
            ])
        } else {
            identityPredicate = NSPredicate(format: "id = %@", message.id)
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            subscriptionPredicate,
            identityPredicate
        ])
        request.fetchLimit = 1
        let notification = try context.fetch(request).first ?? Notification(context: context)

        if
            let existingAttachmentUrl = notification.attachmentUrl,
            existingAttachmentUrl != message.attachment?.url
        {
            deleteAttachmentLocalFile(for: notification)
        }

        notification.id = message.id
        notification.sequenceId = message.sequenceId ?? message.id
        notification.time = message.time
        notification.message = message.message ?? ""
        notification.title = message.title ?? ""
        notification.priority = (message.priority != nil && message.priority != 0) ? message.priority! : 3
        notification.tags = message.tags?.joined(separator: ",") ?? ""
        notification.actions = Actions.shared.encode(message.actions)
        notification.click = message.click ?? ""
        notification.attachmentName = message.attachment?.name
        notification.attachmentType = message.attachment?.type
        notification.attachmentSize = message.attachment?.size ?? 0
        notification.attachmentExpires = message.attachment?.expires ?? 0
        notification.attachmentUrl = message.attachment?.url
        if
            let attachment = message.attachment,
            let remoteUrl = URL(string: attachment.url),
            let localFileUrl = AttachmentFileStore.existingLocalFileUrl(
                notificationID: message.id,
                remoteUrl: remoteUrl,
                attachment: attachment,
                mimeType: attachment.type
            )
        {
            notification.attachmentLocalPath = localFileUrl.path
            notification.attachmentProgress = AttachmentProgressState.done.persistedValue
        } else if notification.attachmentLocalPath == nil {
            notification.attachmentProgress = message.attachment == nil ? 0 : AttachmentProgressState.none.persistedValue
        }
        notification.subscription = subscription
        subscription.addToNotifications(notification)
        Log.d(Store.tag, "Stored notification with ID \(message.id), sequence=\(notification.sequenceId ?? message.id)")
    }

    private func deleteMessage(sequenceId: String?, from subscription: Subscription) throws {
        guard let sequenceId, !sequenceId.isEmpty else {
            Log.w(Store.tag, "Ignoring message_delete event without sequence_id")
            return
        }
        let request = Notification.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "subscription == %@", subscription),
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "sequenceId = %@", sequenceId),
                NSPredicate(format: "id = %@", sequenceId)
            ])
        ])
        for notification in try context.fetch(request) {
            deleteAttachmentLocalFile(for: notification)
            context.delete(notification)
        }
        Log.d(Store.tag, "Deleted notification sequence \(sequenceId)")
    }

    private var hasLoadedPersistentStore: Bool {
        !container.persistentStoreCoordinator.persistentStores.isEmpty
    }

    private func deleteAttachmentLocalFile(for notification: Notification) {
        if let localPath = notification.attachmentLocalPath, !localPath.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: localPath))
            notification.attachmentLocalPath = nil
        }
    }
}

extension Store {
    static let sampleMessages = [
        "stats": [
            // TODO: Message with action
            Message(id: "1", time: 1653048956, event: "message", topic: "stats", message: "In the last 24 hours, hyou had 5,000 users across 13 countries visit your website", title: "Record visitor numbers", priority: 4, tags: ["smile", "server123", "de"], actions: nil),
            Message(id: "2", time: 1653058956, event: "message", topic: "stats", message: "201 users/h\n80 IPs", title: "This is a title", priority: 1, tags: [], actions: nil),
            Message(id: "3", time: 1643058956, event: "message", topic: "stats", message: "This message does not have a title, but is instead super long. Like really really long. It can't be any longer I think. I mean, there is s 4,000 byte limit of the message, so I guess I have to make this 4,000 bytes long. Or do I? 😁 I don't know. It's quite tedious to come up with something so long, so I'll stop now. Bye!", title: nil, priority: 5, tags: ["facepalm"], actions: nil)
        ],
        "backups": [],
        "announcements": [],
        "alerts": [],
        "playground": []
    ]
    
    static var preview: Store = {
        let store = Store(inMemory: true)
        store.context.perform {
            // Subscriptions and notifications
            sampleMessages.forEach { topic, messages in
                store.makeSubscription(store.context, topic, messages)
            }
            
            // Users
            store.saveUser(baseUrl: "https://ntfy.sh", username: "testuser", password: "testuser")
            store.saveUser(baseUrl: "https://ntfy.example.com", username: "phil", password: "phil12")
        }
        return store
    }()
    
    static var previewEmpty: Store = {
        return Store(inMemory: true)
    }()
    
    @discardableResult
    func makeSubscription(_ context: NSManagedObjectContext, _ topic: String, _ messages: [Message]) -> Subscription {
        let notifications = messages.map { message in
            let notification = Notification(context: context)
            notification.id = message.id
            notification.time = message.time
            notification.message = message.message
            notification.title = message.title
            notification.priority = message.priority ?? 3
            notification.tags = message.tags?.joined(separator: ",") ?? ""
            notification.attachmentName = message.attachment?.name
            notification.attachmentType = message.attachment?.type
            notification.attachmentSize = message.attachment?.size ?? 0
            notification.attachmentExpires = message.attachment?.expires ?? 0
            notification.attachmentUrl = message.attachment?.url
            notification.attachmentProgress = message.attachment == nil ? 0 : AttachmentProgressState.none.persistedValue
            return notification
        }
        let subscription = Subscription(context: context)
        subscription.baseUrl = Config.appBaseUrl
        subscription.topic = topic
        subscription.notifications = NSSet(array: notifications)
        return subscription
    }
}
