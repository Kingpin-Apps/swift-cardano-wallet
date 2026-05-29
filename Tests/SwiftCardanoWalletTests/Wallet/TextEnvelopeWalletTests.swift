import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

private func makeTempDir(_ label: String = "te-wallet") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("TextEnvelopeWallet — CLI key-backed wallet")
struct TextEnvelopeWalletTests {

    // MARK: - Load-from-disk path

    /// Build extended HD signing keys from the test mnemonic, write them as `.skey`
    /// TextEnvelopes to a temp dir, and return the file paths plus the expected base
    /// address. `TextEnvelopeKeyManager` accepts both extended and non-extended `.skey`
    /// files (it detects via payload length), so we use the extended HD keys directly
    /// without round-tripping to non-extended — keeps the test setup short.
    private func writeKeyFiles() async throws -> (paymentSkey: URL, stakeSkey: URL, address: Address, tempDir: String) {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let account = Account(index: 0, network: .preprod)

        let pExtSkey = try await km.paymentSigningKey(at: account.paymentPath())
        let sExtSkey = try await km.stakeSigningKey(at: account.stakePath())

        let dir = NSTemporaryDirectory().appending("text-envelope-wallet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let paymentSkey = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("payment.skey"))
        let stakeSkey = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("stake.skey"))
        try pExtSkey.save(to: paymentSkey.path, overwrite: true)
        try sExtSkey.save(to: stakeSkey.path, overwrite: true)

        // Derive the matching address via the same HD wallet — the TextEnvelopeWallet
        // will land on this same address once it loads the .skey files.
        let address = try await account.address(with: km)
        return (paymentSkey, stakeSkey, address, dir)
    }

    @Test func walletDerivesAddressFromSkeyFiles() async throws {
        let (paymentSkey, stakeSkey, expected, tempDir) = try await writeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let stub = StubChainContext(networkId: .testnet)
        let km = try TextEnvelopeKeyManager(paymentKeyFile: paymentSkey, stakeKeyFile: stakeSkey)
        let wallet = try await TextEnvelopeWallet(
            keyManager: km,
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == expected)
        #expect(wallet.kind == .textEnvelope)
    }

    @Test func sendSignsAndSubmitsThroughStub() async throws {
        let (paymentSkey, stakeSkey, address, tempDir) = try await writeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 100_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let km = try TextEnvelopeKeyManager(paymentKeyFile: paymentSkey, stakeKeyFile: stakeSkey)
        let wallet = try await TextEnvelopeWallet(
            keyManager: km,
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let txId = try await wallet.send(lovelace: 5_000_000, to: dest)
        #expect(txId.hasPrefix("stubtx-"))
    }

    @Test func walletConformsToProtocol() async throws {
        let (paymentSkey, stakeSkey, _, tempDir) = try await writeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let stub = StubChainContext(networkId: .testnet)
        let km = try TextEnvelopeKeyManager(paymentKeyFile: paymentSkey, stakeKeyFile: stakeSkey)
        let w: any WalletProtocol = try await TextEnvelopeWallet(
            keyManager: km,
            network: .preprod,
            chainContext: stub
        )
        #expect(w.kind == .textEnvelope)
        #expect(w.network == .preprod)
    }

    @Test func emptyUtxoListGivesZeroBalance() async throws {
        let (paymentSkey, stakeSkey, _, tempDir) = try await writeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let stub = StubChainContext(networkId: .testnet)
        let km = try TextEnvelopeKeyManager(paymentKeyFile: paymentSkey, stakeKeyFile: stakeSkey)
        let wallet = try await TextEnvelopeWallet(
            keyManager: km,
            network: .preprod,
            chainContext: stub
        )
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 0)
        #expect(balance.utxoCount == 0)
    }

    // MARK: - Generation (file)

    @Test func generatedWalletWritesSkeyFilesAndDerivesAddress() async throws {
        let dir = try makeTempDir()
        let stub = StubChainContext(networkId: .testnet)
        let generated = try await TextEnvelopeWallet.generate(
            writeTo: dir,
            network: .preprod,
            provider: .custom(make: { stub })
        )

        #expect(FileManager.default.fileExists(atPath: generated.paymentSkeyURL.path))
        #expect(FileManager.default.fileExists(atPath: generated.stakeSkeyURL.path))
        #expect(generated.paymentSkeyURL.lastPathComponent == "payment.skey")
        #expect(generated.stakeSkeyURL.lastPathComponent == "stake.skey")

        let addr = try await generated.wallet.receiveAddress()
        #expect(try addr.toBech32().hasPrefix("addr_test1"))
    }

    @Test func generatedSkeyFilesAreValidTextEnvelopes() async throws {
        let dir = try makeTempDir()
        let stub = StubChainContext(networkId: .testnet)
        let generated = try await TextEnvelopeWallet.generate(
            writeTo: dir,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let paymentJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: generated.paymentSkeyURL)
        ) as? [String: String]
        #expect(paymentJSON?["type"] == PaymentSigningKey.TYPE)
        #expect(paymentJSON?["cborHex"] != nil)

        let stakeJSON = try JSONSerialization.jsonObject(
            with: Data(contentsOf: generated.stakeSkeyURL)
        ) as? [String: String]
        #expect(stakeJSON?["type"] == StakeSigningKey.TYPE)
    }

    @Test func generateRefusesToOverwriteExistingFile() async throws {
        let dir = try makeTempDir()
        let stub = StubChainContext(networkId: .testnet)
        _ = try await TextEnvelopeWallet.generate(
            writeTo: dir,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        do {
            _ = try await TextEnvelopeWallet.generate(
                writeTo: dir,
                network: .preprod,
                provider: .custom(make: { stub })
            )
            Issue.record("Expected keystore error on overwrite")
        } catch let error as WalletError {
            if case .keystore = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func generateAllowsOverwriteWhenRequested() async throws {
        let dir = try makeTempDir()
        let stub = StubChainContext(networkId: .testnet)
        let first = try await TextEnvelopeWallet.generate(
            writeTo: dir,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let firstAddr = try await first.wallet.receiveAddress()

        let second = try await TextEnvelopeWallet.generate(
            writeTo: dir,
            network: .preprod,
            provider: .custom(make: { stub }),
            overwrite: true
        )
        let secondAddr = try await second.wallet.receiveAddress()

        // New keys → different address (overwhelmingly likely; 2^252 collision space).
        #expect(firstAddr != secondAddr)
    }

    @Test func mismatchedNetworkAndProviderThrows() async throws {
        let dir = try makeTempDir()
        do {
            _ = try await TextEnvelopeWallet.generate(
                writeTo: dir,
                network: .mainnet,
                provider: .blockfrost(projectId: "irrelevant", network: .preprod)
            )
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    // MARK: - Generation (in-memory)

    @Test func generateInMemoryProducesUsableWalletAndPayloads() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let generated = try await TextEnvelopeWallet.generateInMemory(
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(generated.paymentSigningKeyPayload.count == 32)
        #expect(generated.stakeSigningKeyPayload.count == 32)

        let addr = try await generated.wallet.receiveAddress()
        #expect(try addr.toBech32().hasPrefix("addr_test1"))
    }

    @Test func generateInMemoryPayloadsReconstructSameWallet() async throws {
        // The point of the in-memory variant: the caller can persist the raw payloads
        // however they want, then rebuild the same wallet later.
        let stub = StubChainContext(networkId: .testnet)
        let generated = try await TextEnvelopeWallet.generateInMemory(
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let originalAddr = try await generated.wallet.receiveAddress()

        let rebuiltKM = TextEnvelopeKeyManager(
            paymentPayload: generated.paymentSigningKeyPayload,
            paymentIsExtended: false,
            stakePayload: generated.stakeSigningKeyPayload,
            stakeIsExtended: false
        )
        let rebuilt = try await TextEnvelopeWallet(
            keyManager: rebuiltKM,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let rebuiltAddr = try await rebuilt.receiveAddress()
        #expect(originalAddr == rebuiltAddr)
    }
}
