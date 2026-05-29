import Testing
import SwiftCardanoCore
import SwiftCardanoChain
import SwiftMnemonic
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("MnemonicWallet over a stub ChainContext")
struct MnemonicWalletTests {

    @Test func receiveAddressIsDeterministicAndOnNetwork() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let a = try await wallet.receiveAddress()
        let b = try await wallet.receiveAddress()
        #expect(a == b)
        #expect(try a.toBech32().hasPrefix("addr1"))
    }

    @Test func receiveAndChangeAddressDiffer() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let receive = try await wallet.receiveAddress()
        let change = try await wallet.changeAddress()
        #expect(receive != change)
    }

    @Test func emptyUtxoListGivesZeroBalance() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let balance = try await wallet.balance()
        #expect(balance.lovelace == 0)
        #expect(balance.utxoCount == 0)
    }

    @Test func balanceSumsLovelaceAcrossUtxos() async throws {
        // Construct a wallet, capture its receive address, then build a stub that
        // returns three UTxOs at that exact address.
        let probe = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { StubChainContext() })
        )
        let receive = try await probe.receiveAddress()
        let receiveBech32 = try receive.toBech32()

        let utxos = try [
            TestFixtures.makeUTxO(at: receive, lovelace: 1_500_000, index: 0),
            TestFixtures.makeUTxO(at: receive, lovelace:   500_000, index: 1),
            TestFixtures.makeUTxO(at: receive, lovelace: 8_000_000, index: 2),
        ]
        let stub = StubChainContext(utxos: [receiveBech32: utxos])

        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )

        let fetched = try await wallet.utxos()
        let balance = try await wallet.balance()
        #expect(fetched.count == 3)
        #expect(balance.utxoCount == 3)
        #expect(balance.lovelace == 10_000_000)
    }

    @Test func mismatchedNetworkAndProviderThrows() async throws {
        // .blockfrost(network: .preprod) but wallet says .mainnet — should reject
        // before we attempt any network call.
        do {
            _ = try await MnemonicWallet(
                mnemonic: testMnemonic,
                network: .mainnet,
                provider: .blockfrost(projectId: "irrelevant", network: .preprod)
            )
            Issue.record("Expected configurationMissing error")
        } catch let error as WalletError {
            switch error {
            case .configurationMissing:
                break
            default:
                Issue.record("Unexpected WalletError: \(error)")
            }
        }
    }

    @Test func customProviderSkipsNetworkSanityCheck() async throws {
        // .custom doesn't enforce network alignment — caller is trusted.
        let stub = StubChainContext(networkId: .testnet)
        let wallet = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .preprod,
            provider: .custom(make: { stub })
        )
        let addr = try await wallet.receiveAddress()
        #expect(try addr.toBech32().hasPrefix("addr_test1"))
    }

    @Test func walletConformsToProtocol() async throws {
        let stub = StubChainContext()
        let wallet: any WalletProtocol = try await MnemonicWallet(
            mnemonic: testMnemonic,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(wallet.kind == .mnemonic)
        #expect(wallet.network == .mainnet)
        #expect(wallet.account.index == 0)
    }

    // MARK: - Generation

    @Test func generateProducesUsableWalletWithCorrectWordCount() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let generated = try await MnemonicWallet.generate(
            wordCount: 24,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let words = generated.phrase.split(separator: " ")
        #expect(words.count == 24)
        let addr = try await generated.wallet.receiveAddress()
        #expect(try addr.toBech32().hasPrefix("addr1"))
    }

    @Test func generateDefaultsTo24Words() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let generated = try await MnemonicWallet.generate(
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(generated.phrase.split(separator: " ").count == 24)
    }

    @Test func generateSupports12WordPhrases() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let generated = try await MnemonicWallet.generate(
            wordCount: 12,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(generated.phrase.split(separator: " ").count == 12)
    }

    @Test func generateRejectsInvalidWordCount() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        for bad in [0, 11, 13, 20, 25, 30] {
            do {
                _ = try await MnemonicWallet.generate(
                    wordCount: bad,
                    network: .mainnet,
                    provider: .custom(make: { stub })
                )
                Issue.record("Expected configurationMissing for wordCount=\(bad)")
            } catch let error as WalletError {
                if case .configurationMissing = error { /* expected */ } else {
                    Issue.record("Unexpected: \(error)")
                }
            }
        }
    }

    @Test func generatedWalletsAreNonDeterministic() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let a = try await MnemonicWallet.generate(
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        let b = try await MnemonicWallet.generate(
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(a.phrase != b.phrase)
        let addrA = try await a.wallet.receiveAddress()
        let addrB = try await b.wallet.receiveAddress()
        #expect(addrA != addrB)
    }

    @Test func generatedPhraseRoundTripsThroughMnemonicKeyManager() async throws {
        // Generated phrase + the same passphrase must build a deterministic KM that
        // matches the wallet's derived key. Confirms the phrase the caller sees is the
        // actual recovery material, not a divergent representation.
        let stub = StubChainContext(networkId: .mainnet)
        let generated = try await MnemonicWallet.generate(
            network: .mainnet,
            provider: .custom(make: { stub }),
            passphrase: "extra"
        )
        let km = try MnemonicKeyManager(mnemonic: generated.phrase, passphrase: "extra")
        let acct = Account(network: .mainnet)
        let expected = try await acct.address(with: km)
        let actual = try await generated.wallet.receiveAddress()
        #expect(expected == actual)
    }

    @Test func generatedEntropyDecodesToCorrectLength() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        for (words, expectedBytes) in [(12, 16), (15, 20), (18, 24), (21, 28), (24, 32)] {
            let generated = try await MnemonicWallet.generate(
                wordCount: words,
                network: .mainnet,
                provider: .custom(make: { stub })
            )
            #expect(generated.entropy.count == expectedBytes)
        }
    }

    @Test func generateDefaultsToEnglishLanguage() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let generated = try await MnemonicWallet.generate(
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(generated.language == .english)
    }

    @Test func generateExplicitlyAcceptsEnglish() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let generated = try await MnemonicWallet.generate(
            language: .english,
            network: .mainnet,
            provider: .custom(make: { stub })
        )
        #expect(generated.language == .english)
    }

    /// Non-English languages aren't supported end-to-end yet — see the docstring on
    /// `MnemonicWallet.generate`. The API still accepts a `language:` argument so the
    /// signature is forward-compatible.
    @Test func generateRejectsNonEnglishLanguagesWithUnsupportedOperation() async throws {
        let stub = StubChainContext(networkId: .mainnet)
        let unsupported: [SwiftMnemonic.Language] = [.japanese, .spanish, .french, .chinese_simplified]
        for lang in unsupported {
            do {
                _ = try await MnemonicWallet.generate(
                    language: lang,
                    network: .mainnet,
                    provider: .custom(make: { stub })
                )
                Issue.record("Expected unsupportedOperation for \(lang)")
            } catch let error as WalletError {
                if case .unsupportedOperation = error { /* expected */ } else {
                    Issue.record("Unexpected error variant for \(lang): \(error)")
                }
            }
        }
    }
}
