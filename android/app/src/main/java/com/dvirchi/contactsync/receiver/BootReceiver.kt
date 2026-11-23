package com.dvirchi.contactsync.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restart the listener after a reboot or app update, once the phone is paired. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                AppState.init(ctx)
                if (Protocol.isValidCode(AppState.status.value.pairCode)) {
                    runCatching { ReceiverService.start(ctx) }
                }
            }
        }
    }
}
