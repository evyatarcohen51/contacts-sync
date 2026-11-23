package com.dvirchi.contactsync.receiver.account

import android.accounts.AbstractAccountAuthenticator
import android.accounts.Account
import android.accounts.AccountAuthenticatorResponse
import android.app.Service
import android.content.AbstractThreadedSyncAdapter
import android.content.ContentProviderClient
import android.content.Context
import android.content.Intent
import android.content.SyncResult
import android.os.Bundle
import android.os.IBinder

/**
 * Minimal account plumbing so Android shows our "iPhone" contacts account.
 * The real syncing is done by ReceiverService; these are intentionally no-ops.
 */
class AuthenticatorService : Service() {
    private lateinit var authenticator: Authenticator
    override fun onCreate() {
        authenticator = Authenticator(this)
    }
    override fun onBind(intent: Intent?): IBinder? = authenticator.iBinder
}

class Authenticator(ctx: Context) : AbstractAccountAuthenticator(ctx) {
    override fun editProperties(r: AccountAuthenticatorResponse?, t: String?): Bundle? = null
    override fun addAccount(
        r: AccountAuthenticatorResponse?, t: String?, a: String?, f: Array<out String>?, o: Bundle?,
    ): Bundle? = null
    override fun confirmCredentials(r: AccountAuthenticatorResponse?, a: Account?, o: Bundle?): Bundle? = null
    override fun getAuthToken(r: AccountAuthenticatorResponse?, a: Account?, t: String?, o: Bundle?): Bundle? = null
    override fun getAuthTokenLabel(t: String?): String? = null
    override fun updateCredentials(r: AccountAuthenticatorResponse?, a: Account?, t: String?, o: Bundle?): Bundle? = null
    override fun hasFeatures(r: AccountAuthenticatorResponse?, a: Account?, f: Array<out String>?): Bundle =
        Bundle().apply { putBoolean(android.accounts.AccountManager.KEY_BOOLEAN_RESULT, false) }
}

class StubSyncService : Service() {
    private lateinit var adapter: StubSyncAdapter
    override fun onCreate() {
        adapter = StubSyncAdapter(applicationContext)
    }
    override fun onBind(intent: Intent?): IBinder? = adapter.syncAdapterBinder
}

class StubSyncAdapter(ctx: Context) : AbstractThreadedSyncAdapter(ctx, true) {
    override fun onPerformSync(
        account: Account?, extras: Bundle?, authority: String?,
        provider: ContentProviderClient?, syncResult: SyncResult?,
    ) = Unit
}
