// Stand-in for the Keychain calls the app uses: an in-memory generic-password store.
import Foundation

public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = Any
public typealias OSStatus = Int32

public let errSecSuccess: OSStatus = 0
public let errSecItemNotFound: OSStatus = -25300
public let errSecDuplicateItem: OSStatus = -25299

public let kSecClass = "class"
public let kSecClassGenericPassword = "genp"
public let kSecAttrService = "svce"
public let kSecAttrAccount = "acct"
public let kSecValueData = "v_Data"
public let kSecAttrAccessible = "pdmn"
public let kSecAttrAccessibleAfterFirstUnlock = "ck"
public let kSecReturnData = "r_Data"
public let kSecMatchLimit = "m_Limit"
public let kSecMatchLimitOne = "m_LimitOne"

private final class Store: @unchecked Sendable {
    static let shared = Store()
    let lock = NSLock()
    var items: [String: Data] = [:]
}

private func itemKey(_ q: CFDictionary) -> String {
    "\(q[kSecAttrService] ?? "")/\(q[kSecAttrAccount] ?? "")"
}

@discardableResult
public func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let s = Store.shared
    s.lock.lock(); defer { s.lock.unlock() }
    guard let data = attributes[kSecValueData] as? Data else { return -50 }
    if s.items[itemKey(attributes)] != nil { return errSecDuplicateItem }
    s.items[itemKey(attributes)] = data
    return errSecSuccess
}

@discardableResult
public func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    let s = Store.shared
    s.lock.lock(); defer { s.lock.unlock() }
    return s.items.removeValue(forKey: itemKey(query)) == nil ? errSecItemNotFound : errSecSuccess
}

public func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let s = Store.shared
    s.lock.lock(); defer { s.lock.unlock() }
    guard let data = s.items[itemKey(query)] else { return errSecItemNotFound }
    result?.pointee = data
    return errSecSuccess
}
