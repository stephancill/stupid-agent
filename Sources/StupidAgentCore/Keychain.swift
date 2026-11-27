import Foundation
import Security

/// Generic passwords in the Keychain, available after first unlock and kept on this device.
public struct Keychain: Sendable {
    public let service: String
    /// A Keychain access group shared with other targets, such as an App Group; nil is the app's own.
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public struct Failure: Error, LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { "Keychain error \(status)" }
    }

    private func query(account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess {
            throw Failure(status: status)
        }
    }

    /// Deletes the account's items in every access group except `keeping`, such as copies left in the app's own group.
    public func delete(account: String, exceptGroup keeping: String) throws {
        var search: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        guard status != errSecItemNotFound else { return }
        guard status == errSecSuccess else { throw Failure(status: status) }
        let groups = ((result as? [[String: Any]]) ?? []).compactMap { $0[kSecAttrAccessGroup as String] as? String }
        for group in Set(groups) where group != keeping {
            try Keychain(service: service, accessGroup: group).delete(account: account)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
