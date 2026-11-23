package com.dvirchi.contactsync.receiver

import java.io.ByteArrayInputStream
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.ECGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Locale
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Wire protocol shared with the iOS app (see tools/protocol.js for the reference).
 *
 *   code  = 16 chars from ALPHABET (shown as XXXX-XXXX-XXXX-XXXX)
 *   auth  = hex(SHA256("contactsync-auth:" + code))   -> HTTP Bearer token
 *   key   = SHA256("contactsync-key:" + code)         -> AES-256-GCM key
 *   blob  = nonce(12) || ciphertext || tag(16)         (CryptoKit SealedBox.combined)
 *   plaintext = raw DEFLATE of UTF-8 JSON
 *
 * Pairing (same Wi-Fi): P-256 ECDH with SPKI-DER public keys, a 6-digit
 * comparison number, then the code is sent sealed with SHA256(secret || "contactsync-pair").
 */
object Protocol {
    const val ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    const val PORT = 8765
    const val NSD_TYPE = "_contactsync._tcp."

    private val rng = SecureRandom()

    fun normalize(code: String): String =
        code.uppercase().filter { it in 'A'..'Z' || it in '0'..'9' }

    fun isValidCode(code: String) = normalize(code).length == 16

    fun pretty(code: String) = normalize(code).chunked(4).joinToString("-")

    fun generateCode(): String {
        val sb = StringBuilder()
        repeat(16) { sb.append(ALPHABET[rng.nextInt(ALPHABET.length)]) }
        return pretty(sb.toString())
    }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(Locale.ROOT, it) }

    fun authToken(code: String) = hex(sha256("contactsync-auth:${normalize(code)}".toByteArray()))

    fun key(code: String) = sha256("contactsync-key:${normalize(code)}".toByteArray())

    /** Constant-time string compare for tokens. */
    fun safeEquals(a: String, b: String) =
        MessageDigest.isEqual(a.toByteArray(), b.toByteArray())

    // ---- AES-GCM -------------------------------------------------------------

    fun seal(key: ByteArray, plain: ByteArray): ByteArray {
        val nonce = ByteArray(12).also { rng.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return nonce + c.doFinal(plain)
    }

    fun unseal(key: ByteArray, blob: ByteArray): ByteArray {
        require(blob.size >= 28) { "blob too small" }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, blob, 0, 12))
        return c.doFinal(blob, 12, blob.size - 12)
    }

    /** Decrypt + inflate a contacts snapshot into its JSON string. */
    fun openSnapshot(code: String, blob: ByteArray): String {
        val deflated = unseal(key(code), blob)
        return InflaterInputStream(ByteArrayInputStream(deflated), Inflater(true))
            .use { it.readBytes() }
            .toString(Charsets.UTF_8)
    }

    // ---- Pairing (ECDH P-256) -----------------------------------------------

    fun newPairingKeyPair(): KeyPair =
        KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }
            .generateKeyPair()

    fun publicKeyFromDer(der: ByteArray): PublicKey =
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(der))

    /** Raw ECDH shared secret (the X coordinate, 32 bytes) — same as CryptoKit's. */
    fun ecdh(mine: KeyPair, theirs: PublicKey): ByteArray =
        KeyAgreement.getInstance("ECDH").run {
            init(mine.private)
            doPhase(theirs, true)
            generateSecret()
        }

    fun pairingKey(secret: ByteArray) = sha256(secret, "contactsync-pair".toByteArray())

    /** 6-digit number both screens show; derived from both public keys. */
    fun comparisonNumber(iphonePubDer: ByteArray, androidPubDer: ByteArray): String {
        val h = sha256(iphonePubDer, androidPubDer)
        val n = ((h[0].toLong() and 0xff) shl 24) or ((h[1].toLong() and 0xff) shl 16) or
            ((h[2].toLong() and 0xff) shl 8) or (h[3].toLong() and 0xff)
        return "%06d".format(Locale.ROOT, n % 1_000_000) // ROOT: always ASCII digits, like the iPhone
    }
}
