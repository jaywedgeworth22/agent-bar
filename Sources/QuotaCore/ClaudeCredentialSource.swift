import Foundation
import LocalAuthentication
import os
import Security

/// What a silent read of Claude Code's saved login found on this Mac.
///
/// The three cases are deliberately distinct.  "No Claude Code login exists
/// here" and "a login exists that this build has not been allowed to read"
/// need completely different words in the UI, and the old `Data?` could not
/// tell them apart: both arrived as `nil`, so a signed-in owner was told to
/// sign in.
public enum ClaudeCredentialAccess: Equatable, Sendable {
    /// No Claude Code Keychain item exists on this Mac.
    case missing
    /// An item exists, but this build's code identity is not on its access
    /// list, so the data read came back empty.  One interactive read, which
    /// the owner answers with Always Allow, fixes it for good.
    case unauthorized
    /// The item was read.
    case authorized(Data)

    public var data: Data? {
        if case .authorized(let data) = self { return data }
        return nil
    }
}

/// Reads Claude Code's own saved login, and never writes to it, refreshes it,
/// or deletes it.
public enum ClaudeCredentialSource {
    static let service = "Claude Code-credentials"

    private static let worker = DispatchQueue(label: "com.jays.usage-monitor.claude-keychain")
    private static let activeRead = DispatchSemaphore(value: 1)
    private static let timeout: DispatchTimeInterval = .seconds(3)
    /// Long enough for someone to read and answer a system panel, short enough
    /// that a wedged Keychain does not leave the button spinning forever.
    private static let interactiveTimeout: Double = 60
    private static let maxCredentialBytes = 1_048_576

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jays.agent-bar.mac",
                                    category: "claude-credentials")

    /// The refresh loop's read.  Never prompts, never mutates another app's
    /// login, and reports which of the two failures it met.  Metadata chooses
    /// the latest Claude Code item without assuming its account is the OS user.
    public static func access() async -> ClaudeCredentialAccess {
        await withCheckedContinuation { (continuation: CheckedContinuation<ClaudeCredentialAccess, Never>) in
            guard activeRead.wait(timeout: .now()) == .success else { continuation.resume(returning: .missing); return }
            let gate = KeychainReadGate(continuation)
            worker.async {
                defer { activeRead.signal() }
                gate.finish(readSynchronously())
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(.missing)
            }
        }
    }

    /// Bounds injected or future asynchronous keychain adapters as well as
    /// the production synchronous Security call.
    public static func boundedAccess(_ operation: @escaping @Sendable () async -> ClaudeCredentialAccess) async -> ClaudeCredentialAccess {
        await withCheckedContinuation { (continuation: CheckedContinuation<ClaudeCredentialAccess, Never>) in
            let gate = KeychainReadGate(continuation)
            Task.detached(priority: .utility) { gate.finish(await operation()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(.missing)
            }
        }
    }

    /// One read that lets macOS show its own authorization panel, so the owner
    /// can press Always Allow and put this build on the item's access list.
    /// Only ever reached from Allow Access To Claude Code — never from the
    /// refresh loop, which must stay prompt-free.
    ///
    /// Returns whether access was granted rather than the credential itself.
    /// Nothing outside this type has any use for Claude Code's saved login, so
    /// nothing outside this type is handed it.
    public static func readAllowingInteraction() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = KeychainReadGate(continuation)
            // Deliberately not behind `activeRead`: a call parked on a panel
            // nobody has answered must not make every later silent read fail.
            DispatchQueue.global(qos: .userInitiated).async { gate.finish(readInteractively()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interactiveTimeout) {
                gate.finish(false)
            }
        }
    }

    private static func readSynchronously() -> ClaudeCredentialAccess {
        if let data = readViaSecurityCLI() {
            log.notice("claude keychain read through the security CLI")
            return .authorized(data)
        }

        // Never prompt.  Both keys are set, because they cover different
        // dialogs.  `LAContext.interactionNotAllowed` suppresses
        // LocalAuthentication UI, but only for an item carrying an access
        // control policy — Claude Code's item has none, so on macOS it
        // resolves against the file-based login Keychain, whose access and
        // unlock panels are governed by `kSecUseAuthenticationUIFail`
        // instead.  Deprecated, and still the only thing that fails the query
        // rather than showing that panel.  Without it a background refresh
        // could raise a Keychain dialog on its own, which is exactly what the
        // owner met before there was a button to press.
        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        // An attributes-only query reads the item's metadata, which needs no
        // entry on its access list.  That makes it a safe existence check:
        // it answers "is there a Claude Code login here at all" without ever
        // touching the secret.
        let found = SecItemCopyMatching(query as CFDictionary, &result)
        // Status codes only, at notice level so they persist in the log store.
        // Nothing here ever logs the credential.
        log.notice("claude keychain silent attributes status \(found, privacy: .public)")
        guard found == errSecSuccess,
              let items = result as? [[String: Any]],
              let newest = items.max(by: {
                  ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)
                    < ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast)
              }) else { return .missing }

        var dataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        if let account = newest[kSecAttrAccount as String] {
            dataQuery[kSecAttrAccount as String] = account
        }
        var payload: CFTypeRef?
        let status = SecItemCopyMatching(dataQuery as CFDictionary, &payload)
        log.notice("claude keychain silent data status \(status, privacy: .public)")
        // An item is definitely there, so a failed data read is the consent
        // case rather than a missing login.
        guard status == errSecSuccess, let data = payload as? Data else { return .unauthorized }
        // A payload far larger than any credential is not one; treat it as no
        // login rather than carrying it around.
        guard data.count <= maxCredentialBytes else { return .missing }
        return .authorized(data)
    }

    /// The one call allowed to raise the system panel: no `LAContext`, no
    /// `interactionNotAllowed`, no `kSecUseAuthenticationUIFail`.  It only ever
    /// reads — the item is never added, updated, or deleted.
    private static func readInteractively() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &result)
        // Status codes only, at notice level so they persist in the log store.
        // Nothing here ever logs the credential.
        log.notice("claude keychain attributes status \(found, privacy: .public)")
        guard found == errSecSuccess,
              let items = result as? [[String: Any]],
              let newest = items.max(by: {
                  ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)
                    < ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast)
              }) else { return false }

        var dataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account = newest[kSecAttrAccount as String] {
            dataQuery[kSecAttrAccount as String] = account
        }
        var payload: CFTypeRef?
        let status = SecItemCopyMatching(dataQuery as CFDictionary, &payload)
        log.notice("claude keychain interactive read status \(status, privacy: .public)")
        guard status == errSecSuccess, let data = payload as? Data else { return false }
        return !data.isEmpty && data.count <= maxCredentialBytes
    }

    private static func readViaSecurityCLI() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let reader = output.fileHandleForReading
        defer {
            // Ensure the child process is reaped and pipes are closed even on
            // early returns so we never leak a zombie or file descriptor.
            if process.isRunning { process.terminate() }
            try? output.fileHandleForWriting.close()
            try? reader.close()
            if process.isRunning { process.waitUntilExit() }
        }
        do {
            try process.run()
            try? output.fileHandleForWriting.close()
            let descriptor = reader.fileDescriptor
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            let deadline = ProcessInfo.processInfo.systemUptime + 3.0
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if ProcessInfo.processInfo.systemUptime >= deadline { return nil }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= maxCredentialBytes else { return nil }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count < 0 && errno == EAGAIN {
                    if !process.isRunning {
                        while true {
                            let finalCount = Darwin.read(descriptor, &buffer, buffer.count)
                            if finalCount > 0 { data.append(contentsOf: buffer.prefix(finalCount)) }
                            else { break }
                        }
                        break
                    }
                    usleep(5000)
                    continue
                }
                if count == 0 { break }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            if let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let trimmed = string.data(using: .utf8) {
                // macOS 26+ may output a hex-encoded string when the value
                // contains non-ASCII bytes.  Detect and decode it.
                if let decoded = Self.decodeHexString(trimmed) {
                    return decoded
                }
                return trimmed
            }
            return data
        } catch {
            return nil
        }
    }

    /// Returns decoded `Data` when the input is a pure hex string (pairs of
    /// `[0-9a-fA-F]`, optionally whitespace-separated).  Returns `nil` for
    /// anything that doesn't look like hex output, so the caller falls through
    /// to treating the data as-is.
    private static func decodeHexString(_ data: Data) -> Data? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let hex = raw.filter { !$0.isWhitespace }
        // Must be even-length and entirely hex digits.
        guard hex.count >= 2, hex.count.isMultiple(of: 2),
              hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        // Only decode if it looks like hex-encoded JSON (starts with 7b = '{').
        guard hex.hasPrefix("7b") || hex.hasPrefix("7B") else { return nil }
        var decoded = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            decoded.append(byte)
            index = next
        }
        return decoded
    }
}

/// What the Claude reader should say, derived from the only two things it can
/// observe: whether it found a usable, unexpired OAuth record, and what a
/// silent Keychain read saw.  Pure, so the mapping is unit-tested without ever
/// touching a real Keychain.
public enum ClaudeLoginState: Equatable, Sendable {
    /// A usable credential was found — in Claude Code's file or its Keychain
    /// item — and the reader can go on to ask Anthropic for quota.
    case connected
    /// A Claude Code login exists on this Mac, and this build has not been
    /// allowed to read it.  The owner grants that once.
    case needsPermission
    /// No usable Claude Code login exists here at all.
    case signedOut

    public static func resolve(hasUsableCredential: Bool, access: ClaudeCredentialAccess) -> ClaudeLoginState {
        if hasUsableCredential { return .connected }
        return access == .unauthorized ? .needsPermission : .signedOut
    }

    /// The one sentence a Glance row, a Console card and the Settings row all
    /// show.  Short on purpose: Glance has a single line for it.
    public var issue: String? {
        switch self {
        case .connected:
            return nil
        case .needsPermission:
            return "CodeCaps needs your permission to read Claude Code's saved login."
        case .signedOut:
            return "Claude Code quota login is unavailable." + sentenceGap
                + "Sign in to Claude Code to connect subscription quotas."
        }
    }

    /// Whether the UI should offer the one-time Allow Access To Claude Code
    /// step rather than telling the owner to sign in.
    public var needsConsent: Bool { self == .needsPermission }
}

/// Resumes the async caller exactly once when the Security framework returns,
/// or when its bounded wait expires.  A timed-out Security call may remain
/// stuck in the serial worker, but it cannot block this refresh task forever.
private final class KeychainReadGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
