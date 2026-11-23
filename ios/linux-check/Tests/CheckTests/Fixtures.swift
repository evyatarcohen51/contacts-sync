import Contacts
import Foundation

/// A small address book, served by the stub CNContactStore.
enum Fixtures {
    /// A real 1×1 PNG, so Android can decode it as a contact photo.
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    static func contact(_ id: String, _ build: (CNContact) -> Void) -> CNContact {
        let c = CNContact()
        c.identifier = id
        build(c)
        return c
    }

    static func dana(jobTitle: String = "CTO") -> CNContact {
        contact("410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson") { c in
            c.givenName = "דנה"
            c.familyName = "Levi"
            c.namePrefix = "Dr."
            c.organizationName = "Acme"
            c.departmentName = "R&D"
            c.jobTitle = jobTitle
            c.phoneNumbers = [
                CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+972 50-123-4567")),
                CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "03-555-1234")),
            ]
            c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "dana@acme.example" as NSString)]
            c.birthday = DateComponents(year: 1990, month: 3, day: 14)
            c.thumbnailImageData = png
        }
    }

    static func yossi() -> CNContact {
        contact("F57C8277-585D-4327-88A6-B5689FF69DFE:ABPerson") { c in
            c.givenName = "Yossi"
            c.familyName = "Cohen"
            c.nickname = "Yos"
            c.phoneNumbers = [
                CNLabeledValue(label: "Gym", value: CNPhoneNumber(stringValue: "+972 52-765-4321")),
                CNLabeledValue(label: CNLabelPhoneNumberiPhone, value: CNPhoneNumber(stringValue: "052-000-1111")),
                CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "   ")), // blank: must be dropped
            ]
            c.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: CNPostalAddress(
                street: "Herzl 1", city: "Tel Aviv", postalCode: "6100000", country: "Israel"))]
            c.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://yossi.example/me" as NSString)]
        }
    }

    static func pizza() -> CNContact {
        contact("AB211C5F-9EC9-429F-9466-B9382FF61035:ABPerson") { c in
            c.organizationName = "Pizza Place"
            c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: "*1234"))]
        }
    }

    static func noa() -> CNContact {
        contact("E94CD15C-7964-4A9B-8AC4-10D7CFB791FD:ABPerson") { c in
            c.givenName = "Noa"
            c.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberHomeFax, value: CNPhoneNumber(stringValue: "04-000-0000"))]
            c.emailAddresses = [CNLabeledValue(label: CNLabelEmailiCloud, value: "noa@icloud.example" as NSString)]
            c.birthday = DateComponents(month: 12, day: 1) // no year
        }
    }

    static func initial() -> [CNContact] { [dana(), yossi(), pizza()] }
    /// Dana edited, Yossi deleted, Noa added.
    static func changed() -> [CNContact] { [dana(jobTitle: "CEO"), pizza(), noa()] }
}
