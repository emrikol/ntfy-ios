import SwiftUI
import AppIntents

// TODO: Errors are not shown to the user, but instead just logged

@main
struct AppMain: App {
    private let tag = "AppMain"
    
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate: AppDelegate
    @StateObject private var store = Store.shared

    init() {
        Log.d(tag, "Launching ntfy 🥳. Welcome!")
        Log.d(tag, "Base URL is \(Config.appBaseUrl), user agent is \(ApiService.userAgent)")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(delegate)
                .environment(\.managedObjectContext, store.context)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Use this hook instead of applicationDidBecomeActive, see https://stackoverflow.com/a/68888509/1440785
                    // That post also explains how to start SwiftUI from AppDelegate if that's ever needed.
                    
                    Log.d(tag, "App became active, refreshing objects")
                    store.hardRefresh()
                    store.pruneExpiredNotifications()
                    delegate.refreshNotificationSettings()
                    DirectAPNSManager.shared.syncAll()
                }
        }
    }
}

@available(iOS 16.0, *)
struct NtfyTopicEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "ntfy topic")
    static var defaultQuery = NtfyTopicEntityQuery()

    let id: String
    let displayName: String
    let server: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(displayName)",
            subtitle: "\(server)",
            image: .init(systemName: symbolName)
        )
    }
}

@available(iOS 16.0, *)
struct NtfyTopicEntityQuery: EntityQuery {
    func entities(for identifiers: [NtfyTopicEntity.ID]) async throws -> [NtfyTopicEntity] {
        topicEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [NtfyTopicEntity] {
        topicEntities()
    }

    private func topicEntities() -> [NtfyTopicEntity] {
        (Store.shared.getSubscriptions() ?? []).compactMap { subscription in
            guard let baseUrl = subscription.baseUrl, let topic = subscription.topic else { return nil }
            let policy = TopicPolicyStore.shared.policy(baseUrl: baseUrl, topic: topic)
            return NtfyTopicEntity(
                id: policy.id,
                displayName: policy.displayName,
                server: shortUrl(url: baseUrl),
                symbolName: policy.symbolName
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

@available(iOS 16.0, *)
struct NtfyFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Filter ntfy Topics"
    static var description = IntentDescription("Choose which ntfy topics can notify you while this Focus is active.")

    @Parameter(title: "Allowed Topics")
    var topics: [NtfyTopicEntity]?

    var displayRepresentation: DisplayRepresentation {
        let count = topics?.count ?? 0
        return DisplayRepresentation(
            title: "ntfy Topics",
            subtitle: count == 0 ? "Allow all topics" : "Allow \(count) selected"
        )
    }

    var appContext: FocusFilterAppContext {
        let predicate: NSPredicate
        if let topics, !topics.isEmpty {
            predicate = NSPredicate(format: "SELF IN %@", topics.map(\.id))
        } else {
            predicate = NSPredicate(value: true)
        }
        return FocusFilterAppContext(notificationFilterPredicate: predicate)
    }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
