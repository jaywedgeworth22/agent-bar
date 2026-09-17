import Foundation
import LocalAuthentication
import Security

/// Tokens are scoped to their server URL and service domain and never stored in preferences.
enum TokenStore {
    static let readService = "com.jays.agent-bar.mac.read-token"
    static let syncService = "com.jays.agent-bar.mac.sync-token"

    private static let keychainGate = DispatchSemaphore(value: 1)

    static func read(server: String, service: String = readService) async -> String? {
        await bounded(nil) { readSynchronously(server: server, service: service) }
    }

    private static func readSynchronously(server: String, service: String) -> String? {
        var query = base(server, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never prompt: a locked Keychain must fail fast rather than block the
        // refresh loop behind a system dialog.  Both keys are set, because they
        // cover different dialogs.  `LAContext.interactionNotAllowed` suppresses
        // LocalAuthentication UI, but only for an item carrying an access
        // control policy — these are added with none, so on macOS they resolve
        // against the file-based login Keychain, whose unlock panel is governed
        // by `kSecUseAuthenticationUIFail` instead.  Deprecated, and still the
        // only thing that fails the query rather than showing that panel.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, server: String, service: String = readService) async throws {
        let status = await bounded(OSStatus(errSecInteractionNotAllowed)) {
            saveSynchronously(token, server: server, service: service)
        }
        guard status == errSecSuccess else { throw Failure.write }
    }

    private static func saveSynchronously(_ token: String, server: String, service: String) -> OSStatus {
        let query = base(server, service: service)
        let attributes = [kSecValueData as String: Data(token.utf8)] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil)
        }
        return status
    }

    static func delete(server: String, service: String = readService) async throws {
        let status = await bounded(OSStatus(errSecInteractionNotAllowed)) {
            SecItemDelete(base(server, service: service) as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.write }
    }

    private static func bounded<Value: Sendable>(_ fallback: Value, operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .utility).async {
                guard keychainGate.wait(timeout: .now()) == .success else { completion.finish(fallback); return }
                defer { keychainGate.signal() }
                completion.finish(operation())
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { completion.finish(fallback) }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
        func finish(_ value: Value) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static func base(_ server: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: server]
    }

    enum Failure: LocalizedError {
        case read, write
        var errorDescription: String? {
            switch self {
            case .read: return "The saved token is unavailable in Keychain."
            case .write: return "Keychain could not save the token.\u{00A0} Unlock your login Keychain and try again."
            }
        }
    }
}
