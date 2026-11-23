import CryptoKit
import Foundation
import XCTest
@testable import ContactSyncSender

/// The same vectors the Android unit tests use (produced by tools/protocol.js),
/// so all three implementations are checked against each other.
final class ProtoTests: XCTestCase {
    private let nodeBlob = Data(base64Encoded:
        "BwcHBwcHBwcHBwcHR1csLvMj4URn+zBwr3L9iE5468Mr4ZrQhQPtr1nYrku1XHQrzhLZpL2+lBDjM0LFpsmXoJWRaVCK" +
        "1qM4hBlKvLvMxZ0vz7AvBV1h6FhlSMdmWm21Szna53sEGLXTZ3JJ2X0nQbH1JZMo4e1bPBoe24s/p8E=")!

    func testCodeNormalization() {
        XCTAssertEqual(Proto.normalize("test-code 2345-6789"), "TESTCODE23456789")
        XCTAssertEqual(Proto.pretty("testcode23456789"), "TEST-CODE-2345-6789")
        XCTAssertTrue(Proto.isValid("TEST-CODE-2345-6789"))
        XCTAssertFalse(Proto.isValid("TEST-CODE-2345"))
        XCTAssertEqual(Proto.normalize("tést-ĉode"), "TSTODE") // non-ASCII letters are dropped
    }

    func testAuthTokenMatchesNodeAndAndroid() {
        XCTAssertEqual(Proto.authToken("TEST-CODE-2345-6789"),
                       "8d38cc52434a718aec2243faeb6780094334a10d22e47a3683cb7f1c0975ae89")
    }

    func testOpensNodeSealedBlobAndRejectsWrongKey() throws {
        let deflated = try Proto.open(nodeBlob, key: Proto.key("testcode23456789"))
        XCTAssertFalse(deflated.isEmpty)
        XCTAssertThrowsError(try Proto.open(nodeBlob, key: Proto.key("AAAAAAAAAAAAAAAA")))
    }

    func testSealRoundTripAndLayout() throws {
        let key = Proto.key("TEST-CODE-2345-6789")
        let blob = try Proto.seal(Data("hello".utf8), key: key)
        XCTAssertEqual(blob.count, 12 + 5 + 16) // nonce | ciphertext | tag
        XCTAssertEqual(try Proto.open(blob, key: key), Data("hello".utf8))
    }

    func testEcdhAndComparisonNumberMatchNodeAndAndroid() throws {
        let aPriv = try P256.KeyAgreement.PrivateKey(derRepresentation: Data(base64Encoded:
            "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg7wcbFc6KvOcDyowigSttyypNrzt3SfiO23PiKUw0I0ahRANCAAR" +
            "CYYp897iiEvf187Xs8N7k8gZyWpSuCjTeVD7WQjdpL9cyb/i2fdVg7r9mpe8jjEeayySMkPk+R+G2OdsnC7S3")!)
        let aPubDer = Data(base64Encoded:
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQmGKfPe4ohL39fO17PDe5PIGclqUrgo03lQ+1kI3aS/XMm/4tn3VYO6/ZqXvI4xHmsskjJD5PkfhtjnbJwu0tw==")!
        let bPubDer = Data(base64Encoded:
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWss5JpkVsthW62oJcFf677aPOBrXKMVs92PE0BfNdTsSAEyRgqNdfVPud5lG6aRDOLzMql1wzQSFR3hBDgbYzQ==")!

        // The iPhone sends exactly this encoding of its public key.
        XCTAssertEqual(aPriv.publicKey.derRepresentation, aPubDer)
        XCTAssertEqual(aPubDer.count, 91)

        let secret = try aPriv.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(derRepresentation: bPubDer))
        XCTAssertEqual(Proto.hex(secret.withUnsafeBytes { Data($0) }),
                       "cb07d146eb3d5c4be6da9bb5d6ff6592af03d8524454b33d1f09d5e9d9e0797e")
        XCTAssertEqual(Proto.comparisonNumber(iphonePub: aPubDer, androidPub: bPubDer), "443863")

        // pairingKey = SHA256(secret || "contactsync-pair")
        let expected = Proto.sha256(Data(secret.withUnsafeBytes { Data($0) }) + Data("contactsync-pair".utf8))
        XCTAssertEqual(Proto.pairingKey(secret).withUnsafeBytes { Data($0) }, expected)
    }

    func testComparisonNumberKeepsLeadingZeros() {
        // Any input works; the point is the fixed width.
        for i in 0..<200 {
            let n = Proto.comparisonNumber(iphonePub: Data([UInt8(i)]), androidPub: Data([7]))
            XCTAssertEqual(n.count, 6)
            XCTAssertTrue(n.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }
}

final class ReceiverClientTests: XCTestCase {
    private func url(_ host: String, port: Int = 8765) throws -> String {
        try ReceiverClient(host: host, port: port).url("v1/ping").absoluteString
    }

    func testAddressesTypedByHand() throws {
        XCTAssertEqual(try url("100.101.102.103"), "http://100.101.102.103:8765/v1/ping")
        XCTAssertEqual(try url("  100.101.102.103 \n"), "http://100.101.102.103:8765/v1/ping")
        XCTAssertEqual(try url("phone.tailnet.ts.net"), "http://phone.tailnet.ts.net:8765/v1/ping")
        XCTAssertEqual(try url("100.101.102.103:9000"), "http://100.101.102.103:9000/v1/ping")
        XCTAssertEqual(try url("http://192.168.1.20/"), "http://192.168.1.20:8765/v1/ping")
        XCTAssertEqual(try url("fd7a:115c:a1e0::1"), "http://[fd7a:115c:a1e0::1]:8765/v1/ping")
        XCTAssertEqual(try url("[fd7a:115c:a1e0::1]"), "http://[fd7a:115c:a1e0::1]:8765/v1/ping")
    }

    func testBadAddressesThrowInsteadOfCrashing() {
        XCTAssertThrowsError(try url(""))
        XCTAssertThrowsError(try url("   "))
        XCTAssertThrowsError(try url("my samsung"))
    }
}
