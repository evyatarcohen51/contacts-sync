#!/bin/bash
# Runs the two real apps against each other on one Mac: the iPhone app in the iOS Simulator
# and the Samsung app in an Android emulator. It pairs them by tapping through both apps,
# then adds, edits and deletes contacts on the "iPhone" and looks in Android's contact list
# for the result. Screenshots and logs go to ios/ContactSyncSender/both-results/.
#
# Needs macOS with Xcode, xcodegen, node, the Android SDK's adb, the built APK (set APK=… if
# it is not in the usual Gradle folder) and an Android emulator: either one that is already
# running (adb devices), or set ANDROID_AVD=<name> and this script starts it after the
# iPhone build, so that the two do not fight over the Mac's processor.
#
# The emulator sits behind its own little network, so three things stand in for real Wi-Fi:
# `adb forward` plus tools/tcp-relay.js carry the Samsung app's port to this Mac, `dns-sd`
# announces it the way the Samsung app does, and (where sudo is allowed) an extra address
# 100.101.102.103 on this Mac plays the Samsung's Tailscale address.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ios/ContactSyncSender"
OUT="$PWD/both-results"
rm -rf "$OUT"; mkdir -p "$OUT"
export PATH="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools:$PATH"
source "$ROOT/ios/sim-lib.sh"
source "$ROOT/tools/android-lib.sh"

APK="${APK:-$ROOT/android/app/build/outputs/apk/release/app-release.apk}"
TS_IP=100.101.102.103
TS_NAME=samsung.contactsync-test.ts.net
BULK="${BULK:-1000}" # how many contacts the large-address-book step adds
export TAP_EVERY=3   # how often the tap helper re-reads the Android screen while waiting
PIDS=()
ALIAS=no
HOSTS=no
STARTED_EMULATOR=no

cleanup() {
  adb logcat -d -t 600 > "$OUT/android-last-log-lines.txt" 2> /dev/null
  kill ${PIDS[@]+"${PIDS[@]}"} 2> /dev/null
  wait ${PIDS[@]+"${PIDS[@]}"} 2> /dev/null
  [ "$STARTED_EMULATOR" = yes ] && adb emu kill > /dev/null 2>&1
  [ "$ALIAS" = yes ] && sudo -n ifconfig lo0 -alias "$TS_IP" 2> /dev/null
  [ "$HOSTS" = yes ] && sudo -n sed -i '' "/$TS_NAME/d" /etc/hosts 2> /dev/null
}
trap cleanup EXIT

# Uploads the Samsung app has answered with "saved", as seen by the relay on this Mac.
# Waiting for these costs the emulator nothing; asking Android itself every two seconds
# would keep a slow emulator busy with the questions.
uploads() { grep -c "^PUT /v1/contacts -> 200" "$OUT/relay.log" 2> /dev/null || true; }
more_uploads_than() { [ "$(uploads)" -gt "$1" ]; }
# After a change made with the contacts helper, wait for the sync app to send it. It may do
# so by itself while still in the background; otherwise open it, as a person would.
#   UPLOADS=$(uploads); fixture …; sent_after_change <seconds>     sets HOW
sent_after_change() {
  HOW="by itself, in the background"
  wait_until 14 more_uploads_than "$UPLOADS" && return 0
  HOW="when the app was opened"
  activate
  wait_until "$1" more_uploads_than "$UPLOADS"
}
# on_android <check command…>: look in Android's contact list, asking again a few times.
on_android() { EVERY=8 wait_until 40 "$@"; }
message() { prefs lastMessage; }
# What the Samsung app logged about the last upload it saved, e.g. "added=1, updated=0, deleted=0, total=7, failed=0".
applied() { adb logcat -d -s ReceiverApi:I 2> /dev/null | grep "applied snapshot" | tail -n 1 | sed -e 's/.*Result(//' -e 's/).*//' | tr -d '\r'; }
# expect_applied <text>: the Samsung must have counted the change that way, and the iPhone app must show Success.
expect_applied() {
  case "$(applied)" in
    "$1"*) ;;
    *) fail "the Samsung app counted \"$(applied)\", expected \"$1\"" ;;
  esac
  wait_prefs lastOutcome '^success$' 20 || fail "the iPhone app does not show Success: \"$(message)\""
}

# ---- the iPhone app, in the iOS Simulator (first: the build needs the whole Mac) ---------
pick_simulator || exit 1
build_for_simulator || exit 1
boot_and_install || exit 1

# ---- the Samsung app, in the Android emulator ------------------------------------------
booted() { [ "$(adb shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ]; }
if [ -n "${ANDROID_AVD:-}" ] && [ -z "$(adb devices | grep "device$")" ]; then
  # Let the freshly started iPhone simulator finish its own housekeeping first.
  mac_quiet() { [ "$(sysctl -n vm.loadavg | awk '{ print ($2 < 2.5) ? "yes" : "no" }')" = yes ]; }
  EVERY=10 wait_until 300 mac_quiet
  echo "Mac load before starting Android: $(sysctl -n vm.loadavg)" >> "$OUT/android-ui.log"
  T=$SECONDS
  nohup "${ANDROID_HOME:-$HOME/Library/Android/sdk}/emulator/emulator" -avd "$ANDROID_AVD" -no-window -no-audio \
    -no-boot-anim -gpu swiftshader_indirect -no-snapshot -no-metrics -cores 2 -memory 3072 > "$OUT/emulator.log" 2>&1 &
  STARTED_EMULATOR=yes
  if wait_until 1500 booted; then
    note "Android emulator: started in $((SECONDS - T)) s"
  else
    fail "the Android emulator did not start within 25 minutes"; tail -n 20 "$OUT/emulator.log"; exit 1
  fi
fi
adb wait-for-device
booted || { fail "the Android emulator has not finished starting"; exit 1; }
[ -f "$APK" ] || { fail "no APK at $APK"; exit 1; }
# A freshly started emulator can refuse installs for a while ("Broken pipe"): keep trying.
install_samsung_app() {
  local permission
  contacts_ready || return 1
  adb uninstall "$PKG" > /dev/null 2>&1
  adb install -r "$APK" > "$OUT/apk-install.log" 2>&1 || return 1
  for permission in READ_CONTACTS WRITE_CONTACTS POST_NOTIFICATIONS; do
    adb shell pm grant "$PKG" "android.permission.$permission" || return 1
  done
}
INSTALLED=no
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  if install_samsung_app; then INSTALLED=yes; break; fi
  echo "install attempt $attempt: $(tail -n 1 "$OUT/apk-install.log" 2> /dev/null)" >> "$OUT/android-ui.log"
  sleep 20
done
[ "$INSTALLED" = yes ] || { fail "could not install the Samsung app: $(tail -n 1 "$OUT/apk-install.log" 2> /dev/null)"; exit 1; }
android_calm
android_wake
# A just-started emulator is busy with itself for a while; wait until its screen can be read
# and it has quietened down, or the taps below land on a frozen screen.
EVERY=10 wait_until 600 screen_readable || fail "the Android screen cannot be read (the emulator is too slow?)"
EVERY=10 wait_until 600 android_quiet
echo "load before the checks: $(adb shell cat /proc/loadavg 2> /dev/null | tr -d '\r')" >> "$OUT/android-ui.log"
adb logcat -c
samsung_open
adb forward tcp:18765 tcp:8765 > /dev/null
node "$ROOT/tools/tcp-relay.js" 8765 127.0.0.1 18765 > "$OUT/relay.log" 2>&1 &
PIDS+=($!)
dns-sd -R "ContactSync Test" _contactsync._tcp local 8765 > /dev/null 2>&1 &
PIDS+=($!)
if ! wait_until 120 samsung_answers 8765; then
  fail "the Samsung app does not answer on its port"
  adb logcat -d > "$OUT/android-log.txt" 2>&1
  exit 1
fi
note "Samsung app: installed on an Android $(adb shell getprop ro.build.version.release | tr -d '\r') emulator and listening"
adb shell dumpsys power 2> /dev/null | grep -E "mWakefulness=" >> "$OUT/android-ui.log"
samsung_shot "$OUT/samsung-0-first-screen.png"
START_COUNT=$(synced)

if sudo -n ifconfig lo0 alias "$TS_IP" netmask 255.255.255.255 2> /dev/null; then
  ALIAS=yes
  if echo "$TS_IP $TS_NAME" | sudo -n tee -a /etc/hosts > /dev/null 2>&1; then
    HOSTS=yes
    sudo -n dscacheutil -flushcache 2> /dev/null; sudo -n killall -HUP mDNSResponder 2> /dev/null
  fi
fi

# ---- 1. pair over "Wi-Fi" by tapping both apps -----------------------------------------
rm -rf "$SHARED"; mkdir -p "$SHARED"; touch "$SHARED/wait-for-samsung"
ui_test testPairOverWiFiThenSync "$OUT/ui-pair.log" &
TEST=$!
SAMSUNG_NUMBER=
# Wait until the iPhone app lists the Samsung (or the test gave up).
listed_or_over() { [ -e "$SHARED/iphone-ready" ] || ! kill -0 "$TEST" 2> /dev/null; }
wait_until 900 listed_or_over
if [ -e "$SHARED/iphone-ready" ]; then
  tap_android tap "Pair iPhone" >> "$OUT/android-ui.log" 2>&1 || fail "could not tap \"Pair iPhone\" on the Samsung"
  touch "$SHARED/samsung-ready"
  SAMSUNG_NUMBER=$($TAP wait '^[0-9]{3} [0-9]{3}$' 120 2>> "$OUT/android-ui.log")
  samsung_shot "$OUT/samsung-1-same-number.png"
  tap_android tap-exact "Accept" >> "$OUT/android-ui.log" 2>&1 || fail "could not tap Accept on the Samsung"
else
  fail "the iPhone app never showed the Samsung on its pairing screen"
  touch "$SHARED/samsung-ready"
fi
wait "$TEST"; TEST_RESULT=$?
cp "$SHARED"/*.png "$OUT/" 2> /dev/null
IPHONE_NUMBER=$(cat "$SHARED/iphone-number" 2> /dev/null)
if [ -n "$SAMSUNG_NUMBER" ] && [ "$SAMSUNG_NUMBER" = "$IPHONE_NUMBER" ]; then
  note "1. Pairing: both apps showed the same number ($SAMSUNG_NUMBER)"
else
  fail "the pairing numbers differ or are missing: Samsung \"$SAMSUNG_NUMBER\", iPhone \"$IPHONE_NUMBER\""
fi
if [ "$TEST_RESULT" = 0 ]; then
  note "   Tapping through the iPhone app (find the Samsung, pair, first sync, \"Sync now\"): passed"
else
  fail "the iPhone tap-through reported problems:"; ui_problems "$OUT/ui-pair.log"
fi
$TAP tap-exact "OK" >> "$OUT/android-ui.log" 2>&1 # closes "Paired with …" on the Samsung
if [ "$FAILED" != 0 ]; then
  # Everything below needs the two apps to be paired.
  samsung_shot "$OUT/samsung-1-after-failed-pairing.png"
  $TAP texts > "$OUT/samsung-screen-after-failed-pairing.txt" 2>&1
  adb logcat -d > "$OUT/android-log.txt" 2>&1
  finish_simulator
  note "RESULT: the two apps could not be paired, so the other checks were not run"
  exit 1
fi

# ---- 2. the first sync: every iPhone contact is now in Android's contact list ----------
IPHONE_COUNT=$(fixture count | grep -oE '[0-9]+' | head -n 1)
IPHONE_COUNT=${IPHONE_COUNT:-0}
if [ "$IPHONE_COUNT" -gt 0 ] && EVERY=8 wait_until 90 synced_is "$IPHONE_COUNT"; then
  note "2. First sync: all $IPHONE_COUNT iPhone contacts are in Android's contact list"
else
  fail "the iPhone has $IPHONE_COUNT contacts, Android's contact list has $(synced) from it"
fi
phones > "$OUT/android-contacts-after-first-sync.txt"
has_name "Kate Bell" || fail "\"Kate Bell\" (an iPhone sample contact) is not in Android's contact list"
[ "$START_COUNT" = 0 ] || note "   (the emulator already held $START_COUNT synced contacts before this run)"

# ---- 3. add, edit and delete a contact on the iPhone -----------------------------------
UPLOADS=$(uploads)
fixture add Noa Katz +972501112233 > /dev/null || fail "the contacts helper could not add a contact"
if sent_after_change 120 && on_android has_phone "Noa Katz" "+972501112233"; then
  note "3. Added on the iPhone -> appeared on Android ($HOW)"
  expect_applied "added=1, updated=0, deleted=0"
else
  fail "a contact added on the iPhone did not reach Android"
fi

UPLOADS=$(uploads)
fixture edit Noa +972509998877 > /dev/null || fail "the contacts helper could not edit a contact"
if sent_after_change 120 && on_android has_phone "Noa Katz" "+972509998877"; then
  if has_phone "Noa Katz" "+972501112233"; then
    fail "the old phone number is still on Android after the edit"
  else
    note "4. Edited on the iPhone -> number changed on Android ($HOW)"
  fi
  expect_applied "added=0, updated=1, deleted=0"
else
  fail "an edit made on the iPhone did not reach Android"
fi

UPLOADS=$(uploads)
fixture delete Noa > /dev/null || fail "the contacts helper could not delete a contact"
if sent_after_change 120 && on_android no_name "Noa Katz" && synced_is "$IPHONE_COUNT"; then
  note "5. Deleted on the iPhone -> removed from Android ($HOW)"
  expect_applied "added=0, updated=0, deleted=1"
else
  fail "a contact deleted on the iPhone is still on Android"
fi

# ---- 6. nothing changed: no upload ------------------------------------------------------
launch
if wait_prefs lastMessage "^Up to date · $IPHONE_COUNT contacts" 40; then
  note "6. Nothing changed -> the iPhone only checks in (\"$(message)\")"
else
  fail "with nothing changed the iPhone app says \"$(message)\""
fi
shot iphone-6-up-to-date 2

# ---- 7. a large address book, with photos ------------------------------------------------
UPLOADS=$(uploads)
T=$SECONDS
ANSWER=$(fixture bulk "$BULK" 4) || fail "the contacts helper could not add $BULK contacts: $ANSWER"
T=$SECONDS
if sent_after_change 600 && on_android synced_is "$((IPHONE_COUNT + BULK))"; then
  note "7. $BULK more contacts ($ANSWER) -> all on Android $((SECONDS - T)) s later ($HOW); Android holds $(photos) photos"
  note "   The upload: $(grep "^PUT /v1/contacts -> 200" "$OUT/relay.log" | tail -n 1 | sed 's/.*, //')"
  expect_applied "added=$BULK, updated=0, deleted=0"
  [ "$(photos)" -gt 0 ] || fail "no contact photo arrived on Android"
else
  fail "after adding $BULK contacts on the iPhone, Android has $(synced) of $((IPHONE_COUNT + BULK)) (iPhone app: \"$(message)\")"
fi
samsung_top; samsung_shot "$OUT/samsung-7-large-address-book.png"
UPLOADS=$(uploads)
T=$SECONDS
fixture delete Bulk > /dev/null || fail "the contacts helper could not delete the $BULK contacts"
if sent_after_change 600 && on_android synced_is "$IPHONE_COUNT"; then
  note "   Deleted them again on the iPhone -> gone from Android $((SECONDS - T)) s later"
  expect_applied "added=0, updated=0, deleted=$BULK"
else
  fail "after deleting the $BULK contacts on the iPhone, Android still has $(synced)"
fi

# ---- 8. the Samsung app is not running: red on the iPhone, and green again afterwards ---
adb shell am force-stop "$PKG"
launch
if wait_prefs lastOutcome '^failed$' 60; then
  note "8. Samsung app stopped -> the iPhone shows Failed: \"$(message)\""
else
  fail "with the Samsung app stopped the iPhone app shows \"$(prefs lastOutcome)\": \"$(message)\""
fi
shot iphone-8-samsung-stopped 2
samsung_open
wait_until 60 samsung_answers 8765 || fail "the Samsung app did not start listening again"
launch
if wait_prefs lastOutcome '^success$' 60; then
  note "   Samsung app started again -> the iPhone is back to Success: \"$(message)\""
else
  fail "after the Samsung app came back the iPhone app still shows \"$(prefs lastOutcome)\": \"$(message)\""
fi

# ---- 9. unpair on the Samsung: its synced contacts go, and the iPhone is told to pair again
tap_android tap "Unpair and remove" >> "$OUT/android-ui.log" 2>&1 && $TAP wait '^Unpair\?$' 30 > /dev/null 2>&1 \
  && tap_android tap-exact "Unpair" >> "$OUT/android-ui.log" 2>&1 || fail "could not tap through Unpair on the Samsung"
if EVERY=10 wait_until 180 synced_is 0; then
  note "9. Unpaired on the Samsung -> the contacts that came from the iPhone were removed"
else
  fail "after unpairing, Android still has $(synced) synced contacts"
fi
launch
if wait_prefs lastOutcome '^failed$' 60; then
  note "   The iPhone now shows Failed: \"$(message)\""
else
  fail "after unpairing on the Samsung the iPhone app shows \"$(prefs lastOutcome)\": \"$(message)\""
fi
shot iphone-9-samsung-unpaired 2

# ---- 10. pair again by typing the Samsung's code, at its "Tailscale" address ------------
CODE=
tap_android tap "Pair manually" >> "$OUT/android-ui.log" 2>&1 && CODE=$($TAP wait '^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$' 30 2>> "$OUT/android-ui.log")
samsung_shot "$OUT/samsung-10-manual-code.png"
MANUAL_HOST=127.0.0.1
[ "$ALIAS" = yes ] && MANUAL_HOST=$TS_IP
if [ -n "$CODE" ]; then
  rm -f "$SHARED"/wait-for-samsung "$SHARED"/*-ready "$SHARED"/*.png
  echo "$CODE" > "$SHARED/manual-code"
  echo "$MANUAL_HOST" > "$SHARED/manual-host"
  if ui_test testPairWithCode "$OUT/ui-code.log"; then
    note "10. Typed the Samsung's code and the address $MANUAL_HOST into the iPhone app: paired and synced"
  else
    fail "pairing with the typed code reported problems:"; ui_problems "$OUT/ui-code.log"
  fi
  cp "$SHARED"/*.png "$OUT/" 2> /dev/null
  EVERY=8 wait_until 90 synced_is "$IPHONE_COUNT" || fail "after pairing with the code, Android has $(synced) of $IPHONE_COUNT contacts"
  wait_prefs lastGoodHost "^$MANUAL_HOST\$" 20 || fail "the iPhone app did not connect through $MANUAL_HOST but through \"$(prefs lastGoodHost)\""
else
  fail "the Samsung app did not show a manual pairing code"
fi

# ---- 11. the same Samsung reached by a Tailscale-style name ------------------------------
if [ "$HOSTS" = yes ] && [ -n "$CODE" ]; then
  launch -debugPairCode "$CODE" -debugPairHost "$TS_NAME"
  if wait_prefs lastGoodHost "^$TS_NAME\$" 60 && wait_prefs lastOutcome '^success$' 30; then
    note "11. Reached the Samsung by name ($TS_NAME): \"$(message)\""
  else
    fail "could not sync through the name $TS_NAME: \"$(message)\""
  fi
elif [ -n "$CODE" ]; then
  note "11. (skipped the Tailscale-style name: this Mac does not allow sudo without a password)"
fi

# ---- 12. in the background -------------------------------------------------------------
# First without "Keep running in background": iOS should pause the app, so no sync happens.
xcrun simctl location "$UDID" set 32.0853,34.7818 > /dev/null 2>&1 || note "(could not set a location on this simulator)"
launch -intervalMinutes 1
sleep 10
xcrun simctl launch "$UDID" com.apple.Preferences > /dev/null # the sync app is now in the background
sleep 150
PAUSED_AGE=$(prefs lastAttemptAt)

# Then with it on, set by tapping the app's own switch.
rm -f "$SHARED"/*.png
if ui_test testTurnOnBackgroundMode "$OUT/ui-background.log"; then
  note "12. Turned on \"Keep running in background\" and the 1-minute cycle by tapping the app"
else
  fail "turning on background mode reported problems:"; ui_problems "$OUT/ui-background.log"
fi
cp "$SHARED"/*.png "$OUT/" 2> /dev/null
if [ "$(cat "$SHARED/location-prompt" 2> /dev/null)" != allowed ]; then
  note "   (iOS did not ask about location during the taps; allowing it from outside the app instead)"
  xcrun simctl privacy "$UDID" grant location-always "$BUNDLE"
fi
launch
sleep 10
xcrun simctl launch "$UDID" com.apple.Preferences > /dev/null
sleep 150
AWAKE_AGE=$(prefs lastAttemptAt)
note "   App in the background for 150 s, 1-minute cycle: last sync attempt ${AWAKE_AGE:-?} s ago with background mode on, ${PAUSED_AGE:-?} s ago with it off"
if [ "${AWAKE_AGE:-999}" -lt 90 ]; then
  if [ "${PAUSED_AGE:-0}" -ge 90 ]; then
    note "   -> with background mode on the cycle kept running; without it iOS paused the app"
  else
    note "   -> the cycle kept running, but this simulator did not pause the app without background mode either, so this proves little"
  fi
else
  fail "with background mode on, the app did not sync while in the background"
fi
UPLOADS=$(uploads)
fixture add Background Bob +972500000001 > /dev/null || fail "the contacts helper could not add a contact"
if wait_until 60 more_uploads_than "$UPLOADS" && on_android has_phone "Background Bob" "+972500000001"; then
  note "   A contact added while the app was in the background reached Android without opening the app"
else
  fail "a contact added while the app was in the background did not reach Android within 60 s"
fi
activate
shot iphone-12-after-background 4

# ---- the Samsung app's own status, and logs ---------------------------------------------
samsung_open; sleep 2; samsung_top
samsung_shot "$OUT/samsung-13-status.png"
SCREEN=$($TAP texts 2> /dev/null)
if grep -q '^✓ Success$' <<< "$SCREEN"; then
  note "13. The Samsung app shows ✓ Success: $(echo "$SCREEN" | grep -A 1 '^✓ Success$' | tail -n 1)"
else
  fail "the Samsung app does not show Success at the end; it shows: $(echo "$SCREEN" | sed -n '5,10p' | tr '\n' '|')"
fi
adb logcat -d -s ReceiverApi ReceiverService ContactsWriter MiniHttpServer AndroidRuntime > "$OUT/android-log.txt" 2>&1
grep -q "Process: $PKG" "$OUT/android-log.txt" && fail "the Samsung app crashed (see android-log.txt)"
finish_simulator

[ "$FAILED" = 0 ] && note "RESULT: all checks with both real apps passed" || note "RESULT: some checks with both real apps failed"
exit "$FAILED"
