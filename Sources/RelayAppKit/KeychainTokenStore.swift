import Foundation
import Security

struct KeychainTokenStore: Sendable {
    // Preserve the identity used by earlier app versions.
    private let service = "dev.luxass.imessage-relay.api-token"
    private let account = "local-api"

    func read() throws -> String? {
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
            return nil
        default:
            throw KeychainTokenError.operationFailed(status)
        }
    }

    func generate(replacingExisting: Bool = false) throws -> String {
        if !replacingExisting {
            guard try read() == nil else { throw KeychainTokenError.alreadyExists }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KeychainTokenError.operationFailed(status)
        }
        let token = Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        if replacingExisting {
            try save(token)
        } else {
            try add(token)
        }
        return token
    }

    func save(_ token: String) throws {
        guard !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw KeychainTokenError.invalidToken
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: Data(token.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            try add(token)
        } else if status != errSecSuccess {
            throw KeychainTokenError.operationFailed(status)
        }
    }

    private func add(_ token: String) throws {
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
    case alreadyExists
    case invalidToken
    case missingToken
    case invalidStoredToken
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyExists:
            "A token is already stored. Use it or replace it with your own."
        case .invalidToken:
            "Enter a token without spaces or line breaks."
        case .missingToken:
            "No API token is stored in Keychain. Open Settings to add one."
        case .invalidStoredToken:
            "The API token stored in Keychain is invalid."
        case let .operationFailed(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain failed with status \(status)."
        }
    }
}
