#if canImport(Security)
import Testing
import Foundation
@testable import SwiftCardanoWallet

/// Each test gets a unique service name so we don't collide with other tests, prior runs,
/// or anything else in the developer's keychain.
private func makeStore(
    accessibility: KeychainKeyStore.Accessibility = .whenUnlockedThisDeviceOnly
) -> KeychainKeyStore {
    KeychainKeyStore(
        service: "swift-cardano-wallet.tests.\(UUID().uuidString)",
        accessibility: accessibility
    )
}

private func makeBlob(innerKind: String = "test") -> EncryptedBlob {
    EncryptedBlob(
        iterations: 1,
        saltBase64: Data("salt".utf8).base64EncodedString(),
        nonceBase64: Data("nonce-12-byte".utf8).base64EncodedString(),
        ciphertextBase64: Data("ciphertext".utf8).base64EncodedString(),
        tagBase64: Data("tag-16-byte-pad".utf8).base64EncodedString(),
        innerKind: innerKind
    )
}

@Suite(
    "KeychainKeyStore — round-trip + isolation",
    .serialized  // Keychain ops mutate global state; serialise to keep cleanup deterministic.
)
struct KeychainKeyStoreTests {

    @Test func saveLoadRoundTrip() async throws {
        let store = makeStore()
        defer { Task { try? await store.deleteAll() } }

        let blob = makeBlob(innerKind: "mnemonic")
        try await store.save(blob, id: "wallet1")
        let restored = try await store.load(id: "wallet1")
        #expect(restored == blob)
    }

    @Test func saveOverwritesExistingItem() async throws {
        let store = makeStore()
        defer { Task { try? await store.deleteAll() } }

        let original = makeBlob(innerKind: "mnemonic")
        let updated = makeBlob(innerKind: "encrypted")
        try await store.save(original, id: "w")
        try await store.save(updated, id: "w")

        let restored = try await store.load(id: "w")
        #expect(restored.innerKind == "encrypted")
    }

    @Test func loadMissingIdThrowsKeystore() async throws {
        let store = makeStore()
        defer { Task { try? await store.deleteAll() } }

        do {
            _ = try await store.load(id: "nonexistent")
            Issue.record("Expected keystore error for missing id")
        } catch let error as WalletError {
            switch error {
            case .keystore(let msg):
                #expect(msg.contains("nonexistent"))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func deleteIsIdempotent() async throws {
        let store = makeStore()
        defer { Task { try? await store.deleteAll() } }

        try await store.save(makeBlob(), id: "x")
        try await store.delete(id: "x")
        // Second delete should not throw.
        try await store.delete(id: "x")
        do {
            _ = try await store.load(id: "x")
            Issue.record("Expected load to fail after delete")
        } catch let error as WalletError {
            if case .keystore = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func listReturnsAllStoredIds() async throws {
        let store = makeStore()
        defer { Task { try? await store.deleteAll() } }

        try await store.save(makeBlob(), id: "alpha")
        try await store.save(makeBlob(), id: "beta")
        try await store.save(makeBlob(), id: "gamma")

        let listed = try await store.list()
        #expect(listed == ["alpha", "beta", "gamma"])  // sorted alphabetically
    }

    @Test func emptyListWhenStoreIsEmpty() async throws {
        let store = makeStore()
        let listed = try await store.list()
        #expect(listed.isEmpty)
    }

    @Test func separateServicesDoNotInterfere() async throws {
        let storeA = makeStore()
        let storeB = makeStore()
        defer {
            Task { try? await storeA.deleteAll() }
            Task { try? await storeB.deleteAll() }
        }

        try await storeA.save(makeBlob(innerKind: "a-only"), id: "shared-id")
        try await storeB.save(makeBlob(innerKind: "b-only"), id: "shared-id")

        let fromA = try await storeA.load(id: "shared-id")
        let fromB = try await storeB.load(id: "shared-id")
        #expect(fromA.innerKind == "a-only")
        #expect(fromB.innerKind == "b-only")

        // Listing one service shouldn't see the other.
        let listA = try await storeA.list()
        let listB = try await storeB.list()
        #expect(listA == ["shared-id"])
        #expect(listB == ["shared-id"])
    }

    @Test func deleteAllClearsService() async throws {
        let store = makeStore()
        try await store.save(makeBlob(), id: "one")
        try await store.save(makeBlob(), id: "two")
        try await store.deleteAll()
        #expect(try await store.list().isEmpty)
    }

    // MARK: - id validation

    @Test func rejectsEmptyId() async throws {
        let store = makeStore()
        do {
            try await store.save(makeBlob(), id: "")
            Issue.record("Expected keystore error for empty id")
        } catch let error as WalletError {
            if case .keystore = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func rejectsIdWithIllegalChars() async throws {
        let store = makeStore()
        for bad in ["w/allet", "wallet space", "w$llet", "../escape"] {
            do {
                try await store.save(makeBlob(), id: bad)
                Issue.record("Expected keystore error for illegal id '\(bad)'")
            } catch let error as WalletError {
                if case .keystore = error { /* expected */ } else {
                    Issue.record("Unexpected: \(error)")
                }
            }
        }
    }

    // MARK: - Encrypted-key-manager round-trip via the keychain

    @Test func keychainStoreCanBackEncryptedKeyManager() async throws {
        let store = makeStore()
        defer { Task { try? await store.deleteAll() } }

        let mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let passphrase = "correct horse battery staple"

        // Encrypt → persist → load → decrypt → assert vkey round-trips.
        let original = try await EncryptedKeyManager(
            mnemonic: mnemonic,
            passphrase: passphrase
        )
        let blob = try await original.encryptedBlob(passphrase: passphrase)
        try await store.save(blob, id: "primary")

        let restoredBlob = try await store.load(id: "primary")
        let restored = try await EncryptedKeyManager(
            blob: restoredBlob,
            passphrase: passphrase
        )

        let path = Account(network: .preprod).paymentPath()
        let originalVKey = try await original.paymentVerificationKey(at: path)
        let restoredVKey = try await restored.paymentVerificationKey(at: path)
        #expect(originalVKey.payload == restoredVKey.payload)
    }
}
#endif
