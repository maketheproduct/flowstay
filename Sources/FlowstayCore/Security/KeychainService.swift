import Foundation
import os
import Security

/// Protocol for secure API key storage
public protocol KeychainServiceProtocol: Sendable {
    func saveAPIKey(_ key: String, for provider: String) async
    func getAPIKey(for provider: String) async -> String?
    func deleteAPIKey(for provider: String) async
    func hasAPIKey(for provider: String) async -> Bool
}

/// Secure storage for API keys using macOS Keychain
/// SAFETY: @unchecked Sendable is used because:
/// 1. All Keychain operations are serialized through a dedicated DispatchQueue (`queue`)
/// 2. The serviceName and logger are immutable after initialization
/// 3. All async methods use withCheckedContinuation to safely bridge to the serial queue
public final nonisolated class KeychainService: KeychainServiceProtocol, @unchecked Sendable {
    public static let shared = KeychainService()

    private let serviceName = "com.flowstay.Flowstay"
    private let queue = DispatchQueue(label: "com.flowstay.keychain", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.flowstay.core", category: "KeychainService")

    private init() {}

    public func saveAPIKey(_ key: String, for provider: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                let account = "api-key-\(provider)"

                // Delete existing key first
                deleteAPIKeySync(for: provider)

                guard let keyData = key.data(using: .utf8) else {
                    continuation.resume()
                    return
                }

                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: serviceName,
                    kSecAttrAccount as String: account,
                    kSecValueData as String: keyData,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ]

                let status = SecItemAdd(query as CFDictionary, nil)

                if status != errSecSuccess {
                    logger.error("[KeychainService] Failed to save API key for \(provider): \(status)")
                } else {
                    logger.debug("[KeychainService] API key saved for \(provider)")
                }

                continuation.resume()
            }
        }
    }

    public func getAPIKey(for provider: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let result = getAPIKeySync(for: provider)
                continuation.resume(returning: result)
            }
        }
    }

    public func deleteAPIKey(for provider: String) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                self?.deleteAPIKeySync(for: provider)
                continuation.resume()
            }
        }
    }

    public func hasAPIKey(for provider: String) async -> Bool {
        await getAPIKey(for: provider) != nil
    }

    // MARK: - Synchronous helpers (called on queue)

    private func getAPIKeySync(for provider: String) -> String? {
        let account = "api-key-\(provider)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return key
    }

    private func deleteAPIKeySync(for provider: String) {
        let account = "api-key-\(provider)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            logger.debug("[KeychainService] API key deleted for \(provider)")
        }
    }
}
