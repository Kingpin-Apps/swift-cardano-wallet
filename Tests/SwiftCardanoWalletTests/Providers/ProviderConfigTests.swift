import Testing
import SwiftCardanoCore
import SwiftCardanoChain
@testable import SwiftCardanoWallet

@Suite("ProviderConfig.network")
struct ProviderConfigTests {

    @Test func blockfrostExposesItsNetwork() {
        #expect(ProviderConfig.blockfrost(projectId: "k", network: .mainnet).network == .mainnet)
        #expect(ProviderConfig.blockfrost(projectId: "k", network: .preprod).network == .preprod)
        #expect(ProviderConfig.blockfrost(projectId: "k", network: .preview).network == .preview)
    }

    @Test func koiosExposesItsNetwork() {
        #expect(ProviderConfig.koios(network: .mainnet).network == .mainnet)
        #expect(ProviderConfig.koios(network: .preprod, apiKey: nil).network == .preprod)
    }

    @Test func offlineExposesItsNetwork() {
        #expect(ProviderConfig.offline(filePath: "/tmp/x", network: .preview).network == .preview)
    }

    @Test func customDefaultsToMainnetForSanityCheck() {
        // Custom contexts are trusted by the wallet, so the configured network is the
        // wallet-side `network:` argument. ProviderConfig.network returns mainnet as a
        // safe default that's only used for the sanity-check skip path.
        let custom = ProviderConfig.custom(make: { StubChainContext() })
        #expect(custom.network == .mainnet)
    }
}
