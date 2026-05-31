import Foundation
import Security

struct CanvasCredentials: Equatable {
    let host: String
    let token: String
}

/// Keychain-backed storage for Canvas credentials. Tokens never live in source files or app
/// preferences — only in the macOS Keychain under the service name below.
enum CanvasKeychain {
    private static let service = "app.quire.canvas"
    private static let hostAccount = "host"
    private static let tokenAccount = "token"

    static func load() -> CanvasCredentials? {
        guard let host = readString(account: hostAccount),
              !host.isEmpty,
              let token = readString(account: tokenAccount),
              !token.isEmpty
        else { return nil }
        return CanvasCredentials(host: host, token: token)
    }

    static func save(_ credentials: CanvasCredentials) throws {
        try writeString(credentials.host, account: hostAccount)
        try writeString(credentials.token, account: tokenAccount)
    }

    static func clear() {
        delete(account: hostAccount)
        delete(account: tokenAccount)
    }

    private static func readString(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func writeString(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.osStatus(addStatus)
            }
        default:
            throw KeychainError.osStatus(updateStatus)
        }
    }

    @discardableResult
    private static func delete(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(msg) (\(status))"
            }
            return "Keychain error: status \(status)"
        }
    }
}
