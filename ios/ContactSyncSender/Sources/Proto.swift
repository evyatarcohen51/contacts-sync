import CryptoKit
import Foundation

/// Wire protocol shared with the Android receiver (reference: tools/protocol.js).
///
///   code  = 16 chars from `alphabet`, shown as XXXX-XXXX-XXXX-XXXX
///   auth  = hex(SHA256("contactsync-auth:" + code))   -> HTTP Bearer token
///   key   = SHA256("contactsync-key:" + code)         -> AES-256-GCM key
///   blob  = nonce(12) || ciphertext || tag(16)         (SealedBox.combined)
///   plaintext = raw DEFLATE of UTF-8 JSON              (NSData .zlib = raw DEFLATE)
enum Proto {
    static let port = 8765
    static let bonjourType = "_contactsync._tcp"

    static func normalize(_ s: String) -> String {
        String(s.uppercased().filter { c in c.isASCII && (c.isUppercase || c.isNumber) })
    }

    static func isValid(_ code: String) -> Bool { normalize(code).count == 16 }

    static func pretty(_ code: String) -> String {
        let n = Array(normalize(code))
        return stride(from: 0, to: n.count, by: 4)
            .map { String(n[$0..<min($0 + 4, n.count)]) }
            .joined(separator: "-")
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func authToken(_ code: String) -> String {
        hex(sha256(Data("contactsync-auth:\(normalize(code))".utf8)))
    }

    static func key(_ code: String) -> SymmetricKey {
        SymmetricKey(data: sha256(Data("contactsync-key:\(normalize(code))".utf8)))
    }

    static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(plain, using: key).combined else {
            throw SyncError.message("Encryption failed")
        }
        return combined
    }

    static func open(_ blob: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key)
    }

    /// JSON -> raw DEFLATE -> AES-GCM.
    static func sealSnapshot(_ json: Data, code: String) throws -> Data {
        let deflated = try (json as NSData).compressed(using: .zlib) as Data
        return try seal(deflated, key: key(code))
    }

    // MARK: Pairing (P-256 ECDH, SPKI DER keys)

    static func comparisonNumber(iphonePub: Data, androidPub: Data) -> String {
        let h = [UInt8](sha256(iphonePub + androidPub))
        let n = UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])
        return String(format: "%06u", n % 1_000_000)
    }

    static func pairingKey(_ secret: SharedSecret) -> SymmetricKey {
        let raw = secret.withUnsafeBytes { Data($0) }
        return SymmetricKey(data: sha256(raw + Data("contactsync-pair".utf8)))
    }
}

enum SyncError: LocalizedError {
    case message(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .http(let code, let m): return m.isEmpty ? "Samsung answered HTTP \(code)" : m
        }
    }
}
