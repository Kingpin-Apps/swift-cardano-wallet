import Testing
import Foundation
@testable import SwiftCardanoWallet

@Suite("PBKDF2 sanity")
struct PBKDF2Tests {

    @Test func differentPassphrasesProduceDifferentKeys() {
        let salt = Data(repeating: 0xab, count: 16)
        let a = PBKDF2.deriveKeySHA512(
            password: Data("a".utf8), salt: salt, iterations: 1000, keyLength: 32
        )
        let b = PBKDF2.deriveKeySHA512(
            password: Data("b".utf8), salt: salt, iterations: 1000, keyLength: 32
        )
        #expect(a != b)
        #expect(a.count == 32)
        #expect(b.count == 32)
    }

    @Test func deterministicForSameInputs() {
        let salt = Data("salt".utf8)
        let a = PBKDF2.deriveKeySHA512(
            password: Data("password".utf8), salt: salt, iterations: 1024, keyLength: 64
        )
        let b = PBKDF2.deriveKeySHA512(
            password: Data("password".utf8), salt: salt, iterations: 1024, keyLength: 64
        )
        #expect(a == b)
        #expect(a.count == 64)
    }
}
