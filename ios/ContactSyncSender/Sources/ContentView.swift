import Contacts
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var sync: SyncManager

    var body: some View {
        NavigationStack {
            Form {
                if sync.contactsAccess != .authorized && sync.contactsAccess.rawValue != 4 {
                    Section {
                        Text("This app needs access to your contacts to send them to your Samsung.")
                        if sync.contactsAccess == .notDetermined {
                            Button("Allow Contacts access") { Task { await sync.requestContactsAccess() } }
                        } else {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }
                }

                Section("Status") {
                    row("Samsung", sync.isPaired ? (sync.receiverName.isEmpty ? "Paired" : sync.receiverName) : "Not paired")
                    LabeledContent("Last sync attempt") {
                        if let at = sync.lastAttemptAt {
                            VStack(alignment: .trailing, spacing: 2) {
                                // Today: just the time. Older: the date too.
                                Text(Calendar.current.isDateInToday(at)
                                     ? at.formatted(date: .omitted, time: .standard)
                                     : at.formatted(date: .abbreviated, time: .shortened))
                                (Text(at, style: .relative) + Text(" ago"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Never")
                        }
                    }
                    LabeledContent("Result") { resultLabel }
                    if sync.isPaired {
                        Text(sync.message)
                            .font(.footnote)
                            .foregroundStyle(sync.outcome == .failed ? Color.red : Color.secondary)
                    }
                    row("Contacts", "\(sync.lastCount)")
                    row("Last change sent", relative(sync.lastPushAt))
                    if !sync.connectedVia.isEmpty { row("Connected via", sync.connectedVia) }
                    Button {
                        Task { await sync.syncNow(force: true) }
                    } label: {
                        Text("Sync now")
                    }
                    .disabled(!sync.isPaired || sync.isSyncing)
                }

                Section {
                    Picker("Every", selection: $sync.intervalMinutes) {
                        Text("1 min").tag(1)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Include contact photos", isOn: $sync.includePhotos)
                    Toggle("Keep running in background", isOn: $sync.keepAlive)
                    if sync.keepAliveDenied {
                        Text("Location permission is off, so background mode can't work. Turn it on in Settings.")
                            .font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Sync cycle")
                } footer: {
                    Text("iOS pauses apps soon after you leave them. The cycle runs reliably while the app is open, " +
                         "or in the background with \"Keep running in background\" on. That mode uses low-accuracy " +
                         "location to stay awake (blue pill in the status bar, a little extra battery). Location is never " +
                         "stored or sent. With it off, iOS still syncs now and then in the background, at times it chooses.")
                }

                Section {
                    NavigationLink(sync.isPaired ? "Pair again" : "Pair with Samsung") {
                        PairingView()
                    }
                    if sync.isPaired {
                        LabeledContent("Tailscale address") {
                            TextField("100.x.y.z", text: $sync.tailscaleHost)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        row("Wi-Fi address", sync.lanHost.isEmpty ? "—" : sync.lanHost)
                        Button("Unpair", role: .destructive) { sync.unpair() }
                    }
                } header: {
                    Text("Samsung")
                } footer: {
                    Text("Away from home the phones reach each other through Tailscale. Install it on both phones and " +
                         "sign in with the same account.")
                }
            }
            .navigationTitle("Contact Sync")
        }
    }

    /// Green "Success" or red "Failed" for the last sync attempt.
    @ViewBuilder private var resultLabel: some View {
        if sync.isSyncing {
            HStack(spacing: 6) {
                ProgressView()
                Text("Syncing…")
            }
        } else {
            switch sync.outcome {
            case .success:
                Label("Success", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.green)
            case .failed:
                Label("Failed", systemImage: "xmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.red)
            case .notRun:
                Text("No sync yet").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing) }
    }

    private func relative(_ d: Date?) -> String {
        guard let d else { return "Never" }
        return d.formatted(.relative(presentation: .named))
    }
}
