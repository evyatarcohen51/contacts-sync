// swift-tools-version:5.9
//
// Compiles the iPhone app's real sources on Linux against small stand-ins for Apple's
// frameworks (Stubs/), and runs its sync and pairing logic against a running Android
// receiver. It cannot replace an Xcode build, but it catches most mistakes without a Mac.
// See run.sh.
import PackageDescription

let plainStubs = ["Combine", "UIKit", "Contacts", "CoreLocation", "Network", "BackgroundTasks", "Security"]

let package = Package(
    name: "LinuxCheck",
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: plainStubs.map { .target(name: $0, path: "Stubs/\($0)") } + [
        .target(name: "SwiftUI", dependencies: ["Combine", "UIKit"], path: "Stubs/SwiftUI"),
        .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")],
                path: "Stubs/CryptoKit"),
        // App is a symlink to ../ContactSyncSender/Sources: the app's own files, unchanged.
        .executableTarget(
            name: "ContactSyncSender",
            dependencies: ["Combine", "SwiftUI", "UIKit", "Contacts", "CoreLocation", "Network",
                           "BackgroundTasks", "Security", "CryptoKit"],
            path: "App",
            exclude: ["Info.plist", "Assets.xcassets"]
        ),
        .testTarget(name: "CheckTests", dependencies: ["ContactSyncSender"], path: "Tests/CheckTests"),
    ],
    swiftLanguageVersions: [.v5]
)
