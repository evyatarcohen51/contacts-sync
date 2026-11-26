import Contacts
import Foundation
import Network
import UIKit
import XCTest
@testable import ContactSyncSender

/// Runs the app's real pairing flow and sync manager against a running Android receiver
/// (an emulator or a phone), with only Apple's frameworks replaced by stand-ins.
///
/// Needs, in the environment:
///   CONTACTSYNC_HOST  host:port of the receiver, e.g. 127.0.0.1:18765 behind `adb forward`
///   CONTACTSYNC_UI    a command that taps a button by its text: `$CONTACTSYNC_UI tap "Accept"`
/// Skipped when they are not set.
final class EndToEndTests: XCTestCase {

    private var target: String { ProcessInfo.processInfo.environment["CONTACTSYNC_HOST"] ?? "" }

    @discardableResult
    private func tap(_ text: String, required: Bool = true) throws -> Bool {
        let ui = try XCTUnwrap(ProcessInfo.processInfo.environment["CONTACTSYNC_UI"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ui)
        p.arguments = ["tap", text]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if required {
            XCTAssertEqual(p.terminationStatus, 0, "could not tap \"\(text)\" on the Android screen")
        }
        return p.terminationStatus == 0
    }

    @MainActor
    private func wait(_ what: String, seconds: Double = 30, until done: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { throw XCTSkip.fail("timed out waiting for: \(what)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private func settle(_ sync: SyncManager) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
        try await wait("sync to finish", seconds: 60) { !sync.isSyncing }
    }

    @MainActor
    func testPairThenSyncLikeTheIPhone() async throws {
        try XCTSkipIf(target.isEmpty, "set CONTACTSYNC_HOST to run against a receiver")
        let parts = target.split(separator: ":")
        let host = String(parts[0])
        let port = UInt16(parts.count > 1 ? parts[1] : "8765")!

        let sync = SyncManager.shared
        sync.unpair()
        XCTAssertFalse(sync.isPaired)
        XCTAssertEqual(sync.outcome, .notRun)
        CNContactStore.stubAuthorization = .authorized
        CNContactStore.stubContacts = Fixtures.initial()

        // Not paired: a sync does nothing and is not counted as an attempt.
        await sync.syncNow()
        XCTAssertNil(sync.lastAttemptAt)
        XCTAssertEqual(sync.message, "Not paired")

        // ---- Pairing (the stub network "finds" the receiver at CONTACTSYNC_HOST) ----
        NWConnection.stubRemote = .hostPort(host: .ipv4(IPv4Address(host)!), port: NWEndpoint.Port(rawValue: port)!)
        try tap("OK", required: false) // dismiss "Paired with …" left by an earlier run
        try tap("Pair iPhone")
        let flow = PairingFlow()
        let found = SamsungBrowser.Found(
            id: "ContactSync Test", name: "Test",
            endpoint: .service(name: "ContactSync Test", type: "_contactsync._tcp", domain: "local.", interface: nil))
        flow.pair(with: found, sync: sync)

        var number = ""
        try await wait("the comparison number") {
            if case .confirm(let n, _) = flow.phase { number = n; return true }
            if case .failed(let why) = flow.phase { XCTFail("pairing failed: \(why)"); return true }
            return false
        }
        XCTAssertEqual(number.count, 6)
        try tap("Accept")
        try await wait("pairing to complete", seconds: 40) {
            if case .done = flow.phase { return true }
            if case .failed(let why) = flow.phase { XCTFail("pairing failed: \(why)"); return true }
            return false
        }
        XCTAssertTrue(sync.isPaired)
        XCTAssertFalse(sync.receiverName.isEmpty)
        XCTAssertEqual(sync.port, 8765)
        XCTAssertEqual(Keychain.get("pairCode"), sync.code)

        // The Samsung reported its own Wi-Fi address, which this machine cannot reach (it is
        // inside the emulator). The app first tries the address the pairing conversation
        // itself just used, so the sync that follows pairing still gets through.
        try await settle(sync)
        XCTAssertEqual(sync.outcome, .success, sync.message)
        XCTAssertEqual(sync.connectedVia, target)
        XCTAssertEqual(sync.lastCount, 3)
        XCTAssertNotNil(sync.lastAttemptAt)

        // ---- Reach it "over Tailscale": an address typed by hand, with a port ----
        sync.tailscaleHost = target
        await sync.syncNow(force: true)
        XCTAssertEqual(sync.outcome, .success, sync.message)
        // How many were added, updated or removed depends on what the Samsung held before:
        // contacts from another iPhone are removed, ones from this iPhone are reused.
        XCTAssertTrue(sync.message.hasPrefix("Sent · "), sync.message)
        XCTAssertEqual(sync.lastCount, 3)
        XCTAssertEqual(sync.connectedVia, "Tailscale")
        XCTAssertNotNil(sync.lastPushAt)
        let firstAttempt = try XCTUnwrap(sync.lastAttemptAt)

        // ---- Nothing changed: checks in, sends nothing ----
        let pushedAt = sync.lastPushAt
        try await Task.sleep(nanoseconds: 20_000_000)
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .success)
        XCTAssertEqual(sync.message, "Up to date · 3 contacts")
        XCTAssertEqual(sync.lastPushAt, pushedAt)
        XCTAssertGreaterThan(try XCTUnwrap(sync.lastAttemptAt), firstAttempt)

        // ---- One edited, one deleted, one added ----
        CNContactStore.stubContacts = Fixtures.changed()
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .success, sync.message)
        XCTAssertEqual(sync.message, "Sent · 1 added, 1 updated, 1 removed")

        // ---- Photos off: only the contact with a photo is rewritten ----
        sync.includePhotos = false
        await sync.syncNow()
        XCTAssertEqual(sync.message, "Sent · 0 added, 1 updated, 0 removed")
        sync.includePhotos = true
        await sync.syncNow()
        XCTAssertEqual(sync.message, "Sent · 0 added, 1 updated, 0 removed")

        // ---- The iPhone suddenly shows no contacts: refuse to wipe the Samsung ----
        CNContactStore.stubContacts = []
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .failed)
        XCTAssertTrue(sync.message.contains("0 contacts"), sync.message)
        CNContactStore.stubContacts = Fixtures.changed()

        // ---- Contacts permission taken away ----
        CNContactStore.stubAuthorization = .denied
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .failed)
        XCTAssertEqual(sync.message, "Allow Contacts access to sync")
        CNContactStore.stubAuthorization = .authorized

        // ---- Samsung unreachable ----
        UserDefaults.standard.removeObject(forKey: "lastGoodHost")
        sync.tailscaleHost = "127.0.0.1:9" // nothing listens there
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .failed)
        XCTAssertTrue(sync.message.hasPrefix("Can't reach the Samsung"), sync.message)

        // ---- A nonsense address must not crash, and recovery works ----
        sync.tailscaleHost = "not an address"
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .failed)
        sync.tailscaleHost = target
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .success, sync.message)
        XCTAssertEqual(sync.message, "Up to date · 3 contacts")

        // ---- "Sync now" while a sync is running is not lost ----
        async let first: Void = sync.syncNow()
        await sync.syncNow(force: true)
        await first
        try await settle(sync)
        XCTAssertEqual(sync.message, "Sent · 0 added, 0 updated, 0 removed")

        // ---- Check the Samsung directly ----
        let client = ReceiverClient(host: target, port: 8765)
        let code = try XCTUnwrap(sync.code)
        let ping = try await client.ping(code: code, snapshotHash: "x")
        XCTAssertEqual(ping.count, 3)
        XCTAssertEqual(ping.lastSnapshotHash.count, 64)

        // ---- A wrong code is refused, and says so ----
        let good = (code: code, name: sync.receiverName, lan: sync.lanHost)
        sync.savePairing(code: "AAAA-AAAA-AAAA-AAAA", device: "Samsung", port: 8765, tailscale: target, lan: nil)
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .failed)
        XCTAssertEqual(sync.message, "Wrong pairing code — pair again")

        // Leave the pairing as it was, for the checks that run on the Android side.
        sync.savePairing(code: good.code, device: good.name, port: 8765, tailscale: target, lan: good.lan)
        await sync.syncNow()
        XCTAssertEqual(sync.outcome, .success, sync.message)

        // Every sync closed the background task it opened.
        XCTAssertEqual(UIApplication.shared.openBackgroundTasks, 0)
        print("PAIRED_CODE=\(Proto.pretty(good.code))")
    }
}

extension XCTSkip {
    /// A plain error with a message (XCTest on Linux has no XCTFail-and-throw helper).
    static func fail(_ message: String) -> Error {
        NSError(domain: "CheckTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
