#!/usr/bin/env python3
"""Compare a Full or Lite ZIP/DMG with the exact App used to build it, offline."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys
import zipfile

from product_config import PRODUCTS, ROOT, inspect_bundle, require, run


def files(app):
    paths = list(app.rglob('*'))
    require(not any(p.is_symlink() for p in paths), 'Unexpected symlink in product bundle')
    return {p.relative_to(app).as_posix(): p for p in paths if p.is_file()}


def compare_directory(archived, app):
    source, target = files(app), files(archived)
    require(source.keys() == target.keys(), 'DMG/App file lists differ')
    for name, path in source.items():
        require(target[name].read_bytes() == path.read_bytes(), f'DMG/App differs: {name}')
    run('codesign', '--verify', '--deep', '--strict', str(archived))


def verify(archive, app, expected_version, allow_ad_hoc, product_key='full'):
    product = PRODUCTS[product_key]
    require(archive.is_file(), f'Package not found: {archive}')
    require(bool(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?', expected_version)),
            'Expected version must be a semantic version')
    info, architecture, signature = inspect_bundle(app, product, expected_version, allow_ad_hoc)
    if product_key == 'full':
        cli = json.loads(run(str(app / 'Contents/MacOS/display-cli'), 'version', '--json'))
        require(cli.get('ok') is True and cli['data']['version'] == expected_version,
                'display-cli version differs')
        require(cli['data']['architecture'] == architecture, 'CLI architecture differs')
        require(run(str(app / 'Contents/MacOS/displaydj'), '--version') == expected_version,
                'Compatibility CLI version differs')
    require(archive.suffix in ('.zip', '.dmg'), 'Expected ZIP or DMG')
    expected_name = f'{product.prefix}-{expected_version}-macos-{architecture}{archive.suffix}'
    require(archive.name == expected_name, f'Package filename {archive.name} != {expected_name}')
    sidecar = archive.with_name(archive.name + '.sha256')
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    require(sidecar.is_file() and sidecar.read_text().strip().split() == [digest, archive.name],
            'SHA-256 sidecar differs or is missing')
    if archive.suffix == '.zip':
        prefix = product.bundle + '/'
        with zipfile.ZipFile(archive) as package:
            entries = package.infolist()
            require(all(e.filename.startswith((prefix, '__MACOSX/')) for e in entries),
                    'ZIP contains content outside the selected product')
            members = [e for e in entries if e.filename.startswith(prefix) and not e.is_dir()]
            names = {e.filename for e in members}
            require(len(names) == len(members), 'Duplicate App entries in ZIP')
            local = {prefix + name: path for name, path in files(app).items()}
            require(names == local.keys(), 'ZIP/App file lists differ')
            for name, path in local.items():
                require(package.read(name) == path.read_bytes(), f'ZIP/App differs: {name}')
            for executable in product.executables:
                entry = package.getinfo(prefix + 'Contents/MacOS/' + executable)
                require((entry.external_attr >> 16) & 0o111, f'ZIP executable permissions missing: {executable}')
            require(plistlib.loads(package.read(prefix + 'Contents/Info.plist')) == info,
                    'ZIP App plist differs')
    else:
        mounted = plistlib.loads(subprocess.check_output(
            ['hdiutil', 'attach', '-readonly', '-nobrowse', '-plist', str(archive)]))
        mounts = [pathlib.Path(e['mount-point']) for e in mounted.get('system-entities', []) if 'mount-point' in e]
        try:
            require(len(mounts) == 1, 'Expected one mounted volume')
            volume = mounts[0]
            require({p.name for p in volume.glob('*.app')} == {product.bundle}, 'DMG has wrong product set')
            compare_directory(volume / product.bundle, app)
            inspect_bundle(volume / product.bundle, product, expected_version, allow_ad_hoc)
        finally:
            for volume in mounts:
                subprocess.run(['hdiutil', 'detach', '-quiet', str(volume)], check=True)
    print(f'Verified {archive.name}: {product_key}, {architecture}, {signature}, SHA-256 {digest}')
    print('Notarization, Gatekeeper, first launch, upgrade and hardware use are separate checks.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=pathlib.Path)
    parser.add_argument('--product', choices=PRODUCTS, default='full')
    parser.add_argument('--app', type=pathlib.Path)
    parser.add_argument('--expect-version', required=True)
    parser.add_argument('--allow-ad-hoc', action='store_true')
    args = parser.parse_args()
    try:
        app = args.app or ROOT / '.build' / PRODUCTS[args.product].bundle
        verify(args.archive.resolve(), app.resolve(), args.expect_version, args.allow_ad_hoc, args.product)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f'Package verification failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
