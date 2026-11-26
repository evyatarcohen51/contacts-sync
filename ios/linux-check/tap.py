#!/usr/bin/env python3
"""Drives the Android app on a connected device or emulator by visible text (needs adb).

    tap.py tap <text-prefix>          tap the first element whose text starts with the prefix,
                                      scrolling the screen to find it
    tap.py tap-exact <text>           the same, for an element with exactly this text
    tap.py texts                      list the texts on screen
    tap.py find <regex>               print the first on-screen text that matches; fails if none does
    tap.py wait <regex> [seconds]     the same, but keep looking for a while (default 30 s)
"""
import os, re, subprocess, sys, tempfile, time, xml.etree.ElementTree as ET

ADB = os.environ.get('ADB', 'adb')
TMP = os.path.join(tempfile.gettempdir(), 'contactsync-ui.xml')


def centre(node):
    b = [int(v) for v in node.get('bounds').replace('][', ',').strip('[]').split(',')]
    return str((b[0] + b[2]) // 2), str((b[1] + b[3]) // 2)


def nodes():
    """Elements on screen that carry text. Retries: the dump fails while the screen is animating."""
    for _ in range(8):
        dump = subprocess.run([ADB, 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml'], capture_output=True)
        pull = subprocess.run([ADB, 'pull', '/sdcard/ui.xml', TMP], capture_output=True)
        if dump.returncode == 0 and pull.returncode == 0:
            try:
                found = [n for n in ET.parse(TMP).iter('node') if n.get('text')]
            except ET.ParseError:
                found = None
            if found is not None:
                # A slow emulator shows "… isn't responding" over the app: choose "Wait" and look again.
                wait = next((n for n in found if n.get('text') == 'Wait'), None)
                if wait is not None and any("isn't responding" in n.get('text') for n in found):
                    subprocess.run([ADB, 'shell', 'input', 'tap', *centre(wait)])
                    time.sleep(2)
                    continue
                return found
        time.sleep(1)
    sys.exit('could not read the Android screen')


def swipe(up):
    """up=True moves the page up, showing what is further down."""
    y1, y2 = (1700, 700) if up else (700, 1700)
    subprocess.run([ADB, 'shell', 'input', 'swipe', '540', str(y1), '540', str(y2), '300'], check=True)
    time.sleep(1)


def tap(wanted, exact=False):
    # Look where we are, then further down, then back at the top.
    for move in [None, True, True, True, False, False, False, False]:
        if move is not None:
            swipe(move)
        n = next((n for n in nodes()
                  if (n.get('text') == wanted if exact else n.get('text').startswith(wanted))), None)
        if n is not None:
            subprocess.run([ADB, 'shell', 'input', 'tap', *centre(n)], check=True)
            return
    sys.exit('not on screen: ' + wanted)


def find(pattern):
    return next((n.get('text') for n in nodes() if re.search(pattern, n.get('text'))), None)


command = sys.argv[1] if len(sys.argv) > 1 else ''
if command == 'texts':
    for n in nodes():
        print(n.get('text')[:90])
elif command in ('tap', 'tap-exact') and len(sys.argv) == 3:
    tap(sys.argv[2], exact=command == 'tap-exact')
elif command in ('find', 'wait') and len(sys.argv) >= 3:
    deadline = time.time() + (float(sys.argv[3]) if command == 'wait' and len(sys.argv) > 3 else 30 if command == 'wait' else 0)
    while True:
        text = find(sys.argv[2])
        if text is not None:
            print(text)
            break
        if time.time() >= deadline:
            sys.exit('not on screen: ' + sys.argv[2])
        time.sleep(float(os.environ.get('TAP_EVERY', '1')))  # reading the screen is work for a slow emulator
else:
    sys.exit(__doc__)
