#!/usr/bin/env python3
"""Read-only bundle checks. Does not launch a live connection transaction."""
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
app = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else root / '.build/DisplayDJLite.app').resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
source = (root / 'Sources/DisplayDJLite/LiteConnectionService.swift').read_text()
identity = re.search(r'static let bundleID = "([^"]+)"', source).group(1)
version = re.search(r'static let version = "([^"]+)"', source).group(1)
assert info['CFBundleIdentifier'] == identity != 'io.github.hellowmq.displaydj'
assert info['CFBundleVersion'] == info['CFBundleShortVersionString'] == version
assert info['CFBundleExecutable'] == 'DisplayDJLite' and info['LSUIElement'] is True
assert info['CFBundleIconFile'] == 'DisplayDJLite.icns'
assert (app / 'Contents/Resources/DisplayDJLite.icns').stat().st_size > 0
executables = [p.name for p in (app / 'Contents/MacOS').iterdir() if p.is_file()]
assert executables == ['DisplayDJLite'], executables
assert (app / 'Contents/MacOS/DisplayDJLite').stat().st_mode & 0o111
for name in ['LICENSE', 'DisplayDJ-LICENSE.txt', 'VibeDisplay-LICENSE.txt']:
    assert (app / 'Contents/Resources' / name).is_file()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['plutil', '-lint', str(app / 'Contents/Info.plist')], check=True,
               stdout=subprocess.DEVNULL)
print(f'PASS Lite bundle identity, version {version}, executable, licenses and strict signature')
print('Read-only checks only; GUI and physical disconnect/reconnect are separate validation.')
