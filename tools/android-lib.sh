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

# android_fields: every text field of the synced contacts as "<iPhone id> :: <kind> :: <value>"
# lines; `fake-iphone.js fields <variant>` prints the same lines for what was sent.
android_field() { # <kind> <mimetype> <column>
  adb shell "content query --uri content://com.android.contacts/data --projection sourceid:$3 --where \"sync2='contactsync' AND mimetype='vnd.android.cursor.item/$2' AND $3 IS NOT NULL\"" 2> /dev/null \
    | tr -d '\r' | sed -n "s/^Row: [0-9]* sourceid=\([^,]*\), $3=\(.*\)$/\1 :: $1 :: \2/p"
}
android_fields() {
  android_field givenName name data2; android_field familyName name data3
  android_field namePrefix name data4; android_field middleName name data5; android_field nameSuffix name data6
  android_field phoneticGivenName name data7; android_field phoneticFamilyName name data9
  android_field nickname nickname data1
  android_field organization organization data1; android_field jobTitle organization data4
  android_field department organization data5
  android_field phone phone_v2 data1; android_field phoneLabel phone_v2 data3
  android_field email email_v2 data1; android_field url website data1
  android_field street postal-address_v2 data4; android_field city postal-address_v2 data7
  android_field country postal-address_v2 data10
}

# Does the Samsung app answer on its port (through `adb forward tcp:18765 tcp:8765`)?
samsung_answers() { [ "$(curl -s -m 3 "http://127.0.0.1:${1:-18765}/v1/hello" | grep -c contactsync-receiver)" != 0 ]; }

# Is a device or emulator attached at all? (`adb wait-for-device` would wait for ever.)
device_attached() { [ "$(adb get-state 2> /dev/null | tr -d '\r')" = device ]; }

# Android's contact storage only answers once the emulator has fully started.
contacts_ready() {
  local out
  out=$(adb shell "content query --uri content://com.android.contacts/raw_contacts --projection _id" 2>&1) || return 1
  ! grep -qE "Error|Exception" <<< "$out"
}
# samsung_install <apk> <log file>: install the app afresh and allow it what it asks for.
samsung_install() {
  local permission sdk
  contacts_ready || return 1
  # A just-started Android still has start-up messages queued for a copy of the app that is
  # already installed; replacing the app underneath them logs a crash that is not the app's.
  if [ "$(adb shell pm list packages "$PKG" 2> /dev/null | grep -c "$PKG")" != 0 ]; then
    while [ "$(adb shell cat /proc/uptime 2> /dev/null | cut -d. -f1)" -lt 120 ] 2> /dev/null; do sleep 5; done
  fi
  adb uninstall "$PKG" > /dev/null 2>&1
  adb install -r "$1" > "$2" 2>&1 || return 1
  for permission in READ_CONTACTS WRITE_CONTACTS; do
    adb shell pm grant "$PKG" "android.permission.$permission" >> "$2" 2>&1 || return 1
  done
  # Only Android 13 and later ask before an app may show notifications; older versions
  # refuse the grant itself, because they do not know that permission.
  sdk=$(adb shell getprop ro.build.version.sdk 2> /dev/null | tr -d '\r')
  [ "${sdk:-0}" -lt 33 ] || adb shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >> "$2" 2>&1
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
