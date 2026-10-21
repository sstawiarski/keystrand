# Strings

A Redis string stores up to 512 MB of bytes under one key. Redis treats text,
numbers, JSON blobs, and serialized images as strings. Use strings for caches,
counters, flags, and tokens that expire.

Every key on this page starts with `tutorial:`. Use the Browser filter
`tutorial:*` to find these keys. The cleanup block deletes them.

## Store and read a value

`SET` writes a value. It replaces the existing key regardless of its type.
`GET` reads the value.

```redis:[run_confirmation=true] Write and read a greeting
SET tutorial:greeting "Hello, Redis"
GET tutorial:greeting
STRLEN tutorial:greeting
APPEND tutorial:greeting "!"
GET tutorial:greeting
```

## Conditional writes

`NX` writes only if the key does not exist. `XX` writes only if the key exists.
Use `NX` to claim a lock or a unique name. Add `GET` to `SET` to return the
previous value in the same round trip.

```redis:[run_confirmation=true] Write only when absent or present
SET tutorial:lock:report "worker-1" NX
SET tutorial:lock:report "worker-2" NX
SET tutorial:lock:report "worker-3" XX GET
GET tutorial:lock:report
```

The second command returns nil because the key exists. The third command
replaces the value and returns the previous owner.

## Counters

If a string holds an integer, `INCR`, `INCRBY`, and `DECR` change it atomically
on the server. Concurrent increments from two clients preserve both updates.
Redis treats a missing key as 0.

```redis:[run_confirmation=true] Count page views
INCR tutorial:views:home
INCRBY tutorial:views:home 10
DECR tutorial:views:home
INCRBYFLOAT tutorial:price:coffee 3.25
GET tutorial:views:home
```

## Expiring keys

A key can have a time to live (TTL). Redis deletes the key when its TTL expires.
Use a TTL for sessions, one-time codes, and cache entries. `EX` sets the TTL in
seconds. `PX` sets it in milliseconds. `TTL` reports the remaining seconds or
-1 if the key has no TTL.

```redis:[run_confirmation=true] Create a session that expires
SET tutorial:session:a81f "user:1001" EX 300
TTL tutorial:session:a81f
EXPIRE tutorial:session:a81f 600
TTL tutorial:session:a81f
PERSIST tutorial:session:a81f
TTL tutorial:session:a81f
```

## Read and write several keys

`MSET` writes several keys in one command. `MGET` reads several keys in one
command. Both reduce round trips. `GETRANGE` returns part of a value by byte offset.

```redis:[run_confirmation=true] Batch reads and writes
MSET tutorial:city:1 "Lisbon" tutorial:city:2 "Osaka" tutorial:city:3 "Quito"
MGET tutorial:city:1 tutorial:city:2 tutorial:city:3 tutorial:city:4
GETRANGE tutorial:city:2 0 2
```

`MGET` returns nil in the position for the missing key `tutorial:city:4`.

## Clean up

Run this block to delete the keys that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:greeting tutorial:lock:report tutorial:views:home
UNLINK tutorial:price:coffee
UNLINK tutorial:session:a81f tutorial:city:1 tutorial:city:2 tutorial:city:3
```

## Further reading

Use these references to continue:

- [Strings](https://redis.io/docs/latest/develop/data-types/strings/)
- [SET command](https://redis.io/docs/latest/commands/set/)
- [Hashes](hashes.md), the next tutorial
