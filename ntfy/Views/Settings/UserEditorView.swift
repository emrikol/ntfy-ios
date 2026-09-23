//
//  UserEditorView.swift
//  ntfy
//
//  Created by Alek Michelson on 4/10/26.
//

import SwiftUI

struct UserEditorView: View {
    @EnvironmentObject private var store: Store
    
    let selectedUser: User?
    let onSave: (String, String, String) -> Void
    let onDelete: (User) -> Void
    let onCancel: () -> Void
    
    @State private var baseUrl: String
    @State private var username: String
    @State private var password: String
    @State private var useToken: Bool
    
    init(
        selectedUser: User?,
        onSave: @escaping (String, String, String) -> Void,
        onDelete: @escaping (User) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.selectedUser = selectedUser
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _baseUrl = State(initialValue: selectedUser?.baseUrl ?? "")
        _username = State(initialValue: selectedUser?.username ?? "")
        _password = State(initialValue: "")
        _useToken = State(initialValue: selectedUser?.username?.isEmpty == true)
    }
    
    var body: some View {
        NavigationView {
            Form {
                if isNewUser {
                    Section {
                        TextField("Service URL, e.g. https://ntfy.home.io", text: $baseUrl)
                            .disableAutocapitalization()
                            .disableAutocorrection(true)
                    }
                }
                Section {
                    Toggle("Authenticate using an access token", isOn: $useToken)
                }
                Section(
                    footer: isNewUser
                    ? Text("All topics for this server will reuse these credentials. Access tokens are recommended because they can be revoked without changing your account password.")
                    : Text("These credentials are used for every topic on \(shortUrl(url: baseUrl)). Leave the secret blank to keep the existing one.")
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
            .navigationTitle(isNewUser ? "Add user" : "Edit user")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isNewUser {
                        Button("Cancel") {
                            onCancel()
                        }
                    } else {
                        Menu {
                            Button("Cancel") {
                                onCancel()
                            }
                            if #available(iOS 15.0, *) {
                                Button(role: .destructive) {
                                    deleteAction()
                                } label: {
                                    Text("Delete")
                                }
                            } else {
                                Button("Delete") {
                                    deleteAction()
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .padding([.leading], 40)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: saveAction) {
                        Text("Save")
                    }
                    .disabled(!isValid())
                }
            }
        }
    }
    
    private var isNewUser: Bool {
        selectedUser == nil
    }
    
    private func saveAction() {
        onSave(baseUrl, useToken ? "" : username, password)
    }
    
    private func deleteAction() {
        guard let selectedUser = selectedUser else { return }
        onDelete(selectedUser)
    }
    
    private func isValid() -> Bool {
        let existingUsesToken = selectedUser?.username?.isEmpty == true
        let changedAuthenticationType = selectedUser != nil && existingUsesToken != useToken
        if isNewUser {
            if baseUrl.range(of: "^https?://.+", options: .regularExpression, range: nil, locale: nil) == nil {
                return false
            } else if password.isEmpty || (!useToken && username.isEmpty) {
                return false
            } else if store.getUser(baseUrl: baseUrl) != nil {
                return false
            }
        } else if changedAuthenticationType && password.isEmpty {
            return false
        } else if !useToken && username.isEmpty {
            return false
        }
        return true
    }
}
