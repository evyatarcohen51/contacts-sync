import XCTest

/// Taps through the app in the iOS Simulator, the way a person would.
///
/// Run by ios/simulator-check.sh (against tools/fake-samsung.js, a stand-in for the Samsung
/// app) and by ios/both-apps-check.sh (against the real Samsung app in an Android emulator).
/// Those scripts and these tests leave each other notes in a folder on the Mac.
final class ContactSyncUITests: XCTestCase {
    private let app = XCUIApplication()
    private let shared = "/tmp/contactsync-ui"

    // MARK: Helpers

    /// Saves a screenshot next to the test log (and inside the test result).
    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: "\(shared)/\(name).png"))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func leaveNote(_ name: String, _ text: String) {
        try? FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try? text.write(toFile: "\(shared)/\(name)", atomically: true, encoding: .utf8)
    }

    private func readNote(_ name: String) -> String? {
        guard let text = try? String(contentsOfFile: "\(shared)/\(name)", encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func waitForNote(_ name: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: "\(shared)/\(name)") { return true }
            sleep(1)
        }
        return false
    }

    /// Any element whose label or value matches; SwiftUI merges some rows into one element.
    private func element(_ format: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label \(format) OR value \(format)"))
            .firstMatch
    }

    /// Taps "Allow" if iOS asks for permission (for example to search the local network).
    private func allowSystemPrompt(timeout: TimeInterval = 2) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow While Using App", "Allow", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: timeout) {
                button.tap()
                return
            }
        }
    }

    private func launch() {
        continueAfterFailure = true
        addUIInterruptionMonitor(withDescription: "permission prompt") { alert in
            for label in ["Allow While Using App", "Allow", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.launch()
    }

    /// Opens the pairing screen, starting from "not paired" whatever an earlier step left behind.
    private func openPairingScreen(_ shotName: String) {
        app.swipeUp() // the pairing rows are at the bottom of the screen
        let unpair = app.buttons["Unpair"]
        if unpair.waitForExistence(timeout: 5) {
            unpair.tap()
        }
        let pair = app.buttons["Pair with Samsung"]
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "no \"Pair with Samsung\" row")
        shot(shotName)
        pair.tap()
        XCTAssertTrue(app.navigationBars["Pair"].waitForExistence(timeout: 10), "pairing screen did not open")
        allowSystemPrompt()
    }

    /// Back on the main screen, the first sync after pairing must end in green.
    private func expectSuccessfulSync(_ shotName: String) {
        XCTAssertTrue(app.navigationBars["Contact Sync"].waitForExistence(timeout: 10), "not back on the main screen")
        app.swipeDown()
        let sent = element("BEGINSWITH 'Sent ·'")
        XCTAssertTrue(sent.waitForExistence(timeout: 60), "no successful sync after pairing")
        XCTAssertTrue(element("CONTAINS 'Success'").exists, "the result is not shown as Success")
        shot(shotName)
    }

    // MARK: Tests

    /// Finds the Samsung on the network, compares the number, pairs, syncs, taps "Sync now".
    func testPairOverWiFiThenSync() {
        launch()
        openPairingScreen("ui-1-not-paired")

        // The Samsung is announced as "ContactSync Test"; the app lists it as "Test".
        let samsung = app.buttons["Test"]
        let foundOnNetwork = samsung.waitForExistence(timeout: 60)
        shot("ui-2-pairing-screen")
        guard foundOnNetwork else {
            XCTFail("the Samsung was not found on the network")
            return
        }

        // With the real Samsung app, wait until "Pair iPhone" has been tapped over there.
        if FileManager.default.fileExists(atPath: "\(shared)/wait-for-samsung") {
            leaveNote("iphone-ready", "1")
            XCTAssertTrue(waitForNote("samsung-ready", timeout: 240), "pairing was never opened on the Samsung")
        }
        samsung.tap()

        let prompt = element("CONTAINS 'shows this number'")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30), "the comparison number did not appear")
        let number = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "(?s).*[0-9]{3} [0-9]{3}.*"))
            .firstMatch
        if number.waitForExistence(timeout: 5),
           let range = number.label.range(of: "[0-9]{3} [0-9]{3}", options: .regularExpression) {
            leaveNote("iphone-number", String(number.label[range]))
        }
        shot("ui-3-comparison-number")

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 120),
                      "pairing did not finish after the Samsung accepted")
        shot("ui-4-paired")
        app.buttons["Done"].tap()

        expectSuccessfulSync("ui-5-synced")

        app.buttons["Sync now"].tap()
        sleep(4)
        XCTAssertTrue(element("BEGINSWITH 'Sent ·'").waitForExistence(timeout: 30), "Sync now did not send")
        XCTAssertTrue(element("CONTAINS 'Success'").exists, "Sync now did not end in Success")
        shot("ui-6-after-sync-now")

        app.swipeUp()
        sleep(1)
        shot("ui-7-settings-and-samsung")
    }

    /// Pairs by typing the Samsung's code and address, as when the phones share no Wi-Fi.
    func testPairWithCode() {
        let code = readNote("manual-code") ?? "TESTCODE23456789"
        let host = readNote("manual-host") ?? "127.0.0.1"
        launch()
        openPairingScreen("code-1-not-paired")

        var codeField = app.textFields["Pairing code (XXXX-XXXX-XXXX-XXXX)"]
        var hostField = app.textFields["Samsung address (Tailscale 100.x.y.z)"]
        if !codeField.waitForExistence(timeout: 10) {
            codeField = app.textFields.element(boundBy: 0)
            hostField = app.textFields.element(boundBy: 1)
        }
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), "no field for the pairing code")
        codeField.tap()
        codeField.typeText(code)
        hostField.tap()
        hostField.typeText(host)
        shot("code-2-typed")
        let save = app.buttons["Save"]
        XCTAssertTrue(save.isEnabled, "Save is greyed out after typing the code and address")
        save.tap()

        expectSuccessfulSync("code-3-synced")
    }

    /// Sets the cycle to 1 minute and turns on "Keep running in background".
    func testTurnOnBackgroundMode() {
        launch()
        let minute = app.segmentedControls.buttons["1 min"]
        XCTAssertTrue(minute.waitForExistence(timeout: 15), "no \"1 min\" choice")
        minute.tap()

        let toggle = app.switches["Keep running in background"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no \"Keep running in background\" switch")
        if (toggle.value as? String) != "1" {
            // The switch itself sits at the right end of the row.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            sleep(1)
            if (toggle.value as? String) != "1", !XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists {
                toggle.tap()
            }
        }
        // iOS asks whether the app may use the location.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 20) {
            allow.tap()
            leaveNote("location-prompt", "allowed")
        } else {
            leaveNote("location-prompt", "not shown")
        }
        sleep(2)
        XCTAssertEqual(toggle.value as? String, "1", "the switch did not turn on")
        XCTAssertFalse(element("CONTAINS 'Location permission is off'").exists, "the app says location is off")
        XCTAssertTrue(minute.isSelected, "\"1 min\" is not selected")
        shot("bg-1-background-mode-on")
    }
}
