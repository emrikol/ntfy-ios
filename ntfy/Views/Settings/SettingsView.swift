import Foundation
import SwiftUI
import StoreKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var delegate: AppDelegate
    @State private var userDialog: UserDialog?
    
    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text("General"),
                    footer: Text("When subscribing to new topics, this server will be used as a default.")
                ) {
                    DefaultServerView()
                }
                Section(
                    header: Text("Notifications"),
                    footer: Text("Automatically download attachments up to the selected size. Attachments larger than this limit must be downloaded manually.")
                ) {
                    NavigationLink {
                        NotificationDeliveryView()
                    } label: {
                        Label("Delivery & Diagnostics", systemImage: "bell.badge")
                    }
                    AttachmentAutoDownloadView()
                }
                if delegate.criticalAlertSetting != .notSupported {
                    Section(
                        footer: Text("Max priority notifications break through to grab your attention, appearing on the lock screen and playing a sound even when focus mode is on or your device is muted.")
                    ) {
                        CriticalAlertsSettingView()
                    }
                }
                Section(
                    header: Text("Users"),
                    footer: Text("To access read-protected topics, you may add or edit users here. All topics for a given server will use the same user.")
                ) {
                    UserTableView(dialog: $userDialog)
                }
                Section(header: Text("About")) {
                    AboutView()
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(item: $userDialog) { dialog in
            UserEditorView(
                selectedUser: dialog.user,
                onSave: { baseUrl, username, password in
                    store.saveUser(baseUrl: baseUrl, username: username, password: password)
                    DirectAPNSManager.shared.sync(baseUrl: baseUrl)
                    userDialog = nil
                },
                onDelete: { user in
                    if let baseUrl = user.baseUrl {
                        let credential = store.getBasicUser(baseUrl: baseUrl)
                        DirectAPNSManager.shared.unregister(
                            baseUrl: baseUrl,
                            user: credential,
                            removeCredentialAfterSuccess: true
                        )
                    }
                    store.delete(user: user, deleteCredential: false)
                    userDialog = nil
                },
                onCancel: {
                    userDialog = nil
                }
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct NotificationDeliveryView: View {
    @EnvironmentObject private var delegate: AppDelegate
    @State private var relayStatus = DirectAPNSManager.shared.status()
    @State private var testResult: String?

    var body: some View {
        Form {
            Section(
                header: Text("iOS permissions"),
                footer: Text("Time Sensitive alerts may pass through Focus. Critical Alerts also bypass the mute switch, but require a restricted entitlement from Apple.")
            ) {
                NotificationStatusRow(
                    title: "Notifications",
                    value: authorizationLabel(delegate.authorizationStatus),
                    enabled: delegate.authorizationStatus == .authorized || delegate.authorizationStatus == .provisional
                )
                NotificationStatusRow(title: "Alerts", setting: delegate.alertSetting)
                NotificationStatusRow(title: "Sounds", setting: delegate.soundSetting)
                NotificationStatusRow(title: "Time Sensitive", setting: delegate.timeSensitiveSetting)
                NotificationStatusRow(title: "Critical Alerts", setting: delegate.criticalAlertSetting)
                NotificationStatusRow(title: "Scheduled Summary", setting: delegate.scheduledDeliverySetting)
                Button("Open iOS Notification Settings") {
                    delegate.openNotificationSettings()
                }
            }

            Section(
                header: Text("Direct delivery"),
                footer: Text("Your self-hosted relay sends directly to Apple Push Notification service; Firebase is not used.")
            ) {
                NotificationStatusRow(
                    title: "APNs device token",
                    value: relayStatus.hasDeviceToken ? "Ready" : "Waiting",
                    enabled: relayStatus.hasDeviceToken
                )
                HStack {
                    Text("Last relay sync")
                    Spacer()
                    Text(relayStatus.lastSuccessfulSync?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                if let error = relayStatus.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.footnote)
                }
                Button("Sync now") {
                    DirectAPNSManager.shared.syncAll()
                    refreshRelayStatus(after: 0.8)
                }
            }

            Section(
                header: Text("Test delivery"),
                footer: Text("Tests arrive after one second. Lock the phone or leave ntfy open to verify the banner and sound behavior you expect.")
            ) {
                Button("Send standard alert") {
                    sendTest(.standard)
                }
                Button("Send Time Sensitive alert") {
                    sendTest(.timeSensitive)
                }
                Button("Send silent alert") {
                    sendTest(.silent)
                }
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Notification Delivery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            delegate.refreshNotificationSettings()
            relayStatus = DirectAPNSManager.shared.status()
        }
        .onReceive(NotificationCenter.default.publisher(for: .directAPNSStatusDidChange)) { _ in
            relayStatus = DirectAPNSManager.shared.status()
        }
    }

    private func sendTest(_ kind: NotificationDiagnosticKind) {
        delegate.sendDiagnosticNotification(kind) { error in
            DispatchQueue.main.async {
                testResult = error.map { "Could not schedule test: \($0.localizedDescription)" } ?? "Test scheduled."
            }
        }
    }

    private func refreshRelayStatus(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            relayStatus = DirectAPNSManager.shared.status()
        }
    }

    private func authorizationLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Allowed"
        case .provisional: return "Provisional"
        case .ephemeral: return "Temporary"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

private struct NotificationStatusRow: View {
    let title: String
    let value: String
    let enabled: Bool

    init(title: String, value: String, enabled: Bool) {
        self.title = title
        self.value = value
        self.enabled = enabled
    }

    init(title: String, setting: UNNotificationSetting) {
        self.title = title
        switch setting {
        case .enabled:
            self.value = "Enabled"
            self.enabled = true
        case .disabled:
            self.value = "Disabled"
            self.enabled = false
        case .notSupported:
            self.value = "Not available"
            self.enabled = false
        @unknown default:
            self.value = "Unknown"
            self.enabled = false
        }
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
            Image(systemName: enabled ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(enabled ? .green : .orange)
                .accessibilityHidden(true)
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        let store = Store.preview // Store.previewEmpty
        SettingsView()
            .environment(\.managedObjectContext, store.context)
            .environmentObject(store)
            .environmentObject(AppDelegate())
    }
}
