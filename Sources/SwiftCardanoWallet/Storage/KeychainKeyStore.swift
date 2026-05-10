#if canImport(Security)
import Foundation
import Security

/// Apple-platform ``KeyStore`` backed by the Keychain Services API.
///
/// Stores ``EncryptedBlob``s as `kSecClassGenericPassword` items, scoped by a `service`
/// string supplied at construction time so multiple wallets (or multiple apps) can coexist
/// in one keychain without colliding.
///
/// Only available where `Security` can be imported — that's macOS, iOS, tvOS, watchOS.
/// Linux builds get ``FileKeyStore`` instead.
public actor KeychainKeyStore: KeyStore {

    public enum Accessibility: Sendable, Equatable {
        /// Item only readable while device is unlocked. Roams to other devices via iCloud
        /// keychain if `synchronizable: true`. **Default for `iOS`.**
        case whenUnlocked
        /// Same as `whenUnlocked` but the item is **not** backed up / synced. Recommended
        /// when the blob is already encrypted at rest by a passphrase you control.
        case whenUnlockedThisDeviceOnly
        /// Readable after first unlock since boot. Useful for items that need to be
        /// available to background apps, e.g. push handlers.
        case afterFirstUnlock
        /// Same as `afterFirstUnlock` but device-local.
        case afterFirstUnlockThisDeviceOnly

        var secValue: CFString {
            switch self {
            case .whenUnlocked: return kSecAttrAccessibleWhenUnlocked
            case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            case .afterFirstUnlock: return kSecAttrAccessibleAfterFirstUnlock
            case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    public let service: String
    public let accessibility: Accessibility
    public let synchronizable: Bool
    public let accessGroup: String?
    public let useDataProtectionKeychain: Bool

    /// - Parameters:
    ///   - service: Keychain `service` attribute. Use your bundle identifier, or a suffix
    ///     of it, to namespace this store away from other apps.
    ///   - accessibility: When the OS allows reads. Defaults to `.whenUnlockedThisDeviceOnly`,
    ///     the most-restrictive option that still works for foreground apps.
    ///   - synchronizable: Whether the item should sync via iCloud keychain. Default
    ///     `false`. Has no effect on `*ThisDeviceOnly` accessibility values.
    ///   - accessGroup: Optional `kSecAttrAccessGroup`. Required only when sharing items
    ///     across apps in the same App Group / Team ID.
    ///   - useDataProtectionKeychain: When `true`, sets `kSecUseDataProtectionKeychain`.
    ///     **iOS / tvOS / watchOS:** default `true` — the Data Protection keychain is the
    ///     standard backing store and `kSecAttrAccessible` is honored. **macOS:** default
    ///     `false`. Setting this to `true` on macOS requires the app to be code-signed
    ///     with the `keychain-access-groups` entitlement (signed Xcode app or
    ///     `codesign`-blessed binary). Without that, every Keychain Services call returns
    ///     `errSecMissingEntitlement` (`-34018`). Wallet apps that ship through TestFlight
    ///     or the Mac App Store typically have these entitlements; CLI tools and unit
    ///     tests typically don't, which is why the macOS default is the legacy login
    ///     keychain. The legacy keychain ignores `kSecAttrAccessible`, but ``EncryptedBlob``s
    ///     are already encrypted at the application layer (PBKDF2-HMAC-SHA512 + AES-GCM
    ///     via ``EncryptedKeyManager``), so the relaxed at-rest protection on macOS is
    ///     defense-in-depth, not the primary encryption.
    public init(
        service: String,
        accessibility: Accessibility = .whenUnlockedThisDeviceOnly,
        synchronizable: Bool = false,
        accessGroup: String? = nil,
        useDataProtectionKeychain: Bool? = nil
    ) {
        self.service = service
        self.accessibility = accessibility
        self.synchronizable = synchronizable
        self.accessGroup = accessGroup
        if let useDataProtectionKeychain {
            self.useDataProtectionKeychain = useDataProtectionKeychain
        } else {
            #if os(macOS)
            self.useDataProtectionKeychain = false
            #else
            self.useDataProtectionKeychain = true
            #endif
        }
    }

    // MARK: - KeyStore conformance

    public func save(_ blob: EncryptedBlob, id: String) async throws {
        try Self.validate(id: id)
        let data: Data
        do {
            data = try blob.toJSONData()
        } catch {
            throw WalletError.keystore("Failed to encode EncryptedBlob: \(error)")
        }

        // SecItemAdd → on `errSecDuplicateItem`, fall back to SecItemUpdate.
        let addQuery = baseQuery(account: id).merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.secValue,
        ]) { $1 }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: accessibility.secValue,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(account: id) as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw WalletError.keystore(
                    "Keychain update failed for id '\(id)': \(Self.statusMessage(updateStatus))"
                )
            }
        default:
            throw WalletError.keystore(
                "Keychain add failed for id '\(id)': \(Self.statusMessage(addStatus))"
            )
        }
    }

    public func load(id: String) async throws -> EncryptedBlob {
        try Self.validate(id: id)
        let query = baseQuery(account: id).merging([
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { $1 }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw WalletError.keystore("Keychain returned non-Data result for id '\(id)'.")
            }
            do {
                return try EncryptedBlob.fromJSONData(data)
            } catch {
                throw WalletError.keystore("Failed to decode EncryptedBlob for id '\(id)': \(error)")
            }
        case errSecItemNotFound:
            throw WalletError.keystore("No keychain item found for id '\(id)'.")
        default:
            throw WalletError.keystore(
                "Keychain read failed for id '\(id)': \(Self.statusMessage(status))"
            )
        }
    }

    public func delete(id: String) async throws {
        try Self.validate(id: id)
        let status = SecItemDelete(baseQuery(account: id) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return  // idempotent
        default:
            throw WalletError.keystore(
                "Keychain delete failed for id '\(id)': \(Self.statusMessage(status))"
            )
        }
    }

    public func list() async throws -> [String] {
        let query = serviceQuery().merging([
            kSecReturnAttributes as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]) { $1 }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = (result as? [[String: Any]]) ?? []
            return items
                .compactMap { $0[kSecAttrAccount as String] as? String }
                .sorted()
        case errSecItemNotFound:
            return []
        default:
            throw WalletError.keystore(
                "Keychain enumerate failed: \(Self.statusMessage(status))"
            )
        }
    }

    /// Test/maintenance helper: drop every item matching this store's `service`. Public so
    /// tests can isolate themselves; production callers should prefer ``delete(id:)``.
    ///
    /// `SecItemDelete` on macOS only deletes one matching item per call (regardless of what
    /// the docs claim about multi-item queries), so we list-then-delete in a loop to make
    /// the bulk semantics explicit.
    public func deleteAll() async throws {
        for id in try await list() {
            try await delete(id: id)
        }
    }

    // MARK: - Internals

    /// Common query attributes for a single (service, account) item.
    private nonisolated func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        applyDataProtectionAttributes(to: &q)
        if synchronizable {
            q[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        }
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// Common query attributes scoped to the service (no specific account).
    private nonisolated func serviceQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        applyDataProtectionAttributes(to: &q)
        if synchronizable {
            q[kSecAttrSynchronizable as String] = kCFBooleanTrue!
        }
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    /// Apply `kSecUseDataProtectionKeychain` when the caller opted into it. See
    /// ``init(service:accessibility:synchronizable:accessGroup:useDataProtectionKeychain:)``
    /// for the rationale and entitlement requirements.
    private nonisolated func applyDataProtectionAttributes(to query: inout [String: Any]) {
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue!
        }
    }

    private static func validate(id: String) throws {
        guard !id.isEmpty else {
            throw WalletError.keystore("KeychainKeyStore id cannot be empty")
        }
        // Keychain accepts any string in `kSecAttrAccount`, but we mirror FileKeyStore's
        // restrictions so an app can swap stores without auditing existing ids.
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_."))
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw WalletError.keystore("KeychainKeyStore id contains illegal characters: \(id)")
        }
    }

    private static func statusMessage(_ status: OSStatus) -> String {
        if let cfMessage = SecCopyErrorMessageString(status, nil) as String? {
            return "\(status): \(cfMessage)"
        }
        return "OSStatus \(status)"
    }
}
#endif
