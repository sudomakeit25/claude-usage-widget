import Foundation
import Security

// Reads Claude Code's OAuth access token from the system keychain.
// Claude Code stores its credentials under the generic-password service
// "Claude Code-credentials" as a JSON blob with shape:
//   { "claudeAiOauth": { "accessToken": "sk-ant-oat01-...", ... }, ... }

enum KeychainCredentialsError: Error {
    case notFound
    case parseFailed
    case noAccessToken
}

struct ClaudeOAuthCredentials {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
}

enum KeychainCredentials {
    static let serviceName = "Claude Code-credentials"

    static func load() throws -> ClaudeOAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainCredentialsError.notFound
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            throw KeychainCredentialsError.parseFailed
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw KeychainCredentialsError.noAccessToken
        }

        let expires: Date? = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        let subscription = oauth["subscriptionType"] as? String

        return ClaudeOAuthCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: subscription
        )
    }
}
