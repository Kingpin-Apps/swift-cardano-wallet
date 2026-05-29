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
