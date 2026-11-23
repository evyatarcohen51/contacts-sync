package com.dvirchi.contactsync.receiver

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyFactory
import java.security.KeyPair
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64

/** Vectors produced by tools/protocol.js (the same format CryptoKit produces on iOS). */
class ProtocolTest {
    private val b64 = Base64.getDecoder()

    @Test
    fun codeNormalization() {
        assertEquals("TESTCODE23456789", Protocol.normalize("test-code 2345-6789"))
        assertEquals("TEST-CODE-2345-6789", Protocol.pretty("testcode23456789"))
        assertTrue(Protocol.isValidCode(Protocol.generateCode()))
    }

    @Test
    fun authTokenMatchesNode() {
        assertEquals(
            "8d38cc52434a718aec2243faeb6780094334a10d22e47a3683cb7f1c0975ae89",
            Protocol.authToken("TEST-CODE-2345-6789"),
        )
    }

    @Test
    fun opensNodeSealedSnapshot() {
        val blob = b64.decode(
            "BwcHBwcHBwcHBwcHR1csLvMj4URn+zBwr3L9iE5468Mr4ZrQhQPtr1nYrku1XHQrzhLZpL2+lBDjM0LFpsmXoJWRaVCK" +
                "1qM4hBlKvLvMxZ0vz7AvBV1h6FhlSMdmWm21Szna53sEGLXTZ3JJ2X0nQbH1JZMo4e1bPBoe24s/p8E="
        )
        val json = Protocol.openSnapshot("testcode23456789", blob)
        assertTrue(json, json.contains("\"givenName\":\"שלום\""))
        assertTrue(json.contains("\"generatedAt\":1"))
    }

    @Test(expected = Exception::class)
    fun wrongCodeFails() {
        val blob = b64.decode(
            "BwcHBwcHBwcHBwcHR1csLvMj4URn+zBwr3L9iE5468Mr4ZrQhQPtr1nYrku1XHQrzhLZpL2+lBDjM0LFpsmXoJWRaVCK" +
                "1qM4hBlKvLvMxZ0vz7AvBV1h6FhlSMdmWm21Szna53sEGLXTZ3JJ2X0nQbH1JZMo4e1bPBoe24s/p8E="
        )
        Protocol.openSnapshot("AAAAAAAAAAAAAAAA", blob)
    }

    @Test
    fun ecdhAndComparisonNumberMatchNode() {
        val aPriv = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(b64.decode(
            "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg7wcbFc6KvOcDyowigSttyypNrzt3SfiO23PiKUw0I0ahRANCAAR" +
                "CYYp897iiEvf187Xs8N7k8gZyWpSuCjTeVD7WQjdpL9cyb/i2fdVg7r9mpe8jjEeayySMkPk+R+G2OdsnC7S3")))
        val aPubDer = b64.decode(
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQmGKfPe4ohL39fO17PDe5PIGclqUrgo03lQ+1kI3aS/XMm/4tn3VYO6/ZqXvI4xHmsskjJD5PkfhtjnbJwu0tw==")
        val bPubDer = b64.decode(
            "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEWss5JpkVsthW62oJcFf677aPOBrXKMVs92PE0BfNdTsSAEyRgqNdfVPud5lG6aRDOLzMql1wzQSFR3hBDgbYzQ==")

        val a = KeyPair(Protocol.publicKeyFromDer(aPubDer), aPriv)
        val secret = Protocol.ecdh(a, Protocol.publicKeyFromDer(bPubDer))
        assertEquals("cb07d146eb3d5c4be6da9bb5d6ff6592af03d8524454b33d1f09d5e9d9e0797e", Protocol.hex(secret))
        assertEquals("443863", Protocol.comparisonNumber(aPubDer, bPubDer))
    }

    @Test
    fun sealRoundTrip() {
        val key = Protocol.key("TEST-CODE-2345-6789")
        val msg = "hello".toByteArray()
        assertEquals("hello", String(Protocol.unseal(key, Protocol.seal(key, msg))))
    }

    @Test
    fun generatedKeysAreSpki() {
        val kp = Protocol.newPairingKeyPair()
        assertEquals(91, kp.public.encoded.size) // P-256 SPKI DER, what CryptoKit's derRepresentation emits
    }
}
