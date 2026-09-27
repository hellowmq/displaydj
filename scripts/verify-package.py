#!/usr/bin/env python3
"""Verify a packaged DisplayDJ ZIP against the exact local App build.

This is an offline consistency check, not a notarization or install test.
"""

import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import zipfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_PREFIX = "DisplayDJ.app/"
EXECUTABLES = ("DisplayDJBar", "display-cli", "displaydj")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(*args: str) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    require(result.returncode == 0, f"{' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def verify(archive: pathlib.Path, app: pathlib.Path, expected_version: str,
           allow_ad_hoc: bool) -> None:
    require(archive.is_file(), f"ZIP not found: {archive}")
    require(app.is_dir(), f"App not found: {app}")
    require(expected_version and "/" not in expected_version, "invalid expected version")

    cli = json.loads(run(str(app / "Contents/MacOS/display-cli"), "version", "--json"))
    require(cli.get("ok") is True, "display-cli version did not succeed")
    actual_version = cli["data"]["version"]
    architecture = cli["data"]["architecture"]
    require(actual_version == expected_version,
            f"display-cli version {actual_version} != {expected_version}")
    require(run(str(app / "Contents/MacOS/displaydj"), "--version") == expected_version,
            "compatibility CLI version differs")

    expected_name = f"displaydj-{expected_version}-macos-{architecture}.zip"
    require(archive.name == expected_name,
            f"ZIP filename {archive.name} != {expected_name}")

    local_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        require(local_info.get(key) == expected_version,
                f"App {key} {local_info.get(key)} != {expected_version}")
    require(local_info.get("CFBundleIdentifier") == "io.github.hellowmq.displaydj",
            "App bundle identifier differs")

    with zipfile.ZipFile(archive) as package:
        app_entries = [entry for entry in package.infolist()
                       if entry.filename.startswith(APP_PREFIX) and not entry.is_dir()]
        require(len(app_entries) == len({entry.filename for entry in app_entries}),
                "duplicate App entries in ZIP")
        members = {entry.filename: entry for entry in app_entries}
        require(f"{APP_PREFIX}Contents/Info.plist" in members, "ZIP has no App Info.plist")
        archived_info = plistlib.loads(package.read(f"{APP_PREFIX}Contents/Info.plist"))
        require(archived_info == local_info, "ZIP App Info.plist differs from local App")

        local_members = {APP_PREFIX + path.relative_to(app).as_posix(): path
                         for path in app.rglob("*") if path.is_file()}
        require(members.keys() == local_members.keys(),
                f"ZIP/App file lists differ; missing={sorted(local_members.keys() - members.keys())}, "
                f"extra={sorted(members.keys() - local_members.keys())}")
        for name, path in local_members.items():
            require(package.read(name) == path.read_bytes(), f"ZIP/App content differs: {name}")
        for executable in EXECUTABLES:
            require(f"{APP_PREFIX}Contents/MacOS/{executable}" in members,
                    f"ZIP is missing {executable}")

    sidecar = archive.with_name(archive.name + ".sha256")
    require(sidecar.is_file(), f"SHA-256 sidecar not found: {sidecar}")
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    require(sidecar.read_text().strip().split() == [digest, archive.name],
            "SHA-256 sidecar does not match ZIP bytes and filename")

    run("codesign", "--verify", "--deep", "--strict", str(app))
    details = subprocess.run(("codesign", "-dv", "--verbose=4", str(app)),
                             text=True, capture_output=True, check=False)
    require(details.returncode == 0, f"codesign metadata failed: {details.stderr.strip()}")
    signature = details.stderr + details.stdout
    is_ad_hoc = "Signature=adhoc" in signature
    require(allow_ad_hoc or not is_ad_hoc,
            "App is ad-hoc signed; use --allow-ad-hoc only for a preview build")
    require(is_ad_hoc or "Authority=Developer ID Application:" in signature,
            "App signature is not Developer ID Application")
    print(f"Verified {archive.name}: version {expected_version}, {architecture}, "
          f"SHA-256 {digest}, {'ad-hoc' if is_ad_hoc else 'Developer ID'} signed")
    print("Notarization, Gatekeeper, first launch, and upgrade are separate checks.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=pathlib.Path)
    parser.add_argument("--app", type=pathlib.Path, default=ROOT / ".build/DisplayDJ.app")
    parser.add_argument("--expect-version", required=True)
    parser.add_argument("--allow-ad-hoc", action="store_true")
    args = parser.parse_args()
    try:
        verify(args.archive.resolve(), args.app.resolve(), args.expect_version,
               args.allow_ad_hoc)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as error:
        print(f"Package verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
