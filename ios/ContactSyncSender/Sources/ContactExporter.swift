import Contacts
import Foundation

struct LabeledValue: Codable, Hashable {
    var label: String
    var value: String
}

struct PostalAddressDTO: Codable, Hashable {
    var label: String
    var street: String?
    var city: String?
    var state: String?
    var postalCode: String?
    var country: String?
}

struct BirthdayDTO: Codable, Hashable {
    var year: Int?
    var month: Int
    var day: Int
}

/// One contact on the wire. Nil / empty fields are omitted from the JSON.
struct ContactDTO: Codable {
    var id: String
    var hash: String?
    var givenName: String?
    var familyName: String?
    var middleName: String?
    var namePrefix: String?
    var nameSuffix: String?
    var phoneticGivenName: String?
    var phoneticFamilyName: String?
    var nickname: String?
    var organization: String?
    var department: String?
    var jobTitle: String?
    var phones: [LabeledValue]?
    var emails: [LabeledValue]?
    var urls: [LabeledValue]?
    var addresses: [PostalAddressDTO]?
    var birthday: BirthdayDTO?
    var photo: String?
}

struct SnapshotDTO: Codable {
    var v = 1
    var generatedAt: Int64
    var contacts: [ContactDTO]
}

enum ContactExporter {

    /// One long-lived store. iOS only delivers CNContactStoreDidChange to an app that keeps one.
    static let store = CNContactStore()

    /// Reads every contact. Blocking — call off the main thread.
    static func export(includePhotos: Bool) throws -> [ContactDTO] {
        var keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
            CNContactNamePrefixKey, CNContactNameSuffixKey, CNContactNicknameKey,
            CNContactPhoneticGivenNameKey, CNContactPhoneticFamilyNameKey,
            CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
            CNContactUrlAddressesKey, CNContactBirthdayKey,
        ].map { $0 as CNKeyDescriptor }
        if includePhotos { keys.append(CNContactThumbnailImageDataKey as CNKeyDescriptor) }

        let request = CNContactFetchRequest(keysToFetch: keys)
        var out: [ContactDTO] = []
        try store.enumerateContacts(with: request) { c, _ in
            out.append(map(c, includePhotos: includePhotos))
        }
        out.sort { $0.id < $1.id }

        // Per-contact content hash so the Samsung only rewrites changed contacts.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for i in out.indices {
            let data = try encoder.encode(out[i])
            out[i].hash = String(Proto.hex(Proto.sha256(data)).prefix(16))
        }
        return out
    }

    /// Hash of the whole address book; unchanged hash = nothing to send.
    static func snapshotHash(_ contacts: [ContactDTO]) -> String {
        let joined = contacts.map { $0.hash ?? "" }.joined(separator: ",")
        return Proto.hex(Proto.sha256(Data(joined.utf8)))
    }

    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func nonEmpty<T>(_ a: [T]) -> [T]? { a.isEmpty ? nil : a }

    private static func map(_ c: CNContact, includePhotos: Bool) -> ContactDTO {
        let phones = c.phoneNumbers.compactMap { lv -> LabeledValue? in
            guard let v = nonEmpty(lv.value.stringValue) else { return nil }
            return LabeledValue(label: label(lv.label), value: v)
        }
        let emails = c.emailAddresses.compactMap { lv -> LabeledValue? in
            guard let v = nonEmpty(lv.value as String) else { return nil }
            return LabeledValue(label: label(lv.label), value: v)
        }
        let urls = c.urlAddresses.compactMap { lv -> LabeledValue? in
            guard let v = nonEmpty(lv.value as String) else { return nil }
            return LabeledValue(label: label(lv.label), value: v)
        }
        let addresses = c.postalAddresses.map { lv -> PostalAddressDTO in
            let a = lv.value
            return PostalAddressDTO(
                label: label(lv.label),
                street: nonEmpty(a.street), city: nonEmpty(a.city), state: nonEmpty(a.state),
                postalCode: nonEmpty(a.postalCode), country: nonEmpty(a.country)
            )
        }

        var birthday: BirthdayDTO?
        if let b = c.birthday, let m = b.month, let d = b.day,
           m != NSDateComponentUndefined, d != NSDateComponentUndefined {
            var year: Int?
            if let y = b.year, y != NSDateComponentUndefined { year = y }
            birthday = BirthdayDTO(year: year, month: m, day: d)
        }

        var photo: String?
        if includePhotos, let data = c.thumbnailImageData { photo = data.base64EncodedString() }

        return ContactDTO(
            id: c.identifier,
            givenName: nonEmpty(c.givenName),
            familyName: nonEmpty(c.familyName),
            middleName: nonEmpty(c.middleName),
            namePrefix: nonEmpty(c.namePrefix),
            nameSuffix: nonEmpty(c.nameSuffix),
            phoneticGivenName: nonEmpty(c.phoneticGivenName),
            phoneticFamilyName: nonEmpty(c.phoneticFamilyName),
            nickname: nonEmpty(c.nickname),
            organization: nonEmpty(c.organizationName),
            department: nonEmpty(c.departmentName),
            jobTitle: nonEmpty(c.jobTitle),
            phones: nonEmpty(phones),
            emails: nonEmpty(emails),
            urls: nonEmpty(urls),
            addresses: nonEmpty(addresses),
            birthday: birthday,
            photo: photo
        )
    }

    /// Apple's built-in labels -> simple names the Android side understands.
    /// Custom labels ("Gym") are sent as-is.
    private static func label(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "other" }
        switch raw {
        case CNLabelPhoneNumberMobile: return "mobile"
        case CNLabelPhoneNumberiPhone: return "iphone"
        case CNLabelPhoneNumberMain: return "main"
        case CNLabelPhoneNumberHomeFax: return "homefax"
        case CNLabelPhoneNumberWorkFax: return "workfax"
        case CNLabelPhoneNumberOtherFax: return "otherfax"
        case CNLabelPhoneNumberPager: return "pager"
        case CNLabelHome: return "home"
        case CNLabelWork: return "work"
        case CNLabelOther: return "other"
        case CNLabelSchool: return "School"
        case CNLabelEmailiCloud: return "iCloud"
        case CNLabelURLAddressHomePage: return "homepage"
        default: return CNLabeledValue<NSString>.localizedString(forLabel: raw)
        }
    }
}
