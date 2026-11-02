#!/usr/bin/env python3
"""Calendar version and shared build number for every iOS target.

Version: {ISO week-year, two digits}.{ISO week}.{N}. N counts uploads in that week, from 1.
Build:   one CURRENT_PROJECT_VERSION that only increases, across versions, branches and Macs.

Pushed annotated tags named ios/v<version>-<build> are the shared registry. `bump` commits
iOS/Config/Version.xcconfig and pushes that commit and its tag atomically. When another Mac
reserved the same version first, the push is rejected and the next number is computed again.

  version.py show            print "<version> <build>" from Version.xcconfig
  version.py next            print the version and build `bump` would reserve now
  version.py bump            reserve, commit and push the next version and build
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

CONFIG = Path("iOS/Config/Version.xcconfig")
PROJECT = Path("iOS/AirSIM.xcodeproj/project.pbxproj")
TAG_PATTERN = re.compile(r"^ios/v(\d+)\.(\d+)\.(\d+)-(\d+)$")
# Every Mac must agree on the week at midnight between Sunday and Monday.
TIMEZONE = os.environ.get("AIRSIM_VERSION_TIMEZONE", "Asia/Seoul")
ATTEMPTS = 5


class VersionError(Exception):
    pass


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(["git", *args], cwd=ROOT, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise VersionError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result


def parse_config(text: str) -> tuple[str, int]:
    values = dict(re.findall(r"^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$", text, re.M))
    try:
        return values["MARKETING_VERSION"], int(values["CURRENT_PROJECT_VERSION"])
    except (KeyError, ValueError):
        raise VersionError(f"{CONFIG} must set MARKETING_VERSION and an integer CURRENT_PROJECT_VERSION")


def config_at(ref: str) -> tuple[str, int] | None:
    shown = git("show", f"{ref}:{CONFIG}", check=False)
    if shown.returncode == 0:
        return parse_config(shown.stdout)
    # Before Version.xcconfig existed, every target carried the numbers in the project file.
    legacy = git("show", f"{ref}:{PROJECT}", check=False)
    versions = re.findall(r"^\s*MARKETING_VERSION = (\S+);", legacy.stdout, re.M)
    builds = re.findall(r"^\s*CURRENT_PROJECT_VERSION = (\d+);", legacy.stdout, re.M)
    return (max(versions), max(map(int, builds))) if versions and builds else None


def version_tuple(value: str) -> tuple[int, int, int] | None:
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", value)
    return tuple(int(part) for part in match.groups()) if match else None


def registry(remote: str) -> list[tuple[tuple[int, int, int] | None, int]]:
    """Every reserved release: remote tags, plus committed and local files for history before tags."""
    entries = []
    for tag in git("tag", "--list", "ios/v*").stdout.split():
        match = TAG_PATTERN.match(tag)
        if match:
            major, minor, patch, build = (int(part) for part in match.groups())
            entries.append(((major, minor, patch), build))
    found = [parse_config((ROOT / CONFIG).read_text())]
    found += [config_at(ref) for ref in ("HEAD", f"{remote}/main")]
    entries += [(version_tuple(version), build) for version, build in filter(None, found)]
    return entries


def next_release(entries, now: datetime.datetime) -> tuple[str, int]:
    year, week, _ = now.isocalendar()
    key = (year % 100, week)
    build = max((build for _, build in entries), default=0) + 1
    count = max((version[2] for version, _ in entries if version and version[:2] == key), default=0) + 1
    candidate = (*key, count)
    newest = max((version for version, _ in entries if version), default=None)
    if newest and newest > candidate:
        raise VersionError(
            f"{'.'.join(map(str, newest))} is newer than this week's {'.'.join(map(str, candidate))}; "
            "check this Mac's clock")
    return ".".join(map(str, candidate)), build


def now() -> datetime.datetime:
    return datetime.datetime.now(ZoneInfo(TIMEZONE))


def write_config(version: str, build: int) -> None:
    path = ROOT / CONFIG
    text = path.read_text()
    text = re.sub(r"^(\s*MARKETING_VERSION\s*=\s*)\S+", rf"\g<1>{version}", text, flags=re.M)
    text = re.sub(r"^(\s*CURRENT_PROJECT_VERSION\s*=\s*)\S+", rf"\g<1>{build}", text, flags=re.M)
    if parse_config(text) != (version, build):
        raise VersionError(f"could not update {CONFIG}")
    path.write_text(text)


def require_single_source() -> None:
    # Xcode's General tab writes target-level values that would silently override the xcconfig.
    overrides = re.findall(r"^\s*(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=", (ROOT / PROJECT).read_text(), re.M)
    if overrides:
        raise VersionError(f"{PROJECT} overrides {', '.join(sorted(set(overrides)))}; "
                           f"remove them so {CONFIG} is the only source")


def fetch(remote: str, branch: str) -> str | None:
    git("fetch", "--quiet", "--tags", remote)
    git("fetch", "--quiet", remote, "main", check=False)
    if git("ls-remote", "--exit-code", "--heads", remote, branch, check=False).returncode != 0:
        return None
    git("fetch", "--quiet", remote, branch)
    return f"{remote}/{branch}"


def is_ancestor(older: str, newer: str) -> bool:
    return git("merge-base", "--is-ancestor", older, newer, check=False).returncode == 0


def sync(upstream: str | None) -> None:
    if not upstream or is_ancestor(upstream, "HEAD"):
        return
    if is_ancestor("HEAD", upstream):
        git("merge", "--quiet", "--ff-only", upstream)
        return
    print(f"Rebasing local commits onto {upstream}", file=sys.stderr)
    if git("rebase", "--quiet", upstream, check=False).returncode != 0:
        git("rebase", "--abort", check=False)
        raise VersionError(f"rebase onto {upstream} failed; resolve it manually and run bump again")


def remote_refs(remote: str, *refs: str) -> dict[str, str] | None:
    listed = git("ls-remote", remote, *refs, check=False)
    if listed.returncode != 0:
        return None
    return {name: sha for sha, name in (line.split("\t", 1) for line in listed.stdout.splitlines())}


def bump(remote: str) -> None:
    require_single_source()
    if git("status", "--porcelain", "--untracked-files=no").stdout.strip():
        raise VersionError("commit or stash tracked changes first; the uploaded build must match its tag")
    branch = git("symbolic-ref", "--quiet", "--short", "HEAD", check=False).stdout.strip()
    if not branch:
        raise VersionError("check out a branch first; bump pushes the version commit to it")
    for _ in range(ATTEMPTS):
        upstream = fetch(remote, branch)
        sync(upstream)
        based_on = git("rev-parse", upstream).stdout.strip() if upstream else None
        version, build = next_release(registry(remote), now())
        tag = f"ios/v{version}-{build}"
        write_config(version, build)
        git("add", str(CONFIG))
        git("commit", "--quiet", "-m", f"chore: bump iOS version to {version} ({build})")
        # A random line keeps each reservation a distinct tag object, so a racing Mac cannot
        # "succeed" by pushing an identical tag.
        git("tag", "-a", tag, "-m", f"AirSIM iOS {version} ({build})\n\nreservation {secrets.token_hex(8)}")
        pushed = git("push", "--atomic", "--quiet", remote, f"HEAD:refs/heads/{branch}", f"refs/tags/{tag}",
                     check=False)
        if pushed.returncode == 0:
            print(f"{version} {build}")
            return
        git("tag", "-d", tag)
        git("reset", "--quiet", "--keep", "HEAD~1")
        # Recompute only when another Mac moved the branch or took the tag meanwhile.
        # Authentication, network and policy failures are final.
        now_remote = remote_refs(remote, f"refs/heads/{branch}", f"refs/tags/{tag}")
        raced = now_remote is not None and (
            f"refs/tags/{tag}" in now_remote or now_remote.get(f"refs/heads/{branch}") != based_on)
        if not raced:
            raise VersionError(f"push to {remote} failed: {pushed.stderr.strip()}")
        print(f"{tag} was not accepted by {remote}; retrying", file=sys.stderr)
    raise VersionError(f"could not reserve a version after {ATTEMPTS} attempts")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["show", "next", "bump"])
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--offline", action="store_true", help="next: skip fetching the remote registry")
    args = parser.parse_args()
    try:
        if args.command == "show":
            version, build = parse_config((ROOT / CONFIG).read_text())
            print(f"{version} {build}")
        elif args.command == "next":
            if not args.offline:
                git("fetch", "--quiet", "--tags", args.remote)
                git("fetch", "--quiet", args.remote, "main", check=False)
            version, build = next_release(registry(args.remote), now())
            print(f"{version} {build}")
        else:
            bump(args.remote)
    except VersionError as error:
        print(f"version.py: {error}", file=sys.stderr)
        return 1
    return 0


ROOT = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=Path(__file__).resolve().parent,
                           text=True, capture_output=True, check=True).stdout.strip())

if __name__ == "__main__":
    sys.exit(main())
