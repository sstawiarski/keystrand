# Server compatibility

This page lists the Redis and Valkey versions Keystrand supports, the
modules it uses, the features that depend on a server version, and what the
tests cover.

The README says Keystrand works with Redis 6 through 8 and Valkey 8 and 9.
That describes what the app connects to and adapts to: it reads the server
version and modules on connect and hides or adjusts features the server
lacks. The tested matrix is narrower. CI tests Redis 8 and Valkey 9 on every
pull request, and the nightly workflow adds Redis 7.2 and Valkey 8.1. Redis 6
and 7.0 have no live tests; only their version gates are unit-tested with
mock sessions.

## Supported servers

| Server | Standalone | Cluster | Modules in tests | Tested by |
| --- | --- | --- | --- | --- |
| Redis 7.2 | Live (nightly) | Mocks only | None | Nightly `redis-7.2` |
| Redis 8.x | Live (CI, nightly) | Mocks only | Search, JSON, TimeSeries, Bloom, vector sets | CI, nightly `redis-8` |
| Valkey 8.x | Live (nightly) | Not tested | None | Nightly `valkey-8` |
| Valkey 9.x | Live (CI, nightly) | Live (CI, nightly) | None natively; json, bloom, search with the Docker bundle | CI, nightly `valkey-9` |

Connection options are the same for every server version:

| Option | Live tests | Other tests |
| --- | --- | --- |
| Standalone | Yes, against every server above | Mock sessions |
| Cluster | Valkey 9 cluster on 7001-7003: numbered databases, scans, `MOVED` | Redis cluster routing with `MockRedisClient` only |
| Sentinel | Redis Sentinel on 26394 watching a primary and replica on 6394-6395: discovery, primary resolution, sessions, failover | Parser tests and a failover against scripted fake servers |
| SSH tunnel | No | Unit tests of the `ssh` arguments and port selection |
| TLS | No real TLS server | An in-process Network framework TLS server: CA checks, host name checks, client certificates |

## Modules

Keystrand reads `MODULE LIST` on connect. A feature whose module is missing
shows an unavailable-module panel, and its commands drop out of completion
lists.

| Module | `MODULE LIST` names | Used by |
| --- | --- | --- |
| RediSearch (Redis Query Engine) | `search`, `ft` | Browser search by values, Vector Search, `FT.*` in Workbench and the CLI |
| RedisJSON | `ReJSON` | JSON keys: view, edit, create |
| RedisTimeSeries | `timeseries` | Time series keys and charts |
| RedisBloom | `bf` | `BF.*`, `CF.*`, `CMS.*`, `TOPK.*`, `TDIGEST.*` commands |
| Vector sets | Built into Redis 8, not a module | Vector set keys, `VSIM` and the other `V*` commands |
| valkey-json | `json` | JSON keys, always with JSONPath |
| valkey-bloom | `bf` | `BF.*` commands only |
| valkey-search | `search` | Browser search and Vector Search, without match-all queries, `FT.EXPLAIN` or `FT.PROFILE` |
| RedisGraph | `graph` | Command reference only: Command Helper documents its commands, and graph keys show their size |

Homebrew's `redis` formula ships the RediSearch, RedisJSON, RedisTimeSeries
and RedisBloom modules, and `scripts/test-servers.sh native` loads them.
Homebrew's `valkey` formula has no modules. The Docker image
`valkey/valkey-bundle:9` has valkey-json, valkey-bloom and valkey-search.

## Version-gated features

`DatabaseCapabilities` in `Sources/RedisCore/Models/ServerInfo.swift` holds
the gates. Valkey reports `redis_version:7.2.4` for compatibility and its
real version in `valkey_version`. A gate that compares `redis_version`
treats every Valkey as Redis 7.2.4; the other gates compare the real version
of one server family. Until the server version is known, completion lists
offer every command.

| Feature | Redis | Valkey |
| --- | --- | --- |
| Create stream keys | 5.0 | Yes |
| Browser type filter (`SCAN ... TYPE`) | 6.0 | Yes |
| Edit a string and keep its TTL (`SET ... KEEPTTL`); older servers re-apply the TTL with `EXPIRE` | 6.0 | Yes |
| Remove several list elements at once (`LPOP`/`RPOP` with a count) | 6.2 | Yes |
| Page stream pending entries with an exclusive start | 6.2 | Yes |
| Sharded Pub/Sub warning on clusters | 7.0 | Yes |
| Vector Search without the upgrade notice | 7.2 | Yes |
| Hash field TTLs (`HEXPIRE`, `HTTL`) | 7.4 | 9.0 |
| Edit a hash value and keep its field TTL (`HSETEX ... KEEPTTL`); Redis 7.4 restores the expire time instead | 8.0 | 9.0 |
| Vector sets (`V*` commands, vector set keys) | 8.0 | No |
| `VSIM ... WITHATTRIBS` | 8.0.3 | No |
| Array keys | When `COMMAND INFO ARGET` answers, else 8.8 | When `COMMAND INFO ARGET` answers |
| Numbered databases in cluster mode | No | 9.0 |
| `DELIFEQ`, `CLUSTERSCAN`, `COMMANDLOG` in completion lists | No | Any version |

Module versions gate a few more features:

| Feature | Requirement |
| --- | --- |
| Browser search by values and Vector Search | RediSearch 2.0 or later; any valkey-search |
| `FLOAT16` and `BFLOAT16` vector fields | RediSearch 2.10 or later |
| JSONPath (`$`) paths | RedisJSON 2 or later, or valkey-json; RedisJSON 1 uses legacy `.` paths |
| Match-all query `*`, `FT.EXPLAIN`, `FT.PROFILE` | RediSearch only |
| Search indexes only in DB 0 | RediSearch only; valkey-search indexes any database |

## Nightly matrix

`.github/workflows/nightly.yml` runs the whole test suite once a day, and on
demand, against each entry below. GitHub's macOS runners have no Docker, so
every entry runs native processes through `scripts/test-servers.sh native`.

| Entry | Server | Source | Modules | Servers started |
| --- | --- | --- | --- | --- |
| `redis-7.2` | Redis 7.2.16 | Source build | None | Redis on 6390, Sentinel group on 6394, 6395 and 26394 |
| `redis-8` | Redis 8.x, newest | Homebrew `redis` | Search, JSON, TimeSeries, Bloom, vector sets | Redis on 6390, Sentinel group on 6394, 6395 and 26394 |
| `valkey-8` | Valkey 8.1.10 | Source build | None | Valkey on 6392 |
| `valkey-9` | Valkey 9.x, newest | Homebrew `valkey` | None | Valkey on 6392, cluster on 7001-7003 |

Homebrew has only the newest Redis and Valkey (`redis@8.2` exists but has no
modules, and there is no `redis@7.2` or `valkey@8`), so the older entries
are built from source by `scripts/build-server.sh`. It downloads the release
tag's GitHub tarball, checks the SHA-256 pinned in the workflow, and builds
the core server with `MALLOC=libc` in under a minute. Module builds
(`BUILD_WITH_MODULES=yes`) need Rust, CMake and more than ten minutes per
entry, so source-built servers have no modules. The workflow caches the
binaries in `.build/servers`.

```bash
scripts/build-server.sh redis 7.2.16    # prints the SHA-256 to pin
scripts/build-server.sh valkey 8.1.10 --sha256 <hash>
```

The script prints `KEYSTRAND_REDIS_SERVER` and `KEYSTRAND_REDIS_CLI` (or the
Valkey pair) as `KEY=value` lines for `scripts/test-servers.sh native`. Set
`KEYSTRAND_REDIS_MODULES=""` with a source-built Redis.

The tests run without `KEYSTRAND_REQUIRE_LIVE=1`, because that flag would
fail every test of the servers an entry does not start. Tests for absent
servers and modules skip. A "Check the servers" step fails the job when a
started server does not answer `PING`, so a dead server cannot turn the run
into skips. The "Server version" step prints `--version` of the server and
fails when it is not the entry's version.

## Known gaps

- No Valkey modules in native runs. Homebrew has no `valkey-json`,
  `valkey-bloom` or `valkey-search`, so valkey-json, valkey-bloom and
  valkey-search are tested only with the Docker `valkey/valkey-bundle:9`
  image on a developer's machine.
- `LiveValkeyCoreTests` expects Valkey 9.1.2 exactly. It needs valkey-json
  and valkey-search, so it skips in native runs, but it fails against a
  bundle image with another Valkey version.
- The live suites were written against Redis 8.10 and Valkey 9.1.2. Tests
  that use newer commands without a version gate, such as the hash field TTL
  tests, are expected to fail on `redis-7.2` and `valkey-8`. Those failures
  are what the nightly reports; CI does not run these versions.
- `valkey-8` starts no cluster. `scripts/test-servers.sh` starts cluster
  nodes with `--cluster-databases`, which Valkey 8 does not accept, and the
  cluster tests rely on numbered databases in cluster mode.
- Redis cluster and SSH tunnels have no live tests. Sentinel is tested live
  only with Redis, not with Valkey Sentinel. TLS is tested only against an
  in-process TLS server, not a Redis or Valkey TLS port.
- Redis 6 and 7.0 have no live tests.
- GitHub can regenerate a tag's source tarball. If a pinned SHA-256 stops
  matching, rerun `scripts/build-server.sh` without `--sha256`, check the
  release, and pin the new hash.
