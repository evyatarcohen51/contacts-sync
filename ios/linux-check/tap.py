#!/usr/bin/env python3
"""Drives the Android app on a connected device or emulator by visible text (needs adb).

    tap.py tap <text-prefix>     tap the first element whose text starts with the prefix
    tap.py texts                 list the texts on screen
"""
import os, subprocess, sys, tempfile, xml.etree.ElementTree as ET

tmp = os.path.join(tempfile.gettempdir(), 'contactsync-ui.xml')
subprocess.run(['adb', 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml'], capture_output=True, check=True)
subprocess.run(['adb', 'pull', '/sdcard/ui.xml', tmp], capture_output=True, check=True)
nodes = [n for n in ET.parse(tmp).iter('node') if n.get('text')]
if sys.argv[1] == 'texts':
    for n in nodes: print(n.get('text')[:90])
else:
    n = next((n for n in nodes if n.get('text').startswith(sys.argv[2])), None)
    if n is None: sys.exit('not on screen: ' + sys.argv[2])
    b = [int(v) for v in n.get('bounds').replace('][', ',').strip('[]').split(',')]
    subprocess.run(['adb', 'shell', 'input', 'tap', str((b[0] + b[2]) // 2), str((b[1] + b[3]) // 2)], check=True)
