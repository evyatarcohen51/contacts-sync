#!/bin/bash
# Runs the iPhone app in the iOS Simulator and checks that it really syncs:
# builds it, launches it, pairs it with tools/fake-samsung.js on this Mac, adds a contact,
# and saves screenshots plus logs to ios/ContactSyncSender/sim-results/.
#
# Needs macOS with Xcode, xcodegen (brew install xcodegen) and node.
set -uo pipefail
cd "$(dirname "$0")/ContactSyncSender"

OUT="$PWD/sim-results"
BUNDLE=com.dvirchi.contactsync.sender
CODE=TESTCODE23456789
rm -rf "$OUT"; mkdir -p "$OUT"
FAILED=0
note() { echo "$*" | tee -a "$OUT/summary.txt"; }
fail() { note "FAILED: $*"; FAILED=1; }

[ -d ContactSyncSender.xcodeproj ] || xcodegen generate

# ---- pick the newest iPhone simulator -------------------------------------------------
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
[ -n "${UDID:-}" ] || { fail "no iPhone simulator available"; exit 1; }
note "Simulator: $DEVICE ($RUNTIME)"
note "$(xcodebuild -version | tr '\n' ' ')"

# ---- build for the simulator ----------------------------------------------------------
if ! xcodebuild -project ContactSyncSender.xcodeproj -scheme ContactSyncSender -configuration Debug \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$PWD/build/sim" build \
      > "$OUT/sim-build.log" 2>&1; then
  fail "the simulator build did not compile"
  grep -nE "error:|fatal error" "$OUT/sim-build.log" | head -n 60 | tee -a "$OUT/summary.txt"
  exit 1
fi
APP="$PWD/build/sim/Build/Products/Debug-iphonesimulator/ContactSyncSender.app"
note "Simulator build: ok"

# ---- helpers --------------------------------------------------------------------------
shot() { sleep "$2"; xcrun simctl io "$UDID" screenshot "$OUT/$1.png" > /dev/null 2>&1 || note "(no screenshot $1)"; }
running() { xcrun simctl spawn "$UDID" launchctl list 2> /dev/null | grep -q "$BUNDLE"; }
launch() { xcrun simctl terminate "$UDID" "$BUNDLE" > /dev/null 2>&1; sleep 1; xcrun simctl launch "$UDID" "$BUNDLE" "$@" > /dev/null; }
uploads() { grep -c "upload:" "$OUT/fake-samsung.log" 2> /dev/null || true; }

xcrun simctl boot "$UDID" > /dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl install "$UDID" "$APP" || { fail "could not install the app"; exit 1; }
xcrun simctl privacy "$UDID" grant contacts "$BUNDLE" || note "(could not pre-grant Contacts access)"

# ---- 1. first launch, not paired ------------------------------------------------------
launch
shot 1-first-launch 8
if running; then note "1. First launch: app is running"; else fail "the app is not running after launch (crash?)"; fi

# ---- 2. pair with a stand-in Samsung on this Mac and sync ------------------------------
node ../../tools/fake-samsung.js --code "$CODE" --dump "$OUT/received.json" > "$OUT/fake-samsung.log" 2>&1 &
SAMSUNG=$!
sleep 1
launch -debugPairCode "$CODE" -debugPairHost 127.0.0.1
shot 2-paired-and-synced 10
if [ "$(uploads)" -ge 1 ]; then
  note "2. Paired and synced: $(grep "upload:" "$OUT/fake-samsung.log" | head -n 1 | sed 's/^[0-9:]* //')"
else
  fail "the app did not upload its contacts to the stand-in Samsung"
fi
running || fail "the app stopped running after pairing"

# ---- 3. a contact added on the iPhone is noticed and sent by itself --------------------
BEFORE=$(uploads)
cat > "$OUT/new-contact.vcf" <<'VCF'
BEGIN:VCARD
VERSION:3.0
N:לוי;דנה;;Dr.;
FN:Dr. דנה לוי
ORG:Acme;R&D
TITLE:CTO
TEL;type=CELL;type=VOICE;type=pref:+972 50-123-4567
item1.TEL:+972 52-765-4321
item1.X-ABLabel:Gym
EMAIL;type=INTERNET;type=WORK:dana@acme.example
item2.ADR;type=HOME:;;Herzl 1;Tel Aviv;;6100000;Israel
BDAY:1990-03-14
END:VCARD
VCF
if xcrun simctl addmedia "$UDID" "$OUT/new-contact.vcf" 2>> "$OUT/summary.txt"; then
  shot 3-after-adding-a-contact 12
  if [ "$(uploads)" -gt "$BEFORE" ]; then
    note "3. New contact picked up without touching the app: $(grep "upload:" "$OUT/fake-samsung.log" | tail -n 1 | sed 's/^[0-9:]* //')"
  else
    fail "a contact added on the iPhone was not sent within 12 seconds"
  fi
else
  note "3. (could not add a test contact to this simulator; skipped)"
fi

# ---- 4. Samsung unreachable: the app must say so, in red -------------------------------
kill "$SAMSUNG" 2> /dev/null; wait "$SAMSUNG" 2> /dev/null
launch
shot 4-samsung-unreachable 12
if running; then note "4. Samsung switched off: app still running (see screenshot for the red status)"; else fail "the app stopped running when the Samsung was unreachable"; fi

# ---- 5. tap through the app like a person: find the Samsung on the network, pair, sync --
# The stand-in Samsung waits a few seconds before "tapping Accept", and is announced over
# Bonjour under the name the real Samsung app uses.
node ../../tools/fake-samsung.js --code "$CODE" --pairing-open --auto-accept --accept-after 5 \
  --dump "$OUT/received-ui.json" > "$OUT/fake-samsung-ui.log" 2>&1 &
SAMSUNG=$!
dns-sd -R "ContactSync Test" _contactsync._tcp local 8765 > /dev/null 2>&1 &
BONJOUR=$!
sleep 2
rm -rf /tmp/contactsync-ui
if xcodebuild test -project ContactSyncSender.xcodeproj -scheme ContactSyncSender \
      -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$PWD/build/sim" \
      -only-testing:ContactSyncSenderUITests > "$OUT/ui-test.log" 2>&1; then
  note "5. Tapping through the app (find Samsung on the network, pair, sync, Sync now): passed"
else
  fail "the tap-through test reported problems:"
  grep -E "error:|XCTAssert|failed -" "$OUT/ui-test.log" | sed 's/^.*UITests.swift/  line/' | sort -u | head -n 20 | tee -a "$OUT/summary.txt"
fi
cp /tmp/contactsync-ui/*.png "$OUT/" 2> /dev/null || note "(the tap-through test left no screenshots)"
grep -E "pairing request|paired with|upload:" "$OUT/fake-samsung-ui.log" | sed 's/^[0-9:]* /   Samsung: /' | head -n 6 | tee -a "$OUT/summary.txt"
kill "$SAMSUNG" "$BONJOUR" 2> /dev/null; wait "$SAMSUNG" "$BONJOUR" 2> /dev/null

# ---- logs -----------------------------------------------------------------------------
xcrun simctl spawn "$UDID" log show --last 5m --style compact --predicate "process == \"ContactSyncSender\"" 2> /dev/null \
  | tail -n 300 > "$OUT/app-log.txt" || true
cp ~/Library/Logs/DiagnosticReports/ContactSyncSender* "$OUT/" 2> /dev/null && fail "the app left a crash report"
xcrun simctl shutdown "$UDID" > /dev/null 2>&1 || true

[ "$FAILED" = 0 ] && note "RESULT: all simulator checks passed" || note "RESULT: some simulator checks failed"
exit "$FAILED"
