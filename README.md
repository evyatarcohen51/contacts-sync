# iPhone → Samsung Contact Sync

Two apps that keep a Samsung (Android) phone's contacts in sync with an iPhone,
every 1, 5 or 10 minutes, over the internet. There is **no server** to run:

- **Samsung app (receiver)**: listens on port 8765 in an always-on foreground service.
- **iPhone app (sender)**: every cycle it reads all contacts, asks the Samsung which
  version it has, and pushes an encrypted snapshot only when something changed.
- **Tailscale** (free VPN app) connects the two phones from anywhere. On the same
  Wi-Fi they also talk directly.

```
iPhone ──(Tailscale or home Wi-Fi)──► Samsung :8765 ──► Contacts database
         AES-256-GCM, key never leaves the two phones
```

## What syncs

Names (incl. prefix/suffix/phonetic), nickname, company/department/job title, phone
numbers, emails, postal addresses, websites, birthday, and photos (optional). Labels map
to Android types (mobile, home, work, …); custom labels like "Gym" are kept.

It is a **one-way mirror**: new, edited and deleted contacts on the iPhone show up on
the Samsung. Edits made on the Samsung to a synced contact are overwritten the next time
that contact changes on the iPhone. Contacts you create on the Samsung are never touched.

Not synced: contact notes (Apple requires a special entitlement for those).

## Setup

1. **Tailscale**: install it on both phones and sign in with the same account. On the
   Samsung, set Tailscale's battery mode to *Unrestricted*.
2. **Samsung**: install `dist/ContactSyncReceiver.apk` (allow "install unknown apps"),
   open it, grant Contacts and Notifications, and tap **Allow background running**.
   Also Settings → Apps → iPhone Contacts → Battery → **Unrestricted**.
3. **iPhone**: install the iOS app (see below), allow Contacts.
4. **Pair (same Wi-Fi, once)**: on the Samsung tap **Pair iPhone (same Wi-Fi)**. On the
   iPhone tap **Pair with Samsung** and pick the Samsung. Both screens show the same
   6-digit number. Tap **Accept** on the Samsung.
   *No shared Wi-Fi?* On the Samsung tap "Pair manually with a code" and type the code
   and Tailscale address into the iPhone.
5. Pick the cycle (1 / 5 / 10 min) on the iPhone. Done.

### Seeing whether it works

Both apps show, at the top of the screen:

- **Last sync attempt**: when the iPhone last tried to sync.
- **Result**: green **Success** or red **Failed**, with the detail underneath
  ("Up to date · 412 contacts", "Sent · 2 added, 1 updated, 0 removed", or the reason it failed,
  such as "Can't reach the Samsung" or "The iPhone used an old pairing code").

The iPhone counts every attempt, including ones that never reached the Samsung. The Samsung
can only show attempts that reached it, so if its "Last sync attempt" is getting old, look at
the iPhone for the reason.

### Where contacts are stored on the Samsung

- **Phone storage** (default): ordinary phone contacts, visible in every app (Samsung
  Contacts, Google Contacts, dialer, WhatsApp). Each synced contact carries a hidden tag,
  so only those are updated or removed.
- **Separate "iPhone" account**: kept apart. Samsung Contacts shows it, but Google's
  Contacts app hides third-party accounts.

"Unpair and remove synced contacts" deletes only the contacts that came from the iPhone.

## About the 1/5/10-minute cycle on iPhone

iOS pauses apps a few seconds after you leave them. To keep the cycle running:

- **App open**: the cycle runs exactly.
- **"Keep running in background" on**: the app stays awake using low-accuracy location
  (blue pill in the status bar, a little extra battery). Location is never stored or sent.
  This is fine for a personal install; Apple would reject it in the App Store.
- **Off**: iOS still runs background refreshes now and then, at times it chooses
  (often every few hours), and the app syncs right away whenever you open it.

If you swipe the iPhone app away in the app switcher, it stops until you open it again.
The same goes for restarting the iPhone: open the app once afterwards. The Samsung app
restarts by itself after a reboot.

Large address books are fine: 5,000 contacts, or 2,000 contacts with photos, sync in well
under a minute. The first sync is the slow one; after that only changed contacts are rewritten.

## Building

### Android (done on this machine)

```bash
cd android
./gradlew testDebugUnitTest assembleRelease   # needs JDK 17 + Android SDK
# -> android/app/build/outputs/apk/release/app-release.apk
```

The APK is signed with this machine's debug key. An APK built elsewhere (GitHub Actions
included) has a different key, so Android will ask you to uninstall the old one first.

### iOS (needs macOS + Xcode, so it can't be built on Linux)

**Option A: GitHub Actions (no Mac needed).** Push this repo to GitHub. The
`.github/workflows/build.yml` workflow builds an *unsigned* `ContactSyncSender-unsigned.ipa`
on a macOS runner, then runs the app in the iOS Simulator (see Testing). Download the
`.ipa` from the run's Artifacts, or from the `ci-results` branch, where each run also
leaves its build log and simulator screenshots. Install it with
[Sideloadly](https://sideloadly.io) or AltStore, which sign it with your Apple ID.
A free Apple ID's signature lasts 7 days, then you re-sideload; a paid developer account lasts a year.

**Option B: a Mac with Xcode.**

```bash
brew install xcodegen
cd ios/ContactSyncSender && xcodegen generate && open ContactSyncSender.xcodeproj
```

Select your team under Signing & Capabilities, plug in the iPhone, and press Run.
Turn on Developer Mode on the iPhone when asked.

## Testing

**Android unit tests** (protocol vectors, snapshot parsing, the HTTP server): `./gradlew testDebugUnitTest`.

**A fake iPhone** for the Samsung app. `tools/fake-iphone.js` speaks the same protocol as the iOS app:

```bash
node tools/fake-iphone.js pair <samsung-ip>                   # then tap Accept on the Samsung
node tools/fake-iphone.js push <samsung-ip> <code> a          # 3 sample contacts
node tools/fake-iphone.js push <samsung-ip> <code> b          # edit one, delete one, add one
node tools/fake-iphone.js push <samsung-ip> <code> bulk:2000:10   # 2000 contacts with 10 KB photos
node tools/fake-iphone.js push <samsung-ip> <code> a --stale  # an out-of-date snapshot (refused)
```

**The iPhone app's own code, on Linux.** `ios/linux-check` compiles the real Swift sources
against small stand-ins for Apple's frameworks and runs them. It does not replace an Xcode
build (the stand-ins are hand-written, and nothing is drawn), but it checks the parts that
matter most: the encryption and pairing maths against the same vectors as Android, the
contact export, and the whole pair-and-sync routine against a real Android receiver.

```bash
cd ios/linux-check
./run.sh                      # needs a Swift 6 toolchain (swift.org/install)
adb forward tcp:18765 tcp:8765 && ./run.sh 127.0.0.1:18765   # also pair + sync with a phone/emulator
```

**The iPhone app in the iOS Simulator** (on a Mac, or automatically on GitHub Actions).
`ios/simulator-check.sh` builds the app, launches it in the simulator, pairs it with
`tools/fake-samsung.js` (a stand-in for the Samsung app that follows the same rules but
keeps contacts in memory), adds a contact, switches the "Samsung" off, and saves
screenshots and logs to `ios/ContactSyncSender/sim-results/`. A simulator cannot show
Tailscale, real background behaviour, or your actual Samsung; only a real iPhone can.

```bash
ios/simulator-check.sh
node tools/fake-samsung.js --pairing-open --auto-accept    # or run the stand-in by hand
```

## Protocol & security

See `tools/protocol.js` (reference implementation; the Android unit tests check against it).

- Pairing: P-256 ECDH; both phones show a 6-digit number derived from both public keys.
  The Samsung only accepts pairing for 3 minutes after you tap the button, and only
  after you tap Accept.
- The pairing code (stored in the iPhone Keychain / Samsung app data) derives an auth
  token and a separate AES-256-GCM key. Snapshots are compressed, then encrypted, before
  they leave the iPhone.
- The Samsung rejects wrong codes, snapshots older than the last one applied, and an
  empty snapshot that would wipe every contact. It checks the code before it reads an
  upload, so a stranger on the network cannot make it buffer a large one.
- The connection itself is plain HTTP. Over Tailscale that is wrapped in WireGuard. On a
  shared Wi-Fi, someone listening could see *that* a sync happens and replay it, but could
  not read the contacts or change them.

## Layout

```
android/                 Samsung receiver (Kotlin, Jetpack Compose)
ios/ContactSyncSender/   iPhone sender (SwiftUI; XcodeGen project.yml)
ios/linux-check/         compiles and tests the iPhone sources on Linux
tools/                   protocol reference + fake iPhone for testing
dist/                    built Android APK
```
