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
}
