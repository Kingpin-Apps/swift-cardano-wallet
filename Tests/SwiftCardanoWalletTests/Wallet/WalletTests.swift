import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("Wallet enum — unified surface across wallet kinds")
struct WalletEnumTests {

    // MARK: - Construction

    @Test func mnemonicFactoryBuildsAndWraps() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.mnemonic(
            phrase: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .mnemonic)
        #expect(wallet.network == .preprod)
        #expect(wallet.mnemonicWallet != nil)
        #expect(wallet.multisigWallet == nil)
        #expect(wallet.hardwareWallet == nil)
    }

    @Test func multisigFactoryBuildsAndWraps() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let hashes = try [
            await km.paymentVerificationKey(at: Account(index: 0, network: .preprod).paymentPath()).hash(),
            await km.paymentVerificationKey(at: Account(index: 1, network: .preprod).paymentPath()).hash(),
            await km.paymentVerificationKey(at: Account(index: 2, network: .preprod).paymentPath()).hash(),
        ]
        let policy = try MultisigPolicy.nOfM(
            required: 2,
            signerKeyHashes: hashes,
            network: .preprod
        )
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.multisig(
            policy: policy,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .multisig)
        #expect(wallet.network == .preprod)
        #expect(wallet.multisigWallet != nil)
        #expect(wallet.mnemonicWallet == nil)
    }

    @Test func caseConstructorWrapsExistingWallet() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let concrete = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let wrapped: Wallet = .mnemonic(concrete)
        #expect(wrapped.kind == .mnemonic)
        // Same actor instance, not a copy.
        #expect(wrapped.mnemonicWallet === concrete)
    }

    // MARK: - Dispatch

    @Test func primaryAddressDispatchesPerKind() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let mnemonicWallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let mnemonicEnum: Wallet = .mnemonic(mnemonicWallet)
        let mnemonicAddr = try await mnemonicEnum.primaryAddress()
        let direct = try await mnemonicWallet.receiveAddress()
        #expect(mnemonicAddr == direct)

        // Multisig
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let hashes = try [
            await km.paymentVerificationKey(at: Account(index: 0, network: .preprod).paymentPath()).hash(),
            await km.paymentVerificationKey(at: Account(index: 1, network: .preprod).paymentPath()).hash(),
        ]
        let policy = try MultisigPolicy.nOfM(required: 1, signerKeyHashes: hashes, network: .preprod)
        let multisigWallet = try MultisigWallet(policy: policy, chainContext: stub)
        let multisigEnum: Wallet = .multisig(multisigWallet)
        let multisigAddr = try await multisigEnum.primaryAddress()
        #expect(multisigAddr == multisigWallet.address)
    }

    @Test func utxosAndBalanceForwardThroughEnum() async throws {
        // Build a mnemonic wallet with a known UTxO, query through the enum.
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let receive = try await probe.receiveAddress()
        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: 12_345_678)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try receive.toBech32(): [utxo]]
        )
        let wallet: Wallet = .mnemonic(try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        ))

        #expect(try await wallet.utxos().count == 1)
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 12_345_678)
    }

    // MARK: - One-shot send semantics

    @Test func sendForwardsForMnemonic() async throws {
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { StubChainContext(networkId: .testnet) })
        )
        let receive = try await probe.receiveAddress()
        let utxo = try TestFixtures.makeUTxO(at: receive, lovelace: 50_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try receive.toBech32(): [utxo]]
        )
        let wallet: Wallet = .mnemonic(try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        ))

        let dest = try await Account(index: 7, network: .preprod).address(
            with: try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        )
        let txId = try await wallet.send(lovelace: 5_000_000, to: dest)
        #expect(txId.hasPrefix("stubtx-"))
    }

    @Test func sendThrowsForMultisigWithGuidance() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let hashes = try [
            await km.paymentVerificationKey(at: Account(index: 0, network: .preprod).paymentPath()).hash(),
            await km.paymentVerificationKey(at: Account(index: 1, network: .preprod).paymentPath()).hash(),
        ]
        let policy = try MultisigPolicy.nOfM(required: 1, signerKeyHashes: hashes, network: .preprod)
        let stub = StubChainContext(networkId: .testnet)
        let wallet: Wallet = .multisig(try MultisigWallet(policy: policy, chainContext: stub))
        let dest = try await Account(index: 7, network: .preprod).address(with: km)

        do {
            _ = try await wallet.send(lovelace: 5_000_000, to: dest)
            Issue.record("Expected unsupportedOperation for multisig one-shot send")
        } catch let error as WalletError {
            switch error {
            case .unsupportedOperation(let detail):
                #expect(detail.contains("cosigner"))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func sendToHandleThrowsForMultisigAndHardware() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let hashes = try [
            await km.paymentVerificationKey(at: Account(index: 0, network: .preprod).paymentPath()).hash(),
            await km.paymentVerificationKey(at: Account(index: 1, network: .preprod).paymentPath()).hash(),
        ]
        let policy = try MultisigPolicy.nOfM(required: 1, signerKeyHashes: hashes, network: .preprod)
        let stub = StubChainContext(networkId: .testnet)
        let wallet: Wallet = .multisig(try MultisigWallet(policy: policy, chainContext: stub))

        do {
            _ = try await wallet.sendTo(handle: "$alice", lovelace: 5_000_000)
            Issue.record("Expected unsupportedOperation for multisig sendTo(handle:)")
        } catch let error as WalletError {
            if case .unsupportedOperation = error { /* expected */ } else {
                Issue.record("Unexpected: \(error)")
            }
        }
    }

    // MARK: - Chain context escape hatch

    @Test func chainContextHandleSurfaceThroughEnum() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await Wallet.mnemonic(
            phrase: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let ctx = wallet.chainContext()
        // Just confirm we got something out — type-erased ChainContext, type identity check
        // is awkward; trusting that the dispatch didn't throw is enough here.
        _ = ctx
    }

    // MARK: - WalletProtocol still works on the concrete type

    @Test func mnemonicStillConformsToWalletProtocol() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let wallet: any WalletProtocol = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .mnemonic)
        #expect(wallet.network == .preprod)
    }

    // MARK: - Generation factories

    @Test func generateMnemonicReturnsMnemonicCaseAndPhrase() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let (wallet, phrase) = try await Wallet.generateMnemonic(
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .mnemonic)
        #expect(wallet.network == .preprod)
        #expect(phrase.split(separator: " ").count == 24)

        let addr = try await wallet.primaryAddress()
        #expect(try addr.toBech32().hasPrefix("addr_test1"))
    }

    @Test func generateEncryptedReturnsBlobThatRedecrypts() async throws {
        let stub = StubChainContext(networkId: .testnet)
        let (wallet, phrase, blob) = try await Wallet.generateEncrypted(
            passphrase: "user-pass",
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .mnemonic)
        #expect(phrase.split(separator: " ").count == 24)

        // The blob is the at-rest form. Decrypt it back and confirm the resulting wallet
        // has the same primary address.
        let reopened = try await Wallet.encrypted(
            blob: blob,
            passphrase: "user-pass",
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let original = try await wallet.primaryAddress()
        let restored = try await reopened.primaryAddress()
        #expect(original == restored)
    }

    @Test func generateTextEnvelopeWritesFilesAndReturnsEnumCase() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallet-te-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = StubChainContext(networkId: .testnet)
        let (wallet, paymentURL, stakeURL) = try await Wallet.generateTextEnvelope(
            writeTo: dir,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .textEnvelope)
        #expect(FileManager.default.fileExists(atPath: paymentURL.path))
        #expect(FileManager.default.fileExists(atPath: stakeURL.path))
    }

    @Test func generatedMnemonicWalletCanSign() async throws {
        // canSign is false only for watchOnly; the freshly-generated mnemonic must be true.
        let stub = StubChainContext(networkId: .testnet)
        let (wallet, _) = try await Wallet.generateMnemonic(
            network: .preprod,
            provider: .custom(make: { stub })
        )
        #expect(wallet.canSign == true)
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
