import Foundation
import Security

/// Generic-password items in the login keychain. The API key never touches a file or UserDefaults.
enum KeychainStore {
    static let service = "com.laziji.remindbar"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// The DeepSeek key, read from the keychain lazily (and once), so opening the panel never triggers a keychain prompt.
final class KeyBox: @unchecked Sendable {
    static let shared = KeyBox()
    static let account = "deepseek-api-key"
    /// Developer override for tests: `REMINDBAR_DEEPSEEK_KEY=… RemindBar`.
    private static let envName = "REMINDBAR_DEEPSEEK_KEY"

    private let lock = NSLock()
    private var loaded = false
    private var value: String?

    var key: String? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            let env = ProcessInfo.processInfo.environment[Self.envName]
            value = (env?.isEmpty == false) ? env : KeychainStore.read(account: Self.account)
            loaded = true
        }
        return value
    }

    /// Stores (or removes, with nil) the key and remembers whether one exists, for the UI.
    @discardableResult
    func save(_ newValue: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard KeychainStore.write(trimmed, account: Self.account) else { return false }
            value = trimmed
            UserDefaults.standard.set(true, forKey: Prefs.Key.aiKeyPresent)
        } else {
            KeychainStore.delete(account: Self.account)
            value = nil
            UserDefaults.standard.set(false, forKey: Prefs.Key.aiKeyPresent)
        }
        loaded = true
        return true
    }
}
