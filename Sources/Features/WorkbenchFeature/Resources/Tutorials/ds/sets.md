# Sets and sorted sets

A set stores unique strings without an order. Adding the same member twice
leaves the set unchanged. Membership checks stay fast as the set grows.
A sorted set also stores unique members. It assigns each member a numeric score
and orders the members by score.

## Unique members in sets

`SADD` returns the number of new members. `SISMEMBER` checks one member.
`SMISMEMBER` checks several members. `SMEMBERS` returns every member without
a defined order.

```redis:[run_confirmation=true] Tag two articles
SADD tutorial:tags:article:1 redis caching performance
SADD tutorial:tags:article:2 redis queues performance python
SADD tutorial:tags:article:1 redis
SCARD tutorial:tags:article:1
SISMEMBER tutorial:tags:article:1 caching
SMISMEMBER tutorial:tags:article:2 caching python
SMEMBERS tutorial:tags:article:2
```

## Combine sets

Redis supports these set operations on the server:

- `SINTER` returns the members present in every set.
- `SUNION` returns the members present in any set.
- `SDIFF` returns the members of the first set that are absent from the other sets.

The `STORE` variants save the result to a new key.

```redis:[run_confirmation=true] Compare the two tag sets
SINTER tutorial:tags:article:1 tutorial:tags:article:2
SUNION tutorial:tags:article:1 tutorial:tags:article:2
SDIFF tutorial:tags:article:2 tutorial:tags:article:1
SINTERSTORE tutorial:tags:shared tutorial:tags:article:1 tutorial:tags:article:2
SRANDMEMBER tutorial:tags:shared
```

## A leaderboard with sorted sets

`ZADD` takes score-member pairs. `ZINCRBY` atomically increases a member's score.
Use these commands for points or votes. Redis orders members with equal scores
by name.

```redis:[run_confirmation=true] Record game scores
ZADD tutorial:leaderboard 1200 "nova" 950 "orbit" 1430 "pixel" 800 "quark"
ZINCRBY tutorial:leaderboard 300 "orbit"
ZSCORE tutorial:leaderboard orbit
ZCARD tutorial:leaderboard
```

## Rank and range queries

`ZRANGE` reads members by position. Add `BYSCORE` to read by score or `REV` to
read the highest values first. `ZRANK` and `ZREVRANK` return a member's position
in their respective orders, starting at 0.

```redis Read the leaderboard
ZRANGE tutorial:leaderboard 0 2 REV WITHSCORES
ZREVRANK tutorial:leaderboard orbit
ZRANGE tutorial:leaderboard 1000 1300 BYSCORE WITHSCORES
ZCOUNT tutorial:leaderboard 1000 +inf
```

`-inf` and `+inf` specify unbounded scores. Put `(` before a score to exclude
that bound, as in `(1000`.

## Remove members

Use these commands to remove sorted set members:

- `ZREM` removes named members.
- `ZPOPMIN` removes and returns the members with the lowest scores.
- `ZPOPMAX` removes and returns the members with the highest scores.
- `ZREMRANGEBYSCORE` removes a score range. If scores represent time, use it
  to remove entries older than a timestamp.

```redis:[run_confirmation=true] Trim the leaderboard
ZPOPMIN tutorial:leaderboard
ZREMRANGEBYSCORE tutorial:leaderboard -inf (1000
ZRANGE tutorial:leaderboard 0 -1 WITHSCORES
```

## Clean up

Run this block to delete the keys that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:tags:article:1 tutorial:tags:article:2
UNLINK tutorial:tags:shared tutorial:leaderboard
```

## Further reading

Use these references to continue:

- [Sets](https://redis.io/docs/latest/develop/data-types/sets/)
- [Sorted sets](https://redis.io/docs/latest/develop/data-types/sorted-sets/)
- [Streams](streams.md), the next tutorial
