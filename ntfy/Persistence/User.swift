import Foundation

extension User {
    func displayName() -> String {
        guard let username, !username.isEmpty else {
            return "Access token"
        }
        return username
    }
}
