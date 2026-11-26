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
has_phone() { phones | grep -qF "display_name=$1, data1=$2"; }
has_name() { phones | grep -qF "display_name=$1, "; }
no_name() { adb shell true 2> /dev/null && ! has_name "$1"; }

# How many contact photos Android holds.
photos() {
  adb shell "content query --uri content://com.android.contacts/data --projection _id --where \"mimetype='vnd.android.cursor.item/photo'\"" 2> /dev/null | grep -c '^Row'
}

# Does the Samsung app answer on its port (through `adb forward tcp:18765 tcp:8765`)?
samsung_answers() { curl -s -m 3 "http://127.0.0.1:${1:-18765}/v1/hello" | grep -q contactsync-receiver; }

# Android's contact storage only answers once the emulator has fully started.
contacts_ready() {
  local out
  out=$(adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id" 2>&1) || return 1
  ! echo "$out" | grep -qE "Error|Exception"
}
# Screen on and unlocked, and kept that way.
android_wake() {
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  adb shell svc power stayon true
}

samsung_open() { adb shell am start -n "$PKG/.MainActivity" > /dev/null 2>&1; }
samsung_top() { local i; for i in 1 2 3; do adb shell input swipe 540 700 540 1700 200; done; sleep 1; }
samsung_shot() { adb exec-out screencap -p > "$1" 2> /dev/null; }
