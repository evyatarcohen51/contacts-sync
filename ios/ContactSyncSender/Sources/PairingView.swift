import SwiftUI

struct PairingView: View {
    @EnvironmentObject var sync: SyncManager
    @StateObject private var browser = SamsungBrowser()
    @StateObject private var flow = PairingFlow()
    @Environment(\.dismiss) private var dismiss

    @State private var manualCode = ""
    @State private var manualHost = ""

    var body: some View {
        Form {
            switch flow.phase {
            case .idle, .failed:
                Section {
                    if browser.found.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Looking for the Samsung on this Wi-Fi…").padding(.leading, 8)
                        }
                    }
                    ForEach(browser.found) { item in
                        Button(item.name) { flow.pair(with: item, sync: sync) }
                    }
                    if let problem = browser.problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    if case .failed(let msg) = flow.phase {
                        Text(msg).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Find Samsung")
                } footer: {
                    Text("Put both phones on the same Wi-Fi. On the Samsung open \"iPhone Contacts\" and tap " +
                         "\"Pair iPhone (same Wi-Fi)\". The Samsung then shows up here.")
                }

                Section {
                    TextField("Pairing code (XXXX-XXXX-XXXX-XXXX)", text: $manualCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Samsung address (Tailscale 100.x.y.z)", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") {
                        let host = manualHost.trimmingCharacters(in: .whitespaces)
                        let isTailscale = host.hasPrefix("100.") || host.hasSuffix(".ts.net")
                        sync.savePairing(code: manualCode, device: "Samsung", port: Proto.port,
                                         tailscale: isTailscale ? host : nil, lan: isTailscale ? nil : host)
                        Task { await sync.syncNow(force: true) }
                        dismiss()
                    }
                    .disabled(!Proto.isValid(manualCode) || manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Or enter manually")
                } footer: {
                    Text("On the Samsung tap \"Pair manually with a code instead\" to see the code and address.")
                }

            case .connecting(let name):
                Section {
                    HStack {
                        ProgressView()
                        Text("Connecting to \(name)…").padding(.leading, 8)
                    }
                    Button("Cancel") { flow.cancel() }
                }

            case .confirm(let number, let device):
                Section {
                    VStack(spacing: 12) {
                        Text("Check that \(device) shows this number, then tap Accept on the Samsung:")
                            .multilineTextAlignment(.center)
                        Text(String(number.prefix(3)) + " " + String(number.suffix(3)))
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    Button("Cancel") { flow.cancel() }
                }

            case .done(let device):
                Section {
                    Label("Paired with \(device)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationTitle("Pair")
        .onAppear { browser.start() }
        .onDisappear {
            browser.stop()
            flow.cancel()
        }
    }
}
