package com.dvirchi.contactsync.receiver

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Base64
import android.util.Log
import com.dvirchi.contactsync.receiver.MiniHttpServer.Request
import com.dvirchi.contactsync.receiver.MiniHttpServer.Response
import org.json.JSONObject
import java.security.KeyPair
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap

/**
 * HTTP endpoints the iPhone talks to.
 *
 *   GET  /v1/hello                      -> who am I (no auth)
 *   POST /v1/pair/start  {pub, device}  -> {session, pub, device}   (only while pairing is open)
 *   POST /v1/pair/finish {session}      -> 202 pending | 200 {sealed} | 403 rejected | 410 expired
 *   POST /v1/ping   [X-Snapshot-Hash]   -> {lastSnapshotHash, count, tailscale, lan}    (Bearer auth)
 *   PUT  /v1/contacts   body=blob       -> {added, updated, deleted, total, failed}     (Bearer auth)
 */
object ReceiverApi {
    private const val TAG = "ReceiverApi"
    const val PAIRING_WINDOW_MS = 3 * 60_000L

    /** Largest body accepted on anything except an authenticated contacts upload. */
    private const val SMALL_BODY = 16 * 1024

    private class PairSession(
        val id: String,
        val keyPair: KeyPair,
        val secret: ByteArray,
        val device: String,
        val createdAt: Long = System.currentTimeMillis(),
        @Volatile var decision: Boolean? = null,
        /** The encrypted pairing code, kept so a repeated request gets the same answer. */
        var sealed: ByteArray? = null,
    )

    private lateinit var appCtx: Context
    private val sessions = ConcurrentHashMap<String, PairSession>()
    private val rng = SecureRandom()
    private val applyLock = Any()

    fun init(ctx: Context) {
        appCtx = ctx.applicationContext
        AppState.init(appCtx)
    }

    // ---- Called from the UI ---------------------------------------------------

    fun openPairing() {
        sessions.clear()
        AppState.pairing.value = PairingState.Waiting(System.currentTimeMillis() + PAIRING_WINDOW_MS)
    }

    fun cancelPairing() {
        sessions.clear()
        AppState.pairing.value = PairingState.Idle
    }

    fun decide(sessionId: String, accept: Boolean) {
        val s = sessions[sessionId]
        s?.decision = accept
        AppState.pairing.value =
            if (accept && s != null) PairingState.Finishing(s.device) else PairingState.Idle
    }

    /** Called regularly by the UI: close a pairing window or request that timed out. */
    fun expirePairing(now: Long = System.currentTimeMillis()) {
        when (val p = AppState.pairing.value) {
            is PairingState.Waiting -> if (p.until < now) cancelPairing()
            is PairingState.Confirm, is PairingState.Finishing ->
                if (sessions.values.none { now - it.createdAt <= PAIRING_WINDOW_MS }) cancelPairing()
            else -> Unit
        }
    }

    /**
     * Forget the pairing and remove every contact that came from the iPhone.
     * Slow with many contacts, so call it off the main thread.
     */
    fun unpair() {
        cancelPairing()
        // Forget the code first so the iPhone is refused straight away.
        AppState.update {
            Status(running = it.running, storage = it.storage, message = "Removing synced contacts…")
        }
        synchronized(applyLock) {
            runCatching { ContactsWriter.removeAll(appCtx) }.onFailure { Log.w(TAG, "remove failed", it) }
            AppState.update {
                if (Protocol.isValidCode(it.pairCode)) it
                else it.copy(contactCount = 0, lastSnapshotHash = "", lastGeneratedAt = 0, message = "Not paired yet")
            }
        }
    }

    /**
     * Switch where contacts are stored: remove what we created in the old place and
     * clear the snapshot hash so the iPhone re-sends everything on its next check-in.
     */
    fun setStorage(storage: String) {
        if (storage == AppState.status.value.storage) return
        synchronized(applyLock) {
            if (storage == AppState.status.value.storage) return
            runCatching { ContactsWriter.removeAll(appCtx) }.onFailure { Log.w(TAG, "remove failed", it) }
            AppState.update {
                it.copy(storage = storage, contactCount = 0, lastSnapshotHash = "", lastGeneratedAt = 0,
                    attemptState = Attempt.NONE, attemptDetail = "",
                    message = "Storage changed — waiting for the iPhone to re-send")
            }
        }
    }

    /** Manual pairing: make sure a code exists and return it. */
    fun ensureCode(): String {
        val existing = AppState.status.value.pairCode
        if (Protocol.isValidCode(existing)) return existing
        val code = Protocol.generateCode()
        AppState.update { it.copy(pairCode = code, message = "Waiting for iPhone") }
        return code
    }

    // ---- HTTP -----------------------------------------------------------------

    /**
     * Runs once the headers are in, before the body is read. Refuses a contacts upload
     * that would be rejected anyway, and keeps every other request body small, so a
     * stranger on the network cannot make this phone buffer a large upload.
     */
    fun preflight(req: Request): Response? {
        val len = req.header("content-length")?.toIntOrNull() ?: 0
        return when {
            req.method == "PUT" && req.path == "/v1/contacts" ->
                authError(req) ?: null.also { attempt(Attempt.PENDING, "Receiving contacts from the iPhone…") }
            len > SMALL_BODY -> Response.error(413, "too large")
            else -> null
        }
    }

    fun handle(req: Request): Response = when ("${req.method} ${req.path}") {
        "GET /v1/hello" -> Response.json(
            200,
            "app" to "contactsync-receiver",
            "device" to deviceName(),
            "paired" to Protocol.isValidCode(AppState.status.value.pairCode),
            "pairingOpen" to pairingOpen(),
        )
        "POST /v1/pair/start" -> pairStart(req)
        "POST /v1/pair/finish" -> pairFinish(req)
        "POST /v1/ping" -> authed(req) { ping(req) }
        "PUT /v1/contacts" -> authed(req) { push(req) }
        else -> Response.error(404, "not found")
    }

    private fun deviceName() = "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    private fun pairingOpen(): Boolean {
        val p = AppState.pairing.value
        return (p is PairingState.Waiting && p.until > System.currentTimeMillis()) || p is PairingState.Confirm
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun unb64(s: String) = Base64.decode(s, Base64.DEFAULT)

    private fun pairStart(req: Request): Response {
        if (!pairingOpen()) {
            return Response.error(403, "Pairing is not open. On the Samsung, tap \"Pair iPhone\" first.")
        }
        val body = runCatching { req.json() }.getOrNull() ?: return Response.error(400, "bad request")
        val iphonePub = runCatching { unb64(body.optString("pub")) }.getOrNull()
            ?: return Response.error(400, "bad public key")
        val device = body.optString("device").ifEmpty { "iPhone" }.take(60)
        val theirs = runCatching { Protocol.publicKeyFromDer(iphonePub) }.getOrNull()
            ?: return Response.error(400, "bad public key")

        val kp = Protocol.newPairingKeyPair()
        val myPub = kp.public.encoded
        val secret = Protocol.ecdh(kp, theirs)
        val id = Protocol.hex(ByteArray(16).also { rng.nextBytes(it) })
        sessions.clear()
        sessions[id] = PairSession(id, kp, secret, device)
        val number = Protocol.comparisonNumber(iphonePub, myPub)
        AppState.pairing.value = PairingState.Confirm(id, number, device)
        Log.i(TAG, "pairing request from $device")
        return Response.json(200, "session" to id, "pub" to b64(myPub), "device" to deviceName())
    }

    private fun pairFinish(req: Request): Response {
        val id = runCatching { req.json().optString("session") }.getOrDefault("")
        val s = sessions[id] ?: return Response.error(410, "pairing session expired")
        if (System.currentTimeMillis() - s.createdAt > PAIRING_WINDOW_MS) {
            sessions.remove(id)
            AppState.pairing.value = PairingState.Idle
            return Response.error(410, "pairing session expired")
        }
        return when (s.decision) {
            null -> Response.json(202, "pending" to true)
            false -> {
                sessions.remove(id)
                Response.error(403, "Pairing was rejected on the Samsung")
            }
            true -> synchronized(s) {
                // The session stays until it expires: if this answer gets lost on the way,
                // the iPhone asks again and receives the same code.
                val sealed = s.sealed ?: run {
                    val code = Protocol.generateCode()
                    AppState.update {
                        it.copy(pairCode = code, pairedDevice = s.device, lastSnapshotHash = "",
                            lastGeneratedAt = 0, message = "Paired with ${s.device}",
                            attemptAt = 0, attemptState = Attempt.NONE, attemptDetail = "")
                    }
                    AppState.pairing.value = PairingState.Done(s.device)
                    val addrs = Net.addresses()
                    val info = JSONObject()
                        .put("code", code)
                        .put("device", deviceName())
                        .put("port", Protocol.PORT)
                        .put("tailscale", addrs.tailscale ?: JSONObject.NULL)
                        .put("lan", addrs.lan.firstOrNull() ?: JSONObject.NULL)
                    Protocol.seal(Protocol.pairingKey(s.secret), info.toString().toByteArray()).also { s.sealed = it }
                }
                Response.json(200, "sealed" to b64(sealed))
            }
        }
    }

    /** Records how the iPhone's latest sync attempt went; the UI shows it in green or red. */
    private fun attempt(state: String, detail: String) {
        val now = System.currentTimeMillis()
        AppState.update { it.copy(attemptAt = now, attemptState = state, attemptDetail = detail) }
    }

    private fun failed(status: Int, detail: String, reply: String = detail): Response {
        attempt(Attempt.FAILED, detail)
        return Response.error(status, reply)
    }

    /** The upload broke off before all of it arrived. */
    fun uploadInterrupted(req: Request) {
        if (req.method == "PUT" && req.path == "/v1/contacts") {
            attempt(Attempt.FAILED, "The upload from the iPhone was interrupted")
        }
    }

    /** null when the request carries the right token for the current pairing. */
    private fun authError(req: Request): Response? {
        val code = AppState.status.value.pairCode
        if (!Protocol.isValidCode(code)) return Response.error(401, "Samsung is not paired")
        val token = req.header("authorization")?.removePrefix("Bearer ")?.trim() ?: ""
        if (!Protocol.safeEquals(token, Protocol.authToken(code))) {
            return failed(401, "The iPhone used an old pairing code — pair again", "Wrong pairing code — pair again")
        }
        return null
    }

    private inline fun authed(req: Request, block: () -> Response): Response {
        authError(req)?.let { return it }
        AppState.update { it.copy(lastSeenAt = System.currentTimeMillis()) }
        return block()
    }

    /** Also reports this phone's current addresses, so the iPhone keeps up when they change. */
    private fun ping(req: Request): Response {
        val s = AppState.status.value
        // The iPhone tells us the hash of what it has, so we know whether an upload follows.
        val theirs = req.header("x-snapshot-hash")
        when {
            theirs == null -> attempt(Attempt.OK, "The iPhone checked in")
            theirs == s.lastSnapshotHash -> attempt(Attempt.OK, "Up to date · ${s.contactCount} contacts")
            else -> attempt(Attempt.PENDING, "The iPhone has changes to send…")
        }
        val addrs = Net.addresses()
        return Response.json(
            200,
            "lastSnapshotHash" to s.lastSnapshotHash,
            "count" to s.contactCount,
            "tailscale" to addrs.tailscale,
            "lan" to addrs.lan.firstOrNull(),
        )
    }

    private fun push(req: Request): Response {
        if (appCtx.checkSelfPermission(Manifest.permission.WRITE_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            AppState.update { it.copy(message = "Contacts permission missing — open the app") }
            return failed(503, "This phone has not allowed access to contacts", "Contacts permission not granted on the Samsung")
        }
        val code = AppState.status.value.pairCode
        val snapshot = try {
            SnapshotParser.parse(Protocol.openSnapshot(code, req.body))
        } catch (e: Exception) {
            Log.w(TAG, "bad snapshot", e)
            return failed(400, "Could not read what the iPhone sent — pair again", "could not decrypt snapshot")
        }

        synchronized(applyLock) {
            val st = AppState.status.value
            // Unpaired or re-paired while this upload was in flight.
            if (st.pairCode != code) return Response.error(401, "Wrong pairing code — pair again")
            val writer = ContactsWriter(appCtx, ContactsWriter.modeOf(st.storage))
            if (snapshot.generatedAt < st.lastGeneratedAt) {
                return failed(409, "Ignored contacts older than the ones already here",
                    "older than the snapshot already applied")
            }
            if (snapshot.contacts.isEmpty() && req.header("x-allow-empty") != "1" && writer.count() > 0) {
                return failed(422, "Refused: the iPhone sent an empty contact list",
                    "refusing to delete every contact without confirmation")
            }
            val r = try {
                writer.apply(snapshot.contacts)
            } catch (e: Exception) {
                Log.e(TAG, "could not save contacts", e)
                val why = e.message ?: e.javaClass.simpleName
                AppState.update { it.copy(message = "Could not save contacts: $why") }
                return failed(500, "Could not save the contacts: $why", "The Samsung could not save the contacts: $why")
            }
            val now = System.currentTimeMillis()
            val skipped = if (r.failed > 0) " · ${r.failed} could not be saved" else ""
            val summary = if (r.added + r.updated + r.deleted == 0) "Up to date · ${r.total} contacts"
            else "${r.added} added, ${r.updated} updated, ${r.deleted} removed$skipped"
            AppState.update {
                it.copy(
                    contactCount = r.total,
                    lastSyncAt = now,
                    lastSeenAt = now,
                    lastSnapshotHash = req.header("x-snapshot-hash") ?: "",
                    lastGeneratedAt = snapshot.generatedAt,
                    attemptAt = now,
                    attemptState = Attempt.OK,
                    attemptDetail = summary,
                    message = if (r.added + r.updated + r.deleted == 0) "Up to date"
                    else "Synced: ${r.added} added, ${r.updated} updated, ${r.deleted} removed$skipped",
                )
            }
            Log.i(TAG, "applied snapshot: $r")
            return Response.json(200, "added" to r.added, "updated" to r.updated,
                "deleted" to r.deleted, "total" to r.total, "failed" to r.failed)
        }
    }
}
