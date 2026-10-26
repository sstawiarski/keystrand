# Contribute to Keystrand

Use this guide to build Keystrand, check your changes, and open a pull request.
The project accepts bug reports, fixes, and focused improvements.

## Prerequisites

Before you build, install the following:

- macOS 26 and the Xcode version in `.xcode-version`. The project uses Swift 6
  language mode.
- [Homebrew](https://brew.sh). `scripts/bootstrap.sh` checks Xcode and installs
  the tools in `Brewfile`, including XcodeGen, SwiftFormat, ast-grep,
  markdownlint, ShellCheck, Ruff, Redis, and Valkey. macOS includes `jq`.
  Use `scripts/bootstrap.sh --check` to report missing tools without installing them.
- Docker if you prefer containers for live tests. Use
  `scripts/test-servers.sh native` to run Homebrew servers without Docker.

## Build

The code lives in the SwiftPM package `KeystrandKit`, defined in `Package.swift`.
XcodeGen generates the Xcode project and `Config/Info.plist` from `project.yml`.
Git excludes the generated files. Edit `project.yml` to change their settings.

Choose a build command for your task:

```bash
# Package build
swift build --scratch-path .build/dev

# Build and run in Xcode
xcodegen generate
open Keystrand.xcodeproj

# Debug app
xcodegen generate
xcodebuild -project Keystrand.xcodeproj -scheme Keystrand \
  -destination 'platform=macOS' -derivedDataPath .build/dd build
open .build/dd/Build/Products/Debug/Keystrand.app

# Release app
xcodebuild -project Keystrand.xcodeproj -scheme Keystrand \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/dd build

# Release app into dist/, signed and installed to /Applications
scripts/install.sh
```

`scripts/version.sh` derives the version from Git tags. It returns `0.1.0` at
tag `v0.1.0`, `0.1.0-dev.3` three commits later, or `0.0.0-dev` without a
`v*` tag. `scripts/install.sh` passes the version to `xcodebuild` as
`MARKETING_VERSION`. It passes the commit count as `CURRENT_PROJECT_VERSION`.
Pushing a `v*` tag builds that tag and publishes a GitHub Release with generated notes.

## Tests

The tests use Swift Testing. Unit tests need no server. Live tests carry the
`live` tag. They use the servers from `scripts/test-servers.sh` and skip if a
server is unavailable.

Use these commands to manage test servers and run tests:

```bash
scripts/test-servers.sh start          # all containers
scripts/test-servers.sh start redis    # only Redis 8 on 127.0.0.1:6390
scripts/test-servers.sh status
scripts/test-servers.sh stop
scripts/test-servers.sh native         # Homebrew servers, no Docker

swift test --scratch-path .build/dev
swift test --scratch-path .build/dev --filter BrowserFeatureTests
```

The test containers use these ports:

- `keystrand-test` runs Redis 8 on port 6390.
- `keystrand-valkey` runs the Valkey 9 bundle on port 6392.
- The three-node Valkey 9 cluster uses ports 7001–7003.
- `keystrand-sentinel-primary` and `keystrand-sentinel-replica` run a Redis 8
  primary on port 6394 and its replica on port 6395. `keystrand-sentinel`
  watches them as the group `keystrand-primary` on port 26394.

The cluster and the Sentinel group require host networking. Enable it in
Docker Desktop.

A Sentinel test fails the group over, so the replica on 6395 can be the
primary afterwards. Each time the script starts the Sentinel, it makes 6394
the primary again.

`scripts/test-servers.sh native [start|stop|status] [all|redis|valkey|cluster|sentinel]`
runs Homebrew server processes. It stores PID files and logs in
`.build/test-servers/`. CI uses this mode. Homebrew's `redis` and `valkey`
formulae conflict. Install Redis unlinked so both can coexist:

```bash
brew install redis && brew unlink redis && brew install valkey
```

The script finds Redis in Homebrew's `opt/redis` and loads its modules.
Native Valkey has no modules, so tests that need Search, JSON, or Bloom on
Valkey skip in native mode. Set `KEYSTRAND_REQUIRE_LIVE=1` to fail live tests
when a server is missing. Set `KEYSTRAND_SKIP_LIVE=1` to skip every live test.

You must obey these rules to protect local data:

- Tests and manual checks must not connect to `127.0.0.1:6379`. Your local
  Redis server can use that address.
- You must not send `FLUSHDB` or `FLUSHALL`. Each test target owns one logical
  database index and deletes its keys with `SCAN` and `UNLINK`. Read
  [Tests and the live server](docs/ARCHITECTURE.md#8-tests-and-the-live-server)
  for the assigned indexes.

Before a manual app check, set `KEYSTRAND_DISABLE_AUTODISCOVERY=1` to disable
local port probes. Set `KEYSTRAND_DATA_DIR=<dir>` to keep your saved databases
separate from test data.

## Format and lint code

Use these commands to format code and check lint rules:

```bash
scripts/format.sh                 # add the blank lines the style needs
scripts/format.sh --check         # report only; exits 1 on a change
ast-grep scan                     # lint rules in ast-grep/rules
ast-grep test --include-off       # tests for the rules themselves
```

Before you open a pull request, run `scripts/format.sh` on the changed paths.
Run `ast-grep scan` on those paths. Every lint rule reports an error.

## Conventions

Use only Apple frameworks. Do not add third-party packages.

These documents and scripts define the project conventions:

- `CLAUDE.md` summarizes target layers, concurrency, sessions, tests, and lint
  rules. Its instructions apply to AI coding tools and contributors.
- `docs/DESIGN.md` defines windows, components, menus, colors, and Liquid Glass
  rules. UI changes must obey this design contract.
- `docs/ARCHITECTURE.md` describes targets, recorded decisions, threading rules,
  test database indexes, and known gaps. Section 11 contains the generated
  public API reference. After you add, remove, or change a `public` symbol,
  run `scripts/make-api-reference.sh`.
- `scripts/check-generated.sh` runs the generators for command specifications,
  sample data, the app icon, the API reference, and the Xcode project. It fails
  if a generated file is stale. CI runs it on every pull request.

### Localize UI text

UI text belongs in the String Catalog `Keystrand/Localizable.xcstrings`.
Write literals that SwiftUI localizes, such as `Text("Add Database")` or
`Button("Delete")`. You can also use `String(localized:)` or
`LocalizedStringResource`. `Text(title)` displays a `String` variable verbatim
and does not add it to the catalog.

After you change UI text, run `scripts/sync-strings.sh`. The script builds the
app with compiler string extraction and merges strings from every module into
the catalog. Do not edit extracted entries by hand.

## Pull requests

Before you submit a pull request, check the following:

- Keep the pull request to one change. Describe the change and its purpose.
- Add or update tests for behavior changes. `swift test` must pass. The build
  must not add warnings.
- Run `scripts/format.sh --check` and `ast-grep scan`. Both must pass.
- For UI changes, include before and after screenshots in light and dark
  appearance. Use `scripts/snapshot.sh` to capture them.
- Update any affected documentation.
- Check the labels from the Commit style workflow. It assigns `feature`, `bug`,
  `docs`, or `internal` from the title, plus `breaking` when applicable.
  Release notes exclude `internal` changes. Add `dependencies` manually if it applies.

### Commit messages and pull request titles

Commit subjects and pull request titles must use
[Conventional Commits](https://www.conventionalcommits.org) with the format
`<type>[(scope)][!]: <summary>`. The summary must contain at most 72 characters.
Valid types are `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`,
`chore`, and `perf`.

The optional scope uses lowercase letters, digits, and hyphens, such as a
feature name. A `!` after the type or scope marks a breaking change.
A `BREAKING CHANGE:` footer also marks a breaking change.

These examples show a scoped feature and a breaking fix:

```text
feat(workbench): add a Command Helper search field
fix!: store key names as Data in saved queries
```

Pull requests use squash merges, so CI requires a valid title. It only warns
about invalid commit subjects. `scripts/bootstrap.sh` installs a local
`commit-msg` hook that runs `scripts/check-commit-message.sh` for the same check.

## Code of conduct

Participation requires you to obey the Contributor Covenant 2.1 in the
[code of conduct](CODE_OF_CONDUCT.md). That document explains how to report a problem.

Report security problems privately through the process in the
[security policy](SECURITY.md).
