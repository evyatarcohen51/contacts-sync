package com.dvirchi.contactsync.receiver

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The JSON here has the shape the iPhone's JSONEncoder writes (absent keys for empty fields). */
class SnapshotParserTest {

    @Test
    fun parsesAFullContact() {
        val json = """
            {"v":1,"generatedAt":1763900000000,"contacts":[{
              "id":"ABC-123:ABPerson","hash":"0123456789abcdef",
              "givenName":"דנה","familyName":"Levi","middleName":"R","namePrefix":"Dr.","nameSuffix":"Jr.",
              "phoneticGivenName":"Dana","phoneticFamilyName":"Levy","nickname":"Dani",
              "organization":"Acme","department":"R&D","jobTitle":"CTO",
              "phones":[{"label":"mobile","value":"+972 50-123-4567"},{"label":"Gym","value":"03-555"}],
              "emails":[{"label":"work","value":"dana@acme.example"}],
              "urls":[{"label":"homepage","value":"https:\/\/acme.example\/dana"}],
              "addresses":[{"label":"home","street":"Herzl 1","city":"Tel Aviv","postalCode":"6100000","country":"Israel"}],
              "birthday":{"year":1990,"month":3,"day":14},
              "photo":"AQIDBA=="
            }]}
        """.trimIndent()
        val s = SnapshotParser.parse(json)
        assertEquals(1763900000000L, s.generatedAt)
        val c = s.contacts.single()
        assertEquals("ABC-123:ABPerson", c.id)
        assertEquals("0123456789abcdef", c.hash)
        assertEquals("דנה", c.givenName)
        assertEquals("Dr.", c.namePrefix)
        assertEquals("R&D", c.department)
        assertEquals(listOf(Labeled("mobile", "+972 50-123-4567"), Labeled("Gym", "03-555")), c.phones)
        assertEquals("https://acme.example/dana", c.urls.single().value)
        assertEquals(PostalAddress("home", "Herzl 1", "Tel Aviv", "", "6100000", "Israel"), c.addresses.single())
        assertEquals(Birthday(1990, 3, 14), c.birthday)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), c.photo)
    }

    @Test
    fun missingAndNullFieldsBecomeEmpty() {
        val c = SnapshotParser.parse(
            """{"generatedAt":5,"contacts":[{"id":"x","organization":"Pizza","familyName":null,"photo":null}]}"""
        ).contacts.single()
        assertEquals("", c.givenName)
        assertEquals("", c.familyName)
        assertEquals("Pizza", c.organization)
        assertTrue(c.phones.isEmpty() && c.emails.isEmpty() && c.urls.isEmpty() && c.addresses.isEmpty())
        assertNull(c.birthday)
        assertNull(c.photo)
        assertEquals(16, c.hash.length) // no hash sent: one is derived
    }

    @Test
    fun birthdayWithoutAYear() {
        fun bday(b: String) = SnapshotParser.parse("""{"contacts":[{"id":"x","birthday":$b}]}""").contacts.single().birthday
        assertEquals(Birthday(null, 12, 1), bday("""{"month":12,"day":1}"""))
        assertEquals(Birthday(null, 12, 1), bday("""{"year":1604,"month":12,"day":1}""")) // Apple's "no year"
        assertEquals(Birthday(null, 12, 1), bday("""{"year":null,"month":12,"day":1}"""))
        assertNull(bday("""{"month":13,"day":1}"""))
        assertNull(bday("""{"month":2}"""))
    }

    @Test
    fun skipsEntriesWithoutIdOrValue() {
        val s = SnapshotParser.parse(
            """{"contacts":[{"givenName":"no id"},{"id":"ok","phones":[{"label":"","value":" 123 "},{"label":"home","value":" "}]}]}"""
        )
        val c = s.contacts.single()
        assertEquals("ok", c.id)
        assertEquals(listOf(Labeled("other", "123")), c.phones)
    }

    @Test
    fun badPhotoIsDropped() {
        val c = SnapshotParser.parse("""{"contacts":[{"id":"x","photo":"!!not base64!!"}]}""").contacts.single()
        assertNull(c.photo)
    }

    @Test
    fun emptySnapshot() {
        assertTrue(SnapshotParser.parse("""{"v":1,"generatedAt":7,"contacts":[]}""").contacts.isEmpty())
        assertTrue(SnapshotParser.parse("""{"generatedAt":7}""").contacts.isEmpty())
    }
}
