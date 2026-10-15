#!/usr/bin/env python3
"""Build one product once and archive it as ZIP, DMG, or both. No upload or install."""
import argparse
import hashlib
import pathlib
import platform
import subprocess
import sys
import os

from product_config import PRODUCTS, ROOT, inspect_bundle, require


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--product', choices=PRODUCTS, default='full')
    parser.add_argument('--format', choices=('zip', 'dmg', 'all'), default='zip')
    parser.add_argument('--output-dir', type=pathlib.Path,
                        default=pathlib.Path(os.environ.get('DISPLAYDJ_OUTPUT_DIR', ROOT / 'outputs')))
    args = parser.parse_args()
    product = PRODUCTS[args.product]
    version = product.source_version()
    arch = platform.machine()
    formats = ('zip', 'dmg') if args.format == 'all' else (args.format,)
    output = args.output_dir.expanduser().resolve()
    artifacts = [output / f'{product.prefix}-{version}-macos-{arch}.{kind}' for kind in formats]
    # Refuse collisions before building or creating any output.
    for path in artifacts:
        for candidate in (path, path.with_name(path.name + '.sha256')):
            require(not candidate.exists(), f'Output already exists: {candidate}; choose a fresh output directory')
    subprocess.run(['bash', str(ROOT / 'scripts' / product.builder), '--release'], check=True, cwd=ROOT)
    app = ROOT / '.build' / product.bundle
    _, actual_arch, signature = inspect_bundle(app, product, version, allow_ad_hoc=True)
    require(actual_arch == arch, f'Built architecture {actual_arch} != package architecture {arch}')
    output.mkdir(parents=True, exist_ok=True)
    for path in artifacts:
        if path.suffix == '.zip':
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(path)], check=True)
        else:
            subprocess.run(['hdiutil', 'create', '-quiet', '-volname', f'{product.name} {version}',
                            '-srcfolder', str(app), '-format', 'UDZO', str(path)], check=True)
            subprocess.run(['hdiutil', 'verify', '-quiet', str(path)], check=True)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        with path.with_name(path.name + '.sha256').open('x') as stream:
            stream.write(f'{digest}  {path.name}\n')
        command = [sys.executable, str(ROOT / 'scripts/verify-package.py'), str(path),
                   '--product', args.product, '--app', str(app), '--expect-version', version]
        if signature == 'ad-hoc':
            command.append('--allow-ad-hoc')
        subprocess.run(command, check=True)
        print(f'Packaged: {path}', flush=True)
    print(f'{product.name} {version}: {signature} signed. Notarization, installation and hardware checks are separate.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f'Packaging failed: {error}', file=sys.stderr)
        sys.exit(1)
