import Testing
import Foundation
import SwiftCardanoCore
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

private func makeTempDir(_ label: String = "wallet-test") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("FileKeyStore")
struct FileKeyStoreTests {

    @Test func saveLoadDeleteRoundTrip() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)

        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")

        try await store.save(blob, id: "wallet-a")
        let loaded = try await store.load(id: "wallet-a")
        #expect(loaded == blob)

        let listed = try await store.list()
        #expect(listed == ["wallet-a"])

        try await store.delete(id: "wallet-a")
        let afterDelete = try await store.list()
        #expect(afterDelete.isEmpty)
    }

    @Test func deleteIsIdempotent() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        // Should not throw even though "nope" was never saved.
        try await store.delete(id: "nope")
    }

    @Test func rejectsTraversalIds() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")

        for badId in ["..", "../escape", "/abs/path", "with/slash", "with space"] {
            do {
                try await store.save(blob, id: badId)
                Issue.record("Expected keystore error for id '\(badId)'")
            } catch let error as WalletError {
                if case .keystore = error { /* ok */ } else {
                    Issue.record("Unexpected: \(error)")
                }
            }
        }
    }

    @Test func multipleEntriesCoexist() async throws {
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")

        try await store.save(blob, id: "alpha")
        try await store.save(blob, id: "beta")
        try await store.save(blob, id: "gamma")

        let listed = try await store.list()
        #expect(listed == ["alpha", "beta", "gamma"])
    }

    /// Saved blobs must be `0o600` regardless of process umask. Defense-in-depth — the
    /// blob is PBKDF2/AES-GCM encrypted so plaintext isn't exposed even when permissive,
    /// but limiting the file to owner-only foils a same-host attacker who guessed or
    /// keylogged the passphrase from grabbing the ciphertext at leisure.
    @Test func savedBlobsAreOwnerReadableOnly() async throws {
        #if os(Windows)
        // POSIX bits aren't meaningful on Windows; skip.
        return
        #else
        let dir = try makeTempDir()
        let store = try FileKeyStore(directory: dir)
        let km = try await EncryptedKeyManager(mnemonic: testMnemonic, passphrase: "pp")
        let blob = try await km.encryptedBlob(passphrase: "pp")
        try await store.save(blob, id: "wallet-a")

        let path = dir.appendingPathComponent("wallet-a.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mode = attrs[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o600)
        #endif
    }

    /// Directories created by ``FileKeyStore`` should be `0o700`. We have to use a
    /// path that doesn't yet exist — passing an already-created directory deliberately
    /// leaves the existing permissions alone.
    @Test func createdDirectoryIsOwnerOnly() throws {
        #if os(Windows)
        return
        #else
        let parent = try makeTempDir()
        let fresh = parent.appendingPathComponent("vault-\(UUID().uuidString)")
        _ = try FileKeyStore(directory: fresh)
        let attrs = try FileManager.default.attributesOfItem(atPath: fresh.path)
        let mode = attrs[.posixPermissions] as? NSNumber
        #expect(mode?.uint16Value == 0o700)
        #endif
    }

    /// Mirrors the QuickStart article's Persistence example end-to-end:
    /// encrypt mnemonic → save blob → load blob → reopen via ``Wallet/encrypted(blob:passphrase:network:provider:accountIndex:utxoStore:gapLimit:handleResolver:)``
    /// → confirm primary address matches the originally-derived one. If this test
    /// breaks, the QuickStart example is out of date.
    @Test func quickStartPersistenceFlowRoundTrips() async throws {
        let phrase = testMnemonic
        let userPassphrase = "correct horse battery staple"

        let encrypted = try await EncryptedKeyManager(
            mnemonic: phrase,
            passphrase: userPassphrase
        )
        let blob = try await encrypted.encryptedBlob(passphrase: userPassphrase)

        // QuickStart uses KeychainKeyStore; FileKeyStore exercises the same shape on
        // every platform without entitlements.
        let store = try FileKeyStore(directory: try makeTempDir())
        try await store.save(blob, id: "primary")

        let restoredBlob = try await store.load(id: "primary")
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.encrypted(
            blob: restoredBlob,
            passphrase: userPassphrase,
            network: .preprod,
            provider: .custom(make: { stub })
        )

        #expect(wallet.kind == .mnemonic)
        let expectedAddr = try await Account(network: .preprod)
            .address(with: try MnemonicKeyManager(mnemonic: phrase))
        #expect(try await wallet.primaryAddress() == expectedAddr)
    }
}
