// Stand-in for the parts of CoreLocation the app uses.
import Foundation

public typealias CLLocationAccuracy = Double
public typealias CLLocationDistance = Double
public let kCLLocationAccuracyThreeKilometers: CLLocationAccuracy = 3000
public let kCLDistanceFilterNone: CLLocationDistance = -1

public enum CLAuthorizationStatus: Int32, Sendable {
    case notDetermined = 0, restricted, denied, authorizedAlways, authorizedWhenInUse
}

public final class CLLocation: NSObject {}

public protocol CLLocationManagerDelegate: AnyObject {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager)
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation])
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error)
}

// Optional in Objective-C.
extension CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

public final class CLLocationManager: NSObject {
    nonisolated(unsafe) public static var stubAuthorization = CLAuthorizationStatus.notDetermined

    public weak var delegate: CLLocationManagerDelegate?
    public var desiredAccuracy: CLLocationAccuracy = 0
    public var distanceFilter: CLLocationDistance = kCLDistanceFilterNone
    public var pausesLocationUpdatesAutomatically = true
    public var showsBackgroundLocationIndicator = false
    public var allowsBackgroundLocationUpdates = false
    public var authorizationStatus: CLAuthorizationStatus { CLLocationManager.stubAuthorization }
    public private(set) var isUpdating = false

    public override init() {}
    public func requestAlwaysAuthorization() {}
    public func requestWhenInUseAuthorization() {}
    public func startUpdatingLocation() { isUpdating = true }
    public func stopUpdatingLocation() { isUpdating = false }
}
