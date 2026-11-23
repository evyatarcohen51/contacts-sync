// Stand-in for the parts of the Contacts framework the app uses.
// CNContactStore serves whatever the tests put in `stubContacts`.
import Foundation

public enum CNEntityType: Int, Sendable { case contacts }

public enum CNAuthorizationStatus: Int, Sendable {
    case notDetermined = 0, restricted = 1, denied = 2, authorized = 3
}

public protocol CNKeyDescriptor {}
extension NSString: CNKeyDescriptor {}
extension String: CNKeyDescriptor {} // Linux has no automatic String -> NSString bridging

public let CNContactGivenNameKey = "givenName"
public let CNContactFamilyNameKey = "familyName"
public let CNContactMiddleNameKey = "middleName"
public let CNContactNamePrefixKey = "namePrefix"
public let CNContactNameSuffixKey = "nameSuffix"
public let CNContactNicknameKey = "nickname"
public let CNContactPhoneticGivenNameKey = "phoneticGivenName"
public let CNContactPhoneticFamilyNameKey = "phoneticFamilyName"
public let CNContactOrganizationNameKey = "organizationName"
public let CNContactDepartmentNameKey = "departmentName"
public let CNContactJobTitleKey = "jobTitle"
public let CNContactPhoneNumbersKey = "phoneNumbers"
public let CNContactEmailAddressesKey = "emailAddresses"
public let CNContactPostalAddressesKey = "postalAddresses"
public let CNContactUrlAddressesKey = "urlAddresses"
public let CNContactBirthdayKey = "birthday"
public let CNContactThumbnailImageDataKey = "thumbnailImageData"

public let CNLabelHome = "_$!<Home>!$_"
public let CNLabelWork = "_$!<Work>!$_"
public let CNLabelOther = "_$!<Other>!$_"
public let CNLabelSchool = "_$!<School>!$_"
public let CNLabelEmailiCloud = "iCloud"
public let CNLabelURLAddressHomePage = "_$!<HomePage>!$_"
public let CNLabelPhoneNumberMobile = "_$!<Mobile>!$_"
public let CNLabelPhoneNumberiPhone = "iPhone"
public let CNLabelPhoneNumberMain = "_$!<Main>!$_"
public let CNLabelPhoneNumberHomeFax = "_$!<HomeFAX>!$_"
public let CNLabelPhoneNumberWorkFax = "_$!<WorkFAX>!$_"
public let CNLabelPhoneNumberOtherFax = "_$!<OtherFAX>!$_"
public let CNLabelPhoneNumberPager = "_$!<Pager>!$_"

public final class CNPhoneNumber: NSObject {
    public let stringValue: String
    public init(stringValue: String) { self.stringValue = stringValue }
}

public final class CNPostalAddress: NSObject {
    public var street = "", city = "", state = "", postalCode = "", country = ""
    public init(street: String = "", city: String = "", state: String = "", postalCode: String = "", country: String = "") {
        self.street = street; self.city = city; self.state = state; self.postalCode = postalCode; self.country = country
    }
}

public final class CNLabeledValue<ValueType>: NSObject {
    public let label: String?
    public let value: ValueType
    public init(label: String?, value: ValueType) { self.label = label; self.value = value }

    /// Apple returns the display name for built-in labels and the label itself for custom ones.
    public class func localizedString(forLabel label: String) -> String {
        guard label.hasPrefix("_$!<"), label.hasSuffix(">!$_") else { return label }
        return String(label.dropFirst(4).dropLast(4)).lowercased()
    }
}

public final class CNContact: NSObject {
    public var identifier = UUID().uuidString
    public var givenName = "", familyName = "", middleName = "", namePrefix = "", nameSuffix = ""
    public var nickname = "", phoneticGivenName = "", phoneticFamilyName = ""
    public var organizationName = "", departmentName = "", jobTitle = ""
    public var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] = []
    public var emailAddresses: [CNLabeledValue<NSString>] = []
    public var postalAddresses: [CNLabeledValue<CNPostalAddress>] = []
    public var urlAddresses: [CNLabeledValue<NSString>] = []
    public var birthday: DateComponents?
    public var thumbnailImageData: Data?
    public override init() {}
}

public final class CNContactFetchRequest: NSObject {
    public let keysToFetch: [CNKeyDescriptor]
    public var unifyResults = true
    public init(keysToFetch: [CNKeyDescriptor]) { self.keysToFetch = keysToFetch }
}

public struct ObjCBool { public var boolValue: Bool }

public final class CNContactStore: NSObject, @unchecked Sendable {
    // Test fixtures.
    nonisolated(unsafe) public static var stubContacts: [CNContact] = []
    nonisolated(unsafe) public static var stubAuthorization = CNAuthorizationStatus.authorized

    public override init() {}

    public class func authorizationStatus(for entityType: CNEntityType) -> CNAuthorizationStatus { stubAuthorization }

    public func requestAccess(for entityType: CNEntityType) async throws -> Bool {
        CNContactStore.stubAuthorization == .authorized
    }

    public func enumerateContacts(
        with fetchRequest: CNContactFetchRequest,
        usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void
    ) throws {
        var stop = ObjCBool(boolValue: false)
        for c in CNContactStore.stubContacts {
            block(c, &stop)
            if stop.boolValue { break }
        }
    }
}

extension NSNotification.Name {
    public static let CNContactStoreDidChange = NSNotification.Name("CNContactStoreDidChangeNotification")
}
