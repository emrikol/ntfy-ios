import SwiftUI
import VisionKit

struct SubscriptionAddView: View {
    private let tag = "SubscriptionAddView"
    
    @Binding var isShowing: Bool
    
    @EnvironmentObject private var store: Store
    @State private var topic: String = ""
    @State private var useAnother: Bool = false
    @State private var baseUrl: String = ""
    
    @State private var showLogin: Bool = false
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useToken: Bool = false
    
    @State private var loading = false
    @State private var addError: String?
    @State private var loginError: String?
    @State private var showingScanner = false
    @State private var scannerError: String?

    private var subscriptionManager: SubscriptionManager {
        return SubscriptionManager(store: store)
    }
    
    var body: some View {
        NavigationView {
            // This is a little weird, but it works. The nagivation link for the login view
            // is rendered in the backgroun (it's hidden), abd we toggle it manually.
            // If anyone has a better way to do a two-page layout let me know.
            
            addView
                .background(Group {
                    NavigationLink(
                        destination: loginView,
                        isActive: $showLogin
                    ) {
                        EmptyView()
                    }
                })
        }
    }
    
    private var addView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section(
                    footer: Text("Topics may not be password-protected, so choose a name that's not easy to guess. Once subscribed, you can PUT/POST notifications")
                ) {
                    TextField("Topic name, e.g. phil_alerts", text: $topic)
                        .disableAutocapitalization()
                        .disableAutocorrection(true)
                    Button {
                        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                            scannerError = nil
                            showingScanner = true
                        } else {
                            scannerError = "QR scanning is not available on this device."
                        }
                    } label: {
                        Label("Scan subscription QR code", systemImage: "qrcode.viewfinder")
                    }
                }
                Section(
                    footer:
                        (useAnother) ? Text("To ensure instant delivery from your self-hosted server, be sure to set upstream-base-url in your server's config, otherwise messages may arrive with significant delay.") : Text("")
                ) {
                    Toggle("Use another server", isOn: $useAnother)
                    if useAnother {
                        TextField("Service URL, e.g. https://ntfy.home.io", text: $baseUrl)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                }
            }
            if let error = addError {
                ErrorView(error: error)
            }
            if let scannerError {
                ErrorView(error: scannerError)
            }
        }
        .navigationTitle("Add subscription")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: cancelAction) {
                    Text("Cancel")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: subscribeOrShowLoginAction) {
                    VStack {
                        if loading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Subscribe")
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)

                }
                .disabled(!isAddViewValid())
            }
        }
        .sheet(isPresented: $showingScanner) {
            NavigationStack {
                SubscriptionQRScannerView { value in
                    applyScannedSubscription(value)
                    showingScanner = false
                }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Scan ntfy subscription")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingScanner = false }
                    }
                }
            }
        }
    }
    
    private var loginView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("Authenticate using an access token", isOn: $useToken)
                }
                Section(
                    footer: Text(useToken
                        ? "Enter a revocable ntfy access token. It will be stored securely and reused for other topics on this server."
                        : "Enter your username and password. They will be stored securely and reused for other topics on this server.")
                ) {
                    if useToken {
                        SecureField("Access token", text: $password)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    } else {
                        TextField("Username", text: $username)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                        SecureField("Password", text: $password)
                    }
                }
            }
            if let error = loginError {
                ErrorView(error: error)
            }
        }
        .navigationTitle("Login required")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: subscribeWithUserAction) {
                    if loading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Text("Subscribe")
                    }
                }
                .disabled(!isLoginViewValid())
            }
        }
    }
    
    private var sanitizedTopic: String {
        return topic.trimmingCharacters(in: .whitespaces)
    }
    
    private func isAddViewValid() -> Bool {
        if sanitizedTopic.isEmpty {
            return false
        } else if sanitizedTopic.range(of: "^[-_A-Za-z0-9]{1,64}$", options: .regularExpression, range: nil, locale: nil) == nil {
            return false
        } else if selectedBaseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
            return false
        } else if store.getSubscription(baseUrl: selectedBaseUrl, topic: sanitizedTopic) != nil {
            return false
        }
        return true
    }
    
    private func isLoginViewValid() -> Bool {
        if password.isEmpty || (!useToken && username.isEmpty) {
            return false
        }
        return true
    }
    
    private func subscribeOrShowLoginAction() {
        loading = true
        addError = nil
        let user = store.getBasicUser(baseUrl: selectedBaseUrl)
        ApiService.shared.checkAuth(baseUrl: selectedBaseUrl, topic: sanitizedTopic, user: user) { result in
            switch result {
            case .Success:
                DispatchQueue.global(qos: .background).async {
                    subscriptionManager.subscribe(baseUrl: selectedBaseUrl, topic: sanitizedTopic)
                    resetAndHide()
                }
                // Do not reset "loading", because resetAndHide() will do that after everything is done
            case .Unauthorized:
                if let user = user {
                    addError = "The saved \(user.displayName) is not authorized to read this topic"
                } else {
                    addError = nil // Reset
                    showLogin = true
                }
                loading = false
            case .Error(let err):
                addError = err
                loading = false
            }
        }
    }
    
    private func subscribeWithUserAction() {
        loading = true
        loginError = nil
        let savedUsername = useToken ? "" : username
        let user = BasicUser(username: savedUsername, password: password)
        ApiService.shared.checkAuth(baseUrl: selectedBaseUrl, topic: sanitizedTopic, user: user) { result in
            switch result {
            case .Success:
                DispatchQueue.global(qos: .background).async {
                    store.saveUser(baseUrl: selectedBaseUrl, username: savedUsername, password: password)
                    subscriptionManager.subscribe(baseUrl: selectedBaseUrl, topic: sanitizedTopic)
                    resetAndHide()
                }
                // Do not reset "loading", because resetAndHide() will do that after everything is done
            case .Unauthorized:
                loginError = useToken
                    ? "Invalid access token, or the token is not authorized to read this topic"
                    : "Invalid credentials, or user \(username) is not authorized to read this topic"
                loading = false
            case .Error(let err):
                loginError = err
                loading = false
            }
        }
    }
    
    private func cancelAction() {
        resetAndHide()
    }

    private func applyScannedSubscription(_ scannedValue: String) {
        let value = scannedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            topic = value
            return
        }

        if scheme == "http" || scheme == "https" {
            let scannedTopic = url.lastPathComponent
            guard !scannedTopic.isEmpty else {
                scannerError = "That QR code does not contain an ntfy topic."
                return
            }
            topic = scannedTopic
            baseUrl = url.deletingLastPathComponent().absoluteString
            useAnother = normalizeBaseUrl(baseUrl) != normalizeBaseUrl(store.getDefaultBaseUrl())
            return
        }

        if scheme == "ntfy" {
            let pathTopic = url.pathComponents.last(where: { $0 != "/" })
            if let pathTopic, let host = url.host {
                topic = pathTopic
                baseUrl = "https://\(host)"
                useAnother = normalizeBaseUrl(baseUrl) != normalizeBaseUrl(store.getDefaultBaseUrl())
            } else if let host = url.host {
                topic = host
            }
            return
        }

        scannerError = "That QR code is not an ntfy subscription URL."
    }
    
    private var selectedBaseUrl: String {
        return normalizeBaseUrl((useAnother) ? baseUrl : store.getDefaultBaseUrl())
    }
    
    private func resetAndHide() {
        isShowing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            // Hide first and then reset, otherwise we'll see the text fields change
            addError = nil
            loginError = nil
            loading = false
            baseUrl = ""
            topic = ""
            useAnother = false
            useToken = false
            username = ""
            password = ""
        }
    }
}

private struct SubscriptionQRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        guard !uiViewController.isScanning else { return }
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue else { continue }
                hasScanned = true
                onScan(value)
                return
            }
        }
    }
}

struct ErrorView: View {
    var error: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.title2)
            Text(error)
                .font(.subheadline)
        }
        .padding([.leading, .trailing], 20)
        .padding([.top, .bottom], 10)
    }
}

struct SubscriptionAddView_Previews: PreviewProvider {
    @State static var isShowing = true
    
    static var previews: some View {
        let store = Store.preview
        SubscriptionAddView(isShowing: $isShowing)
            .environmentObject(store)
    }
}
