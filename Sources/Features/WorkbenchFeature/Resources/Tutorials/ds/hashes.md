# Hashes

A hash maps field names to string values under one key, like a table row or a
small object. Use hashes for user profiles, product records, and settings.
You can read or change one field without rewriting the other fields.

Redis stores small hashes in a compact encoding. Several small hashes often
use less memory than the same data in separate string keys.

## Create and read a record

`HSET` writes one or more fields and returns the number of new fields.
`HGET` reads one field. `HMGET` reads several fields. `HGETALL` reads all fields
and their values.

```redis:[run_confirmation=true] Create a user profile
HSET tutorial:user:1001 name "Ada" email "ada@example.com" plan "free" logins 0
HGET tutorial:user:1001 name
HMGET tutorial:user:1001 email plan missing_field
HGETALL tutorial:user:1001
```

## Change individual fields

You can update, increment, or remove each field independently. `HSETNX` writes
a field only if it does not exist. Use it to set default values.

```redis:[run_confirmation=true] Update the profile
HSET tutorial:user:1001 plan "pro"
HINCRBY tutorial:user:1001 logins 1
HSETNX tutorial:user:1001 theme "dark"
HSETNX tutorial:user:1001 theme "light"
HDEL tutorial:user:1001 email
HEXISTS tutorial:user:1001 email
HLEN tutorial:user:1001
```

The second `HSETNX` leaves the existing value unchanged, so `theme` remains `dark`.

## Inspect the shape of a hash

`HKEYS` lists field names. `HVALS` lists values. Use `HSCAN` to read a large
hash in pages instead of returning all fields at once.

```redis Look at fields and values
HKEYS tutorial:user:1001
HVALS tutorial:user:1001
HSCAN tutorial:user:1001 0 MATCH l* COUNT 10
HSTRLEN tutorial:user:1001 name
```

## Expire single fields (Redis 7.4 and later)

A TTL normally applies to a whole key. Redis 7.4 and later also support a TTL
for each hash field. A value that expires, such as a one-time code, can share a
hash with permanent fields. `HEXPIRE` takes seconds and a `FIELDS` count.
`HTTL` reports the remaining seconds for each field. It returns -1 if the field
has no TTL or -2 if the field does not exist.

```redis:[run_confirmation=true] Give one field a TTL
HSET tutorial:user:1001 otp "493021"
HEXPIRE tutorial:user:1001 120 FIELDS 1 otp
HTTL tutorial:user:1001 FIELDS 2 otp name
HPERSIST tutorial:user:1001 FIELDS 1 otp
HTTL tutorial:user:1001 FIELDS 1 otp
```

`HPEXPIRE` uses milliseconds. `HEXPIREAT` uses a Unix time. Redis deletes the
key when its last field expires.

## Set and read with a TTL in one step (Redis 8.0 and later)

Redis 8.0 adds three commands for field values and their TTLs:

- `HSETEX` writes fields and sets their TTLs in the same command.
- `HGETEX` reads fields and changes their TTLs in the same command.
- `HGETDEL` reads fields and removes them in the same command. Use it to
  consume a token exactly once.

```redis:[run_confirmation=true] Write, read, and consume a token
HSETEX tutorial:user:1001 EX 60 FIELDS 1 reset_token "c0ffee"
HGETEX tutorial:user:1001 PERSIST FIELDS 1 reset_token
HGETDEL tutorial:user:1001 FIELDS 1 reset_token
HEXISTS tutorial:user:1001 reset_token
```

## Clean up

Run this block to delete the key that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:user:1001
```

## Further reading

Use these references to continue:

- [Hashes](https://redis.io/docs/latest/develop/data-types/hashes/)
- [HEXPIRE command](https://redis.io/docs/latest/commands/hexpire/)
- [Lists](lists.md), the next tutorial
