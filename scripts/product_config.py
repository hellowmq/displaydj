"""Product identity and offline bundle contract shared by the packaging tools."""
from dataclasses import dataclass
import pathlib
import plistlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    require(result.returncode == 0, f"{args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


@dataclass(frozen=True)
class Product:
    name: str
    bundle: str
    bundle_id: str
    executables: tuple[str, ...]
    prefix: str
    icon: str
    builder: str
    version_file: str
    version_pattern: str

    def source_version(self):
        match = re.search(self.version_pattern, (ROOT / self.version_file).read_text())
        require(match is not None, f"Cannot read {self.name} source version")
        return match.group(1)


PRODUCTS = {
    'full': Product('DisplayDJ', 'DisplayDJ.app', 'io.github.hellowmq.displaydj',
                    ('DisplayDJBar', 'display-cli', 'displaydj'), 'displaydj', 'DisplayDJ.icns',
                    'build-app.sh', 'Sources/VibeDisplayCore/Support/Version.swift',
                    r'static let current = "([^"]+)"'),
    'lite': Product('DisplayDJ Lite', 'DisplayDJLite.app', 'io.github.hellowmq.displaydj.lite',
                    ('DisplayDJLite',), 'displaydj-lite', 'DisplayDJLite.icns',
                    'build-lite-app.sh', 'Sources/DisplayDJLite/LiteConnectionService.swift',
                    r'static let version = "([^"]+)"'),
}


def inspect_bundle(app, product, version, allow_ad_hoc):
    require(app.is_dir(), f"App not found: {app}")
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == product.bundle_id, 'Wrong product bundle identifier')
    require(info.get('CFBundleExecutable') == product.executables[0], 'Wrong App executable')
    for key in ('CFBundleVersion', 'CFBundleShortVersionString'):
        require(info.get(key) == version, f'{key} differs from expected version {version}')
    executable_dir = app / 'Contents/MacOS'
    require({p.name for p in executable_dir.iterdir()} == set(product.executables),
            'App executable set differs from product contract')
    architectures = set()
    for name in product.executables:
        path = executable_dir / name
        require(path.is_file() and path.stat().st_mode & 0o111, f'Not executable: {name}')
        arches = run('lipo', '-archs', str(path)).split()
        require(len(arches) == 1, 'Only single-architecture packages are currently supported')
        architectures.update(arches)
    require(len(architectures) == 1, 'App executables have different architectures')
    require(info.get('CFBundleIconFile') == product.icon, 'Wrong or missing App icon declaration')
    resources = app / 'Contents/Resources'
    required = ['LICENSE', 'DisplayDJ-LICENSE.txt', 'VibeDisplay-LICENSE.txt', product.icon]
    if len(product.executables) > 1:
        required.append('MediaKeyTap-LICENSE.txt')
    for name in required:
        require((resources / name).is_file() and (resources / name).stat().st_size > 0,
                f'Missing resource: {name}')
    run('codesign', '--verify', '--deep', '--strict', str(app))
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(app)],
                               text=True, capture_output=True, check=True)
    details = signature.stdout + signature.stderr
    ad_hoc = 'Signature=adhoc' in details
    require(allow_ad_hoc or not ad_hoc, 'Ad-hoc package requires explicit --allow-ad-hoc')
    require(ad_hoc or 'Authority=Developer ID Application:' in details, 'Unsupported signature type')
    return info, architectures.pop(), 'ad-hoc' if ad_hoc else 'Developer ID'
