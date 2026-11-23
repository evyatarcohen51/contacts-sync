#!/bin/bash
# Compiles the iPhone app's own sources on Linux (Apple's frameworks replaced by the
# stand-ins in Stubs/) and runs the tests. Needs a Swift 6 toolchain: https://swift.org/install
#
#   ./run.sh                    protocol, export and URL tests
#   ./run.sh 127.0.0.1:18765    also pair and sync with a running Android receiver:
#                               connect the phone or emulator with adb, open the app on it,
#                               and run `adb forward tcp:18765 tcp:8765` first
set -euo pipefail
cd "$(dirname "$0")"

if [ $# -ge 1 ]; then
  export CONTACTSYNC_HOST="$1"
  export CONTACTSYNC_UI="$PWD/tap.py"
fi

swift build --build-tests
# The app stores its settings with UserDefaults; keep the test's copy out of your home folder.
HOME="$(mktemp -d)" swift test --skip-build
