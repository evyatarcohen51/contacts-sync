import XCTest

/// Taps through the app in the iOS Simulator, the way a person would.
///
/// Run by ios/simulator-check.sh, which first starts tools/fake-samsung.js (a stand-in
/// for the Samsung app that accepts pairing by itself after a few seconds) and advertises
/// it on the network as "ContactSync Test", the way the real Samsung app does.
final class ContactSyncUITests: XCTestCase {
    private let app = XCUIApplication()
    private let shotsDir = "/tmp/contactsync-ui"

    /// Saves a screenshot next to the test log (and inside the test result).
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: shotsDir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "\(shotsDir)/\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Any element whose label or value matches; SwiftUI merges some rows into one element.
    private func element(_ format: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label \(format) OR value \(format)"))
            .firstMatch
    }

    /// Taps "Allow" if iOS asks for permission (for example to search the local network).
    private func allowSystemPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Allow While Using App"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    func testPairOverWiFiThenSync() {
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "permission prompt") { alert in
            for label in ["Allow", "OK", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()

        // The pairing rows are at the bottom of the screen. Start from "not paired",
        // whatever an earlier step left behind.
        app.swipeUp()
        let unpair = app.buttons["Unpair"]
        if unpair.waitForExistence(timeout: 5) {
            unpair.tap()
        }
        let pair = app.buttons["Pair with Samsung"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "no \"Pair with Samsung\" row")
        shot("ui-1-not-paired")

        // ---- Pairing screen ----
        pair.tap()
        XCTAssertTrue(app.navigationBars["Pair"].waitForExistence(timeout: 10), "pairing screen did not open")
        allowSystemPrompt()

        // The app lists "ContactSync Test" as "Test".
        let samsung = app.buttons["Test"]
        let foundOnNetwork = samsung.waitForExistence(timeout: 25)
        shot("ui-2-pairing-screen")

        if foundOnNetwork {
            samsung.tap()
            let number = element("CONTAINS 'shows this number'")
            XCTAssertTrue(number.waitForExistence(timeout: 20), "the comparison number did not appear")
            shot("ui-3-comparison-number")
            XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 40),
                          "pairing did not finish after the Samsung accepted")
            shot("ui-4-paired")
            app.buttons["Done"].tap()
        } else {
            XCTFail("the Samsung was not found on the network; pairing with the code instead")
            let code = app.textFields["Pairing code (XXXX-XXXX-XXXX-XXXX)"]
            code.tap()
            code.typeText("TESTCODE23456789")
            let host = app.textFields["Samsung address (Tailscale 100.x.y.z)"]
            host.tap()
            host.typeText("127.0.0.1")
            shot("ui-3-manual-entry")
            app.buttons["Save"].tap()
        }

        // ---- Back on the main screen: the sync must end in green ----
        XCTAssertTrue(app.navigationBars["Contact Sync"].waitForExistence(timeout: 10), "not back on the main screen")
        app.swipeDown()
        let sent = element("BEGINSWITH 'Sent ·'")
        XCTAssertTrue(sent.waitForExistence(timeout: 40), "no successful sync after pairing")
        XCTAssertTrue(element("CONTAINS 'Success'").exists, "the result is not shown as Success")
        shot("ui-5-synced")

        app.buttons["Sync now"].tap()
        sleep(4)
        XCTAssertTrue(element("BEGINSWITH 'Sent ·'").waitForExistence(timeout: 20), "Sync now did not send")
        XCTAssertTrue(element("CONTAINS 'Success'").exists, "Sync now did not end in Success")
        shot("ui-6-after-sync-now")

        app.swipeUp()
        sleep(1)
        shot("ui-7-settings-and-samsung")
    }
}
