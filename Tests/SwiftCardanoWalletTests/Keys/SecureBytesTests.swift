import Testing
import Foundation
@testable import SwiftCardanoWallet

@Suite("Data.zeroize")
struct ZeroizeTests {

    @Test func zeroizeReplacesContentWithZeros() {
        var buf = Data([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03])
        buf.zeroize()
        #expect(buf == Data(repeating: 0, count: 7))
    }

    @Test func zeroizeIsSafeOnEmpty() {
        var buf = Data()
        buf.zeroize()  // must not crash
        #expect(buf.isEmpty)
    }
}
