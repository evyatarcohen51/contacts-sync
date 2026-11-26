import Combine
import CryptoKit
import Foundation
import Network
import UIKit

/// Finds the Samsung on the local Wi-Fi via Bonjour (the Android app advertises `_contactsync._tcp`).
@MainActor
final class SamsungBrowser: ObservableObject {
    struct Found: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
    }

    @Published var found: [Found] = []
    @Published var problem: String?
    private var browser: NWBrowser?

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: Proto.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let items: [Found] = results.compactMap { r in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                return Found(id: name, name: name.replacingOccurrences(of: "ContactSync ", with: ""), endpoint: r.endpoint)
            }
            let sorted = items.sorted { $0.name < $1.name }
            Task { @MainActor [weak self] in self?.found = sorted }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .waiting, .failed:
                    self?.problem = "Can't search the Wi-Fi. Allow \"Local Network\" for this app in Settings → Privacy."
                case .ready:
                    self?.problem = nil
                default:
                    break
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// The connection callback and the timeout race to finish a lookup; only the first wins.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// Resolve a Bonjour service to an IPv4 address + port usable with URLSession.
    nonisolated static func resolve(_ endpoint: NWEndpoint) async throws -> (String, Int) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        let once = Once()
        let queue = DispatchQueue(label: "contactsync.resolve")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(String, Int), Error>) in
            let finish: @Sendable (Result<(String, Int), Error>) -> Void = { result in
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(with: result)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint else {
                        finish(.failure(SyncError.message("Could not find the Samsung's address")))
                        return
                    }
                    let text: String
                    switch host {
                    case .ipv4(let a): text = "\(a)"
                    case .ipv6(let a): text = "\(a)"
                    case .name(let n, _): text = n
                    @unknown default: text = "\(host)"
                    }
                    // Drop a "%en0" interface suffix.
                    let address = text.components(separatedBy: "%").first ?? text
                    finish(.success((address, Int(port.rawValue))))
                case .failed(let e), .waiting(let e):
                    finish(.failure(SyncError.message("Could not connect to the Samsung (\(e.localizedDescription))")))
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 10) {
                finish(.failure(SyncError.message("Timed out connecting to the Samsung")))
            }
        }
    }
}

/// Same-Wi-Fi pairing: ECDH key exchange, both phones show a 6-digit number,
/// the user taps Accept on the Samsung, and the Samsung sends the pairing code
/// (plus its Tailscale address) encrypted with the shared key.
@MainActor
final class PairingFlow: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case confirm(number: String, device: String)
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    private var task: Task<Void, Never>?
    /// Identifies the attempt that currently owns `phase`, so a cancelled one cannot overwrite it.
    private var current: UUID?

    func pair(with found: SamsungBrowser.Found, sync: SyncManager) {
        task?.cancel()
        let id = UUID()
        current = id
        task = Task { await run(found, sync, id) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        current = nil
        phase = .idle
    }

    private func show(_ p: Phase, _ id: UUID) {
        if current == id { phase = p }
    }

    private func run(_ found: SamsungBrowser.Found, _ sync: SyncManager, _ id: UUID) async {
        show(.connecting(found.name), id)
        do {
            let (host, port) = try await SamsungBrowser.resolve(found.endpoint)
            let client = ReceiverClient(host: host, port: port)

            let priv = P256.KeyAgreement.PrivateKey()
            let myPub = priv.publicKey.derRepresentation
            let start = try await client.pairStart(pub: myPub, device: UIDevice.current.name)
            guard let theirPubDer = Data(base64Encoded: start.pub) else {
                throw SyncError.message("Bad answer from the Samsung")
            }
            let theirPub = try P256.KeyAgreement.PublicKey(derRepresentation: theirPubDer)
            let key = Proto.pairingKey(try priv.sharedSecretFromKeyAgreement(with: theirPub))

            show(.confirm(number: Proto.comparisonNumber(iphonePub: myPub, androidPub: theirPubDer),
                          device: start.device), id)

            let deadline = Date().addingTimeInterval(180)
            var misses = 0
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let answer: ReceiverClient.PairFinish
                do {
                    answer = try await client.pairFinish(session: start.session)
                    misses = 0
                } catch let e as SyncError {
                    throw e // the Samsung said no (rejected or expired)
                } catch {
                    // A dropped request is not fatal: the Samsung keeps the answer for us.
                    misses += 1
                    if misses >= 5 || Task.isCancelled { throw error }
                    continue
                }
                switch answer {
                case .pending:
                    continue
                case .sealed(let blob):
                    let info = try JSONDecoder().decode(ReceiverClient.PairInfo.self,
                                                        from: Proto.open(blob, key: key))
                    sync.savePairing(code: info.code, device: info.device, port: info.port,
                                     tailscale: info.tailscale, lan: info.lan ?? host,
                                     reachedAt: port == info.port ? host : "\(host):\(port)")
                    show(.done(info.device), id)
                    Task { await sync.syncNow(force: true) } // not tied to this view's lifetime
                    return
                }
            }
            throw SyncError.message("Pairing timed out — tap Accept on the Samsung within 3 minutes")
        } catch {
            show(Task.isCancelled ? .idle : .failed(error.localizedDescription), id)
        }
    }
}
