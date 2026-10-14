#!/usr/bin/env python3
"""Notarize the staged build; --submit authorizes Apple upload."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
TEAM = "F57QJC4XU3"
REQUIREMENT = ('=identifier "local.unarchiver" and anchor apple generic and '
               'certificate 1[field.1.2.840.113635.100.6.2.6] exists and '
               'certificate leaf[field.1.2.840.113635.100.6.1.13] exists and '
               f'certificate leaf[subject.OU] = "{TEAM}"')
PROFILE = "notary"
MACHO = {bytes.fromhex(value) for value in
         ("feedface", "feedfacf", "cefaedfe", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}


def run(label, *command):
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if result.returncode:
        raise RuntimeError(f"{label} failed (exit {result.returncode}); private command output withheld")
    return result.stdout


def add_notices(app, version):
    notices = app / "Contents/Resources/ThirdPartyLicenses"
    notices.mkdir()
    shutil.copy2(ROOT / ".build/artifacts/sparkle/Sparkle/LICENSE", notices / "Sparkle-LICENSE")
    for name in ("XADMaster", "UniversalDetector"):
        shutil.copy2(ROOT / "Vendor" / name / "LICENSE", notices / f"{name}-LICENSE")
    (notices / "SOURCE-NOTICES.txt").write_text(
        "Dynamically linked XADMaster and UniversalDetector: LGPL 2.1.\n"
        f"Matching sources and rebuild instructions: https://github.com/ngzhenghui94/unarchiver/releases/tag/v{version}\n"
        f"Asset: Archiver-{version}-archive-sources.tar.gz\n"
        "Recipients may replace/rebuild these libraries and re-sign their local app.\n"
        "Authored app source is not included in this binary distribution.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--submit", action="store_true", help="Sign and upload only Archiver to Apple using Keychain profile notary")
    args = parser.parse_args()
    source = ROOT / "build/staging/Archiver.app"
    with (source / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "local.unarchiver":
        raise RuntimeError("Unexpected source app identity")
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+(?:\.\d+)*", version):
        raise RuntimeError("Invalid release version")
    identities = run("Signing identity lookup", "/usr/bin/security", "find-identity", "-v", "-p", "codesigning")
    matches = re.findall(r'\b([0-9A-Fa-f]{40})\s+"Developer ID Application: [^"\n]+ \(' + TEAM + r'\)"', identities)
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one valid Developer ID Application identity for the release team")
    print(f"Plan: copy Archiver {version}, add dependency notices, sign nested code, and upload to Apple.", flush=True)
    print(f"Keychain profile: {PROFILE}; existing build and installed apps remain unchanged.", flush=True)
    if not args.submit:
        print("Preview only. Pass --submit to authorize signing and Apple notarization.")
        return
    output = ROOT / "build/releases" / version
    output.mkdir(parents=True, exist_ok=False)
    app = output / "Archiver.app"
    run("Copy app", "/usr/bin/ditto", str(source), str(app))
    add_notices(app, version)
    binaries = []
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO:
                    binaries.append(path)
    if not binaries:
        raise RuntimeError("No Mach-O code found in app")
    bundles = [path for path in app.rglob("*")
               if path.is_dir() and not path.is_symlink()
               and path.suffix in (".framework", ".xpc", ".app")]
    # Seal each nested bundle only after its own code and child bundles.
    for path in sorted(binaries + bundles, key=lambda path: len(path.parts), reverse=True):
        run("Sign nested code", "/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime", "--preserve-metadata=entitlements", "--sign", matches[0], str(path))
    run("Sign app", "/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime", "--preserve-metadata=entitlements", "--sign", matches[0], str(app))
    run("Verify signatures", "/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    run("Stable signing requirement", "/usr/bin/codesign", "--verify", "-R", REQUIREMENT, str(app))
    print(f"Signed and verified {len(binaries)} Mach-O files.", flush=True)
    print(run("Native signed-app checks", str(app / "Contents/MacOS/Archiver"), "--selftest"), end="", flush=True)
    archive = output / "notarization.zip"
    run("Archive app", "/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
    record = output / "notarization.json"
    record.write_text(json.dumps({"version": version, "status": "Submitting"}) + "\n")
    print("Submitting Archiver to Apple; waiting for notarization.", flush=True)
    result = subprocess.run(["/usr/bin/xcrun", "notarytool", "submit", str(archive), "--keychain-profile", PROFILE, "--wait", "--output-format", "json"], capture_output=True, text=True)
    try:
        response = json.loads(result.stdout)
    except ValueError:
        raise RuntimeError("Unknown notarization result. Inspect Apple submission history; do not blindly resubmit.") from None
    status = response.get("status")
    identifier = response.get("id")
    if not isinstance(identifier, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", identifier):
        raise RuntimeError("Missing submission ID. Inspect Apple submission history; do not blindly resubmit.")
    record.write_text(json.dumps({"version": version, "id": identifier, "status": status}, indent=2) + "\n")
    print(f"Apple submission {identifier}: {status}", flush=True)
    if result.returncode or status != "Accepted":
        raise RuntimeError("Apple did not accept the submission; no stapling or publication performed")
    run("Staple notarization ticket", "/usr/bin/xcrun", "stapler", "staple", str(app))
    run("Validate notarization ticket", "/usr/bin/xcrun", "stapler", "validate", str(app))
    run("Verify stapled app", "/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    run("Gatekeeper assessment", "/usr/sbin/spctl", "--assess", "--type", "execute", str(app))
    print("PASS: Apple accepted, ticket stapled, signatures valid, Gatekeeper assessment passed.")
    print(f"Notarized app: {app}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        sys.exit(f"BLOCKED: {error}")
