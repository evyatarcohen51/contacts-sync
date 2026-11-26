import BackgroundTasks
import Combine
import Contacts
import Foundation
import SwiftUI
import UIKit

/// Owns settings, the sync timer and the sync routine.
///
/// Each cycle: read all contacts -> hash them -> ask the Samsung which snapshot
/// it already has (ping) -> push an encrypted snapshot only if it differs.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()
    static let refreshTaskId = "com.dvirchi.contactsync.sender.refresh"

    /// How the last sync attempt ended. The UI shows it in green or red.
    enum Outcome: String {
        case notRun, success, failed
    }

    private let defaults = UserDefaults.standard

    // MARK: Settings (persisted)

    @Published var intervalMinutes: Int {
        didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes"); restartTimer(); scheduleRefresh() }
    }
    @Published var includePhotos: Bool {
        didSet { defaults.set(includePhotos, forKey: "includePhotos") }
    }
    @Published var keepAlive: Bool {
        didSet { defaults.set(keepAlive, forKey: "keepAlive"); applyKeepAlive() }
    }
    @Published var tailscaleHost: String {
        didSet { defaults.set(tailscaleHost.trimmingCharacters(in: .whitespaces), forKey: "tailscaleHost") }
    }
    @Published private(set) var lanHost: String
    @Published private(set) var receiverName: String
    @Published private(set) var code: String?
    private(set) var port: Int

    // MARK: Status

    /// When the last sync attempt started, whether or not it reached the Samsung.
    @Published private(set) var lastAttemptAt: Date?
    @Published private(set) var outcome = Outcome.notRun
    /// Detail for `outcome`: what was sent, or why it failed.
    @Published private(set) var message = "Not paired"
    @Published private(set) var isSyncing = false
    @Published private(set) var lastPushAt: Date?
    @Published private(set) var lastCount = 0
    @Published private(set) var connectedVia = ""
    @Published private(set) var contactsAccess = CNContactStore.authorizationStatus(for: .contacts)

    var isPaired: Bool { code.map(Proto.isValid) ?? false }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?
    private let keepAliveManager = KeepAlive()
    private var started = false
    private var forceAgain = false

    private init() {
        let minutes = defaults.integer(forKey: "intervalMinutes")
        intervalMinutes = [1, 5, 10].contains(minutes) ? minutes : 5
        includePhotos = defaults.object(forKey: "includePhotos") as? Bool ?? true
        keepAlive = defaults.bool(forKey: "keepAlive")
        tailscaleHost = defaults.string(forKey: "tailscaleHost") ?? ""
        lanHost = defaults.string(forKey: "lanHost") ?? ""
        receiverName = defaults.string(forKey: "receiverName") ?? ""
        port = defaults.object(forKey: "port") as? Int ?? Proto.port
        code = Keychain.get("pairCode")
        lastPushAt = defaults.object(forKey: "lastPushAt") as? Date
        lastCount = defaults.integer(forKey: "lastCount")
        if isPaired {
            lastAttemptAt = defaults.object(forKey: "lastAttemptAt") as? Date
            outcome = Outcome(rawValue: defaults.string(forKey: "lastOutcome") ?? "") ?? .notRun
            message = defaults.string(forKey: "lastMessage") ?? "Ready"
        }
        keepAliveManager.onEvent = { [weak self] in
            Task { @MainActor [weak self] in self?.keepAliveEvent() }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.contactsChanged() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.becameActive() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        })
        #if targetEnvironment(simulator)
        // Automated checks on the iOS Simulator pair without tapping through the screens:
        //   xcrun simctl launch booted <bundle id> -debugPairCode <code> -debugPairHost <host[:port]>
        // This block is left out of builds for a real iPhone.
        if let code = defaults.string(forKey: "debugPairCode"),
           let host = defaults.string(forKey: "debugPairHost"), Proto.isValid(code) {
            savePairing(code: code, device: "Test receiver", port: Proto.port, tailscale: host, lan: nil)
        }
        #endif
        restartTimer()
        applyKeepAlive()
        Task { await syncNow() }
    }

    private func becameActive() async {
        contactsAccess = CNContactStore.authorizationStatus(for: .contacts)
        await syncNow()
    }

    func requestContactsAccess() async {
        _ = try? await ContactExporter.store.requestAccess(for: .contacts)
        contactsAccess = CNContactStore.authorizationStatus(for: .contacts)
        await syncNow()
    }

    private func contactsChanged() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(intervalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func applyKeepAlive() {
        if keepAlive && isPaired { keepAliveManager.start() } else { keepAliveManager.stop() }
    }

    var keepAliveDenied: Bool { keepAlive && keepAliveManager.isDenied }

    /// Location permission changed, or iOS woke the app with a location.
    private func keepAliveEvent() {
        objectWillChange.send() // `keepAliveDenied` may have changed
        Task { await syncIfDue() }
    }

    /// Safety net for the timer, which iOS can hold back while the app is in the background.
    private func syncIfDue() async {
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < TimeInterval(intervalMinutes * 60) - 5 {
            return
        }
        await syncNow()
    }

    // MARK: Background refresh (opportunistic — iOS decides when)

    func scheduleRefresh() {
        guard isPaired else { return }
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(intervalMinutes * 60))
        try? BGTaskScheduler.shared.submit(req)
    }

    func backgroundRefresh() async {
        scheduleRefresh()
        await syncNow()
    }

    // MARK: Pairing

    /// `reachedAt` is the address the pairing conversation just used, if there was one.
    /// The first sync tries it first: it is known to work, whatever the Samsung says its own address is.
    func savePairing(code: String, device: String, port: Int, tailscale: String?, lan: String?,
                     reachedAt: String? = nil) {
        Keychain.set(Proto.normalize(code), for: "pairCode")
        self.code = Proto.normalize(code)
        receiverName = device
        defaults.set(device, forKey: "receiverName")
        self.port = port
        defaults.set(port, forKey: "port")
        if let tailscale, !tailscale.isEmpty { tailscaleHost = tailscale }
        lanHost = lan ?? ""
        defaults.set(lanHost, forKey: "lanHost")
        defaults.set(reachedAt, forKey: "lastGoodHost") // nil removes it
        setStatus(.notRun, "Paired with \(device)")
        applyKeepAlive()
        scheduleRefresh()
    }

    func unpair() {
        Keychain.set(nil, for: "pairCode")
        code = nil
        receiverName = ""
        lanHost = ""
        tailscaleHost = ""
        connectedVia = ""
        ["receiverName", "lanHost", "lastGoodHost", "lastPushAt", "lastCount", "lastAttemptAt",
         "lastOutcome", "lastMessage"].forEach { defaults.removeObject(forKey: $0) }
        lastPushAt = nil
        lastAttemptAt = nil
        lastCount = 0
        outcome = .notRun
        message = "Not paired"
        keepAliveManager.stop()
    }

    // MARK: Sync

    private func candidateHosts() -> [String] {
        var seen = Set<String>()
        return [defaults.string(forKey: "lastGoodHost") ?? "", tailscaleHost, lanHost]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func setStatus(_ outcome: Outcome, _ text: String) {
        self.outcome = outcome
        message = text
        defaults.set(outcome.rawValue, forKey: "lastOutcome")
        defaults.set(text, forKey: "lastMessage")
    }

    func syncNow(force: Bool = false) async {
        guard let code, isPaired else {
            outcome = .notRun
            message = "Not paired"
            return
        }
        guard !isSyncing else {
            if force { forceAgain = true } // run once more when the current sync ends
            return
        }

        isSyncing = true
        let startedAt = Date()
        lastAttemptAt = startedAt
        defaults.set(startedAt, forKey: "lastAttemptAt")
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "contact-sync")
        defer {
            isSyncing = false
            UIApplication.shared.endBackgroundTask(bgTask)
            if forceAgain {
                forceAgain = false
                Task { await syncNow(force: true) }
            }
        }

        let (result, text) = await attempt(code: code, force: force)
        // Unpaired or paired again while this attempt was running: its result no longer applies.
        if self.code == code { setStatus(result, text) }
    }

    /// One sync attempt. Returns how it ended and the text to show.
    private func attempt(code: String, force: Bool) async -> (Outcome, String) {
        contactsAccess = CNContactStore.authorizationStatus(for: .contacts)
        guard contactsAccess == .authorized || contactsAccess.rawValue == 4 /* .limited, iOS 18 */ else {
            return (.failed, "Allow Contacts access to sync")
        }

        do {
            let photos = includePhotos
            let contacts = try await Task.detached(priority: .utility) {
                try ContactExporter.export(includePhotos: photos)
            }.value
            let snapHash = ContactExporter.snapshotHash(contacts)

            // Find the Samsung: last address that worked, then Tailscale, then Wi-Fi.
            var client: ReceiverClient?
            var ping: ReceiverClient.PingResponse?
            var lastError: Error?
            for host in candidateHosts() {
                let c = ReceiverClient(host: host, port: port)
                do {
                    ping = try await c.ping(code: code, snapshotHash: snapHash)
                    client = c
                    defaults.set(host, forKey: "lastGoodHost")
                    connectedVia = host == tailscaleHost ? "Tailscale" : (host == lanHost ? "Wi-Fi" : host)
                    break
                } catch let e as SyncError {
                    // 401 = it is the Samsung and it refuses our code: other addresses won't help.
                    if case .http(401, _) = e { throw e }
                    lastError = e
                } catch {
                    lastError = error
                }
            }
            guard let client, let ping else {
                if let e = lastError as? SyncError { throw e }
                throw SyncError.message(
                    "Can't reach the Samsung. Check Tailscale is on on both phones." +
                    (lastError.map { " (\($0.localizedDescription))" } ?? "")
                )
            }

            // The Samsung reports its current addresses, so a new Tailscale or Wi-Fi
            // address is picked up without pairing again.
            if let ts = ping.tailscale, !ts.isEmpty, ts != tailscaleHost { tailscaleHost = ts }
            if let lan = ping.lan, !lan.isEmpty, lan != lanHost {
                lanHost = lan
                defaults.set(lan, forKey: "lanHost")
            }

            if !force && ping.lastSnapshotHash == snapHash {
                lastCount = contacts.count
                defaults.set(contacts.count, forKey: "lastCount")
                return (.success, "Up to date · \(contacts.count) contacts")
            }
            if contacts.isEmpty && ping.count > 0 {
                return (.failed, "This iPhone shows 0 contacts — not deleting everything on the Samsung")
            }

            let snapshot = SnapshotDTO(generatedAt: Int64(Date().timeIntervalSince1970 * 1000), contacts: contacts)
            let blob = try Proto.sealSnapshot(try JSONEncoder().encode(snapshot), code: code)
            let r = try await client.push(blob: blob, code: code, snapshotHash: snapHash, allowEmpty: false)

            let now = Date()
            lastPushAt = now
            lastCount = r.total
            defaults.set(now, forKey: "lastPushAt")
            defaults.set(r.total, forKey: "lastCount")
            var text = "Sent · \(r.added) added, \(r.updated) updated, \(r.deleted) removed"
            if let failed = r.failed, failed > 0 { text += " · \(failed) not saved on the Samsung" }
            return (.success, text)
        } catch {
            return (.failed, error.localizedDescription)
        }
    }
}
