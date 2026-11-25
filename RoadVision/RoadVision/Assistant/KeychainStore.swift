import Foundation
import Security

/// Minimal Keychain wrapper (generic-password items) for secrets such as AI provider API keys.
///
/// Keys never go to `UserDefaults` or to the source code: each chat preset stores its key under
/// the account `"ai.key.<presetID>"` (see `KeychainStore.apiKeyAccount(for:)`).
/// Items are readable after the first unlock of the device so the assistant also works while the
/// phone is locked in a car mount, and they are not synchronised to other devices.
final class KeychainStore: Sendable {
    /// Shared store for the app's service identifier.
    static let shared = KeychainStore()

    /// `kSecAttrService` value that groups all items of the app.
    let service: String

    init(service: String = "uz.roadvision.RoadVision") {
        self.service = service
    }

    /// Keychain account used for the API key of a chat provider preset.
    static func apiKeyAccount(for presetID: String) -> String {
        "ai.key.\(presetID)"
    }

    /// Returns the UTF-8 string stored for `key`, or nil when there is no item (or it cannot be read).
    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Stores `value` for `key`. Leading/trailing whitespace is removed (keys are often pasted with a newline);
    /// `nil` or an empty string deletes the item.
    func set(_ value: String?, for key: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = baseQuery(for: key)
        guard !trimmed.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(trimmed.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (attribute, attributeValue) in attributes {
                addQuery[attribute] = attributeValue
            }
            SecItemAdd(addQuery as CFDictionary, nil)
        } else if updateStatus != errSecSuccess {
            // The existing item could not be updated (e.g. it was created with other attributes): replace it.
            SecItemDelete(query as CFDictionary)
            var addQuery = query
            for (attribute, attributeValue) in attributes {
                addQuery[attribute] = attributeValue
            }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    /// True when a non-empty value is stored for `key`.
    func contains(_ key: String) -> Bool {
        string(for: key) != nil
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
