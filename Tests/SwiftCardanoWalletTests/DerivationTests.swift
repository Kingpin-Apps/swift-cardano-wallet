import Testing
import SwiftCardanoCore
@testable import SwiftCardanoWallet

@Suite("Derivation paths")
struct DerivationPathTests {
    @Test func paymentPathFormatting() {
        let p = DerivationPath.payment(account: 0, index: 0)
        #expect(p.description == "m/1852'/1815'/0'/0/0")
    }

    @Test func stakePathRoleIs2() {
        let p = DerivationPath.stake(account: 0, index: 0)
        #expect(p.role == .stake)
        #expect(p.description == "m/1852'/1815'/0'/2/0")
    }

    @Test func changePathRoleIs1() {
        let p = DerivationPath.change(account: 0, index: 5)
        #expect(p.description == "m/1852'/1815'/0'/1/5")
    }

    @Test func multisigPurpose() {
        let p = DerivationPath.payment(account: 0, index: 0, purpose: DerivationPath.multisigPurpose)
        #expect(p.description == "m/1854'/1815'/0'/0/0")
    }

    @Test func varyingAccountIndex() {
        let p0 = DerivationPath.payment(account: 0, index: 0)
        let p1 = DerivationPath.payment(account: 1, index: 0)
        #expect(p0 != p1)
        #expect(p1.description == "m/1852'/1815'/1'/0/0")
    }
}

// Standard BIP-39 test vector: 12 zero-entropy words.
private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("MnemonicKeyManager + Account")
struct MnemonicKeyManagerTests {

    @Test func constructionFromValidMnemonic() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        #expect(km.kind == .mnemonic)
        #expect(km.canSign == true)
    }

    @Test func constructionFromInvalidMnemonicThrows() throws {
        #expect(throws: WalletError.self) {
            _ = try MnemonicKeyManager(mnemonic: "not a real mnemonic phrase at all")
        }
    }

    @Test func deterministicPaymentVerificationKey() async throws {
        let km1 = try MnemonicKeyManager(mnemonic: testMnemonic)
        let km2 = try MnemonicKeyManager(mnemonic: testMnemonic)
        let path = DerivationPath.payment(account: 0, index: 0)
        let v1 = try await km1.paymentVerificationKey(at: path)
        let v2 = try await km2.paymentVerificationKey(at: path)
        #expect(v1.payload == v2.payload)
    }

    @Test func differentIndicesProduceDifferentKeys() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let v0 = try await km.paymentVerificationKey(at: .payment(account: 0, index: 0))
        let v1 = try await km.paymentVerificationKey(at: .payment(account: 0, index: 1))
        #expect(v0.payload != v1.payload)
    }

    @Test func differentAccountsProduceDifferentKeys() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let v0 = try await km.paymentVerificationKey(at: .payment(account: 0))
        let v1 = try await km.paymentVerificationKey(at: .payment(account: 1))
        #expect(v0.payload != v1.payload)
    }

    @Test func passphraseChangesDerivation() async throws {
        let kmA = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "")
        let kmB = try MnemonicKeyManager(mnemonic: testMnemonic, passphrase: "TREZOR")
        let path = DerivationPath.payment(account: 0, index: 0)
        let a = try await kmA.paymentVerificationKey(at: path)
        let b = try await kmB.paymentVerificationKey(at: path)
        #expect(a.payload != b.payload)
    }

    @Test func paymentAndStakeKeysDiffer() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let p = try await km.paymentVerificationKey(at: .payment(account: 0))
        let s = try await km.stakeVerificationKey(at: .stake(account: 0))
        #expect(p.payload != s.payload)
    }

    @Test func mainnetAddressHasMainnetHrp() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(index: 0, network: .mainnet)
        let addr = try await acct.address(with: km)
        let bech32 = try addr.toBech32()
        #expect(bech32.hasPrefix("addr1"))
        #expect(addr.network == .mainnet)
    }

    @Test func testnetAddressHasTestnetHrp() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(index: 0, network: .preprod)
        let addr = try await acct.address(with: km)
        let bech32 = try addr.toBech32()
        #expect(bech32.hasPrefix("addr_test1"))
        #expect(addr.network == .testnet)
    }

    @Test func rewardAddressHasNoPaymentPart() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(index: 0, network: .mainnet)
        let reward = try await acct.rewardAddress(with: km)
        #expect(reward.paymentPart == nil)
        #expect(reward.stakingPart != nil)
        let bech32 = try reward.toBech32()
        #expect(bech32.hasPrefix("stake1"))
    }

    @Test func enterpriseAddressHasNoStakePart() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let acct = Account(index: 0, network: .mainnet)
        let enterprise = try await acct.enterpriseAddress(with: km)
        #expect(enterprise.paymentPart != nil)
        #expect(enterprise.stakingPart == nil)
    }

    @Test func differentAccountsProduceDifferentAddresses() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let addr0 = try await Account(index: 0, network: .mainnet).address(with: km)
        let addr1 = try await Account(index: 1, network: .mainnet).address(with: km)
        #expect(addr0 != addr1)
    }

    @Test func cachingIsDeterministic() async throws {
        let km = try MnemonicKeyManager(mnemonic: testMnemonic)
        let path = DerivationPath.payment(account: 0, index: 0)
        let first = try await km.paymentSigningKey(at: path)
        let second = try await km.paymentSigningKey(at: path)
        #expect(first.payload == second.payload)
    }
}
