import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum ActiveAlert {
    case clear, unsubscribe, selected
}


struct NotificationListView: View {
    private let tag = "NotificationListView"
    
    @EnvironmentObject private var delegate: AppDelegate
    @EnvironmentObject private var store: Store
    
    @ObservedObject var subscription: Subscription
    @ObservedObject var notificationsModel: NotificationsObservable
    
    @State private var editMode = EditMode.inactive
    @State private var selection = Set<Notification>()
    
    @State private var showAlert = false
    @State private var activeAlert: ActiveAlert = .clear
    @State private var showCopiedConfirmation = false
    @State private var showTopicSettings = false
    @State private var searchText = ""
    @State private var showUnreadOnly = false
    @State private var policyRevision = UUID()
    
    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    init(subscription: Subscription) {
        self.subscription = subscription
        self.notificationsModel = NotificationsObservable(subscriptionID: subscription.objectID)
    }

    var body: some View {
        notificationList
            .refreshable {
                subscriptionManager.poll(subscription)
            }
    }
    
    private var notificationList: some View {
        Group {
            if editMode == .active {
                List(selection: $selection) {
                    notificationRows
                }
            } else {
                List {
                    notificationRows
                }
            }
        }
        .listStyle(PlainListStyle())
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, self.$editMode)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(subscription.displayName())
                    .font(.headline)
                    .lineLimit(1)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if (self.editMode == .active) {
                    editButton
                } else {
                    Menu {
                        if notificationsModel.notifications.count > 0 {
                            editButton
                        }
                        Button("Send test notification") {
                            self.sendTestNotification()
                        }
                        Button("Topic settings") {
                            self.showTopicSettings = true
                        }
                        Button(showUnreadOnly ? "Show all notifications" : "Show unread only") {
                            showUnreadOnly.toggle()
                        }
                        Button("Mark all as read") {
                            markAllRead()
                        }
                        if notificationsModel.notifications.count > 0 {
                            Button("Clear all notifications") {
                                self.showAlert = true
                                self.activeAlert = .clear
                            }
                        }
                        Button("Unsubscribe") {
                            self.showAlert = true
                            self.activeAlert = .unsubscribe
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .padding([.leading], 40)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                if (self.editMode == .active) {
                    Button(action: {
                        self.showAlert = true
                        self.activeAlert = .selected
                    }) {
                        Text("Delete")
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search notifications")
        .sheet(isPresented: $showTopicSettings) {
            TopicSettingsView(subscription: subscription)
                .environmentObject(store)
                .environmentObject(delegate)
        }
        .alert(isPresented: $showAlert) {
            switch activeAlert {
            case .clear:
                return Alert(
                    title: Text("Clear notifications"),
                    message: Text("Do you really want to delete all of the notifications in this topic?"),
                    primaryButton: .destructive(
                        Text("Permanently delete"),
                        action: deleteAll
                    ),
                    secondaryButton: .cancel())
            case .unsubscribe:
                return Alert(
                    title: Text("Unsubscribe"),
                    message: Text("Do you really want to unsubscribe from this topic and delete all of the notifications you received?"),
                    primaryButton: .destructive(
                        Text("Unsubscribe"),
                        action: unsubscribe
                    ),
                    secondaryButton: .cancel())
            case .selected:
                return Alert(
                    title: Text("Delete"),
                    message: Text("Do you really want to delete these selected notifications?"),
                    primaryButton: .destructive(
                        Text("Delete"),
                        action: deleteSelected
                    ),
                    secondaryButton: .cancel())
            }
        }
        .overlay(Group {
            if filteredNotifications.isEmpty {
                VStack {
                    Text(emptyStateTitle)
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom)
                    
                    if notificationsModel.notifications.isEmpty {
                        Text("To send notifications to this topic, simply PUT or POST to the topic URL.\n\nExample:\n`$ curl -d \"hi\" ntfy.sh/\(subscription.topicName())`\n\nDetailed instructions are available on [ntfy.sh](https://ntfy.sh) and [in the docs](https://ntfy.sh/docs).")
                            .foregroundColor(.secondary)
                    }
                }
                .padding(40)
            }
        })
        .overlay(Group {
            if showCopiedConfirmation {
                Text("Copied to Clipboard")
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.cornerRadius(20))
                    .shadow(radius: 5)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        })
        .onAppear {
            cancelSubscriptionNotifications()
        }
        .onDisappear {
            markAllRead()
            if delegate.selectedBaseUrl == subscription.urlString() {
                delegate.selectedBaseUrl = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TopicPolicyStore.didChange)) { _ in
            policyRevision = UUID()
        }
    }
    
    @ViewBuilder
    private var notificationRows: some View {
        ForEach(filteredNotifications, id: \.self) { notification in
            NotificationRowView(
                notification: notification,
                onCopyMessage: showCopyConfirmation
            )
        }
    }

    private var filteredNotifications: [Notification] {
        let policy = TopicPolicyStore.shared.policy(
            baseUrl: subscription.baseUrl ?? Config.appBaseUrl,
            topic: subscription.topicName()
        )
        return notificationsModel.notifications.filter { notification in
            let matchesUnread = !showUnreadOnly || notification.time > policy.lastReadTime
            let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = trimmedQuery.isEmpty || [notification.title, notification.message, notification.tags]
                .compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            return matchesUnread && matchesSearch
        }
    }

    private var emptyStateTitle: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No notifications match your search."
        }
        if showUnreadOnly {
            return "You're all caught up."
        }
        return "You haven't received any notifications for this topic yet."
    }
    
    private var editButton: some View {
        if editMode == .inactive {
            return Button(action: {
                self.editMode = .active
                self.selection = Set<Notification>()
            }) {
                Text("Select messages")
            }
        } else {
            return Button(action: {
                self.editMode = .inactive
                self.selection = Set<Notification>()
            }) {
                Text("Done")
            }
        }
    }
    
    private func sendTestNotification() {
        guard let baseUrl = subscription.baseUrl else {
            Log.w(tag, "Cannot send test notification: subscription base URL is missing")
            return
        }

        let possibleTags: Array<String> = ["warning", "skull", "success", "triangular_flag_on_post", "de", "us", "dog", "cat", "rotating_light", "bike", "backup", "rsync", "this-s-a-tag", "ios"]
        let priority = Int.random(in: 1..<6)
        let tags = Array(possibleTags.shuffled().prefix(Int.random(in: 0..<4)))

        let user = store.getBasicUser(baseUrl: baseUrl)
        ApiService.shared.publish(
            subscription: subscription,
            user: user,
            message: "This is a test notification from the ntfy iOS app. It has a priority of \(priority). If you send another one, it may look different.",
            title: "Test: You can set a title if you like",
            priority: priority,
            tags: tags
        ) {
            DispatchQueue.main.async {
                subscriptionManager.poll(subscription)
            }
        }
    }
    
    private func unsubscribe() {
        subscriptionManager.unsubscribe(subscription)
        delegate.selectedBaseUrl = nil
    }
    
    private func deleteAll() {
        store.delete(allNotificationsFor: subscription)
    }
    
    private func deleteSelected() {
        store.delete(notifications: selection)
        selection = Set<Notification>()
        editMode = .inactive
    }
    
    private func cancelSubscriptionNotifications() {
        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { notification in
                    let userInfo = notification.request.content.userInfo
                    if let baseUrl = userInfo["base_url"] as? String, let topic = userInfo["topic"] as? String {
                        return baseUrl == subscription.baseUrl && topic == subscription.topic
                    }
                    return false
                }
                .map { notification in
                    notification.request.identifier
                }
            if !ids.isEmpty {
                Log.d(tag, "Cancelling \(ids.count) notification(s) from notification center")
                notificationCenter.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    private func markAllRead() {
        guard
            let baseUrl = subscription.baseUrl,
            let topic = subscription.topic,
            let newest = notificationsModel.notifications.map(\.time).max()
        else { return }
        TopicPolicyStore.shared.markRead(baseUrl: baseUrl, topic: topic, through: newest)
        policyRevision = UUID()
        UIApplication.shared.applicationIconBadgeNumber = store.unreadNotificationCount()
    }
    
    private func showCopyConfirmation() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showCopiedConfirmation = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showCopiedConfirmation = false
            }
        }
    }
    
}

private enum TopicMuteSelection: String, CaseIterable, Identifiable {
    case off
    case oneHour
    case tonight
    case tomorrow
    case indefinitely
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .oneHour: return "For 1 hour"
        case .tonight: return "Until tomorrow morning"
        case .tomorrow: return "For 24 hours"
        case .indefinitely: return "Indefinitely"
        case .custom: return "Until a date"
        }
    }
}

struct TopicSettingsView: View {
    private static let symbols = [
        "bell", "exclamationmark.triangle", "server.rack", "externaldrive",
        "house", "lock.shield", "network", "bolt", "waveform.path.ecg",
        "shippingbox", "person", "briefcase", "gearshape", "checkmark.circle"
    ]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @ObservedObject var subscription: Subscription
    @State private var policy: TopicPolicy
    @State private var muteSelection: TopicMuteSelection
    @State private var customMuteDate: Date

    init(subscription: Subscription) {
        self.subscription = subscription
        let loaded = TopicPolicyStore.shared.policy(
            baseUrl: subscription.baseUrl ?? Config.appBaseUrl,
            topic: subscription.topicName()
        )
        _policy = State(initialValue: loaded)
        if let mutedUntil = loaded.mutedUntil, mutedUntil > Date() {
            if mutedUntil > Date().addingTimeInterval(60 * 60 * 24 * 365 * 20) {
                _muteSelection = State(initialValue: .indefinitely)
            } else {
                _muteSelection = State(initialValue: .custom)
            }
            _customMuteDate = State(initialValue: mutedUntil)
        } else {
            _muteSelection = State(initialValue: .off)
            _customMuteDate = State(initialValue: Date().addingTimeInterval(60 * 60))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Topic") {
                    TextField("Display name", text: $policy.alias)
                        .textInputAutocapitalization(.words)
                    Picker("Icon", selection: $policy.symbolName) {
                        ForEach(Self.symbols, id: \.self) { symbol in
                            Label(symbolLabel(symbol), systemImage: symbol)
                                .tag(symbol)
                        }
                    }
                }

                Section(
                    header: Text("Delivery"),
                    footer: Text("\(policy.alertMode.detail) Apple exposes only the system default notification sound to apps; any app-wide sound choice is managed in iOS Settings.")
                ) {
                    Picker("Alert style", selection: $policy.alertMode) {
                        ForEach(TopicAlertMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("Sound", selection: $policy.soundMode) {
                        ForEach(TopicSoundMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Button("Open iOS Notification Settings") {
                        delegate.openNotificationSettings()
                    }
                }

                Section(
                    header: Text("Mute"),
                    footer: Text("Muted topics still appear in Notification Center, without sound or an interruption.")
                ) {
                    Picker("Mute", selection: $muteSelection) {
                        ForEach(TopicMuteSelection.allCases) { selection in
                            Text(selection.label).tag(selection)
                        }
                    }
                    .onChange(of: muteSelection) { newValue in
                        applyMuteSelection(newValue)
                    }
                    if muteSelection == .custom {
                        DatePicker(
                            "Muted until",
                            selection: $customMuteDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .onChange(of: customMuteDate) { newValue in
                            policy.mutedUntil = newValue
                        }
                    }
                }

                Section(
                    header: Text("Privacy"),
                    footer: Text("iOS notification preview settings can hide additional content for the entire app.")
                ) {
                    Picker("Notification preview", selection: $policy.previewMode) {
                        ForEach(TopicPreviewMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section(
                    header: Text("History"),
                    footer: Text("Retention is applied locally on this iPhone. It does not delete messages from the ntfy server.")
                ) {
                    Picker("Keep notifications", selection: $policy.retentionDays) {
                        Text("Forever").tag(0)
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                }

                Section(
                    header: Text("Focus"),
                    footer: Text("Add the ntfy filter inside an iOS Focus to choose which topics that Focus allows.")
                ) {
                    Label("Managed by iOS Focus", systemImage: "moon.circle")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Topic settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        TopicPolicyStore.shared.save(policy)
                        store.pruneExpiredNotifications()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func applyMuteSelection(_ selection: TopicMuteSelection) {
        let calendar = Calendar.current
        switch selection {
        case .off:
            policy.mutedUntil = nil
        case .oneHour:
            policy.mutedUntil = Date().addingTimeInterval(60 * 60)
        case .tonight:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)
            policy.mutedUntil = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
        case .tomorrow:
            policy.mutedUntil = Date().addingTimeInterval(86_400)
        case .indefinitely:
            policy.mutedUntil = Date().addingTimeInterval(60 * 60 * 24 * 365 * 100)
        case .custom:
            policy.mutedUntil = customMuteDate
        }
    }

    private func symbolLabel(_ symbol: String) -> String {
        switch symbol {
        case "bell": return "Bell"
        case "exclamationmark.triangle": return "Warning"
        case "server.rack": return "Server"
        case "externaldrive": return "Drive"
        case "house": return "Home"
        case "lock.shield": return "Security"
        case "network": return "Network"
        case "bolt": return "Power"
        case "waveform.path.ecg": return "Health"
        case "shippingbox": return "Package"
        case "person": return "Person"
        case "briefcase": return "Work"
        case "gearshape": return "System"
        case "checkmark.circle": return "Success"
        default: return "Topic"
        }
    }
}

struct NotificationListView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview
        Group {
            let subscriptionWithNotifications = store.makeSubscription(store.context, "stats", Store.sampleMessages["stats"]!)
            let subscriptionWithoutNotifications = store.makeSubscription(store.context, "announcements", Store.sampleMessages["announcements"]!)
            NotificationListView(subscription: subscriptionWithNotifications)
                .environment(\.managedObjectContext, store.context)
                .environmentObject(store)
            NotificationListView(subscription: subscriptionWithoutNotifications)
                .environment(\.managedObjectContext, store.context)
                .environmentObject(store)
        }
    }
}
