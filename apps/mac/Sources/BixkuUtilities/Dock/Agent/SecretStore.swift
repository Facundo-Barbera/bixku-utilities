import Foundation
#if canImport(Security)
import Security
#endif

/// Storage for secrets such as LLM API keys. Secrets never go to files, logs
/// or `UserDefaults`; the app uses the Keychain, tests use memory.
protocol SecretStore: Sendable {
    /// The stored secret, or `nil` if there is none.
    func secret(for account: String) throws -> String?
    /// Stores `secret`, replacing any previous value.
    func setSecret(_ secret: String, for account: String) throws
    /// Removes the secret. Removing a missing secret is not an error.
    func removeSecret(for account: String) throws
}

/// A ``SecretStore`` that keeps secrets in memory only. For tests and previews.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String]

    init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func secret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func setSecret(_ secret: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func removeSecret(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = nil
    }
}

#if canImport(Security)
struct KeychainError: Error, LocalizedError, Equatable {
    var status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String?
        return "Keychain error \(status)" + (message.map { ": \($0)" } ?? "")
    }
}

/// A ``SecretStore`` backed by generic-password items in the user's login keychain.
struct KeychainSecretStore: SecretStore {
    /// Keychain service the items are filed under.
    var service: String

    init(service: String = "online.bixku.utilities") {
        self.service = service
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func secret(for account: String) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(
            query(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query(for: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        default:
            throw KeychainError(status: update)
        }
    }

    func removeSecret(for account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
#endif
