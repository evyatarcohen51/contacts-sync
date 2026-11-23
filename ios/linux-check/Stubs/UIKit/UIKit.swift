// Stand-in for the parts of UIKit the app uses.
@_exported import Foundation

public struct UIBackgroundTaskIdentifier: Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

@MainActor
public final class UIApplication {
    public static let shared = UIApplication()
    public static let openSettingsURLString = "app-settings:"
    public static let didBecomeActiveNotification = NSNotification.Name("UIApplicationDidBecomeActiveNotification")
    public static let didEnterBackgroundNotification = NSNotification.Name("UIApplicationDidEnterBackgroundNotification")

    /// Test hook: how many background tasks are open right now (must return to 0).
    public private(set) var openBackgroundTasks = 0
    private var next = 1

    public func beginBackgroundTask(
        withName taskName: String?, expirationHandler handler: (@MainActor @Sendable () -> Void)? = nil
    ) -> UIBackgroundTaskIdentifier {
        openBackgroundTasks += 1
        next += 1
        return UIBackgroundTaskIdentifier(rawValue: next)
    }

    public func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        openBackgroundTasks -= 1
    }

    public func open(_ url: URL, options: [String: Any] = [:], completionHandler completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {}
}

@MainActor
public final class UIDevice {
    public static let current = UIDevice()
    public var name: String { "iPhone" }
}

public enum UIKeyboardType: Int, Sendable {
    case `default`, asciiCapable, numbersAndPunctuation, URL, numberPad, phonePad, namePhonePad
    case emailAddress, decimalPad, twitter, webSearch, asciiCapableNumberPad
}
