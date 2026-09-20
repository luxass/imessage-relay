import Foundation
import Security

struct KeychainTokenStore: Sendable {
    private let service = "dev.luxass.imessage-relay.api-token"
    private let account = "local-api"

    func loadOrCreate() throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8),
                  !token.isEmpty else {
                throw KeychainTokenError.invalidStoredToken
            }
            return token
        case errSecItemNotFound:
            let token = try makeToken()
            try store(token)
            return token
        default:
            throw KeychainTokenError.operationFailed(status)
        }
    }

    private func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainTokenError.operationFailed(status)
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func store(_ token: String) throws {
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "iMessage Relay API Token",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainTokenError.operationFailed(status)
        }
    }
}

enum KeychainTokenError: Error, LocalizedError {
    case invalidStoredToken
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredToken:
            "The API token stored in Keychain is invalid."
        case let .operationFailed(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain failed with status \(status)."
        }
    }
}
