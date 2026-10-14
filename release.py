#!/usr/bin/env python3
"""Publish the staged build as a new notarized Archiver update."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import sys
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from notarize import ROOT, REQUIREMENT, run

REPO = "ngzhenghui94/unarchiver"
TAP = "ngzhenghui94/homebrew-tap"
REMOTE = f"https://github.com/{TAP}.git"
CHECKOUT = ROOT / "build/update-tap"
STAGED = ROOT / "build/staging/Archiver.app"
SIGNING = ROOT / "signing.swift"


def git(*arguments):
    return run("Release checkout", "git", "-c", "credential.helper=", "-c",
               "credential.helper=!gh auth git-credential", "-C", str(CHECKOUT), *arguments)


def version_parts(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Release versions must contain one to three numeric components")
    return tuple(int(part) for part in value.split("."))


def next_version(versions, builds):
    parts = list(max((version_parts(version) for version in versions), key=lambda p: p + (0,) * (3 - len(p))))
    parts[-1] += 1
    if any(not isinstance(build, str) or not re.fullmatch(r"[1-9]\d{0,3}", build) for build in builds):
        raise ValueError("Expected positive integer build numbers below 10000")
    build = max(map(int, builds)) + 1
    if build > 9999:
        raise ValueError("Build number exhausted; migrate the release numbering before publishing")
    return ".".join(map(str, parts)), str(build)


def read_info(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != "local.unarchiver":
        raise ValueError("Refusing an unrelated app bundle")
    return info


def selftest():
    assert next_version(["1.1", "1.9", "1.10"], ["2", "9"]) == ("1.11", "10")
    assert next_version(["1.1", "2.0.4"], ["3", "4"]) == ("2.0.5", "5")
    for version in ("../1", "1.2/3", "1..2", "XX.YY.3.4", "", "1.2-beta"):
        try:
            version_parts(version)
        except ValueError:
            pass
        else:
            raise AssertionError("Unsafe version accepted")
    for build in ("0", "-1", "3.2", "10000", "9999"):
        try:
            next_version(["1.1"], [build])
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid or exhausted build number accepted")
    from unittest.mock import patch
    failure = subprocess.CompletedProcess((), 1, stderr="OSStatus=-25293")
    with patch("subprocess.run", return_value=failure):
        for command, expected in ((("/usr/bin/swift", str(SIGNING)), "OSStatus=-25293"),
                                  (("/usr/bin/codesign",), "private command output withheld")):
            try:
                run("Fixture", *command)
            except RuntimeError as error:
                assert expected in str(error)
            else:
                raise AssertionError("Signing failure was ignored")
    print("release selftest ok: numeric version ordering, monotonic builds, unsafe names, build limits")


def main():
    public_key = read_info(STAGED)["SUPublicEDKey"]
    run("Noninteractive update signing key", "/usr/bin/swift", str(SIGNING), "check", "local.swissKnife", public_key)
    metadata = json.loads(run("Publication access", "gh", "api", f"repos/{TAP}"))
    if metadata.get("private") or metadata.get("default_branch") != "main" or not metadata.get("permissions", {}).get("push"):
        raise RuntimeError("Expected push access to the public release repository on main")
    if not CHECKOUT.exists():
        run("Clone release checkout", "git", "clone", "--branch", "main", REMOTE, str(CHECKOUT))
    if git("remote", "get-url", "origin").strip() != REMOTE or git("branch", "--show-current").strip() != "main":
        raise RuntimeError("Release checkout must track the expected remote on main")
    if git("status", "--porcelain", "--untracked-files=all").strip():
        raise RuntimeError("Release checkout has local changes; preserve and resolve them before building")
    git("fetch", "origin", "main")
    if git("rev-list", "--count", "origin/main..HEAD").strip() != "0":
        raise RuntimeError("Release checkout has unpushed commits; resolve publication before building again")
    git("merge", "--ff-only", "origin/main")
    feed = CHECKOUT / "appcasts/archiver.xml"
    if feed.exists():
        run("Existing feed signature", "/usr/bin/swift", str(SIGNING), "verify", public_key, str(feed))
        xml = ET.parse(feed)
    else:
        xml = ET.ElementTree(ET.Element("rss"))
    namespace = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
    info = read_info(STAGED)
    versions = [info["CFBundleShortVersionString"]]
    builds = [info["CFBundleVersion"]]
    versions.extend(element.text for element in xml.findall(".//sparkle:shortVersionString", namespace))
    builds.extend(element.text for element in xml.findall(".//sparkle:version", namespace))
    pages = json.loads(run("Release version inventory", "gh", "api", "--paginate", "--slurp", f"repos/{REPO}/releases?per_page=100"))
    for page in pages:
        for release in page:
            tag = release["tag_name"]
            if tag.startswith("v"):
                versions.append(tag.removeprefix("v"))
    releases = ROOT / "build/releases"
    for directory in releases.iterdir() if releases.exists() else []:
        if directory.is_dir():
            versions.append(directory.name)
            previous = read_info(directory / "Archiver.app")
            builds.append(previous["CFBundleVersion"])
    version, build = next_version(versions, builds)
    tag = f"v{version}"
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build
    with (STAGED / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)
    print(f"Releasing Archiver {version} (build {build}) to {REPO}; previous releases are not overwritten.", flush=True)
    if subprocess.run([sys.executable, str(ROOT / "notarize.py"), "--submit"], cwd=ROOT).returncode:
        raise RuntimeError("Notarization failed; see the stage error above")
    app = releases / version / "Archiver.app"
    run("Stable signing identity", "codesign", "--verify", "--deep", "--strict", "-R", REQUIREMENT, str(app))
    final = ROOT / "build/Archiver.app"
    if final.exists():
        read_info(final)
        if final.is_symlink():
            raise RuntimeError("Refusing to replace a symlink at the final app path")
        shutil.rmtree(final)
    run("Promote notarized build", "ditto", str(app), str(final))
    print(run("Release packaging", "/bin/sh", str(ROOT / "package.sh"), "--release"), end="", flush=True)
    package = releases / version / "package"
    assets = [package / f"Archiver-{version}-arm64.zip", package / f"Archiver-{version}-archive-sources.tar.gz", package / "appcast.xml"]
    expected = {}
    for asset in assets:
        with asset.open("rb") as stream:
            expected[asset.name] = hashlib.file_digest(stream, "sha256").hexdigest()
    # Assets must exist and be verified before the live update feed points at them.
    run("Create draft release", "gh", "release", "create", tag, "--repo", REPO, "--target", "main", "--draft",
        "--title", f"Archiver {version}", "--notes", "Developer ID signed and Apple-notarized update. Includes matching archive-library sources and a signed Sparkle update feed.", *map(str, assets))
    with tempfile.TemporaryDirectory(prefix="archiver-release-verify-") as temporary:
        run("Verify uploaded draft", "gh", "release", "download", tag, "--repo", REPO, "--dir", temporary)
        for name, digest in expected.items():
            with (Path(temporary) / name).open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
                    raise RuntimeError("Uploaded asset checksum differs; draft retained, feed unchanged")
        run("Publish verified release", "gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--latest=false")
        for name, digest in expected.items():
            downloaded = Path(temporary) / name
            run("Verify public download", "curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
                "--output", str(downloaded), f"https://github.com/{REPO}/releases/download/{tag}/{name}")
            with downloaded.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
                    raise RuntimeError("Public asset checksum differs; live feed unchanged")
    shutil.copy2(package / "Casks/archiver.rb", CHECKOUT / "Casks/archiver.rb")
    shutil.copy2(package / "appcast.xml", feed)
    git("add", "--", "Casks/archiver.rb", "appcasts/archiver.xml")
    git("commit", "-m", f"Publish notarized Archiver {version} and signed update feed")
    git("fetch", "origin", "main")
    git("rebase", "origin/main")
    git("push", "origin", "HEAD:main")
    print(f"Published https://github.com/{REPO}/releases/tag/{tag}")
    print(f"Ready: {final}. Signed feed and cask committed and pushed to main; no permissions were changed.")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--selftest"]:
            selftest()
        elif not sys.argv[1:]:
            main()
        else:
            raise ValueError("Usage: release.py [--selftest]; normally invoked by ./build.sh")
    except (RuntimeError, OSError, ValueError, KeyError, ET.ParseError) as error:
        sys.exit(f"BLOCKED: {error}. Preserve build/releases and build/update-tap; inspect any recorded Apple submission or GitHub draft before retrying.")
