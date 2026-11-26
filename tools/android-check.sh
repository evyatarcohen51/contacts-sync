#!/bin/bash
# Checks the Samsung app on a connected Android emulator or phone, with tools/fake-iphone.js
# standing in for the iPhone. It installs the APK afresh, pairs by tapping the app, syncs,
# changes contacts, sends a large address book, tries things the app must refuse, restarts
# the app and the phone, and unpairs. Screenshots and logs go to android/check-results/.
#
#   tools/android-check.sh [path/to/app.apk]
#
# Needs adb, node and python3. With several devices attached, set ANDROID_SERIAL.
# Meant for an emulator: it reinstalls the app (so its pairing is lost), removes the
# contacts the app synced before, and restarts the device (SKIP_REBOOT=1 leaves that out).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/android/check-results"
rm -rf "$OUT"; mkdir -p "$OUT"
[ -n "${ANDROID_HOME:-}" ] && export PATH="$ANDROID_HOME/platform-tools:$PATH"
source "$ROOT/tools/android-lib.sh"

APK="${1:-$ROOT/dist/ContactSyncReceiver.apk}"
AT=127.0.0.1:18765 # the app's port 8765, brought to this computer by `adb forward`
BULK=1000
FAILED=0
CODE=
LOCAL_ID=

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
booted() { [ "$(adb shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ]; }
# iphone <fake-iphone.js arguments…>: prints the stand-in iPhone's last line, e.g.
#   push: 200 {"added":3,"updated":0,"deleted":0,"total":3,"failed":0}  (3 contacts, 1 KB, 40 ms)
iphone() { node "$ROOT/tools/fake-iphone.js" "$@" 2>&1 | tee -a "$OUT/fake-iphone.log" | tail -n 1; }
# expect <what was done> <text the answer must contain> <the answer>
expect() {
  case "$3" in
    *"$2"*) return 0 ;;
    *) fail "$1: expected $2, got: $3"; return 1 ;;
  esac
}
# The contacts that came from the iPhone, as "_id, the iPhone's id, version" lines. Android
# raises a contact's version whenever it is written, so equal lines mean "not touched".
rows() {
  adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id:sourceid:version --where \"deleted=0 AND sync2='contactsync'\"" \
    | tr -d '\r' | sed -n 's/^Row: [0-9]* //p' | LC_ALL=C sort
}
# only_in_second <file> <file>: how many lines of the second file are not in the first.
only_in_second() { grep -Fxvc -f "$1" "$2"; }
in_both() { grep -Fxc -f "$1" "$2"; }
all_ids() {
  adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id" | tr -d '\r' | sed -n 's/.*_id=//p'
}

# ---- install -------------------------------------------------------------------------
[ -f "$APK" ] || { fail "no APK at $APK"; exit 1; }
adb wait-for-device
wait_until 600 booted || { fail "the Android device has not finished starting"; exit 1; }
SDK=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
install_app() {
  local permission
  contacts_ready || return 1
  adb uninstall "$PKG" > /dev/null 2>&1
  adb install -r "$APK" > "$OUT/apk-install.log" 2>&1 || return 1
  for permission in READ_CONTACTS WRITE_CONTACTS; do
    adb shell pm grant "$PKG" "android.permission.$permission" || return 1
  done
  # Android 13 and later ask before an app may show notifications.
  [ "$SDK" -lt 33 ] || adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS
}
INSTALLED=no
for attempt in 1 2 3 4 5 6; do
  if install_app; then INSTALLED=yes; break; fi
  sleep 15
done
[ "$INSTALLED" = yes ] || { fail "could not install the app: $(tail -n 1 "$OUT/apk-install.log" 2> /dev/null)"; exit 1; }
# Contacts left by an earlier run of this check.
adb shell "content delete --uri 'content://com.android.contacts/raw_contacts?caller_is_syncadapter=true' --where \"sync2='contactsync'\"" > /dev/null 2>&1
android_calm
android_wake
adb logcat -c
samsung_open
adb forward tcp:18765 tcp:8765 > /dev/null
if ! wait_until 90 samsung_answers; then
  fail "the app does not answer on its port"
  adb logcat -d > "$OUT/android-log.txt" 2>&1
  exit 1
fi
note "Samsung app: installed on Android $(adb shell getprop ro.build.version.release | tr -d '\r') (API $SDK, $(adb shell getprop ro.product.model | tr -d '\r')) and listening"

# A contact made on the Samsung itself. No sync and no unpairing may ever touch it.
BEFORE_IDS=$(all_ids)
adb shell "content insert --uri content://com.android.contacts/raw_contacts --bind starred:i:0" > /dev/null 2>&1
LOCAL_ID=$(all_ids | grep -Fxv -f <(echo "${BEFORE_IDS:-none}") | tail -n 1)
if [ -n "$LOCAL_ID" ]; then
  adb shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$LOCAL_ID --bind mimetype:s:vnd.android.cursor.item/name --bind data1:s:'Samsung Only'" > /dev/null 2>&1
  adb shell "content insert --uri content://com.android.contacts/data --bind raw_contact_id:i:$LOCAL_ID --bind mimetype:s:vnd.android.cursor.item/phone_v2 --bind data1:s:0501234567" > /dev/null 2>&1
fi
own_contact_intact() { has_phone "Samsung Only" 0501234567; }
own_contact_intact || { note "(could not create a contact of the Samsung's own to watch)"; LOCAL_ID=; }

# ---- 1. pair by tapping, comparing the number ------------------------------------------
tap_android tap "Pair iPhone" >> "$OUT/android-ui.log" 2>&1 || fail "could not tap \"Pair iPhone\""
node "$ROOT/tools/fake-iphone.js" pair "$AT" > "$OUT/pair.log" 2>&1 &
PAIR=$!
SAMSUNG_NUMBER=$($TAP wait '^[0-9]{3} [0-9]{3}$' 60 2>> "$OUT/android-ui.log" | tr -d ' ')
IPHONE_NUMBER=$(sed -n 's/^Confirm this number on the Samsung: //p' "$OUT/pair.log" | tr -d ' ')
samsung_shot "$OUT/1-same-number.png"
tap_android tap-exact "Accept" >> "$OUT/android-ui.log" 2>&1 || fail "could not tap Accept"
wait_until 30 grep -q "^Paired:" "$OUT/pair.log"
kill "$PAIR" 2> /dev/null; wait "$PAIR" 2> /dev/null
CODE=$(sed -n "s/.*code: '\([A-Z0-9-]*\)'.*/\1/p" "$OUT/pair.log" | head -n 1)
if [ -n "$CODE" ] && [ -n "$SAMSUNG_NUMBER" ] && [ "$SAMSUNG_NUMBER" = "$IPHONE_NUMBER" ]; then
  note "1. Paired by tapping; both sides showed the same number ($SAMSUNG_NUMBER)"
else
  fail "pairing: Samsung showed \"$SAMSUNG_NUMBER\", the iPhone side \"$IPHONE_NUMBER\", code \"${CODE:+received}\""
  cat "$OUT/pair.log" >> "$OUT/summary.txt"
  samsung_shot "$OUT/1-pairing-failed.png"
  adb logcat -d > "$OUT/android-log.txt" 2>&1
  note "RESULT: could not pair, so the other checks were not run"
  exit 1
fi
$TAP tap-exact "OK" >> "$OUT/android-ui.log" 2>&1 # closes "Paired with …"

# ---- 2. first sync, and the same list again ---------------------------------------------
ANSWER=$(iphone push "$AT" "$CODE" a)
expect "first sync" '"added":3,"updated":0' "$ANSWER" && expect "first sync" '"total":3,"failed":0' "$ANSWER"
if synced_is 3 && has_phone "Dana Levi" "+972 50-123-4567" && has_phone "Yossi Cohen" "+972 52-765-4321" && has_phone "Pizza Place" "*1234"; then
  note "2. First sync: the 3 contacts are in Android's contact list, with their numbers"
else
  fail "after the first sync Android holds $(synced) synced contacts: $(phones | tr '\n' '|')"
fi
rows > "$OUT/rows-1.txt"
ANSWER=$(iphone push "$AT" "$CODE" a)
expect "the same list again" '"added":0,"updated":0,"deleted":0' "$ANSWER"
rows > "$OUT/rows-2.txt"
if cmp -s "$OUT/rows-1.txt" "$OUT/rows-2.txt"; then
  note "   The same list sent again: nothing written, no duplicates"
else
  fail "sending the same list again changed contacts on Android"
fi

# ---- 3. one edited, one deleted, one added ----------------------------------------------
ANSWER=$(iphone push "$AT" "$CODE" b)
expect "edit + delete + add" '"added":1,"updated":1,"deleted":1,"total":3,"failed":0' "$ANSWER"
rows > "$OUT/rows-3.txt"
if has_name "Noa" && ! has_name "Yossi Cohen" && synced_is 3 \
   && [ "$(grep "sourceid=fake-3," "$OUT/rows-2.txt")" = "$(grep "sourceid=fake-3," "$OUT/rows-3.txt")" ] \
   && [ "$(grep "sourceid=fake-1," "$OUT/rows-2.txt")" != "$(grep "sourceid=fake-1," "$OUT/rows-3.txt")" ]; then
  note "3. One edited, one deleted, one added: exactly those changed; the unchanged contact was not touched"
else
  fail "after edit + delete + add Android holds: $(cat "$OUT/rows-3.txt" | tr '\n' '|')"
fi
samsung_top; samsung_shot "$OUT/3-after-changes.png"

# ---- the other place to save contacts: a separate "iPhone" account -------------------------
in_iphone_account() {
  adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"deleted=0 AND account_type='com.dvirchi.contactsync.account'\"" 2> /dev/null | grep -c '^Row'
}
tap_android tap "Separate" >> "$OUT/android-ui.log" 2>&1 || fail "could not choose the separate \"iPhone\" account"
wait_until 60 synced_is 0 || fail "switching where contacts are saved did not clear the synced contacts"
ANSWER=$(iphone push "$AT" "$CODE" b)
expect "a sync into the separate account" '"added":3,"updated":0,"deleted":0,"total":3,"failed":0' "$ANSWER"
IN_ACCOUNT=$(in_iphone_account)
samsung_shot "$OUT/3-separate-account.png"
tap_android tap "Phone storage" >> "$OUT/android-ui.log" 2>&1 || fail "could not choose phone storage again"
wait_until 60 synced_is 0 || fail "switching back to phone storage did not clear the synced contacts"
ANSWER=$(iphone push "$AT" "$CODE" b)
expect "a sync into phone storage again" '"added":3,"updated":0,"deleted":0,"total":3,"failed":0' "$ANSWER"
if [ "$IN_ACCOUNT" = 3 ] && [ "$(in_iphone_account)" = 0 ] && synced_is 3 && has_name "Noa"; then
  note "   Saving to a separate \"iPhone\" account and back to phone storage: the 3 contacts moved each time, no leftovers"
else
  fail "separate account: $IN_ACCOUNT contacts were in it (expected 3), $(in_iphone_account) are left in it (expected 0), $(synced) synced in all"
fi

# ---- 4. a large address book with photos, then one more contact --------------------------
T=$SECONDS
ANSWER=$(iphone push "$AT" "$CODE" "bulk:$BULK:8")
expect "$BULK contacts" "\"added\":$BULK,\"updated\":0,\"deleted\":3,\"total\":$BULK,\"failed\":0" "$ANSWER"
rows > "$OUT/rows-4.txt"
if synced_is "$BULK" && [ "$(photos)" -ge "$BULK" ]; then
  note "4. $BULK contacts with photos: all saved ($(echo "$ANSWER" | sed 's/.*(\(.*\))/\1/'))"
else
  fail "after sending $BULK contacts Android holds $(synced), with $(photos) photos"
fi
ANSWER=$(iphone push "$AT" "$CODE" "bulk:$((BULK + 1)):8")
expect "one more contact" '"added":1,"updated":0,"deleted":0' "$ANSWER"
rows > "$OUT/rows-5.txt"
NEW=$(only_in_second "$OUT/rows-4.txt" "$OUT/rows-5.txt")
KEPT=$(in_both "$OUT/rows-4.txt" "$OUT/rows-5.txt")
if [ "$NEW" = 1 ] && [ "$KEPT" = "$BULK" ]; then
  note "   One contact added to those $BULK: Android wrote 1 contact and left the other $KEPT untouched ($(echo "$ANSWER" | sed 's/.*, \([0-9]* ms\))/\1/'))"
else
  fail "after adding one contact to $BULK, Android wrote $NEW and left $KEPT untouched"
fi

# ---- 5. things the app must refuse -------------------------------------------------------
expect "an out-of-date list" "push: 409" "$(iphone push "$AT" "$CODE" a --stale)"
expect "an empty list" "push: 422" "$(iphone push "$AT" "$CODE" empty)"
expect "a wrong pairing code" "401" "$(iphone push "$AT" AAAA-AAAA-AAAA-AAAA a)"
if synced_is "$((BULK + 1))"; then
  note "5. Refused an out-of-date list, an empty list and a wrong pairing code; contacts unchanged"
else
  fail "after the refused uploads Android holds $(synced) contacts instead of $((BULK + 1))"
fi

# ---- 6. the app is killed, and the phone is restarted -------------------------------------
adb shell am force-stop "$PKG"
samsung_open
wait_until 60 samsung_answers || fail "the app did not listen again after being stopped"
ANSWER=$(iphone ping "$AT" "$CODE")
expect "after the app was stopped and opened" "\"count\":$((BULK + 1))" "$ANSWER" \
  && note "6. App stopped and opened again: still paired, still knows its $((BULK + 1)) contacts"
if [ -z "${SKIP_REBOOT:-}" ]; then
  T=$SECONDS
  adb reboot
  sleep 5
  adb wait-for-device
  wait_until 600 booted || fail "the device did not come back after a restart"
  adb forward tcp:18765 tcp:8765 > /dev/null
  # The app is not opened here: it has to start listening by itself.
  if wait_until 240 samsung_answers; then
    ANSWER=$(iphone push "$AT" "$CODE" "bulk:$BULK:8")
    expect "a sync after the restart" '"added":0,"updated":0,"deleted":1' "$ANSWER" \
      && note "   Device restarted: the app was listening again by itself after $((SECONDS - T)) s, and the next sync went through"
  else
    fail "after a restart of the device the app did not start listening by itself"
  fi
  android_wake
  samsung_open
  wait_until 60 screen_readable
fi

# ---- 7. the Samsung's own contact, and unpairing ------------------------------------------
if [ -n "$LOCAL_ID" ]; then
  own_contact_intact || fail "a contact made on the Samsung itself was changed or removed by the syncs"
fi
samsung_top; samsung_shot "$OUT/7-before-unpairing.png"
SCREEN=$($TAP texts 2> /dev/null)
grep -q '^✓ Success$' <<< "$SCREEN" || fail "the app does not show Success; it shows: $(echo "$SCREEN" | sed -n '5,10p' | tr '\n' '|')"
tap_android tap "Unpair and remove" >> "$OUT/android-ui.log" 2>&1 && $TAP wait '^Unpair\?$' 30 > /dev/null 2>&1 \
  && tap_android tap-exact "Unpair" >> "$OUT/android-ui.log" 2>&1 || fail "could not tap through Unpair"
if wait_until 120 synced_is 0; then
  if [ -z "$LOCAL_ID" ] || own_contact_intact; then
    OWN=
    [ -n "$LOCAL_ID" ] && OWN="; the contact made on the Samsung itself is still there"
    note "7. Unpaired: the synced contacts were removed$OWN"
  else
    fail "unpairing removed a contact made on the Samsung itself"
  fi
else
  fail "after unpairing Android still holds $(synced) synced contacts"
fi
expect "the old pairing code after unpairing" "401" "$(iphone push "$AT" "$CODE" a)"
samsung_top; samsung_shot "$OUT/7-unpaired.png"

# ---- logs --------------------------------------------------------------------------------
[ -n "$LOCAL_ID" ] && adb shell "content delete --uri 'content://com.android.contacts/raw_contacts?caller_is_syncadapter=true' --where \"_id=$LOCAL_ID\"" > /dev/null 2>&1
adb logcat -d -s ReceiverApi ReceiverService ContactsWriter MiniHttpServer AndroidRuntime > "$OUT/android-log.txt" 2>&1
grep -q "Process: $PKG" "$OUT/android-log.txt" && fail "the app crashed (see android-log.txt)"

[ "$FAILED" = 0 ] && note "RESULT: all checks of the Samsung app passed" || note "RESULT: some checks of the Samsung app failed"
exit "$FAILED"
