import Foundation

// Reads Claude Code's OAuth access token from the login keychain.
// Claude Code stores its credentials under the generic-password service
// "Claude Code-credentials" as a JSON blob with shape:
//   { "claudeAiOauth": { "accessToken": "sk-ant-oat01-...", ... }, ... }
//
// Why this shells out to /usr/bin/security instead of calling
// SecItemCopyMatching directly:
//
// Claude Code rewrites this keychain item with the `security` CLI whenever a
// session starts or the token refreshes. Every rewrite resets the item's
// partition list to "apple-tool:" only. A direct SecItem read from this app
// then fails the partition check (securityd logs "ACL partition mismatch:
// client teamid:... ACL (apple-tool:)") and macOS shows the keychain password
// prompt again, even though the user already clicked "Always Allow". With
// several Claude Code sessions starting and refreshing tokens, that meant a
// prompt on nearly every 5-minute poll.
//
// /usr/bin/security is an Apple tool, so it always matches "apple-tool:" and
// is always in the item's application list (Claude Code itself uses it). It
// never prompts, no matter how often the item is rewritten. This is the same
// path other Claude Code companion tools take.

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
    private static let securityTool = "/usr/bin/security"

    static func load() throws -> ClaudeOAuthCredentials {
        let data = try readSecret()

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

    /// Runs `security find-generic-password -s <service> -w` and returns the
    /// secret bytes with the trailing newline removed.
    private static func readSecret() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityTool)
        process.arguments = ["find-generic-password", "-s", serviceName, "-w"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KeychainCredentialsError.notFound
        }

        // Drain stdout before waiting so the child can never block on a full pipe.
        var data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !data.isEmpty else {
            throw KeychainCredentialsError.notFound
        }
        while let last = data.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            data.removeLast()
        }
        return data
    }
}
