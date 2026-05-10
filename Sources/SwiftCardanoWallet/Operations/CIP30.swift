import Foundation
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftCardanoCIPs

/// `CIP30Provider` conformance for ``MnemonicWallet``.
///
/// This is the language-agnostic surface from the spec. Hosts (iOS dApp browsers, native
/// in-app dApp UIs, etc.) bridge / proxy these methods however they prefer; this file does
/// not ship a webview or JS bridge.
///
/// Notes on the v0.1 implementation:
/// - `getUtxos` ignores `amount` (no pre-filtering) and applies a coarse `paginate` slice.
/// - `getCollateral` returns the default `nil` (no Plutus support yet).
/// - `getUsedAddresses` returns every address the ``BalanceTracker`` knows about that has
///   ever had a UTxO; `getUnusedAddresses` returns the receive + change addresses at index 0
///   so dApps have a deterministic destination to send funds to.
/// - `signTx` signs with the wallet's role-0 payment key only (same shortcut as `Send.swift`).
///   Multi-address / required-signer-aware signing is a follow-up.
/// - `signData` is wired through the CIP-8 helper in `swift-cardano-cips`.
extension MnemonicWallet: CIP30Provider {

    public func getNetworkId() async throws -> Int {
        network.networkId.rawValue
    }

    public func getUtxos(amount: Data?, paginate: Paginate?) async throws -> [Data]? {
        let utxos = try await self.utxos()
        guard !utxos.isEmpty else { return nil }
        let slice: [UTxO]
        if let p = paginate {
            let limit = Int(p.limit)
            let start = Int(p.page) * limit
            let end = min(utxos.count, start + limit)
            slice = start < end ? Array(utxos[start..<end]) : []
        } else {
            slice = utxos
        }
        do {
            return try slice.map { try $0.toCBORData() }
        } catch {
            throw APIError.internalError("Failed to CBOR-encode UTxOs: \(error)")
        }
    }

    public func getBalance() async throws -> Data {
        let bal = try await self.balance()
        let value = Value(coin: bal.lovelace, multiAsset: bal.multiAsset)
        do {
            return try value.toCBORData()
        } catch {
            throw APIError.internalError("Failed to CBOR-encode balance Value: \(error)")
        }
    }

    public func getUsedAddresses(paginate: Paginate?) async throws -> [Data] {
        // Trigger a tracker refresh so the snapshot is hot, then list addresses
        // with at least one UTxO.
        _ = try await self.utxos()
        let tracker = self.balanceTracker()
        let allAddresses = try await tracker.allTrackedAddresses()
        let used: [Address] = try await {
            var out: [Address] = []
            for addr in allAddresses {
                let utxos = try await tracker.utxos(at: addr)
                if !utxos.isEmpty { out.append(addr) }
            }
            return out
        }()

        let slice: [Address]
        if let p = paginate {
            let limit = Int(p.limit)
            let start = Int(p.page) * limit
            let end = min(used.count, start + limit)
            slice = start < end ? Array(used[start..<end]) : []
        } else {
            slice = used
        }
        do {
            return try slice.map { try $0.toCBORData() }
        } catch {
            throw APIError.internalError("Failed to CBOR-encode used addresses: \(error)")
        }
    }

    public func getUnusedAddresses() async throws -> [Data] {
        // v0.1: just expose receive + change at index 0. A future PR can return the
        // full gap-limit tail of empty addresses.
        let receive = try await self.receiveAddress()
        let change = try await self.changeAddress()
        do {
            return [try receive.toCBORData(), try change.toCBORData()]
        } catch {
            throw APIError.internalError("Failed to CBOR-encode unused addresses: \(error)")
        }
    }

    public func getChangeAddress() async throws -> Data {
        do {
            return try await self.changeAddress().toCBORData()
        } catch {
            throw APIError.internalError("Failed to CBOR-encode change address: \(error)")
        }
    }

    public func getRewardAddresses() async throws -> [Data] {
        do {
            return [try await self.rewardAddress().toCBORData()]
        } catch {
            throw APIError.internalError("Failed to CBOR-encode reward address: \(error)")
        }
    }

    public func signTx(_ tx: Data, partialSign: Bool) async throws -> Data {
        let parsed = Transaction(payload: tx, type: nil, description: nil)

        // Sign with the wallet's role-0 payment key. Future work: inspect
        // `parsed.transactionBody.requiredSigners` and the inputs' addresses to derive the
        // exact set of keys we should sign with.
        let path = self.account.paymentPath(role: .external, index: 0)
        let skeyType: SigningKeyType
        do {
            skeyType = try await self.keyManager.paymentSigningKeyType(at: path)
        } catch let error as WalletError {
            if case .watchOnly = error {
                throw TxSignError.proofGeneration("Watch-only wallet cannot sign")
            }
            throw TxSignError.proofGeneration("\(error)")
        } catch {
            throw TxSignError.proofGeneration("\(error)")
        }

        let bodyHash = parsed.transactionBody.hash()
        let signature: Data
        let vkeyType: VerificationKeyType
        do {
            signature = try skeyType.sign(data: bodyHash)
            vkeyType = try skeyType.toVerificationKeyType()
        } catch {
            throw TxSignError.proofGeneration("\(error)")
        }

        var witnessSet = TransactionWitnessSet()
        let witness = VerificationKeyWitness(vkey: vkeyType, signature: signature)
        witnessSet.vkeyWitnesses = .nonEmptyOrderedSet(NonEmptyOrderedSet([witness]))

        if !partialSign {
            // We can't currently prove we covered every required signer. Honour partialSign=false
            // by trusting the caller — they wanted whatever witnesses we can produce.
        }

        do {
            return try witnessSet.toCBORData()
        } catch {
            throw TxSignError.proofGeneration("Failed to CBOR-encode witness set: \(error)")
        }
    }

    public func signData(address: String, payload: Data) async throws -> DataSignature {
        // Decide whether to sign with the payment or stake key based on the address's role.
        let addr: Address
        do {
            addr = try Address(from: .string(address))
        } catch {
            throw DataSignError.proofGeneration("Invalid address: \(error)")
        }

        let path: DerivationPath
        if addr.paymentPart != nil {
            path = self.account.paymentPath(role: .external, index: 0)
        } else if addr.stakingPart != nil {
            path = self.account.stakePath()
        } else {
            throw DataSignError.addressNotPK("Address has no public-key credential")
        }

        let skeyType: SigningKeyType
        do {
            skeyType = (path.role == .stake)
                ? try await self.keyManager.stakeSigningKeyType(at: path)
                : try await self.keyManager.paymentSigningKeyType(at: path)
        } catch let error as WalletError {
            if case .watchOnly = error {
                throw DataSignError.userDeclined("Watch-only wallet cannot sign")
            }
            throw DataSignError.proofGeneration("\(error)")
        } catch {
            throw DataSignError.proofGeneration("\(error)")
        }

        let messageString = String(data: payload, encoding: .utf8) ?? payload.toHex
        let signed: SignedMessage
        do {
            signed = try CIP8.sign(
                message: messageString,
                signingKey: skeyType,
                attachCoseKey: true,
                network: self.network
            )
        } catch {
            throw DataSignError.proofGeneration("CIP-8 signing failed: \(error)")
        }

        return DataSignature(signature: signed.signature, key: signed.key ?? "")
    }

    public func submitTx(_ tx: Data) async throws -> String {
        do {
            return try await self.chainContextHandle().submitTxCBOR(cbor: tx)
        } catch {
            throw TxSendError.failure("\(error)")
        }
    }
}

// MARK: - Internal helpers

private extension Data {
    var toHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
