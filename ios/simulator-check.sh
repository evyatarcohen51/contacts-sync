#!/bin/bash
# Runs the iPhone app in the iOS Simulator and checks that it really syncs:
# builds it, launches it, pairs it with tools/fake-samsung.js on this Mac, adds a contact,
# and saves screenshots plus logs to ios/ContactSyncSender/sim-results/.
#
# Needs macOS with Xcode, xcodegen (brew install xcodegen) and node.
# ios/both-apps-check.sh goes further: it uses the real Samsung app in an Android emulator.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/ios/ContactSyncSender"
OUT="$PWD/sim-results"
rm -rf "$OUT"; mkdir -p "$OUT"
source "$ROOT/ios/sim-lib.sh"

CODE=TESTCODE23456789
uploads() { grep -c "upload:" "$OUT/fake-samsung.log" 2> /dev/null || true; }

pick_simulator || exit 1
build_for_simulator || exit 1
boot_and_install || exit 1

# ---- 1. first launch, not paired ------------------------------------------------------
launch
shot 1-first-launch 8
if running; then note "1. First launch: app is running"; else fail "the app is not running after launch (crash?)"; fi

# ---- 2. pair with a stand-in Samsung on this Mac and sync ------------------------------
node "$ROOT/tools/fake-samsung.js" --code "$CODE" --dump "$OUT/received.json" > "$OUT/fake-samsung.log" 2>&1 &
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
node "$ROOT/tools/fake-samsung.js" --code "$CODE" --pairing-open --auto-accept --accept-after 5 \
  --dump "$OUT/received-ui.json" > "$OUT/fake-samsung-ui.log" 2>&1 &
SAMSUNG=$!
dns-sd -R "ContactSync Test" _contactsync._tcp local 8765 > /dev/null 2>&1 &
BONJOUR=$!
sleep 2
rm -rf "$SHARED"; mkdir -p "$SHARED"
if ui_test testPairOverWiFiThenSync "$OUT/ui-test.log"; then
  note "5. Tapping through the app (find Samsung on the network, pair, sync, Sync now): passed"
else
  fail "the tap-through test reported problems:"
  ui_problems "$OUT/ui-test.log"
fi
cp "$SHARED"/*.png "$OUT/" 2> /dev/null || note "(the tap-through test left no screenshots)"
grep -E "pairing request|paired with|upload:" "$OUT/fake-samsung-ui.log" | sed 's/^[0-9:]* /   Samsung: /' | head -n 6 | tee -a "$OUT/summary.txt"
kill "$SAMSUNG" "$BONJOUR" 2> /dev/null; wait "$SAMSUNG" "$BONJOUR" 2> /dev/null

finish_simulator

[ "$FAILED" = 0 ] && note "RESULT: all simulator checks passed" || note "RESULT: some simulator checks failed"
exit "$FAILED"
