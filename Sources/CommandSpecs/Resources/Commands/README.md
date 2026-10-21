# Command specifications

`CommandCatalog` loads every `*.json` file in this directory. `redis.json`
supplies core commands with provider `main`. Each other file uses its filename
as the provider name. Read the repository's
[third-party notices](../../../../THIRD_PARTY_NOTICES.md) for licenses and attribution.

Do not edit these JSON files by hand. The sources come from pinned versions in
`scripts/command-sources.lock`. To regenerate them, run this command from the
repository root:

```bash
python3 -I scripts/make-redis-commands.py <cache-dir>
```

`<cache-dir>` is the download directory. The script checks each download against
its pinned SHA-256 hash. The same lock file therefore produces the same files.

Use these flags to change the output or lock file:

- `--output FILE` writes `redis.json` to another path. It writes module files
  next to that file.
- `--skip-modules` writes only `redis.json`.
- `--lock FILE` reads another lock file.

## Lock file

`scripts/command-sources.lock` uses JSON. Each source defines a `repo`, a `track`
regular expression for matching tags, and a pin. The file groups pins as follows:

- `core` contains `redis-7.2`, `redis-8`, and `valkey-9`. Each entry defines a
  `tag`, tarball `url`, and tarball `sha256`.
- `modules` contains one entry per module file. Each entry defines a `ref`,
  `path` to `commands.json`, file `sha256`, and local `file` name. The `ref`
  uses a commit if no tag contains the file.

The Sync command specs workflow runs monthly. It runs
`scripts/sync-command-specs.py resolve --write` to select the newest matching
tag for each `track` pattern. It regenerates the files and opens a pull request
if they change. `scripts/sync-command-specs.py summarize` writes the pull request
body with changed pins, added or removed commands, changed commands, and new groups.

To preview a sync, run this command:

```bash
python3 -I scripts/sync-command-specs.py resolve --dry-run
```

`redis-7.2` stays on the last BSD-licensed Redis release line, 7.2.
`redis-8` and `valkey-9` track generally available (GA) releases of their major
versions. To track a new major version, change the lock file manually and review
its license. Module pins track every `v8` tag, including release candidates.

## `redis.json`

`scripts/make-redis-commands.py` converts core definitions to the layout of
server `COMMAND DOCS` and `COMMAND INFO` replies. It selects definitions from
these sources:

- `redis-7.2`, `src/commands/*.json`, supplies commands other than `SENTINEL`
  and the commands listed in the next three items.
- `redis-8`, `src/commands/*.json`, supplies `HEXPIRE`, `HEXPIREAT`,
  `HEXPIRETIME`, `HGETDEL`, `HGETEX`, `HPERSIST`, `HPEXPIRE`, `HPEXPIREAT`,
  `HPEXPIRETIME`, `HPTTL`, `HTTL`, and `MSETEX`.
- `redis-8`, `modules/vector-sets/commands.json`, supplies `VADD`, `VCARD`,
  `VDIM`, `VEMB`, `VGETATTR`, `VINFO`, `VISMEMBER`, `VLINKS`, `VRANDMEMBER`,
  `VRANGE`, `VREM`, `VSETATTR`, and `VSIM`.
- `valkey-9`, `src/commands/*.json`, supplies `CLUSTERSCAN`, `COMMANDLOG` and
  its subcommands, `DELIFEQ`, and `HSETEX`.

To add a command, add its name to `REDIS_8_COMMANDS` or `VALKEY_COMMANDS` in
the script. For a Valkey-only command, also add the name to
`CommandAvailability.valkeyOnlyCommands`.

## Module files

`redisbloom.json`, `redisearch.json`, `redisgraph.json`, `redisjson.json`, and
`redistimeseries.json` are unmodified copies of their modules' `commands.json`
files. The script downloads each file at its pinned ref and writes the bytes unchanged.

To update a module file:

1. Change its `ref` and `sha256` in the lock file, or use the sync workflow.
2. Regenerate the files.
3. Update its row in `THIRD_PARTY_NOTICES.md`.
