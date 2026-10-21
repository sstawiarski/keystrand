# Third-party notices

Keystrand's code and original content use the MIT License in `LICENSE`.
Original content includes Workbench tutorials, Database Analysis tips, and
Browser and Vector Search sample data. The project writes this content or
generates it with its own scripts.

The command specification files are the repository's only third-party content.
They contain third-party material or data generated from it. Their licenses
are separate from the MIT License. `LICENSES/` contains the full license texts.
All command specification files live in `Sources/CommandSpecs/Resources/Commands/`.

The app bundle includes this file, `LICENSE`, and `LICENSES/` in
`Keystrand.app/Contents/Resources`. Choose **Help > Acknowledgements** to read
them. **About Keystrand** names the applicable licenses.

## Core command specifications in `redis.json`

`scripts/make-redis-commands.py` generates `redis.json` from the four sources
in this section. The script uses the MIT License. It reads each command's JSON
definition and converts it to the layout of server `COMMAND DOCS` and
`COMMAND INFO` replies. It writes the combined definitions to one file.

### Redis 7.2.4 (BSD-3-Clause)

The source is [Redis 7.2.4 command definitions](https://github.com/redis/redis/tree/7.2.4/src/commands).
Keystrand uses all 370 entries other than the `SENTINEL` commands.
This material uses the BSD 3-Clause License in `LICENSES/BSD-3-Clause-Redis.txt`.

The copyright notice reads as follows:

```text
Copyright (c) 2006-2020, Salvatore Sanfilippo
All rights reserved.
```

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the conditions in
`LICENSES/BSD-3-Clause-Redis.txt` are met. That file also contains the
disclaimer that applies to this material.

### Valkey 9.1.2 (BSD-3-Clause)

The source is [Valkey 9.1.2 command definitions](https://github.com/valkey-io/valkey/tree/9.1.2/src/commands).
Keystrand uses the definitions for the following commands:

- `CLUSTERSCAN`.
- `COMMANDLOG`, `COMMANDLOG GET`, `COMMANDLOG HELP`, `COMMANDLOG LEN`, and
  `COMMANDLOG RESET`.
- `DELIFEQ`.
- `HSETEX`.

Valkey's `HSETEX` argument list includes Redis's arguments and adds the
`NX | XX` key condition to the `FNX | FXX` field condition and expiration
options. Keystrand therefore uses Valkey's definition, including its summary
and `since` version.

This material uses the BSD 3-Clause License in `LICENSES/BSD-3-Clause-Valkey.txt`.
The copyright notice reads as follows:

```text
Copyright (c) 2024-present, Valkey contributors
Copyright (c) 2006-2020, Redis Ltd.
All rights reserved.
```

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the conditions in
`LICENSES/BSD-3-Clause-Valkey.txt` are met. That file also contains the
disclaimer that applies to this material.

### Redis 8.4.7 core commands (RSALv2)

The source is [Redis 8.4.7 command definitions](https://github.com/redis/redis/tree/8.4.7/src/commands).
Keystrand uses the following definitions so Command Helper reports Redis
`since` versions:

- `HEXPIRE`, `HEXPIREAT`, and `HEXPIRETIME`.
- `HGETDEL`, `HGETEX`, and `HPERSIST`.
- `HPEXPIRE`, `HPEXPIREAT`, and `HPEXPIRETIME`.
- `HPTTL`, `HTTL`, and `MSETEX`.

Copyright Redis Ltd. Redis 8 is available under your choice of the Redis Source
Available License 2.0 (RSALv2), Server Side Public License v1 (SSPLv1), or GNU
Affero General Public License v3 (AGPLv3). Keystrand uses this material under
RSALv2. Read the full text in `LICENSES/RSALv2-redis.txt`.

### Redis 8.4.7 vector sets (RSALv2)

The source is [Redis 8.4.7 vector set command definitions](https://github.com/redis/redis/blob/8.4.7/modules/vector-sets/commands.json).
Keystrand uses these definitions:

- `VADD`, `VCARD`, `VDIM`, and `VEMB`.
- `VGETATTR`, `VINFO`, `VISMEMBER`, and `VLINKS`.
- `VRANDMEMBER`, `VRANGE`, `VREM`, `VSETATTR`, and `VSIM`.

Copyright Redis Ltd. Keystrand uses this material under RSALv2 on the same terms
as the Redis 8.4.7 core commands. Read the full text in `LICENSES/RSALv2-redis.txt`.

### Modification notice (RSALv2)

Keystrand changes the Redis 8.4.7 material in `redis.json` as follows:

- The script converts each entry from the server's command-definition layout
  to the layout of `COMMAND DOCS` and `COMMAND INFO` replies. It converts flags
  to lowercase or Boolean values. It adds implied ACL categories and display
  text. It converts argument names to lowercase and tokens to uppercase.
  It removes fields absent from the replies.
- The script adds a key spec index to each vector set entry's first key
  argument. It adds the key spec that the server reports for a module command.
  It also adds `module` to the command flags.
- The script restructures `VADD` and `VSIM` arguments. `FP32` takes a `vector`
  value. `VALUES` takes a count followed by that number of doubles.
  For `VSIM`, `ELE` takes an `element` value.

## Redis module command specifications (RSALv2)

The module files are unmodified, byte-for-byte copies of `commands.json` at the
tag or commit pinned in `scripts/command-sources.lock`.

Copyright Redis Ltd. Each module is available under your choice of RSALv2,
SSPLv1, or AGPLv3. Keystrand uses this material under the Redis Source Available
License 2.0. Read the full text in `LICENSES/RSALv2.txt`.

The following table lists each file and its source:

| File | Source |
| --- | --- |
| `redisbloom.json` | <https://github.com/RedisBloom/RedisBloom/blob/v8.11.90/commands.json> |
| `redisearch.json` | <https://github.com/RediSearch/RediSearch/blob/3635ada5fed6aec58eba05c606ff3bc641b41c08/commands.json> |
| `redisgraph.json` | <https://github.com/RedisGraph/RedisGraph/blob/v2.12.10/commands.json> |
| `redisjson.json` | <https://github.com/RedisJSON/RedisJSON/blob/v8.11.90/commands.json> |
| `redistimeseries.json` | <https://github.com/RedisTimeSeries/RedisTimeSeries/blob/v8.11.90/commands.json> |

## Trademarks

Redis is a registered trademark of Redis Ltd. RediSearch, RedisJSON, RedisBloom,
RedisTimeSeries, and RedisGraph are trademarks of Redis Ltd. Valkey is a
trademark of LF Projects, LLC.

Keystrand is not affiliated with or endorsed by Redis Ltd. or the Valkey
project. The project uses these names only to identify software that
Keystrand connects to.
