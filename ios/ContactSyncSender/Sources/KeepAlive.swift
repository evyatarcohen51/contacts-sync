import CoreLocation
import Foundation

/// Optional "keep running in background" mode.
///
/// iOS normally suspends apps a few seconds after they leave the screen, and
/// background refresh runs only when iOS decides (often hours apart). Low-accuracy
/// background location updates keep the app alive so the 1/5/10-minute timer
/// keeps firing. Location data is never stored or sent. A blue location pill
/// shows in the status bar while this is on.
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var wanted = false

    /// Called on the main thread when permission changes or iOS delivers a location.
    /// The owner uses it as a nudge to check whether a sync is due.
    var onEvent: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 100
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        wanted = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: begin()
        default: break
        }
    }

    func stop() {
        wanted = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    private func begin() {
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wanted, [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) { begin() }
        onEvent?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        onEvent?() // the location itself is deliberately ignored
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
