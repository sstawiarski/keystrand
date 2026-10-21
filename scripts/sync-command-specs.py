#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shawn Stawiarski
"""Keep the command spec sources in scripts/command-sources.lock current.

Usage:
    python3 -I scripts/sync-command-specs.py resolve (--dry-run | --write) [--lock FILE]
    python3 -I scripts/sync-command-specs.py summarize --old-lock FILE --new-lock FILE
        --old-dir DIR --new-dir DIR

resolve asks the GitHub API for the newest tag of each source whose name
matches the source's `track` pattern, downloads it, and computes its SHA-256.
--dry-run prints the planned changes and --write also updates the lock. Set
GITHUB_TOKEN to raise the API rate limit.

A pin never moves backwards:
- A tag pin moves to the newest tracked tag when that tag's version is higher.
- A commit pin moves to the newest tracked tag only once that tag contains
  the commit.
- A module pin keeps its ref when the newer tag's commands.json is
  byte-identical to the pinned one, unless the pin is a commit.

Each source tracks one release line. redis-7.2 stays on 7.2.x, the last
BSD-licensed Redis line. redis-8 and valkey-9 follow GA releases of their
major version and skip -rc and -m tags; a new major version is a manual
change that also needs license review. Redis 8 modules track every v8 tag,
including the x.y.80 milestone and x.y.90 release candidate tags that Redis
ships its module command specs in first.

summarize compares two lock files and two folders of generated command files
and prints a Markdown report: changed pins, commands added, removed and
changed, new command groups, and the files that still name an old pin.

Only the Python 3 standard library is used.
"""

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_LOCK = ROOT / "scripts/command-sources.lock"
API = "https://api.github.com"
COMMIT = re.compile(r"^[0-9a-f]{40}$")

# Files a reviewer updates by hand when a pin changes.
PIN_MENTIONS = [
    "THIRD_PARTY_NOTICES.md",
    "README.md",
    "Sources/CommandSpecs/Resources/Commands/README.md",
]

# Swift code that sorts commands by group, server, and version.
GROUP_CODE = [
    ("Sources/CommandSpecs/CommandGroups.swift", "group display names and hidden groups"),
    ("Sources/CommandSpecs/CommandRules.swift", "dangerous, blocking, and unsupported command lists, module requirements"),
    ("Sources/CommandSpecs/CommandCatalog.swift", "`CommandAvailability` and `valkeyOnlyCommands`"),
    ("Sources/RedisCore/Models/ServerInfo.swift", "`commandAvailability`, the per-server version gate"),
]


class SyncError(Exception):
    pass


def request(url):
    headers = {"User-Agent": "keystrand-sync-command-specs"}
    if url.startswith(API):
        headers["Accept"] = "application/vnd.github+json"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
        token = os.environ.get("GITHUB_TOKEN")
        if token:
            headers["Authorization"] = f"Bearer {token}"
    try:
        return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120)
    except urllib.error.HTTPError as error:
        raise SyncError(f"{url}: HTTP {error.code} {error.reason}") from error
    except (urllib.error.URLError, OSError) as error:
        raise SyncError(f"{url}: {error}") from error


def api(path):
    """Decoded JSON for an API path, following `Link: rel="next"` across pages."""
    url = f"{API}/{path}"
    pages = []
    while url:
        with request(url) as response:
            pages.append(json.load(response))
            links = response.headers.get("Link", "")
        url = next((m.group(1) for m in re.finditer(r'<([^>]+)>;\s*rel="next"', links)), None)
    if len(pages) == 1:
        return pages[0]
    return [item for page in pages for item in page]


def sha256_of(url):
    digest = hashlib.sha256()
    with request(url) as response:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def literal_prefix(pattern):
    """The fixed text a `track` pattern starts with, for the matching-refs query."""
    prefix = []
    chars = iter(pattern.removeprefix("^"))
    for char in chars:
        if char == "\\":
            escaped = next(chars, "")
            if escaped.isalnum() or not escaped:
                break
            prefix.append(escaped)
        elif char in ".^$*+?{}[]|()":
            break
        else:
            prefix.append(char)
    return "".join(prefix)


def version(tag):
    return tuple(int(n) for n in re.findall(r"\d+", tag))


def newest_tag(repo, track):
    prefix = urllib.parse.quote(literal_prefix(track))
    refs = api(f"repos/{repo}/git/matching-refs/tags/{prefix}")
    pattern = re.compile(track)
    tags = [r["ref"].removeprefix("refs/tags/") for r in refs]
    tags = [t for t in tags if pattern.search(t)]
    if not tags:
        raise SyncError(f"{repo}: no tag matches {track}")
    return max(tags, key=version)


def contains(repo, tag, commit):
    comparison = api(f"repos/{repo}/compare/{commit}...{urllib.parse.quote(tag)}?per_page=1")
    return comparison["status"] in ("ahead", "identical")


def core_url(repo, tag):
    return f"https://codeload.github.com/{repo}/tar.gz/refs/tags/{tag}"


def module_url(module, ref):
    return f"https://raw.githubusercontent.com/{module['repo']}/{ref}/{module['path']}"


def resolve_core(key, source):
    tag = newest_tag(source["repo"], source["track"])
    if version(tag) <= version(source["tag"]):
        return None, f"{key}: {source['tag']} is current"
    url = core_url(source["repo"], tag)
    print(f"Hashing {url}", file=sys.stderr)
    updated = dict(source, tag=tag, url=url, sha256=sha256_of(url))
    return updated, f"{key}: {source['tag']} -> {tag}"


def resolve_module(key, module):
    ref = module["ref"]
    tag = newest_tag(module["repo"], module["track"])
    is_commit = COMMIT.match(ref) is not None
    if is_commit and not contains(module["repo"], tag, ref):
        return None, f"{key}: {ref[:12]} is current (newest tag {tag} does not contain it)"
    if not is_commit and version(tag) <= version(ref):
        return None, f"{key}: {ref} is current"
    url = module_url(module, tag)
    print(f"Hashing {url}", file=sys.stderr)
    digest = sha256_of(url)
    if digest == module["sha256"] and not is_commit:
        return None, f"{key}: {ref} is current ({tag} has the same {module['path']})"
    return dict(module, ref=tag, sha256=digest), f"{key}: {ref} -> {tag}"


def read_lock(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SyncError(f"{path}: {error}") from error


def resolve(options):
    lock = read_lock(options.lock)
    changes = 0
    for section, resolver in (("core", resolve_core), ("modules", resolve_module)):
        for key, source in lock.get(section, {}).items():
            if "track" not in source:
                print(f"{key}: not tracked")
                continue
            updated, line = resolver(key, source)
            print(line)
            if updated:
                lock[section][key] = updated
                changes += 1
    if not changes:
        print("pins are current")
        return
    if options.write:
        options.lock.write_text(json.dumps(lock, indent=4) + "\n", encoding="utf-8")
        print(f"Updated {changes} pins in {options.lock}")
    else:
        print(f"{changes} pins would change (dry run)")


def load_commands(path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SyncError(f"{path}: {error}") from error


def code_list(names):
    return ", ".join(f"`{n}`" for n in sorted(names))


def pin_label(section, entry):
    ref = entry.get("tag") or entry.get("ref", "")
    return ref[:12] if COMMIT.match(ref) else ref


def pin_rows(old_lock, new_lock):
    rows = []
    for section in ("core", "modules"):
        old_section = old_lock.get(section, {})
        new_section = new_lock.get(section, {})
        for key in sorted(old_section.keys() | new_section.keys()):
            old = pin_label(section, old_section.get(key, {})) or "none"
            new = pin_label(section, new_section.get(key, {})) or "none"
            if old != new:
                repo = (new_section.get(key) or old_section.get(key))["repo"]
                rows.append((key, repo, old, new))
    return rows


def file_report(name, old, new):
    added = new.keys() - old.keys()
    removed = old.keys() - new.keys()
    changed = {n for n in old.keys() & new.keys() if old[n] != new[n]}
    old_groups = {c.get("group") for c in old.values()}
    new_groups = {c.get("group") for c in new.values()} - old_groups - {None}
    if not (added or removed or changed):
        return [], new_groups
    lines = [f"### `{name}`", ""]
    for label, names in (("Added", added), ("Removed", removed), ("Changed", changed)):
        if names:
            lines.append(f"- {label} ({len(names)}): {code_list(names)}")
    if new_groups:
        lines.append(f"- New groups: {code_list(new_groups)}")
    lines.append("")
    return lines, new_groups


def stale_mentions(root, old_lock, new_lock):
    """`path:line` for each line in PIN_MENTIONS that names a pin which changed."""
    old_refs = []
    for section in ("core", "modules"):
        for key, entry in old_lock.get(section, {}).items():
            new_entry = new_lock.get(section, {}).get(key, {})
            field = "tag" if section == "core" else "ref"
            if entry.get(field) != new_entry.get(field):
                old_refs.append((entry[field], entry.get("file")))
    mentions = []
    for relative in PIN_MENTIONS:
        path = root / relative
        if not path.exists():
            continue
        for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for ref, file in old_refs:
                if re.search(rf"(?<![\w.]){re.escape(ref)}(?![\w])", text) and (file is None or file in text):
                    mentions.append(f"`{relative}:{number}` names `{ref}`")
                    break
    return mentions


def summarize(options):
    old_lock = read_lock(options.old_lock)
    new_lock = read_lock(options.new_lock)
    lines = ["## Command spec sync", ""]
    rows = pin_rows(old_lock, new_lock)
    if rows:
        lines += ["| Source | Repository | Old | New |", "| --- | --- | --- | --- |"]
        lines += [f"| `{k}` | {r} | `{o}` | `{n}` |" for k, r, o, n in rows]
    else:
        lines.append("No pins changed.")
    lines.append("")

    names = sorted({p.name for d in (options.old_dir, options.new_dir) for p in d.glob("*.json")})
    all_new_groups = set()
    reports = []
    for name in names:
        report, new_groups = file_report(
            name, load_commands(options.old_dir / name), load_commands(options.new_dir / name),
        )
        reports += report
        all_new_groups |= new_groups
    lines += reports or ["No command changes.", ""]

    if all_new_groups:
        lines += [
            "> [!WARNING]",
            f"> New command groups ({code_list(all_new_groups)}) usually need Swift work:",
            ">",
        ]
        lines += [f"> - `{path}`: {what}" for path, what in GROUP_CODE if (options.root / path).exists()]
        lines.append("")

    mentions = stale_mentions(options.root, old_lock, new_lock)
    lines += ["### Before merging", ""]
    lines += [
        "- [ ] Update the source links and versions in `THIRD_PARTY_NOTICES.md` and the License section of `README.md`.",
        "- [ ] Add new Valkey-only commands to `CommandAvailability.valkeyOnlyCommands`.",
        "- [ ] Run `swift test --filter CommandSpecsTests`.",
    ]
    if mentions:
        lines += ["", "Lines that still name an old pin:", ""]
        lines += [f"- {m}" for m in mentions]
    print("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description="Keep the pinned command spec sources current.")
    commands = parser.add_subparsers(dest="command", required=True)

    resolve_parser = commands.add_parser("resolve", help="find the newest tag of each source")
    mode = resolve_parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="print the planned changes")
    mode.add_argument("--write", action="store_true", help="update the lock file")
    resolve_parser.add_argument("--lock", type=pathlib.Path, default=DEFAULT_LOCK,
                                help="lock file (default: scripts/command-sources.lock)")

    summary_parser = commands.add_parser("summarize", help="print a Markdown summary of a sync")
    summary_parser.add_argument("--old-lock", type=pathlib.Path, required=True)
    summary_parser.add_argument("--new-lock", type=pathlib.Path, required=True)
    summary_parser.add_argument("--old-dir", type=pathlib.Path, required=True,
                                help="folder with the command files before the sync")
    summary_parser.add_argument("--new-dir", type=pathlib.Path, required=True,
                                help="folder with the command files after the sync")
    summary_parser.add_argument("--root", type=pathlib.Path, default=ROOT,
                                help="repository root for the file checks (default: this repository)")

    options = parser.parse_args()
    try:
        if options.command == "resolve":
            resolve(options)
        else:
            summarize(options)
    except SyncError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
