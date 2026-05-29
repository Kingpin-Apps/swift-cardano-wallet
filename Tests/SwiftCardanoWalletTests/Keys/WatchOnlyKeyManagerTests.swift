import Testing
import SwiftCardanoCore
@testable import SwiftCardanoWallet

private let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

@Suite("WatchOnlyKeyManager")
struct WatchOnlyKeyManagerTests {

    @Test func canDeriveAddressFromVerificationKeysOnly() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let pVKey = try await mnemonicKM.paymentVerificationKey(at: .payment())
        let sVKey = try await mnemonicKM.stakeVerificationKey(at: .stake())

        let watch = WatchOnlyKeyManager(
            paymentVerificationKey: pVKey,
            stakeVerificationKey: sVKey
        )
        #expect(watch.canSign == false)

        let acct = Account(network: .mainnet)
        let addrM = try await acct.address(with: mnemonicKM)
        let addrW = try await acct.address(with: watch)
        #expect(addrM == addrW)
    }

    @Test func signingThrowsWatchOnly() async throws {
        let mnemonicKM = try MnemonicKeyManager(mnemonic: testMnemonic)
        let pVKey = try await mnemonicKM.paymentVerificationKey(at: .payment())
        let watch = WatchOnlyKeyManager(paymentVerificationKey: pVKey)

        do {
            _ = try watch.paymentSigningKeyType(at: .payment())
            Issue.record("Expected watchOnly error")
        } catch let error as WalletError {
            #expect(error == .watchOnly)
        }
    }
}
