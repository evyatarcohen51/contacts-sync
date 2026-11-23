package com.dvirchi.contactsync.receiver

import android.content.Context
import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Persistent settings + live status, observed by the UI and the notification. */
data class Status(
    val pairCode: String = "",
    val pairedDevice: String = "",
    val running: Boolean = false,
    val message: String = "Not paired yet",
    val lastSyncAt: Long = 0,
    val lastSeenAt: Long = 0,
    val contactCount: Int = 0,
    val lastSnapshotHash: String = "",
    val lastGeneratedAt: Long = 0,
    val storage: String = "phone",
    /** When the iPhone last tried to sync with this phone, and how that went. */
    val attemptAt: Long = 0,
    val attemptState: String = Attempt.NONE,
    val attemptDetail: String = "",
)

/** Result of a sync attempt, as far as this phone can tell. */
object Attempt {
    const val NONE = ""
    /** The iPhone said it has changes and is sending them. */
    const val PENDING = "pending"
    const val OK = "ok"
    const val FAILED = "failed"

    /** The iPhone uploads right after checking in; this long without it means it gave up. */
    const val PENDING_LIMIT_MS = 2 * 60_000L
}

/** Pairing state machine for the same-Wi-Fi pairing flow. */
sealed interface PairingState {
    data object Idle : PairingState
    data class Waiting(val until: Long) : PairingState
    data class Confirm(val session: String, val number: String, val device: String) : PairingState
    /** Accepted on this phone; waiting for the iPhone to collect the pairing code. */
    data class Finishing(val device: String) : PairingState
    data class Done(val device: String) : PairingState
}

object AppState {
    private lateinit var prefs: SharedPreferences
    private val _status = MutableStateFlow(Status())
    val status: StateFlow<Status> = _status.asStateFlow()

    val pairing = MutableStateFlow<PairingState>(PairingState.Idle)

    fun init(ctx: Context) {
        if (::prefs.isInitialized) return
        prefs = ctx.applicationContext.getSharedPreferences("contactsync", Context.MODE_PRIVATE)
        _status.value = Status(
            pairCode = prefs.getString("pairCode", "") ?: "",
            pairedDevice = prefs.getString("pairedDevice", "") ?: "",
            message = prefs.getString("message", null)
                ?: if (prefs.getString("pairCode", "").isNullOrEmpty()) "Not paired yet" else "Waiting for iPhone",
            lastSyncAt = prefs.getLong("lastSyncAt", 0),
            lastSeenAt = prefs.getLong("lastSeenAt", 0),
            contactCount = prefs.getInt("contactCount", 0),
            lastSnapshotHash = prefs.getString("lastSnapshotHash", "") ?: "",
            lastGeneratedAt = prefs.getLong("lastGeneratedAt", 0),
            storage = prefs.getString("storage", "phone") ?: "phone",
            attemptAt = prefs.getLong("attemptAt", 0),
            attemptState = prefs.getString("attemptState", Attempt.NONE) ?: Attempt.NONE,
            attemptDetail = prefs.getString("attemptDetail", "") ?: "",
        )
    }

    @Synchronized
    fun update(block: (Status) -> Status) {
        _status.update(block)
        val s = _status.value
        prefs.edit()
            .putString("pairCode", s.pairCode)
            .putString("pairedDevice", s.pairedDevice)
            .putString("message", s.message)
            .putLong("lastSyncAt", s.lastSyncAt)
            .putLong("lastSeenAt", s.lastSeenAt)
            .putInt("contactCount", s.contactCount)
            .putString("lastSnapshotHash", s.lastSnapshotHash)
            .putLong("lastGeneratedAt", s.lastGeneratedAt)
            .putString("storage", s.storage)
            .putLong("attemptAt", s.attemptAt)
            .putString("attemptState", s.attemptState)
            .putString("attemptDetail", s.attemptDetail)
            .apply()
    }
}
