import Contacts
import Foundation
import XCTest
@testable import ContactSyncSender

final class ExporterTests: XCTestCase {
    override func setUp() {
        CNContactStore.stubContacts = Fixtures.initial()
    }

    func testMapsFieldsAndLabels() throws {
        let out = try ContactExporter.export(includePhotos: true)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.id), out.map(\.id).sorted()) // stable order

        let dana = try XCTUnwrap(out.first { $0.givenName == "דנה" })
        XCTAssertEqual(dana.familyName, "Levi")
        XCTAssertEqual(dana.namePrefix, "Dr.")
        XCTAssertEqual(dana.organization, "Acme")
        XCTAssertEqual(dana.department, "R&D")
        XCTAssertEqual(dana.jobTitle, "CTO")
        XCTAssertNil(dana.middleName) // empty fields are left out
        XCTAssertEqual(dana.phones, [LabeledValue(label: "mobile", value: "+972 50-123-4567"),
                                     LabeledValue(label: "work", value: "03-555-1234")])
        XCTAssertEqual(dana.emails, [LabeledValue(label: "work", value: "dana@acme.example")])
        XCTAssertEqual(dana.birthday, BirthdayDTO(year: 1990, month: 3, day: 14))
        XCTAssertEqual(dana.photo, Fixtures.png.base64EncodedString())
        XCTAssertEqual(dana.hash?.count, 16)

        let yossi = try XCTUnwrap(out.first { $0.givenName == "Yossi" })
        XCTAssertEqual(yossi.phones, [LabeledValue(label: "Gym", value: "+972 52-765-4321"),   // custom label kept
                                      LabeledValue(label: "iphone", value: "052-000-1111")])   // blank one dropped
        XCTAssertEqual(yossi.addresses, [PostalAddressDTO(label: "home", street: "Herzl 1", city: "Tel Aviv",
                                                          state: nil, postalCode: "6100000", country: "Israel")])
        XCTAssertEqual(yossi.urls, [LabeledValue(label: "homepage", value: "https://yossi.example/me")])
        XCTAssertEqual(yossi.nickname, "Yos")
        XCTAssertNil(yossi.photo)

        let pizza = try XCTUnwrap(out.first { $0.organization == "Pizza Place" })
        XCTAssertNil(pizza.givenName)
        XCTAssertEqual(pizza.phones, [LabeledValue(label: "main", value: "*1234")])
    }

    func testBirthdayWithoutYearAndOtherLabels() throws {
        CNContactStore.stubContacts = [Fixtures.noa()]
        let noa = try XCTUnwrap(try ContactExporter.export(includePhotos: true).first)
        XCTAssertEqual(noa.birthday, BirthdayDTO(year: nil, month: 12, day: 1))
        XCTAssertEqual(noa.phones, [LabeledValue(label: "homefax", value: "04-000-0000")])
        XCTAssertEqual(noa.emails, [LabeledValue(label: "iCloud", value: "noa@icloud.example")])
    }

    func testHashesAreStableAndFollowContent() throws {
        let a = try ContactExporter.export(includePhotos: true)
        let b = try ContactExporter.export(includePhotos: true)
        XCTAssertEqual(a.map(\.hash), b.map(\.hash))
        XCTAssertEqual(ContactExporter.snapshotHash(a), ContactExporter.snapshotHash(b))
        XCTAssertEqual(ContactExporter.snapshotHash(a).count, 64)

        // Leaving photos out changes only the contact that has one.
        let noPhotos = try ContactExporter.export(includePhotos: false)
        XCTAssertNil(noPhotos.first { $0.givenName == "דנה" }?.photo)
        XCTAssertEqual(zip(a, noPhotos).filter { $0.hash != $1.hash }.count, 1)
        XCTAssertNotEqual(ContactExporter.snapshotHash(a), ContactExporter.snapshotHash(noPhotos))

        // An edit changes that contact's hash and the snapshot hash.
        CNContactStore.stubContacts = Fixtures.changed()
        let c = try ContactExporter.export(includePhotos: true)
        XCTAssertNotEqual(ContactExporter.snapshotHash(a), ContactExporter.snapshotHash(c))
        XCTAssertNotEqual(a.first { $0.givenName == "דנה" }?.hash, c.first { $0.givenName == "דנה" }?.hash)
        XCTAssertEqual(a.first { $0.organization == "Pizza Place" }?.hash, c.first { $0.organization == "Pizza Place" }?.hash)
    }

    func testSnapshotJsonShape() throws {
        let contacts = try ContactExporter.export(includePhotos: true)
        let data = try JSONEncoder().encode(SnapshotDTO(generatedAt: 1_763_900_000_000, contacts: contacts))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["v"] as? Int, 1)
        XCTAssertEqual(root["generatedAt"] as? Int, 1_763_900_000_000)
        let list = try XCTUnwrap(root["contacts"] as? [[String: Any]])
        XCTAssertEqual(list.count, 3)
        let pizza = try XCTUnwrap(list.first { $0["organization"] as? String == "Pizza Place" })
        // Absent fields are omitted, never null: that is what the Android parser expects.
        XCTAssertEqual(Set(pizza.keys), ["id", "hash", "organization", "phones"])

        // Sealing gives nonce(12) + raw DEFLATE + tag(16).
        let blob = try Proto.sealSnapshot(data, code: "TEST-CODE-2345-6789")
        XCTAssertGreaterThan(blob.count, 28)
        XCTAssertNoThrow(try Proto.open(blob, key: Proto.key("TEST-CODE-2345-6789")))
    }

    func testEmptyAddressBook() throws {
        CNContactStore.stubContacts = []
        let out = try ContactExporter.export(includePhotos: true)
        XCTAssertTrue(out.isEmpty)
        XCTAssertEqual(ContactExporter.snapshotHash(out).count, 64)
    }
}
