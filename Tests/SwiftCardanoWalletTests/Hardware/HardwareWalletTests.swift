#if HARDWARE // hardware-wallet tests — Hardware trait only
import Testing
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("HardwareWallet — manual signing flow + address derivation")
struct HardwareWalletTests {

    // MARK: - Test fixtures

    /// Build a `HardwareKeyFile` pair backed by the test mnemonic. Writes the verification
    /// keys to a temp dir as TextEnvelope files so the wallet can load them like real
    /// `cardano-hw-cli`-generated `.vkey` files.
    ///
    /// The `.hwsfile` paths are bogus (we never invoke the device in unit tests); they're
    /// only consulted by the driven `signWithDevice()` path which we don't exercise here.
    private func makeKeyFiles(
        accountIndex: UInt32 = 0,
        network: Network = .preprod
    ) async throws -> (
        payment: HardwareKeyFile,
        stake: HardwareKeyFile,
        keyManager: MnemonicKeyManager,
        account: Account,
        tempDir: String
    ) {
        let tempDir = NSTemporaryDirectory().appending("hw-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )

        let km = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let account = Account(index: accountIndex, network: network)

        // Derive payment + stake verification keys (KeyManager already returns 32-byte
        // non-extended keys) and persist as TextEnvelope `.vkey` files matching what
        // `cardano-hw-cli address key-gen` would produce.
        let paymentVkey = try await km.paymentVerificationKey(at: account.paymentPath())
        let stakeVkey = try await km.stakeVerificationKey(at: account.stakePath())

        let paymentVkeyPath = (tempDir as NSString).appendingPathComponent("payment.vkey")
        let stakeVkeyPath = (tempDir as NSString).appendingPathComponent("stake.vkey")
        try paymentVkey.save(to: paymentVkeyPath, overwrite: true)
        try stakeVkey.save(to: stakeVkeyPath, overwrite: true)

        let paymentHwsfile = (tempDir as NSString).appendingPathComponent("payment.hwsfile")
        let stakeHwsfile = (tempDir as NSString).appendingPathComponent("stake.hwsfile")
        // Write a minimal placeholder so `signWithDevice` paths see a file (we never read it).
        try "{}".write(toFile: paymentHwsfile, atomically: true, encoding: .utf8)
        try "{}".write(toFile: stakeHwsfile, atomically: true, encoding: .utf8)

        let payment = HardwareKeyFile(
            hwsfilePath: paymentHwsfile,
            vkeyPath: paymentVkeyPath,
            role: .payment
        )
        let stake = HardwareKeyFile(
            hwsfilePath: stakeHwsfile,
            vkeyPath: stakeVkeyPath,
            role: .stake
        )
        return (payment, stake, km, account, tempDir)
    }

    // MARK: - HardwareKeyFile

    @Test func loadVerificationKeyParsesTextEnvelope() async throws {
        let (payment, _, _, _, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let vkey = try payment.loadVerificationKey()
        // Non-extended vkey is 32 bytes.
        switch vkey {
        case .verificationKey(let v):
            #expect(v.payload.count == 32)
        case .extendedVerificationKey:
            Issue.record("Expected non-extended (32-byte) vkey, got extended")
        }
    }

    @Test func keyHashReturnsBlake2b224() async throws {
        let (payment, _, _, _, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let hash = try payment.keyHash()
        #expect(hash.payload.count == 28)  // VerificationKeyHash is blake2b-224 = 28 bytes
    }

    @Test func loadFailsLoudlyWhenVkeyPathMissing() async throws {
        let bogus = HardwareKeyFile(
            hwsfilePath: "/no/such/path.hwsfile",
            vkeyPath: "/no/such/path.vkey",
            role: .payment
        )
        do {
            _ = try bogus.loadVerificationKey()
            Issue.record("Expected configurationMissing")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing: break
            default: Issue.record("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - HardwareWallet construction

    @Test func walletRejectsWrongRoleOnPaymentSlot() async throws {
        let (_, stake, _, _, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let stub = StubChainContext(networkId: .testnet)
        do {
            _ = try HardwareWallet(payment: stake, network: .preprod, chainContext: stub)
            Issue.record("Expected configurationMissing for stake-role file in payment slot")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing(let detail):
                #expect(detail.contains("payment"))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func walletDerivesBaseAddressWhenStakeProvided() async throws {
        let (payment, stake, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let stub = StubChainContext(networkId: .testnet)
        let wallet = try HardwareWallet(
            payment: payment,
            stake: stake,
            network: .preprod,
            chainContext: stub
        )
        // Should match the address derived through the same mnemonic + account.
        let expected = try await account.address(with: km)
        #expect(wallet.address == expected)
    }

    @Test func walletDerivesEnterpriseAddressWhenStakeOmitted() async throws {
        let (payment, _, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let stub = StubChainContext(networkId: .testnet)
        let wallet = try HardwareWallet(
            payment: payment,
            network: .preprod,
            chainContext: stub
        )
        let expected = try await account.enterpriseAddress(with: km)
        #expect(wallet.address == expected)
        #expect(wallet.address.stakingPart == nil)
    }

    @Test func walletKindReportsHardware() async throws {
        let (payment, _, _, _, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try HardwareWallet(payment: payment, network: .preprod, chainContext: stub)
        #expect(wallet.kind == .hardware)
    }

    // MARK: - Balance / UTxOs

    @Test func utxosAndBalanceQueryThroughChainContext() async throws {
        let (payment, stake, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let address = try await account.address(with: km)
        let utxo = try TestFixtures.makeUTxO(at: address, lovelace: 25_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try address.toBech32(): [utxo]]
        )
        let wallet = try HardwareWallet(
            payment: payment,
            stake: stake,
            network: .preprod,
            chainContext: stub
        )
        #expect(try await wallet.utxos().count == 1)
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 25_000_000)
        #expect(balance.utxoCount == 1)
    }

    // MARK: - prepareSend builds an unsigned tx

    @Test func prepareSendProducesUnsignedTransaction() async throws {
        let (payment, stake, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let walletAddr = try await account.address(with: km)
        let utxo = try TestFixtures.makeUTxO(at: walletAddr, lovelace: 5_000_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try walletAddr.toBech32(): [utxo]]
        )
        let wallet = try HardwareWallet(
            payment: payment,
            stake: stake,
            network: .preprod,
            chainContext: stub
        )

        let dest = try await Account(index: 7, network: .preprod).address(with: km)
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)

        // The unsigned tx should have one output to `dest` plus a change output to the
        // wallet itself, no vkey witnesses yet, and a non-zero fee.
        let body = prepared.transaction.transactionBody
        #expect(body.outputs.contains { $0.address == dest })
        #expect(body.fee > 0)
        let preWitnesses = prepared.transaction.transactionWitnessSet.vkeyWitnesses?.asList ?? []
        #expect(preWitnesses.isEmpty)
    }

    // MARK: - Manual flow: write tx body, externally sign, attach witnesses

    @Test func manualFlowAttachesExternallyProducedWitnesses() async throws {
        let (payment, stake, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let walletAddr = try await account.address(with: km)
        let utxo = try TestFixtures.makeUTxO(at: walletAddr, lovelace: 5_000_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try walletAddr.toBech32(): [utxo]]
        )
        let wallet = try HardwareWallet(
            payment: payment,
            stake: stake,
            network: .preprod,
            chainContext: stub
        )

        let dest = try await Account(index: 7, network: .preprod).address(with: km)
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)

        // Write the tx to disk — this is what cardano-hw-cli would consume.
        let txPath = (tempDir as NSString).appendingPathComponent("tx.txbody")
        try prepared.writeTxBody(to: txPath)
        #expect(FileManager.default.fileExists(atPath: txPath))

        // Simulate the device: sign the body hash with the payment software key, persist as
        // a `.witness` TextEnvelope. (Real cardano-hw-cli would do the same shape.)
        let bodyHash = prepared.transaction.transactionBody.hash()
        let paymentSkey = try await km.paymentSigningKeyType(at: account.paymentPath())
        let paymentSig = try paymentSkey.sign(data: bodyHash)
        let paymentWitness = VerificationKeyWitness(
            vkey: try paymentSkey.toVerificationKeyType(),
            signature: paymentSig
        )
        let paymentWitnessPath = (tempDir as NSString).appendingPathComponent("payment.witness")
        try paymentWitness.save(to: paymentWitnessPath, overwrite: true)

        // For a pure send we only need the payment witness, but the API supports merging
        // multiple witnesses — exercise that with a stake witness too.
        let stakeSkey = try await km.stakeSigningKeyType(at: account.stakePath())
        let stakeSig = try stakeSkey.sign(data: bodyHash)
        let stakeWitness = VerificationKeyWitness(
            vkey: try stakeSkey.toVerificationKeyType(),
            signature: stakeSig
        )
        let stakeWitnessPath = (tempDir as NSString).appendingPathComponent("stake.witness")
        try stakeWitness.save(to: stakeWitnessPath, overwrite: true)

        let signed = try prepared.attachWitnesses(fromFiles: [paymentWitnessPath, stakeWitnessPath])
        guard case .nonEmptyOrderedSet(let set) = signed.transaction.transactionWitnessSet.vkeyWitnesses else {
            Issue.record("Expected non-empty witnesses on signed tx")
            return
        }
        #expect(set.elements.count == 2)

        // Submit through the stub and check it received the bytes.
        let txid = try await signed.submit()
        #expect(txid.hasPrefix("stubtx-"))
    }

    @Test func attachWitnessesRejectsEmptyList() async throws {
        let (payment, _, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let walletAddr = try await account.enterpriseAddress(with: km)
        let utxo = try TestFixtures.makeUTxO(at: walletAddr, lovelace: 5_000_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try walletAddr.toBech32(): [utxo]]
        )
        let wallet = try HardwareWallet(
            payment: payment,
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).enterpriseAddress(with: km)
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)

        do {
            _ = try prepared.attachWitnesses(fromFiles: [])
            Issue.record("Expected signingFailed for empty witness list")
        } catch let error as WalletError {
            switch error {
            case .signingFailed: break
            default: Issue.record("Unexpected: \(error)")
            }
        }
    }

    @Test func signWithDeviceRequiresInjectedHwcli() async throws {
        let (payment, stake, km, account, tempDir) = try await makeKeyFiles()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let walletAddr = try await account.address(with: km)
        let utxo = try TestFixtures.makeUTxO(at: walletAddr, lovelace: 5_000_000_000)
        let stub = StubChainContext(
            networkId: .testnet,
            utxos: [try walletAddr.toBech32(): [utxo]]
        )
        // No hwcli injected — the driven flow should refuse to start.
        let wallet = try HardwareWallet(
            payment: payment,
            stake: stake,
            network: .preprod,
            chainContext: stub
        )
        let dest = try await Account(index: 7, network: .preprod).address(with: km)
        let prepared = try await wallet.prepareSend(lovelace: 5_000_000, to: dest)
        do {
            _ = try await prepared.signWithDevice()
            Issue.record("Expected configurationMissing without injected hwcli")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing(let detail):
                #expect(detail.contains("CardanoHWCLI"))
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}

#endif
