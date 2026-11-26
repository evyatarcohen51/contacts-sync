# Shared by simulator-check.sh and both-apps-check.sh (source it; do not run it).
# Expects the current folder to be ios/ContactSyncSender and $OUT to be the results folder.

BUNDLE=com.dvirchi.contactsync.sender
FIXTURE=com.dvirchi.contactsync.fixture
SHARED=/tmp/contactsync-ui   # notes passed between these scripts and the tap-through tests
FAILED=0

note() { echo "$*" | tee -a "$OUT/summary.txt"; }
fail() { note "FAILED: $*"; FAILED=1; }

# wait_until <seconds> <command...>: run the command every 2 s until it succeeds.
wait_until() {
  local deadline=$((SECONDS + $1)); shift
  until "$@" > /dev/null 2>&1; do
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 2
  done
}

# Picks the newest iPhone simulator: sets UDID, DEVICE and RUNTIME.
pick_simulator() {
  read -r UDID DEVICE RUNTIME < <(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
best = None
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone") and "SE" not in d["name"]:
            key = (version, "Pro" not in d["name"], d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"].replace(" ", "_"), "iOS_%d.%d" % version)
print(*best[1:]) if best else sys.exit("no iPhone simulator found")
')
  [ -n "${UDID:-}" ] || { fail "no iPhone simulator available"; return 1; }
  note "Simulator: $DEVICE ($RUNTIME), $(xcodebuild -version | tr '\n' ' ')"
}

# Builds the app, its tap-through tests and the contacts helper for the simulator.
build_for_simulator() {
  command -v xcodegen > /dev/null && xcodegen generate > /dev/null
  local scheme action
  for scheme in ContactSyncSender ContactsFixture; do
    action=build
    [ "$scheme" = ContactSyncSender ] && action=build-for-testing
    if ! xcodebuild -project ContactSyncSender.xcodeproj -scheme "$scheme" -configuration Debug \
          -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$PWD/build/sim" "$action" \
          >> "$OUT/sim-build.log" 2>&1; then
      fail "the simulator build of $scheme did not compile"
      grep -nE "error:|fatal error" "$OUT/sim-build.log" | head -n 60 | tee -a "$OUT/summary.txt"
      return 1
    fi
  done
  note "Simulator build: ok"
}

# Starts the simulator and installs both apps with access to Contacts.
boot_and_install() {
  local products="$PWD/build/sim/Build/Products/Debug-iphonesimulator"
  xcrun simctl boot "$UDID" > /dev/null 2>&1 || true
  xcrun simctl bootstatus "$UDID" -b > /dev/null
  xcrun simctl install "$UDID" "$products/ContactSyncSender.app" || { fail "could not install the app"; return 1; }
  xcrun simctl install "$UDID" "$products/ContactsFixture.app" || { fail "could not install the contacts helper"; return 1; }
  xcrun simctl privacy "$UDID" grant contacts "$BUNDLE" || note "(could not pre-grant Contacts access)"
  xcrun simctl privacy "$UDID" grant contacts "$FIXTURE" || note "(could not pre-grant Contacts access to the helper)"
  mkdir -p "$SHARED"
}

# shot <name> <seconds to wait first>
shot() { sleep "$2"; xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || note "(no screenshot $1)"; }
running() { [ "$(xcrun simctl spawn "$UDID" launchctl list 2> /dev/null | grep -c "$BUNDLE")" != 0 ]; }
# launch [arguments]: restart the app.   activate: bring it to the front, as when a person opens it.
launch() { xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1; sleep 1; xcrun simctl launch "$UDID" "$BUNDLE" "$@" > /dev/null; }
activate() { xcrun simctl launch "$UDID" "$BUNDLE" > /dev/null; }

# prefs <key>: what the app last saved under this key (lastOutcome, lastMessage, lastGoodHost…).
# A saved time is printed as its age in seconds.
prefs() {
  python3 -c '
import datetime, plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        saved = plistlib.load(f)
except Exception:
    saved = {}
value = saved.get(sys.argv[2], "")
if isinstance(value, datetime.datetime):
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    value = int((now - value).total_seconds())
print(value)' "$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2> /dev/null)/Library/Preferences/$BUNDLE.plist" "$1"
}
prefs_match() { [ "$(prefs "$1" | grep -Ec "$2")" != 0 ]; }
# wait_prefs <key> <regex> <seconds>
wait_prefs() { wait_until "$3" prefs_match "$1" "$2"; }

# fixture <command…>: change the simulator's contacts with the helper app (see Fixture/main.swift).
# Prints the helper's answer. Opening the helper puts the sync app in the background.
fixture() {
  local answer="$SHARED/fixture-answer"
  rm -f "$answer"
  xcrun simctl launch "$UDID" "$FIXTURE" "$@" -out "$answer" > /dev/null 2>&1
  wait_until 300 test -s "$answer"
  cat "$answer" 2> /dev/null || echo "error no answer from the contacts helper"
  grep -q '^ok ' "$answer" 2> /dev/null
}

# ui_test <test name> <log file>: run one tap-through test from UITests/ContactSyncUITests.swift.
ui_test() {
  xcodebuild test-without-building -project ContactSyncSender.xcodeproj -scheme ContactSyncSender \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$PWD/build/sim" \
      -only-testing:"ContactSyncSenderUITests/ContactSyncUITests/$1" > "$2" 2>&1
}
# ui_problems <log file>: the failed checks of a tap-through test, shortened.
ui_problems() {
  grep -E "error:|XCTAssert|failed -" "$1" | sed 's/^.*UITests.swift/  line/' | sort -u | head -n 20 | tee -a "$OUT/summary.txt"
}

# Saves the app's log and reports a crash, then shuts the simulator down.
finish_simulator() {
  xcrun simctl spawn "$UDID" log show --last 10m --style compact --predicate "process == \"ContactSyncSender\"" 2> /dev/null \
    | tail -n 400 > "$OUT/app-log.txt" || true
  cp ~/Library/Logs/DiagnosticReports/ContactSyncSender* "$OUT/" 2> /dev/null && fail "the app left a crash report"
  xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true
}
