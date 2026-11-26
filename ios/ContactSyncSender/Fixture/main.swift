import Contacts
import CoreGraphics
import Foundation
import ImageIO
import UIKit

// Test helper for the iOS Simulator. It changes the simulated iPhone's contacts the way a
// person would in the Contacts app, so the checks can see whether the sync app notices.
// It is a separate little app and is never part of the app that goes on a real iPhone.
//
//   xcrun simctl launch <device> com.dvirchi.contactsync.fixture <command> -out <file on the Mac>
//
//   add <first> <last> <phone>     add one contact
//   edit <first> <phone>           replace the phone numbers of contacts with this first name
//   delete <first-prefix>          delete contacts whose first name starts with this
//   bulk <count> <photo-every>     add <count> contacts "Bulk 00001"…; every Nth one gets a photo (0 = none)
//   count                          how many contacts there are
//
// The answer ("ok …" or "error …") is printed and written to the -out file.

var args = Array(CommandLine.arguments.dropFirst())
var outPath: String?
if let i = args.firstIndex(of: "-out"), i + 1 < args.count {
    outPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

func finish(_ text: String, ok: Bool = true) -> Never {
    let line = (ok ? "ok " : "error ") + text
    print(line)
    if let outPath { try? (line + "\n").write(toFile: outPath, atomically: true, encoding: .utf8) }
    exit(ok ? 0 : 1)
}

let store = CNContactStore()

func contacts(_ keys: [String]) throws -> [CNContact] {
    var out: [CNContact] = []
    let request = CNContactFetchRequest(keysToFetch: keys.map { $0 as CNKeyDescriptor })
    try store.enumerateContacts(with: request) { c, _ in out.append(c) }
    return out
}

func mobile(_ number: String) -> [CNLabeledValue<CNPhoneNumber>] {
    [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: number))]
}

/// A small JPEG of coloured rectangles, different for every seed.
func picture(_ seed: Int) -> Data? {
    let side = 320
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    var x = UInt32(truncatingIfNeeded: seed &* 2_654_435_761) | 1
    func next() -> CGFloat {
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        return CGFloat(x % 1000) / 1000
    }
    for _ in 0..<40 {
        ctx.setFillColor(red: next(), green: next(), blue: next(), alpha: 1)
        ctx.fill(CGRect(x: next() * 320, y: next() * 320, width: next() * 160, height: next() * 160))
    }
    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

/// Carries out the command, then quits the app.
func run() -> Never {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    guard status == .authorized else {
        finish("no access to Contacts (status \(status.rawValue))", ok: false)
    }

    do {
        switch args.first ?? "" {
        case "add" where args.count == 4:
            let c = CNMutableContact()
            c.givenName = args[1]
            c.familyName = args[2]
            c.phoneNumbers = mobile(args[3])
            let request = CNSaveRequest()
            request.add(c, toContainerWithIdentifier: nil)
            try store.execute(request)
            finish("added \(args[1]) \(args[2])")

        case "edit" where args.count == 3:
            let found = try contacts([CNContactGivenNameKey, CNContactPhoneNumbersKey]).filter { $0.givenName == args[1] }
            guard !found.isEmpty else { finish("no contact named \(args[1])", ok: false) }
            let request = CNSaveRequest()
            for c in found {
                guard let m = c.mutableCopy() as? CNMutableContact else { continue }
                m.phoneNumbers = mobile(args[2])
                request.update(m)
            }
            try store.execute(request)
            finish("edited \(found.count)")

        case "delete" where args.count == 2:
            let found = try contacts([CNContactGivenNameKey]).filter { $0.givenName.hasPrefix(args[1]) }
            var done = 0
            while done < found.count {
                let request = CNSaveRequest()
                for c in found[done..<min(done + 200, found.count)] {
                    if let m = c.mutableCopy() as? CNMutableContact { request.delete(m) }
                }
                try store.execute(request)
                done += 200
            }
            finish("deleted \(found.count)")

        case "bulk" where args.count == 3:
            guard let count = Int(args[1]), let every = Int(args[2]), count > 0 else {
                finish("bulk needs two numbers", ok: false)
            }
            var photos = 0
            var request = CNSaveRequest()
            for i in 1...count {
                let c = CNMutableContact()
                c.givenName = "Bulk"
                c.familyName = String(format: "%05d", i)
                c.organizationName = "Company \(i % 50)"
                c.phoneNumbers = mobile(String(format: "+97250%07d", i))
                c.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "bulk\(i)@example.com" as NSString)]
                if every > 0, i % every == 0, let data = picture(i) {
                    c.imageData = data
                    photos += 1
                }
                request.add(c, toContainerWithIdentifier: nil)
                if i % 200 == 0 || i == count {
                    try store.execute(request)
                    request = CNSaveRequest()
                }
            }
            finish("added \(count), \(photos) with a photo")

        case "count":
            let all = try contacts([CNContactGivenNameKey])
            finish("\(all.count) contacts")

        default:
            finish("unknown command: \(args.joined(separator: " "))", ok: false)
        }
    } catch {
        finish("\(error)", ok: false)
    }
}

/// A normal (empty) app as far as iOS is concerned; the work happens off the main thread.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DispatchQueue.global(qos: .userInitiated).async { run() }
        return true
    }
}

_ = UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
