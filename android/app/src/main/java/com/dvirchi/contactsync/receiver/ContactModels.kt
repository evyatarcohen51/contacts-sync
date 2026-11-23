package com.dvirchi.contactsync.receiver

import org.json.JSONArray
import org.json.JSONObject

data class Labeled(val label: String, val value: String)

data class PostalAddress(
    val label: String,
    val street: String,
    val city: String,
    val state: String,
    val postalCode: String,
    val country: String,
)

data class Birthday(val year: Int?, val month: Int, val day: Int)

data class IncomingContact(
    val id: String,
    val hash: String,
    val givenName: String,
    val familyName: String,
    val middleName: String,
    val namePrefix: String,
    val nameSuffix: String,
    val phoneticGivenName: String,
    val phoneticFamilyName: String,
    val nickname: String,
    val organization: String,
    val department: String,
    val jobTitle: String,
    val phones: List<Labeled>,
    val emails: List<Labeled>,
    val urls: List<Labeled>,
    val addresses: List<PostalAddress>,
    val birthday: Birthday?,
    val photo: ByteArray?,
)

data class Snapshot(val generatedAt: Long, val contacts: List<IncomingContact>)

object SnapshotParser {
    fun parse(json: String): Snapshot {
        val root = JSONObject(json)
        val arr = root.optJSONArray("contacts") ?: JSONArray()
        val list = ArrayList<IncomingContact>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val id = o.optString("id")
            if (id.isEmpty()) continue
            list += IncomingContact(
                id = id,
                hash = o.optString("hash").ifEmpty {
                    Protocol.hex(Protocol.sha256(o.toString().toByteArray())).take(16)
                },
                givenName = o.str("givenName"),
                familyName = o.str("familyName"),
                middleName = o.str("middleName"),
                namePrefix = o.str("namePrefix"),
                nameSuffix = o.str("nameSuffix"),
                phoneticGivenName = o.str("phoneticGivenName"),
                phoneticFamilyName = o.str("phoneticFamilyName"),
                nickname = o.str("nickname"),
                organization = o.str("organization"),
                department = o.str("department"),
                jobTitle = o.str("jobTitle"),
                phones = o.labeled("phones"),
                emails = o.labeled("emails"),
                urls = o.labeled("urls"),
                addresses = o.optJSONArray("addresses")?.let { a ->
                    (0 until a.length()).map { j ->
                        val x = a.getJSONObject(j)
                        PostalAddress(
                            label = x.str("label").ifEmpty { "other" },
                            street = x.str("street"),
                            city = x.str("city"),
                            state = x.str("state"),
                            postalCode = x.str("postalCode"),
                            country = x.str("country"),
                        )
                    }
                } ?: emptyList(),
                birthday = o.optJSONObject("birthday")?.let { b ->
                    val m = b.optInt("month", 0)
                    val d = b.optInt("day", 0)
                    if (m in 1..12 && d in 1..31) {
                        // 1604 is Apple's old placeholder for "no year".
                        val y = if (b.has("year") && !b.isNull("year")) b.optInt("year") else 0
                        Birthday(y.takeIf { it in 1..9999 && it != 1604 }, m, d)
                    } else null
                },
                photo = o.str("photo").takeIf { it.isNotEmpty() }?.let {
                    runCatching { java.util.Base64.getMimeDecoder().decode(it) }.getOrNull()
                        ?.takeIf { bytes -> bytes.isNotEmpty() }
                },
            )
        }
        return Snapshot(root.optLong("generatedAt", 0L), list)
    }

    private fun JSONObject.str(k: String): String =
        if (isNull(k)) "" else optString(k, "").trim()

    private fun JSONObject.labeled(k: String): List<Labeled> {
        val a = optJSONArray(k) ?: return emptyList()
        return (0 until a.length()).mapNotNull { i ->
            val x = a.getJSONObject(i)
            val v = x.str("value")
            if (v.isEmpty()) null else Labeled(x.str("label").ifEmpty { "other" }, v)
        }
    }
}
