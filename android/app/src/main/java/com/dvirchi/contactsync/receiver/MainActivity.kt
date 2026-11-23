package com.dvirchi.contactsync.receiver

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.text.format.DateFormat
import android.text.format.DateUtils
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.RadioButton
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.util.Date

class MainActivity : ComponentActivity() {

    private val permissions = buildList {
        add(Manifest.permission.READ_CONTACTS)
        add(Manifest.permission.WRITE_CONTACTS)
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
    }.toTypedArray()

    private var hasContacts by mutableStateOf(false)

    private val permLauncher = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        refreshPermissions()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ReceiverApi.init(this)
        refreshPermissions()
        if (!hasContacts) permLauncher.launch(permissions)
        setContent {
            val dark = isSystemInDarkTheme()
            MaterialTheme(colorScheme = if (dark) darkColorScheme() else lightColorScheme()) {
                Surface(Modifier.fillMaxSize()) { Screen() }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        refreshPermissions()
    }

    private fun refreshPermissions() {
        hasContacts = checkSelfPermission(Manifest.permission.WRITE_CONTACTS) == PackageManager.PERMISSION_GRANTED
        if (hasContacts) ReceiverService.start(this)
    }

    private fun ignoringBattery() =
        (getSystemService(POWER_SERVICE) as PowerManager).isIgnoringBatteryOptimizations(packageName)

    @SuppressLint("BatteryLife")
    private fun askBattery() {
        startActivity(
            Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
        )
    }

    @Composable
    private fun Screen() {
        val status by AppState.status.collectAsState()
        val pairing by AppState.pairing.collectAsState()
        var addrs by remember { mutableStateOf(Net.addresses()) }
        var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
        var battery by remember { mutableStateOf(ignoringBattery()) }
        var showCode by remember { mutableStateOf(false) }
        var confirmRemove by remember { mutableStateOf(false) }

        LaunchedEffect(Unit) {
            while (true) {
                addrs = Net.addresses()
                now = System.currentTimeMillis()
                battery = ignoringBattery()
                ReceiverApi.expirePairing(now)
                delay(3000)
            }
        }

        val paired = Protocol.isValidCode(status.pairCode)
        // `now` ticks every few seconds, so anything newer than a minute is simply "Just now".
        fun ago(t: Long) = when {
            t == 0L -> "Never"
            now - t < DateUtils.MINUTE_IN_MILLIS -> "Just now"
            else -> DateUtils.getRelativeTimeSpanString(t, now, DateUtils.MINUTE_IN_MILLIS).toString()
        }
        /** Exact clock time, with the date when it was not today. */
        fun stamp(t: Long): String {
            val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.MEDIUM).format(Date(t))
            return if (DateUtils.isToday(t)) time else
                "${DateFormat.getMediumDateFormat(this@MainActivity).format(Date(t))} $time"
        }

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("iPhone Contact Receiver", fontSize = 24.sp, fontWeight = FontWeight.Bold)

            if (!hasContacts) {
                Section("Permission needed") {
                    Text("Allow access to contacts so the iPhone's contacts can be saved here.")
                    Button(onClick = { permLauncher.launch(permissions) }) { Text("Grant permission") }
                }
            }

            Section("Status") {
                Line("Paired with", if (paired) status.pairedDevice.ifEmpty { "iPhone (manual code)" } else "—")
                Line("Last sync attempt", if (status.attemptAt == 0L) "Never" else
                    "${ago(status.attemptAt)} · ${stamp(status.attemptAt)}")
                ResultLine(status, now)
                Line("Synced contacts", status.contactCount.toString())
                Line("Last change applied", ago(status.lastSyncAt))
                Line("Listener", if (status.running) "running on port ${Protocol.PORT}" else "stopped")
                if (!status.running) Text(status.message, fontSize = 13.sp, color = MaterialTheme.colorScheme.error)
            }

            Section("Connection") {
                if (addrs.tailscale != null) {
                    Line("Tailscale address", addrs.tailscale!!)
                } else {
                    Text(
                        "Tailscale is not connected. Install Tailscale on both phones and sign in " +
                            "with the same account so they can reach each other away from home.",
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                Line("Wi-Fi address", addrs.lan.firstOrNull() ?: "—")
            }

            Section("Pairing") {
                when (val p = pairing) {
                    is PairingState.Waiting -> {
                        Text("Waiting for the iPhone… Keep both phones on the same Wi-Fi. In the iPhone app " +
                            "tap \"Pair with Samsung\" and pick this phone.")
                        OutlinedButton(onClick = { ReceiverApi.cancelPairing() }) { Text("Cancel") }
                    }
                    is PairingState.Confirm -> Text("Answer the question on screen.")
                    is PairingState.Finishing -> {
                        Text("Finishing pairing with ${p.device}… Keep the iPhone app open.")
                        OutlinedButton(onClick = { ReceiverApi.cancelPairing() }) { Text("Cancel") }
                    }
                    is PairingState.Done -> {
                        Text("Paired with ${p.device}.")
                        OutlinedButton(onClick = { AppState.pairing.value = PairingState.Idle }) { Text("OK") }
                    }
                    else -> {
                        Text(if (paired) "Pair again to replace the current iPhone." else
                            "Put both phones on the same Wi-Fi, then tap below.")
                        Button(onClick = { ReceiverApi.openPairing() }, enabled = status.running) {
                            Text("Pair iPhone (same Wi-Fi)")
                        }
                    }
                }
                TextButton(onClick = {
                    showCode = !showCode
                    if (showCode) ReceiverApi.ensureCode()
                }) {
                    Text(if (showCode) "Hide manual code" else "Pair manually with a code instead")
                }
                if (showCode && paired) {
                    Text("In the iPhone app tap \"Pair with Samsung\" and type this under \"Or enter manually\":")
                    SelectionContainer {
                        Column {
                            Text(Protocol.pretty(status.pairCode), fontFamily = FontFamily.Monospace, fontSize = 22.sp)
                            Text("Address: ${addrs.tailscale ?: addrs.lan.firstOrNull() ?: "?"}",
                                fontFamily = FontFamily.Monospace)
                        }
                    }
                }
            }

            Section("Save contacts to") {
                StorageOption("phone", status.storage, "Phone storage (recommended)",
                    "Normal phone contacts. Shows in every contacts app, including Google Contacts. " +
                        "Only contacts that came from the iPhone are ever changed.")
                StorageOption("account", status.storage, "Separate \"iPhone\" account",
                    "Kept apart from your other contacts. Shows in Samsung Contacts, but Google's " +
                        "Contacts app hides it.")
            }

            if (!battery) {
                Section("Keep running in background") {
                    Text("Samsung may put the app to sleep. Allow it to run in the background, and in " +
                        "Settings → Apps → this app → Battery choose \"Unrestricted\" (do the same for Tailscale).")
                    Button(onClick = { askBattery() }) { Text("Allow background running") }
                }
            }

            OutlinedButton(onClick = { confirmRemove = true }, modifier = Modifier.fillMaxWidth()) {
                Text("Unpair and remove synced contacts")
            }
            Spacer(Modifier.height(24.dp))
        }

        (pairing as? PairingState.Confirm)?.let { p ->
            AlertDialog(
                onDismissRequest = {},
                title = { Text("Pair with ${p.device}?") },
                text = {
                    Column {
                        Text("Check that the iPhone shows the same number:")
                        Spacer(Modifier.height(8.dp))
                        Text(p.number.chunked(3).joinToString(" "), fontSize = 34.sp,
                            fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold)
                    }
                },
                confirmButton = { Button(onClick = { ReceiverApi.decide(p.session, true) }) { Text("Accept") } },
                dismissButton = { TextButton(onClick = { ReceiverApi.decide(p.session, false) }) { Text("Reject") } },
            )
        }

        if (confirmRemove) {
            AlertDialog(
                onDismissRequest = { confirmRemove = false },
                title = { Text("Unpair?") },
                text = { Text("This removes all contacts that came from the iPhone from this phone and forgets the pairing. Your other contacts are not touched.") },
                confirmButton = {
                    Button(onClick = {
                        Thread { ReceiverApi.unpair() }.start()
                        showCode = false
                        confirmRemove = false
                    }) { Text("Unpair") }
                },
                dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel") } },
            )
        }
    }

    /** Green "Success" or red "Failed" for the iPhone's last sync attempt, with the reason. */
    @Composable
    private fun ResultLine(status: Status, now: Long) {
        // The iPhone uploads right after announcing changes; if nothing came, it gave up.
        val stalled = status.attemptState == Attempt.PENDING &&
            now - status.attemptAt > Attempt.PENDING_LIMIT_MS
        val dark = isSystemInDarkTheme()
        val green = if (dark) Color(0xFF81C784) else Color(0xFF2E7D32)
        val red = MaterialTheme.colorScheme.error
        val (label, color) = when {
            status.attemptState == Attempt.OK -> "✓ Success" to green
            status.attemptState == Attempt.FAILED || stalled -> "✕ Failed" to red
            status.attemptState == Attempt.PENDING -> "Receiving…" to MaterialTheme.colorScheme.onSurfaceVariant
            else -> "No sync yet" to MaterialTheme.colorScheme.onSurfaceVariant
        }
        val detail = when {
            stalled -> "The iPhone had changes but did not finish sending them"
            status.attemptState == Attempt.NONE -> status.message // e.g. "Paired with …", "Not paired yet"
            else -> status.attemptDetail
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Result", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.padding(horizontal = 8.dp))
            Text(label, fontWeight = FontWeight.Bold, color = color)
        }
        if (detail.isNotEmpty()) {
            Text(detail, fontSize = 13.sp,
                color = if (color == red) red else MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }

    @Composable
    private fun StorageOption(value: String, current: String, title: String, desc: String) {
        Row(
            Modifier.fillMaxWidth().selectable(selected = value == current, role = Role.RadioButton) {
                Thread { ReceiverApi.setStorage(value) }.start()
            },
            verticalAlignment = Alignment.Top,
        ) {
            RadioButton(selected = value == current, onClick = null, modifier = Modifier.padding(top = 2.dp, end = 8.dp))
            Column {
                Text(title, fontWeight = FontWeight.Medium)
                Text(desc, fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }

    @Composable
    private fun Section(title: String, content: @Composable () -> Unit) {
        Card(
            Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                content()
            }
        }
    }

    @Composable
    private fun Line(label: String, value: String) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.padding(horizontal = 8.dp))
            Text(value, fontWeight = FontWeight.Medium)
        }
    }
}
