#if HARDWARE // hardware-wallet path (cardano-hw-cli via SwiftCardanoUtils) — macOS/Linux, trait-gated
import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoUtils
import SystemPackage

/// Unsigned transaction produced by ``HardwareWallet/prepareSend(lovelace:to:)``, plus the
/// metadata needed to drive the signing flow against a Ledger / Trezor.
///
/// Two ways to finish signing:
///
/// 1. **Manual** — for offline / air-gapped workflows.
///    - ``writeTxBody(to:)`` writes the unsigned `Transaction` as a TextEnvelope file.
///    - The user runs `cardano-hw-cli` themselves to produce one `.witness` file per
///      signing key.
///    - ``attachWitnesses(fromFiles:)`` reads those files and assembles the final
///      ``SignedTransaction`` in-process. **No `cardano-cli` required** — assembly happens
///      in pure Swift.
///
/// 2. **Driven** — when the device is connected to the same machine.
///    - ``signWithDevice()`` runs the full sequence: serialise → autocorrect → start
///      device → witness → parse → assemble. Requires the wallet to have been built with a
///      ``CardanoHWCLI``.
///
/// Both paths produce the same in-process witness merge: read each `.witness` file as a
/// ``SwiftCardanoCore/VerificationKeyWitness`` TextEnvelope, drop them into the witness
/// set, return a ``SignedTransaction``.
public struct PreparedHardwareTransaction: Sendable {

    public let transaction: Transaction
    public let chainContext: any ChainContext

    private let payment: HardwareKeyFile
    private let stake: HardwareKeyFile?
    private let hwcli: CardanoHWCLI?

    public init(
        transaction: Transaction,
        payment: HardwareKeyFile,
        stake: HardwareKeyFile? = nil,
        chainContext: any ChainContext,
        hwcli: CardanoHWCLI? = nil
    ) {
        self.transaction = transaction
        self.payment = payment
        self.stake = stake
        self.chainContext = chainContext
        self.hwcli = hwcli
    }

    /// CBOR encoding of the (still-unsigned) transaction.
    public func exportCBOR() -> Data {
        transaction.payload
    }

    // MARK: - Manual flow

    /// Write the unsigned `Transaction` as a TextEnvelope JSON file (the format
    /// `cardano-hw-cli` expects via `--tx-file`).
    public func writeTxBody(to path: String) throws {
        do {
            try transaction.save(to: path, overwrite: true)
        } catch {
            throw WalletError.signingFailed("Failed to write tx body to '\(path)': \(error)")
        }
    }

    /// Read the supplied `.witness` files (`VerificationKeyWitness` TextEnvelopes) and
    /// merge them into the witness set. Returns a fully-signed ``SignedTransaction``.
    public func attachWitnesses(fromFiles paths: [String]) throws -> SignedTransaction {
        guard !paths.isEmpty else {
            throw WalletError.signingFailed("attachWitnesses called with no witness files")
        }
        var witnesses: [VerificationKeyWitness] = []
        for path in paths {
            let w: VerificationKeyWitness
            do {
                w = try VerificationKeyWitness.load(from: path)
            } catch {
                throw WalletError.signingFailed("Failed to load witness file '\(path)': \(error)")
            }
            witnesses.append(w)
        }
        return finalise(witnesses: witnesses)
    }

    // MARK: - Driven flow

    /// Run the full hardware signing sequence using the injected ``CardanoHWCLI``.
    ///
    /// 1. Write the unsigned tx to a temp file.
    /// 2. `cardano-hw-cli transaction transform` (`autocorrectTxBodyFile`).
    /// 3. `cardano-hw-cli transaction witness ...` to produce one `.witness` file per
    ///    `.hwsfile`.
    /// 4. Optionally `cardano-hw-cli device start` to wake the device (called automatically
    ///    if `wakeDevice` is `true`, which is the default).
    /// 5. Read witness files in-process and assemble.
    ///
    /// Cleans up the temp directory whether signing succeeds or fails.
    public func signWithDevice(wakeDevice: Bool = true) async throws -> SignedTransaction {
        guard let hwcli else {
            throw WalletError.configurationMissing(
                "signWithDevice requires a CardanoHWCLI; pass one to HardwareWallet.init."
            )
        }

        // Build a list of (hwsfile, .witness output) pairs — payment always present, stake
        // only if it was supplied.
        var hwsfiles: [FilePath] = [FilePath(payment.hwsfilePath)]
        if let stake { hwsfiles.append(FilePath(stake.hwsfilePath)) }

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let txFile = FilePath((tempDir as NSString).appendingPathComponent("tx.txbody"))
        let witnessFiles: [FilePath] = (0..<hwsfiles.count).map { i in
            FilePath((tempDir as NSString).appendingPathComponent("\(i).witness"))
        }

        do {
            try writeTxBody(to: txFile.string)
        } catch {
            throw error
        }

        do {
            try await hwcli.autocorrectTxBodyFile(txBodyFile: txFile.string)
        } catch {
            throw WalletError.signingFailed("autocorrectTxBodyFile failed: \(error)")
        }

        if wakeDevice {
            do {
                _ = try await hwcli.startHardwareWallet()
            } catch {
                throw WalletError.signingFailed("startHardwareWallet failed: \(error)")
            }
        }

        do {
            _ = try await hwcli.transaction.witness(
                txFile: txFile,
                hwSigningFiles: hwsfiles,
                outFiles: witnessFiles,
                changeOutputKeyFiles: hwsfiles
            )
        } catch {
            throw WalletError.signingFailed("transaction.witness failed: \(error)")
        }

        return try attachWitnesses(fromFiles: witnessFiles.map(\.string))
    }

    // MARK: - Internals

    private func finalise(witnesses: [VerificationKeyWitness]) -> SignedTransaction {
        var witnessSet = transaction.transactionWitnessSet
        if !witnesses.isEmpty {
            witnessSet.vkeyWitnesses = .nonEmptyOrderedSet(NonEmptyOrderedSet(witnesses))
        }
        let signed = Transaction(
            transactionBody: transaction.transactionBody,
            transactionWitnessSet: witnessSet,
            valid: transaction.valid,
            auxiliaryData: transaction.auxiliaryData
        )
        return SignedTransaction(transaction: signed, chainContext: chainContext)
    }

    private func makeTempDir() throws -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("swift-cardano-wallet-hw-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true
            )
        } catch {
            throw WalletError.signingFailed("Could not create temp dir for hw signing: \(error)")
        }
        return dir
    }
}

#endif
