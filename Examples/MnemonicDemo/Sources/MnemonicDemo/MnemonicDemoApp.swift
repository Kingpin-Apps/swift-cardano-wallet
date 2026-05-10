import SwiftUI
import SwiftCardanoCore
import SwiftCardanoWallet

/// Tiny SwiftUI app that takes a mnemonic, opens a `MnemonicWallet` against Koios mainnet,
/// and shows the receive address + lovelace balance. Read-only — no send button.
@main
struct MnemonicDemoApp: App {
    var body: some Scene {
        WindowGroup("Cardano Wallet Demo") {
            ContentView()
                .frame(minWidth: 520, minHeight: 360)
        }
    }
}

/// Network choices we expose in the picker. `Network` itself isn't `Hashable` (and
/// SwiftUI's `Picker` requires it), so we round-trip through this enum.
enum NetworkChoice: String, CaseIterable, Identifiable {
    case mainnet, preprod, preview

    var id: String { rawValue }

    var network: Network {
        switch self {
        case .mainnet: return .mainnet
        case .preprod: return .preprod
        case .preview: return .preview
        }
    }
}

@MainActor
final class WalletViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case ready(address: String, lovelace: Int)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var mnemonic: String = ""
    @Published var network: NetworkChoice = .mainnet

    func open() async {
        state = .loading
        let phrase = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            state = .failed("Mnemonic cannot be empty.")
            return
        }
        do {
            let net = network.network
            let wallet = try await MnemonicWallet(
                mnemonic: phrase,
                network: net,
                provider: .koios(network: net)
            )
            let address = try await wallet.receiveAddress()
            let bech32 = try address.toBech32()
            let balance = try await wallet.balance()
            state = .ready(address: bech32, lovelace: balance.lovelace)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = WalletViewModel()

    var body: some View {
        Form {
            Section("Inputs") {
                Picker("Network", selection: $viewModel.network) {
                    ForEach(NetworkChoice.allCases) { choice in
                        Text(choice.rawValue.capitalized).tag(choice)
                    }
                }
                .pickerStyle(.segmented)

                TextEditor(text: $viewModel.mnemonic)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .border(.gray.opacity(0.3))
                    .help("Paste your 12 / 15 / 24 word BIP-39 phrase")

                Button("Open wallet") {
                    Task { await viewModel.open() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.mnemonic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("State") {
                switch viewModel.state {
                case .idle:
                    Text("Enter a mnemonic to begin.")
                        .foregroundStyle(.secondary)

                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Talking to chain…")
                    }

                case .ready(let address, let lovelace):
                    LabeledContent("Receive address") {
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    LabeledContent("Balance") {
                        Text("\(lovelace.formatted()) lovelace (\(lovelaceAsAda(lovelace)) ADA)")
                            .monospacedDigit()
                    }

                case .failed(let detail):
                    Text(detail)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
    }

    private func lovelaceAsAda(_ lovelace: Int) -> String {
        let ada = Double(lovelace) / 1_000_000.0
        return String(format: "%.6f", ada)
    }
}
