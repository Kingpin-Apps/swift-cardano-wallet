import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

/// Helper: derive the test mnemonic's first payment + stake verification keys, return them
/// alongside the matching base address. Used by both wallet tests and stub setup.
private func vkeysAndAddress(network: Network = .preprod) async throws
-> (pVKey: PaymentVerificationKey, sVKey: StakeVerificationKey, address: Address)
{
    let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
    let account = Account(network: network)
    let pVKey = try await km.paymentVerificationKey(at: account.paymentPath())
    let sVKey = try await km.stakeVerificationKey(at: account.stakePath())
    let address = try await account.address(with: km)
    return (pVKey, sVKey, address)
}

@Suite("WatchOnlyWallet — read-only observation + unsigned-tx building")
struct WatchOnlyWalletTests {

    @Test func walletDerivesBaseAddressFromVKeys() async throws {
        let (pVKey, sVKey, expected) = try await vkeysAndAddress()
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == expected)
        #expect(try await wallet.changeAddress() == expected)
        #expect(wallet.kind == .watchOnly)
    }

    @Test func walletDerivesEnterpriseAddressWhenStakeOmitted() async throws {
        let (pVKey, _, _) = try await vkeysAndAddress()
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(paymentVerificationKey: pVKey),
            network: .preprod,
            chainContext: stub
        )
        let addr = try await wallet.receiveAddress()
        #expect(addr.stakingPart == nil)
    }

    @Test func rewardAddressThrowsWhenStakeOmitted() async throws {
        let (pVKey, _, _) = try await vkeysAndAddress()
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(paymentVerificationKey: pVKey),
            network: .preprod,
            chainContext: stub
        )
        do {
            _ = try await wallet.rewardAddress()
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func utxosAndBalanceQueryChain() async throws {
        let (pVKey, sVKey, address) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 7_500_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 7_500_000)
        #expect(balance.utxoCount == 1)
    }

    @Test func prepareSendBuildsUnsignedTransaction() async throws {
        let (pVKey, sVKey, address) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 100_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
        // Body has the expected output; no vkey witnesses yet.
        #expect(prepared.transaction.transactionBody.outputs.contains { $0.address == dest })
        #expect(prepared.transaction.transactionWitnessSet.vkeyWitnesses == nil)
    }

    // MARK: - Address-based construction (no vkeys)

    @Test func walletAcceptsBaseAddressDirectly() async throws {
        let (_, _, baseAddress) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: baseAddress, lovelace: 9_999_999)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try baseAddress.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            address: baseAddress,
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == baseAddress)
        #expect(wallet.kind == .watchOnly)

        let bal = try await wallet.balance()
        #expect(bal.lovelace == 9_999_999)

        // Reward address derivable from the vkey-hash staking part of the base address.
        let reward = try await wallet.rewardAddress()
        #expect(reward.paymentPart == nil)
        #expect(reward.stakingPart != nil)
    }

    @Test func walletAcceptsEnterpriseAddressWithoutStakingPart() async throws {
        // Build a vkey-only enterprise address (no staking part).
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let pVKey = try await km.paymentVerificationKey(at: Account(network: .preprod).paymentPath())
        let enterprise = try Address(
            paymentPart: .verificationKeyHash(try pVKey.hash()),
            network: Network.preprod.networkId
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            address: enterprise,
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.receiveAddress() == enterprise)
        // No staking part → rewardAddress() throws.
        do {
            _ = try await wallet.rewardAddress()
            Issue.record("Expected configurationMissing for enterprise reward address")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func walletAcceptsStakeOnlyAddress() async throws {
        // Construct a reward-only address (`stake1…` shape).
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let sVKey = try await km.stakeVerificationKey(at: Account(network: .preprod).stakePath())
        let rewardAddr = try Address(
            stakingPart: .verificationKeyHash(try sVKey.hash()),
            network: Network.preprod.networkId
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            address: rewardAddr,
            network: .preprod,
            chainContext: stub
        )
        // Reward address is the supplied address.
        #expect(try await wallet.rewardAddress() == rewardAddr)
        // No payment side: receive/utxos behave as expected.
        do {
            _ = try await wallet.receiveAddress()
            Issue.record("Expected configurationMissing for stake-only receive")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
        // utxos() short-circuits to empty (stake addresses don't hold UTxOs).
        #expect(try await wallet.utxos().isEmpty)
        let bal = try await wallet.balance()
        #expect(bal.lovelace == 0)
    }

    @Test func prepareSendThrowsOnStakeOnlyWallet() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let sVKey = try await km.stakeVerificationKey(at: Account(network: .preprod).stakePath())
        let rewardAddr = try Address(
            stakingPart: .verificationKeyHash(try sVKey.hash()),
            network: Network.preprod.networkId
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try WatchOnlyWallet(
            address: rewardAddr,
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(with: km)
        do {
            _ = try await wallet.prepareSend(lovelace: 1_000_000, to: dest)
            Issue.record("Expected configurationMissing for stake-only prepareSend")
        } catch let error as WalletError {
            if case .configurationMissing = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func walletEnumWatchOnlyAddressFactoryRoundTrips() async throws {
        let (_, _, baseAddress) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: baseAddress, lovelace: 4_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try baseAddress.toBech32(): [utxo]]
        )
        let wallet = try await Wallet.watchOnly(
            address: baseAddress,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .watchOnly)
        #expect(wallet.canSign == false)
        #expect(try await wallet.primaryAddress() == baseAddress)
        #expect(try await wallet.balance().lovelace == 4_000_000)
    }

    @Test func signingThroughPreparedTxThrowsWatchOnly() async throws {
        let (pVKey, sVKey, address) = try await vkeysAndAddress()
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 100_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try WatchOnlyWallet(
            keyManager: WatchOnlyKeyManager(
                paymentVerificationKey: pVKey,
                stakeVerificationKey: sVKey
            ),
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
        do {
            _ = try await prepared.sign()
            Issue.record("Expected sign() to throw watchOnly")
        } catch let error as WalletError {
            if case .watchOnly = error { /* expected — wrapped via wrappingSigning? */ } else if case .signingFailed = error { /* also OK — gets wrapped */ } else {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}

@Suite("TextEnvelopeWallet — CLI key-backed wallet")
struct TextEnvelopeWalletTests {

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
}

@Suite("Wallet enum — extended cases (textEnvelope, watchOnly, encrypted factory)")
struct WalletEnumExtendedTests {

    @Test func watchOnlyFactoryWrapsCorrectly() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let account = Account(network: .preprod)
        let pVKey = try await km.paymentVerificationKey(at: account.paymentPath())
        let sVKey = try await km.stakeVerificationKey(at: account.stakePath())
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.watchOnly(
            paymentVerificationKey: pVKey,
            stakeVerificationKey: sVKey,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .watchOnly)
        #expect(wallet.canSign == false)
        #expect(wallet.watchOnlyWallet != nil)
    }

    @Test func watchOnlySendThrowsThroughEnum() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let account = Account(network: .preprod)
        let pVKey = try await km.paymentVerificationKey(at: account.paymentPath())
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.watchOnly(
            paymentVerificationKey: pVKey,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let dest = try await Account(index: 7, network: .preprod).address(with: km)
        do {
            _ = try await wallet.send(lovelace: 1_000_000, to: dest)
            Issue.record("Expected watchOnly error")
        } catch let error as WalletError {
            if case .watchOnly = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func encryptedFactoryDecryptsBlobAndProducesMnemonicWallet() async throws {
        let mnemonic = testMnemonic
        let passphrase = "correct horse battery staple"
        let encryptedKM = try await EncryptedKeyManager(mnemonic: mnemonic, passphrase: passphrase)
        let blob = try await encryptedKM.encryptedBlob(passphrase: passphrase)

        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.encrypted(
            blob: blob,
            passphrase: passphrase,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        // encrypted is just a key-management concern → produces a .mnemonic case.
        #expect(wallet.kind == .mnemonic)
        #expect(wallet.canSign == true)
        #expect(wallet.mnemonicWallet != nil)
        // Should derive the same receive address as the original mnemonic.
        let expectedAddr = try await Account(network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: mnemonic, passphrase: "")
        )
        #expect(try await wallet.primaryAddress() == expectedAddr)
    }

    @Test func encryptedFactoryRejectsWrongPassphrase() async throws {
        let encryptedKM = try await EncryptedKeyManager(
            mnemonic: testMnemonic,
            passphrase: "right"
        )
        let blob = try await encryptedKM.encryptedBlob(passphrase: "right")
        let stub = StubChainContext(networkId: .testnet)
        do {
            _ = try await Wallet.encrypted(
                blob: blob,
                passphrase: "wrong",
                network: .preprod,
                provider: .custom(make: { stub })
            )
            Issue.record("Expected invalidPassphrase")
        } catch let error as WalletError {
            if case .invalidPassphrase = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func textEnvelopeFactoryEndToEnd() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let account = Account(network: .preprod)
        let pExt = try await km.paymentSigningKey(at: account.paymentPath())
        let sExt = try await km.stakeSigningKey(at: account.stakePath())

        let dir = NSTemporaryDirectory().appending("envelope-enum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pSkey = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("payment.skey"))
        let sSkey = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("stake.skey"))
        try pExt.save(to: pSkey.path, overwrite: true)
        try sExt.save(to: sSkey.path, overwrite: true)

        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.textEnvelope(
            paymentKeyFile: pSkey,
            stakeKeyFile: sSkey,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .textEnvelope)
        #expect(wallet.canSign == true)
        #expect(wallet.textEnvelopeWallet != nil)
    }
}
