#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Shawn Stawiarski
"""Generate the bundled command specs in Sources/CommandSpecs/Resources/Commands.

Usage:
    python3 -I scripts/make-redis-commands.py CACHE_DIR [--output FILE]
        [--lock FILE] [--skip-modules]

Every source is pinned in scripts/command-sources.lock: a tag, tarball URL and
SHA-256 for each server, and a tag or commit plus SHA-256 for each module's
commands.json. CACHE_DIR holds the downloads. A missing file is downloaded from
GitHub, and every file is checked against its pinned SHA-256 before it is read.

FILE is the core spec file, redis.json. It defaults to the path above, relative
to this script. Each module's commands.json is written byte for byte, under its
local name from the lock, to the folder that holds FILE. --skip-modules writes
only FILE.

Core sources (see THIRD_PARTY_NOTICES.md for licenses):
    redis-7.2   redis/redis        src/commands/*.json                every command except SENTINEL *
    redis-8     redis/redis        src/commands/*.json                hash field expiration, HGETDEL, HGETEX, MSETEX
    redis-8     redis/redis        modules/vector-sets/commands.json  the vector set commands
    valkey-9    valkey-io/valkey   src/commands/*.json                CLUSTERSCAN, COMMANDLOG *, DELIFEQ, HSETEX

Each core source file uses the server's command-definition layout. redis.json
uses the layout of the server's COMMAND DOCS and COMMAND INFO replies: flags
become lowercase lists or booleans, implied ACL categories are added, groups use
their reply names, and arguments get display text. VADD and VSIM are
restructured so that FP32 takes a vector and VALUES takes a count followed by
that many doubles.

The output is deterministic: commands are sorted by name, the fields of each
entry are written in a fixed order, and the file is pretty-printed with four
spaces. The tarballs are read in memory as data. Nothing is extracted or run.
Only the Python 3 standard library is used.
"""

import argparse
import hashlib
import json
import pathlib
import sys
import tarfile
import urllib.error
import urllib.request

CORE_SOURCES = ("redis-7.2", "redis-8", "valkey-9")

REDIS_8_COMMANDS = [
    "HEXPIRE", "HEXPIREAT", "HEXPIRETIME", "HGETDEL", "HGETEX", "HPERSIST",
    "HPEXPIRE", "HPEXPIREAT", "HPEXPIRETIME", "HPTTL", "HTTL", "MSETEX",
]

# HSETEX comes from Valkey because its argument list is the superset: Valkey
# adds the NX | XX key condition to Redis's FNX | FXX and expiration options.
VALKEY_COMMANDS = [
    "CLUSTERSCAN", "COMMANDLOG", "COMMANDLOG GET", "COMMANDLOG HELP",
    "COMMANDLOG LEN", "COMMANDLOG RESET", "DELIFEQ", "HSETEX",
]

GROUP_NAMES = {"sorted_set": "sorted-set"}

ARGUMENT_TYPES = {
    "key", "string", "integer", "double", "pattern", "unix-time",
    "pure-token", "oneof", "block",
}

# Reply order of COMMAND's flag list. Flags the server hides from the reply are absent.
COMMAND_FLAG_ORDER = [
    "write", "readonly", "denyoom", "module", "admin", "pubsub", "noscript",
    "blocking", "loading", "stale", "skip_monitor", "skip_slowlog", "skip_commandlog",
    "asking", "fast", "no_auth", "no_mandatory_keys", "no_async_loading", "no_multi",
    "movablekeys", "allow_busy", "all_dbs",
]
HIDDEN_COMMAND_FLAGS = {
    "may_replicate", "sentinel", "only_sentinel", "protected", "touches_arbitrary_keys",
}

# Reply order of COMMAND's ACL category list.
ACL_CATEGORY_ORDER = [
    "keyspace", "read", "write", "set", "sortedset", "list", "hash", "string",
    "bitmap", "hyperloglog", "geo", "stream", "pubsub", "admin", "fast", "slow",
    "blocking", "dangerous", "connection", "transaction", "scripting",
]

KEY_SPEC_FLAG_ORDER = [
    "RO", "RW", "OW", "RM", "access", "update", "insert", "delete",
    "not_key", "incomplete", "variable_flags",
]

SCRIPTS = pathlib.Path(__file__).resolve().parent
DEFAULT_LOCK = SCRIPTS / "command-sources.lock"
DEFAULT_REDIS_JSON = SCRIPTS.parent / "Sources/CommandSpecs/Resources/Commands/redis.json"


class GenerateError(Exception):
    pass


def load_lock(path):
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise GenerateError(f"{path}: {error}") from error
    missing = [k for k in CORE_SOURCES if k not in lock.get("core", {})]
    if missing:
        raise GenerateError(f"{path}: core sources missing {missing}")
    return lock


def cached_download(url, path, digest):
    if not path.exists():
        print(f"Downloading {url}", file=sys.stderr)
        partial = path.with_name(path.name + ".partial")
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                partial.write_bytes(response.read())
        except (urllib.error.URLError, OSError) as error:
            raise GenerateError(f"{url}: {error}") from error
        partial.replace(path)
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise GenerateError(f"{path}: SHA-256 is {actual}, expected {digest}")
    return path


def fetch(cache_dir, source):
    name = source["repo"].rpartition("/")[2]
    return cached_download(source["url"], cache_dir / f"{name}-{source['tag']}.tar.gz", source["sha256"])


def module_url(module):
    return f"https://raw.githubusercontent.com/{module['repo']}/{module['ref']}/{module['path']}"


def fetch_module(cache_dir, key, module):
    return cached_download(module_url(module), cache_dir / f"{key}-{module['ref']}.json", module["sha256"])


def read_json_members(tarball, wanted):
    """Decoded JSON for each tarball member whose path after the top folder passes `wanted`."""
    documents = {}
    with tarfile.open(tarball, "r:gz") as archive:
        for member in archive.getmembers():
            relative = member.name.partition("/")[2]
            if member.isfile() and wanted(relative):
                with archive.extractfile(member) as stream:
                    documents[relative] = json.load(stream)
    if not documents:
        raise GenerateError(f"{tarball}: no matching files")
    return documents


def command_definitions(tarball):
    """Command definitions from src/commands, keyed by uppercased full name."""

    def is_command_file(relative):
        folder, _, file = relative.rpartition("/")
        return folder == "src/commands" and file.endswith(".json")

    definitions = {}
    for _relative, document in sorted(read_json_members(tarball, is_command_file).items()):
        for name, definition in document.items():
            container = definition.get("container")
            full = f"{container} {name}" if container else name
            definitions[full.upper()] = definition
    return definitions


def vector_set_definitions(tarball):
    documents = read_json_members(tarball, lambda r: r == "modules/vector-sets/commands.json")
    return {name.upper(): definition for name, definition in documents.popitem()[1].items()}


def ordered(values, order, label, name):
    unknown = [v for v in values if v not in order]
    if unknown:
        raise GenerateError(f"{name}: unknown {label} {unknown}")
    return [v for v in order if v in values]


def is_movable(definition):
    return any(
        "index" not in spec["begin_search"] or "range" not in spec["find_keys"]
        for spec in definition.get("key_specs", [])
    )


def command_flags(definition, name, module):
    flags = {f.lower() for f in definition.get("command_flags", [])} - HIDDEN_COMMAND_FLAGS
    if module:
        flags.add("module")
    if is_movable(definition):
        flags.add("movablekeys")
    return ordered(flags, COMMAND_FLAG_ORDER, "command flags", name)


def acl_categories(definition, name):
    flags = {f.lower() for f in definition.get("command_flags", [])}
    categories = {c.lower() for c in definition.get("acl_categories", [])}
    if "write" in flags:
        categories.add("write")
    if "readonly" in flags and "scripting" not in categories:
        categories.add("read")
    if "admin" in flags:
        categories |= {"admin", "dangerous"}
    if "pubsub" in flags:
        categories.add("pubsub")
    if "fast" in flags:
        categories.add("fast")
    if "blocking" in flags:
        categories.add("blocking")
    if "fast" not in categories:
        categories.add("slow")
    return ["@" + c for c in ordered(categories, ACL_CATEGORY_ORDER, "ACL categories", name)]


def begin_search(spec):
    if "index" in spec:
        return {"type": "index", "spec": {"index": spec["index"]["pos"]}}
    if "keyword" in spec:
        keyword = spec["keyword"]
        return {"type": "keyword", "spec": {"keyword": keyword["keyword"], "startfrom": keyword["startfrom"]}}
    return {"type": "unknown", "spec": {}}


def find_keys(spec):
    if "range" in spec:
        r = spec["range"]
        return {"type": "range", "spec": {"lastkey": r["lastkey"], "keystep": r["step"], "limit": r["limit"]}}
    if "keynum" in spec:
        k = spec["keynum"]
        return {"type": "keynum", "spec": {"keynumidx": k["keynumidx"], "firstkey": k["firstkey"], "keystep": k["step"]}}
    return {"type": "unknown", "spec": {}}


def key_spec(spec, name):
    out = {}
    if "notes" in spec:
        out["notes"] = spec["notes"]
    out["begin_search"] = begin_search(spec["begin_search"])
    out["find_keys"] = find_keys(spec["find_keys"])
    raw = {f if f in ("RO", "RW", "OW", "RM") else f.lower() for f in spec.get("flags", [])}
    for flag in ordered(raw, KEY_SPEC_FLAG_ORDER, "key spec flags", name):
        out[flag] = True
    return out


def module_key_spec():
    """What COMMAND reports for a module command whose only key is the first argument."""
    return {
        "begin_search": {"type": "index", "spec": {"index": 1}},
        "find_keys": {"type": "range", "spec": {"lastkey": 0, "keystep": 1, "limit": 0}},
        "RW": True,
        "access": True,
        "update": True,
    }


def argument(arg, name):
    kind = arg["type"]
    if kind not in ARGUMENT_TYPES:
        raise GenerateError(f"{name}: argument {arg['name']} has unknown type {kind}")
    out = {"name": arg["name"].lower(), "type": kind}
    if kind not in ("oneof", "block"):
        out["display_text"] = arg.get("display", arg["name"]).lower()
    if kind in ("key", "pattern") and "key_spec_index" in arg:
        out["key_spec_index"] = arg["key_spec_index"]
    if "token" in arg:
        # The server's C tables turn the JSON token `""` (MIGRATE's empty key) into an empty string.
        out["token"] = "" if arg["token"] == '""' else arg["token"].upper()
    for field in ("summary", "since", "deprecated_since"):
        if field in arg:
            out[field] = arg[field]
    for field in ("optional", "multiple", "multiple_token"):
        if arg.get(field):
            out[field] = True
    if arg.get("arguments"):
        out["arguments"] = [argument(a, name) for a in arg["arguments"]]
    return out


def entry(definition, name, module=False):
    out = {
        "summary": definition["summary"],
        "since": definition["since"],
        "group": GROUP_NAMES.get(definition["group"], definition["group"]),
    }
    for field in ("complexity", "deprecated_since", "replaced_by", "history"):
        if definition.get(field):
            out[field] = definition[field]
    if not module:
        out["acl_categories"] = acl_categories(definition, name)
    out["arity"] = definition["arity"]
    specs = [key_spec(s, name) for s in definition.get("key_specs", [])]
    arguments = [argument(a, name) for a in definition.get("arguments", [])]
    if module and arguments and arguments[0]["type"] == "key":
        arguments[0].setdefault("key_spec_index", 0)
        specs = specs or [module_key_spec()]
    if specs:
        out["key_specs"] = specs
    if arguments:
        out["arguments"] = arguments
    flags = command_flags(definition, name, module)
    if flags:
        out["command_flags"] = flags
    if definition.get("doc_flags"):
        out["doc_flags"] = [f.lower() for f in definition["doc_flags"]]
    if definition.get("command_tips"):
        out["hints"] = [t.lower() for t in definition["command_tips"]]
    return out


def vector_argument(name, token, kind="string"):
    return {"name": name, "type": kind, "display_text": name, "token": token}


def restructure_vector_input(spec, name, with_element):
    """Replaces the `format` token choice and the value after it with one typed choice."""
    arguments = spec["arguments"]
    index = next((i for i, a in enumerate(arguments) if a["name"] == "format"), None)
    if index is None or index + 1 >= len(arguments):
        raise GenerateError(f"{name}: no format argument to restructure")
    choices = [vector_argument("element", "ELE")] if with_element else []
    choices.append(vector_argument("vector", "FP32"))
    choices.append({
        "name": "values",
        "type": "block",
        "token": "VALUES",
        "arguments": [
            {"name": "num", "type": "integer", "display_text": "num"},
            {"name": "value", "type": "double", "display_text": "value", "multiple": True},
        ],
    })
    arguments[index:index + 2] = [{"name": "format", "type": "oneof", "arguments": choices}]


def pick(definitions, names, source):
    missing = [n for n in names if n not in definitions]
    if missing:
        raise GenerateError(f"{source}: missing {missing}")
    return {n: definitions[n] for n in names}


def generate(cache_dir, core):
    redis72 = command_definitions(fetch(cache_dir, core["redis-7.2"]))
    redis8_tarball = fetch(cache_dir, core["redis-8"])
    redis8 = command_definitions(redis8_tarball)
    valkey = command_definitions(fetch(cache_dir, core["valkey-9"]))
    vector_sets = vector_set_definitions(redis8_tarball)

    commands = {}
    for name, definition in redis72.items():
        if definition["group"] != "sentinel":
            commands[name] = entry(definition, name)
    for name, definition in pick(redis8, REDIS_8_COMMANDS, "redis-8").items():
        commands[name] = entry(definition, name)
    for name, definition in pick(valkey, VALKEY_COMMANDS, "valkey-9").items():
        commands[name] = entry(definition, name)
    for name, definition in vector_sets.items():
        commands[name] = entry(definition, name, module=True)

    restructure_vector_input(commands["VADD"], "VADD", with_element=False)
    restructure_vector_input(commands["VSIM"], "VSIM", with_element=True)
    return {name: commands[name] for name in sorted(commands)}


def module_files(cache_dir, modules):
    """Verified cached file for each module, before anything is written."""
    return [(module, fetch_module(cache_dir, key, module)) for key, module in sorted(modules.items())]


def main():
    parser = argparse.ArgumentParser(
        description="Generate the bundled command specs from the sources pinned in the lock file.",
    )
    parser.add_argument("cache_dir", type=pathlib.Path, help="directory for the downloaded source files")
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_REDIS_JSON,
                        help="redis.json to write; module files go next to it (default: this repository's)")
    parser.add_argument("--lock", type=pathlib.Path, default=DEFAULT_LOCK,
                        help="source pins (default: command-sources.lock next to this script)")
    parser.add_argument("--skip-modules", action="store_true",
                        help="write only redis.json, not the module command files")
    options = parser.parse_args()
    options.cache_dir.mkdir(parents=True, exist_ok=True)
    try:
        lock = load_lock(options.lock)
        commands = generate(options.cache_dir, lock["core"])
        modules = [] if options.skip_modules else module_files(options.cache_dir, lock.get("modules", {}))
    except GenerateError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    text = json.dumps(commands, indent=4, ensure_ascii=False) + "\n"
    options.output.write_text(text, encoding="utf-8")
    print(f"Wrote {len(commands)} commands to {options.output}", file=sys.stderr)
    for module, cached in modules:
        target = options.output.parent / module["file"]
        target.write_bytes(cached.read_bytes())
        print(f"Wrote {target} ({module['repo']} {module['ref']})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
