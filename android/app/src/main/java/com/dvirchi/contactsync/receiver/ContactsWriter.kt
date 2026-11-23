package com.dvirchi.contactsync.receiver

import android.accounts.Account
import android.accounts.AccountManager
import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Event
import android.provider.ContactsContract.CommonDataKinds.Nickname
import android.provider.ContactsContract.CommonDataKinds.Organization
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.Photo
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.CommonDataKinds.StructuredPostal
import android.provider.ContactsContract.CommonDataKinds.Website
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts
import android.util.Log
import java.util.Locale

/**
 * Mirrors the iPhone's contacts into this phone's contacts database.
 *
 * Two storage modes:
 *  - PHONE (default): normal phone-storage contacts, visible in every contacts app
 *    (Samsung Contacts, Google Contacts, dialer, WhatsApp...). Each synced contact is
 *    tagged SYNC2="contactsync", and only tagged contacts are ever changed or deleted,
 *    so contacts you created yourself are never touched.
 *  - ACCOUNT: a separate "iPhone" account. Cleanest separation, but Google's Contacts
 *    app does not display third-party accounts (Samsung Contacts does).
 *
 * Each raw contact stores the iPhone contact id in SOURCE_ID and a content hash in
 * SYNC1, so only contacts that actually changed are rewritten.
 */
class ContactsWriter(private val ctx: Context, private val mode: Mode) {

    enum class Mode { PHONE, ACCOUNT }

    companion object {
        const val ACCOUNT_TYPE = "com.dvirchi.contactsync.account"
        const val ACCOUNT_NAME = "iPhone"
        const val MARKER = "contactsync"
        val ACCOUNT = Account(ACCOUNT_NAME, ACCOUNT_TYPE)
        private const val TAG = "ContactsWriter"

        // One applyBatch() is one Binder transaction, which Android caps at about 1 MB,
        // and the contacts provider allows at most 500 operations per batch.
        private const val BATCH_LIMIT = 300
        private const val BATCH_BYTES = 256 * 1024
        private const val MAX_PHOTO_BYTES = 512 * 1024
        private const val OP_OVERHEAD = 512

        /** More failed contacts than this means something is broken, not one odd contact. */
        private const val MAX_SKIPPED = 5

        fun modeOf(s: String) = if (s == "account") Mode.ACCOUNT else Mode.PHONE

        /** Remove every contact this app created, in both modes. */
        fun removeAll(ctx: Context) {
            AccountManager.get(ctx).removeAccountExplicitly(ACCOUNT)
            runCatching { ContactsWriter(ctx, Mode.PHONE).deleteAllTagged() }
        }
    }

    data class Result(val added: Int, val updated: Int, val deleted: Int, val total: Int, val failed: Int = 0)

    private data class Existing(val rawId: Long, val hash: String?)

    /**
     * Every operation for one contact. Built late, because the back-reference to the
     * new raw contact depends on where the group lands inside its batch.
     */
    private class Group(
        val id: String,
        val ops: Int,
        val bytes: Int,
        val build: (base: Int) -> List<ContentProviderOperation>,
    )

    private val resolver: ContentResolver = ctx.contentResolver

    /** Account the new raw contacts go into (null name/type = the phone's local storage). */
    private val targetName: String?
    private val targetType: String?

    init {
        if (mode == Mode.ACCOUNT) {
            targetName = ACCOUNT_NAME
            targetType = ACCOUNT_TYPE
        } else if (Build.VERSION.SDK_INT >= 33) {
            targetName = RawContacts.getLocalAccountName(ctx)
            targetType = RawContacts.getLocalAccountType(ctx)
        } else {
            targetName = null
            targetType = null
        }
    }

    private fun Uri.asSyncAdapter(): Uri = buildUpon()
        .appendQueryParameter(ContactsContract.CALLER_IS_SYNCADAPTER, "true")
        .apply {
            if (targetName != null && targetType != null) {
                appendQueryParameter(RawContacts.ACCOUNT_NAME, targetName)
                appendQueryParameter(RawContacts.ACCOUNT_TYPE, targetType)
            }
        }
        .build()

    /** Rows that belong to us in the current mode. */
    private val ownSelection: Pair<String, Array<String>>
        get() = if (mode == Mode.ACCOUNT) {
            "${RawContacts.ACCOUNT_TYPE}=? AND ${RawContacts.ACCOUNT_NAME}=? AND ${RawContacts.DELETED}=0" to
                arrayOf(ACCOUNT_TYPE, ACCOUNT_NAME)
        } else {
            "${RawContacts.SYNC2}=? AND ${RawContacts.DELETED}=0 AND " +
                "(${RawContacts.ACCOUNT_TYPE} IS NULL OR ${RawContacts.ACCOUNT_TYPE}!=?)" to
                arrayOf(MARKER, ACCOUNT_TYPE)
        }

    private fun ensureTarget() {
        if (mode != Mode.ACCOUNT) return
        val am = AccountManager.get(ctx)
        if (am.getAccountsByType(ACCOUNT_TYPE).none { it.name == ACCOUNT_NAME }) {
            am.addAccountExplicitly(ACCOUNT, null, null)
        }
        ContentResolver.setIsSyncable(ACCOUNT, ContactsContract.AUTHORITY, 1)

        // Make the account's contacts visible in the Contacts app.
        val values = ContentValues().apply {
            put(ContactsContract.Settings.ACCOUNT_NAME, ACCOUNT_NAME)
            put(ContactsContract.Settings.ACCOUNT_TYPE, ACCOUNT_TYPE)
            put(ContactsContract.Settings.UNGROUPED_VISIBLE, 1)
            put(ContactsContract.Settings.SHOULD_SYNC, 1)
        }
        val settingsUri = ContactsContract.Settings.CONTENT_URI.asSyncAdapter()
        val where = "${ContactsContract.Settings.ACCOUNT_NAME}=? AND ${ContactsContract.Settings.ACCOUNT_TYPE}=?"
        val updated = resolver.update(settingsUri, values, where, arrayOf(ACCOUNT_NAME, ACCOUNT_TYPE))
        if (updated == 0) resolver.insert(settingsUri, values)
    }

    fun count(): Int = existing().size

    private fun existing(): MutableMap<String, Existing> {
        val map = HashMap<String, Existing>()
        val orphans = ArrayList<Long>()
        val (where, args) = ownSelection
        resolver.query(
            RawContacts.CONTENT_URI.asSyncAdapter(),
            arrayOf(RawContacts._ID, RawContacts.SOURCE_ID, RawContacts.SYNC1),
            where, args, null,
        )?.use { c ->
            while (c.moveToNext()) {
                val src = c.getString(1)
                if (src.isNullOrEmpty() || map.containsKey(src)) orphans += c.getLong(0)
                else map[src] = Existing(c.getLong(0), c.getString(2))
            }
        }
        if (orphans.isNotEmpty()) {
            val ops = orphans.map { deleteRaw(it) }
            ops.chunked(BATCH_LIMIT).forEach { resolver.applyBatch(ContactsContract.AUTHORITY, ArrayList(it)) }
        }
        return map
    }

    fun deleteAllTagged() {
        val ops = existing().values.map { deleteRaw(it.rawId) }
        ops.chunked(BATCH_LIMIT).forEach { resolver.applyBatch(ContactsContract.AUTHORITY, ArrayList(it)) }
    }

    fun apply(contacts: List<IncomingContact>): Result {
        ensureTarget()
        val current = existing()
        val groups = ArrayList<Group>()
        var added = 0
        var updated = 0
        var deleted = 0

        val seen = HashSet<String>()
        for (c in contacts) {
            if (!seen.add(c.id)) continue
            val ex = current[c.id]
            if (ex == null) {
                groups += insertGroup(c)
                added++
            } else if (ex.hash != c.hash) {
                groups += updateGroup(ex.rawId, c)
                updated++
            }
        }
        for ((src, ex) in current) {
            if (src !in seen) {
                groups += Group(src, 1, OP_OVERHEAD) { listOf(deleteRaw(ex.rawId)) }
                deleted++
            }
        }
        return Result(added, updated, deleted, seen.size, run(groups))
    }

    private fun insertGroup(c: IncomingContact): Group {
        val rows = dataRows(c)
        return Group(c.id, 1 + rows.size, OP_OVERHEAD + size(rows)) { base ->
            val ops = ArrayList<ContentProviderOperation>(1 + rows.size)
            ops += ContentProviderOperation.newInsert(RawContacts.CONTENT_URI.asSyncAdapter())
                .withValue(RawContacts.ACCOUNT_NAME, targetName)
                .withValue(RawContacts.ACCOUNT_TYPE, targetType)
                .withValue(RawContacts.SOURCE_ID, c.id)
                .withValue(RawContacts.SYNC1, c.hash)
                .withValue(RawContacts.SYNC2, MARKER)
                .build()
            for (row in rows) {
                ops += ContentProviderOperation.newInsert(Data.CONTENT_URI.asSyncAdapter())
                    .withValueBackReference(Data.RAW_CONTACT_ID, base)
                    .withValues(row)
                    .build()
            }
            ops
        }
    }

    private fun updateGroup(rawId: Long, c: IncomingContact): Group {
        val rows = dataRows(c)
        return Group(c.id, 2 + rows.size, 2 * OP_OVERHEAD + size(rows)) {
            val ops = ArrayList<ContentProviderOperation>(2 + rows.size)
            ops += ContentProviderOperation.newUpdate(
                ContentUris.withAppendedId(RawContacts.CONTENT_URI, rawId).asSyncAdapter()
            ).withValue(RawContacts.SYNC1, c.hash).build()
            ops += ContentProviderOperation.newDelete(Data.CONTENT_URI.asSyncAdapter())
                .withSelection("${Data.RAW_CONTACT_ID}=?", arrayOf(rawId.toString()))
                .build()
            for (row in rows) {
                ops += ContentProviderOperation.newInsert(Data.CONTENT_URI.asSyncAdapter())
                    .withValue(Data.RAW_CONTACT_ID, rawId)
                    .withValues(row)
                    .build()
            }
            ops
        }
    }

    /** Rough size of the rows once parcelled (strings travel as UTF-16). */
    private fun size(rows: List<ContentValues>): Int = rows.sumOf { row ->
        OP_OVERHEAD + row.keySet().sumOf { k ->
            2 * k.length + 8 + when (val v = row.get(k)) {
                is ByteArray -> v.size
                is String -> 2 * v.length + 8
                else -> 8
            }
        }
    }

    /**
     * Applies whole contacts in batches that fit one Binder transaction.
     * Returns how many contacts could not be written. If a batch fails, its contacts
     * are retried one at a time, so one odd contact does not block all the others.
     */
    private fun run(groups: List<Group>): Int {
        var failed = 0
        var lastError: Exception? = null
        var i = 0
        while (i < groups.size) {
            val batch = ArrayList<ContentProviderOperation>()
            var bytes = 0
            var j = i
            while (j < groups.size) {
                val g = groups[j]
                if (j > i && (batch.size + g.ops > BATCH_LIMIT || bytes + g.bytes > BATCH_BYTES)) break
                batch += g.build(batch.size)
                bytes += g.bytes
                j++
            }
            try {
                resolver.applyBatch(ContactsContract.AUTHORITY, batch)
            } catch (e: Exception) {
                Log.w(TAG, "batch of ${j - i} contacts failed, retrying one by one", e)
                for (k in i until j) {
                    try {
                        resolver.applyBatch(ContactsContract.AUTHORITY, ArrayList(groups[k].build(0)))
                    } catch (e2: Exception) {
                        Log.w(TAG, "could not write contact ${groups[k].id}", e2)
                        lastError = e2
                        failed++
                    }
                }
                if (failed > MAX_SKIPPED) throw lastError ?: e
            }
            i = j
        }
        if (failed > 0 && failed == groups.size) throw lastError!!
        return failed
    }

    private fun deleteRaw(rawId: Long) =
        ContentProviderOperation.newDelete(
            ContentUris.withAppendedId(RawContacts.CONTENT_URI, rawId).asSyncAdapter()
        ).build()

    // ---- Mapping iPhone fields -> Android data rows ---------------------------

    private fun row(mime: String, block: ContentValues.() -> Unit) =
        ContentValues().apply { put(Data.MIMETYPE, mime); block() }

    private fun dataRows(c: IncomingContact): List<ContentValues> {
        val rows = ArrayList<ContentValues>()

        if (listOf(c.givenName, c.familyName, c.middleName, c.namePrefix, c.nameSuffix,
                c.phoneticGivenName, c.phoneticFamilyName).any { it.isNotEmpty() }) {
            rows += row(StructuredName.CONTENT_ITEM_TYPE) {
                putIfNotEmpty(StructuredName.GIVEN_NAME, c.givenName)
                putIfNotEmpty(StructuredName.FAMILY_NAME, c.familyName)
                putIfNotEmpty(StructuredName.MIDDLE_NAME, c.middleName)
                putIfNotEmpty(StructuredName.PREFIX, c.namePrefix)
                putIfNotEmpty(StructuredName.SUFFIX, c.nameSuffix)
                putIfNotEmpty(StructuredName.PHONETIC_GIVEN_NAME, c.phoneticGivenName)
                putIfNotEmpty(StructuredName.PHONETIC_FAMILY_NAME, c.phoneticFamilyName)
            }
        }
        if (c.nickname.isNotEmpty()) {
            rows += row(Nickname.CONTENT_ITEM_TYPE) {
                put(Nickname.NAME, c.nickname)
                put(Nickname.TYPE, Nickname.TYPE_DEFAULT)
            }
        }
        if (c.organization.isNotEmpty() || c.jobTitle.isNotEmpty() || c.department.isNotEmpty()) {
            rows += row(Organization.CONTENT_ITEM_TYPE) {
                putIfNotEmpty(Organization.COMPANY, c.organization)
                putIfNotEmpty(Organization.TITLE, c.jobTitle)
                putIfNotEmpty(Organization.DEPARTMENT, c.department)
                put(Organization.TYPE, Organization.TYPE_WORK)
            }
        }
        for (p in c.phones) {
            rows += row(Phone.CONTENT_ITEM_TYPE) {
                put(Phone.NUMBER, p.value)
                typed(Phone.TYPE, Phone.LABEL, Phone.TYPE_CUSTOM, phoneType(p.label), p.label)
            }
        }
        for (e in c.emails) {
            rows += row(Email.CONTENT_ITEM_TYPE) {
                put(Email.ADDRESS, e.value)
                typed(Email.TYPE, Email.LABEL, Email.TYPE_CUSTOM, emailType(e.label), e.label)
            }
        }
        for (a in c.addresses) {
            rows += row(StructuredPostal.CONTENT_ITEM_TYPE) {
                putIfNotEmpty(StructuredPostal.STREET, a.street)
                putIfNotEmpty(StructuredPostal.CITY, a.city)
                putIfNotEmpty(StructuredPostal.REGION, a.state)
                putIfNotEmpty(StructuredPostal.POSTCODE, a.postalCode)
                putIfNotEmpty(StructuredPostal.COUNTRY, a.country)
                typed(StructuredPostal.TYPE, StructuredPostal.LABEL, StructuredPostal.TYPE_CUSTOM,
                    postalType(a.label), a.label)
            }
        }
        for (u in c.urls) {
            rows += row(Website.CONTENT_ITEM_TYPE) {
                put(Website.URL, u.value)
                typed(Website.TYPE, Website.LABEL, Website.TYPE_CUSTOM, websiteType(u.label), u.label)
            }
        }
        c.birthday?.let { b ->
            rows += row(Event.CONTENT_ITEM_TYPE) {
                put(Event.TYPE, Event.TYPE_BIRTHDAY)
                // Locale.ROOT: some locales would otherwise write non-ASCII digits.
                put(Event.START_DATE,
                    if (b.year != null) "%04d-%02d-%02d".format(Locale.ROOT, b.year, b.month, b.day)
                    else "--%02d-%02d".format(Locale.ROOT, b.month, b.day))
            }
        }
        // A photo must fit in one Binder transaction together with the rest of the contact.
        c.photo?.takeIf { it.isNotEmpty() && it.size <= MAX_PHOTO_BYTES }?.let { bytes ->
            rows += row(Photo.CONTENT_ITEM_TYPE) { put(Photo.PHOTO, bytes) }
        }
        return rows
    }

    private fun ContentValues.putIfNotEmpty(k: String, v: String) {
        if (v.isNotEmpty()) put(k, v)
    }

    /** Known label -> type constant; unknown label -> custom type + label text. */
    private fun ContentValues.typed(typeCol: String, labelCol: String, custom: Int, type: Int?, label: String) {
        if (type != null) put(typeCol, type) else {
            put(typeCol, custom)
            put(labelCol, label)
        }
    }

    private fun phoneType(l: String) = when (l.lowercase()) {
        "mobile", "iphone", "cell" -> Phone.TYPE_MOBILE
        "home" -> Phone.TYPE_HOME
        "work" -> Phone.TYPE_WORK
        "main" -> Phone.TYPE_MAIN
        "homefax" -> Phone.TYPE_FAX_HOME
        "workfax" -> Phone.TYPE_FAX_WORK
        "otherfax" -> Phone.TYPE_OTHER_FAX
        "pager" -> Phone.TYPE_PAGER
        "other" -> Phone.TYPE_OTHER
        else -> null
    }

    private fun emailType(l: String) = when (l.lowercase()) {
        "home" -> Email.TYPE_HOME
        "work" -> Email.TYPE_WORK
        "other" -> Email.TYPE_OTHER
        "mobile" -> Email.TYPE_MOBILE
        else -> null
    }

    private fun postalType(l: String) = when (l.lowercase()) {
        "home" -> StructuredPostal.TYPE_HOME
        "work" -> StructuredPostal.TYPE_WORK
        "other" -> StructuredPostal.TYPE_OTHER
        else -> null
    }

    private fun websiteType(l: String) = when (l.lowercase()) {
        "homepage" -> Website.TYPE_HOMEPAGE
        "home" -> Website.TYPE_HOME
        "work" -> Website.TYPE_WORK
        "blog" -> Website.TYPE_BLOG
        "other" -> Website.TYPE_OTHER
        else -> null
    }
}
