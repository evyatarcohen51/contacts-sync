# Helpers for checking the Samsung app on a connected Android device or emulator
# (source it; do not run it). Needs adb on the PATH, and $ROOT pointing at the repository.

PKG=com.dvirchi.contactsync.receiver
TAP="python3 $ROOT/ios/linux-check/tap.py"

# How many contacts on the Android side came from the iPhone.
synced() {
  adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"deleted=0 AND sync2='contactsync'\"" 2> /dev/null | grep -c '^Row'
}
synced_is() { [ "$(synced)" = "$1" ]; }

# Every phone number in the Android contact list, as "display_name=<name>, data1=<number>".
phones() {
  adb shell "content query --uri content://com.android.contacts/data/phones --projection display_name:data1" 2> /dev/null | tr -d '\r'
}
# has_phone <name> <number>, has_name <name>, no_name <name>
# (grep -c, not grep -q: under `set -o pipefail` a grep that stops reading early makes the
# command before it fail, and the answer would wrongly be "no".)
has_phone() { [ "$(phones | grep -cF "display_name=$1, data1=$2")" != 0 ]; }
has_name() { [ "$(phones | grep -cF "display_name=$1, ")" != 0 ]; }
no_name() { adb shell true 2> /dev/null && ! has_name "$1"; }

# How many contact photos Android holds.
photos() {
  adb shell "content query --uri content://com.android.contacts/data --projection _id --where \"mimetype='vnd.android.cursor.item/photo'\"" 2> /dev/null | grep -c '^Row'
}

# Does the Samsung app answer on its port (through `adb forward tcp:18765 tcp:8765`)?
samsung_answers() { [ "$(curl -s -m 3 "http://127.0.0.1:${1:-18765}/v1/hello" | grep -c contactsync-receiver)" != 0 ]; }

# Android's contact storage only answers once the emulator has fully started.
contacts_ready() {
  local out
  out=$(adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id" 2>&1) || return 1
  ! grep -qE "Error|Exception" <<< "$out"
}
# Screen on and unlocked, and kept that way.
android_wake() {
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  adb shell svc power stayon true
}

# For a slow emulator: no animations. ("… isn't responding" dialogs stay on: with them hidden
# Android closes a slow app instead of waiting; the tap helper answers them with "Wait".)
android_calm() {
  local scale
  for scale in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb shell settings put global "$scale" 0
  done
  adb shell settings delete global hide_error_dialogs > /dev/null 2>&1
}
# Can the screen be read (the tap helper needs that)? Has the emulator quietened down?
screen_readable() { $TAP texts > /dev/null 2>&1; }
android_quiet() { [ "$(adb shell cat /proc/loadavg 2> /dev/null | awk '{ print ($1 < 1.5) ? "yes" : "no" }')" = yes ]; }
# tap_android <tap.py arguments…>: tap, trying again if the screen could not be read.
tap_android() {
  local try
  for try in 1 2 3; do
    $TAP "$@" && return 0
    sleep 5
  done
  return 1
}

samsung_open() { adb shell am start -n "$PKG/.MainActivity" > /dev/null 2>&1; }
samsung_top() { local i; for i in 1 2 3; do adb shell input swipe 540 700 540 1700 200; done; sleep 1; }
samsung_shot() { adb exec-out screencap -p > "$1" 2> /dev/null; }
