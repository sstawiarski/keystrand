# Lists

A list stores an ordered sequence of strings. Adding or removing an element at
either end stays fast as the list grows. Use lists for queues, stacks, and feeds
that keep the latest N entries. Access by index in the middle slows as the list grows.

## Push and read

`LPUSH` adds elements to the head, or left end. `RPUSH` adds elements to the
tail, or right end. `LRANGE` reads a range by index. Index 0 identifies the
head. Index -1 identifies the last element. `LRANGE key 0 -1` returns the whole list.

```redis:[run_confirmation=true] Build a list from both ends
RPUSH tutorial:jobs "resize:photo-17" "email:welcome-88"
LPUSH tutorial:jobs "urgent:invoice-3"
RPUSH tutorial:jobs "report:weekly"
LRANGE tutorial:jobs 0 -1
LLEN tutorial:jobs
LINDEX tutorial:jobs 1
```

## Use the list as a queue

Producers push elements to one end. Consumers pop elements from the other end.
With `RPUSH` and `LPOP`, consumers receive the oldest job first. Pass a count
to `LPOP` to take several jobs at once.

```redis:[run_confirmation=true] Take jobs from the head
LPOP tutorial:jobs
LPOP tutorial:jobs 2
LRANGE tutorial:jobs 0 -1
```

Application workers usually use `BLPOP` to wait for an element or a timeout.
This avoids polling.

## Move work between lists

If a worker crashes after it pops a job, the job is lost. `LMOVE` atomically
pops a job from one list and pushes it to another. Keep the job in a processing
list until the worker finishes it. Use `LREM` to remove the completed job.

```redis:[run_confirmation=true] Track jobs that are in progress
RPUSH tutorial:jobs "thumbnail:video-5" "sync:crm"
LMOVE tutorial:jobs tutorial:jobs:processing LEFT RIGHT
LRANGE tutorial:jobs:processing 0 -1
LREM tutorial:jobs:processing 1 "report:weekly"
LRANGE tutorial:jobs:processing 0 -1
```

## Keep only the latest entries

`LTRIM` keeps a specified range of a list. Push new entries before you trim the
list to cap a feed, such as the last five pages a visitor viewed.

```redis:[run_confirmation=true] A capped recent-activity feed
LPUSH tutorial:recent:ada "/home" "/pricing" "/docs" "/blog"
  "/docs/lists" "/contact"
LTRIM tutorial:recent:ada 0 4
LRANGE tutorial:recent:ada 0 -1
LPOS tutorial:recent:ada "/docs"
```

`LPUSH` inserts multiple values in the order you supply them. The last value
becomes the head.

## Edit in place

`LSET` replaces the element at an index. `LINSERT` adds an element before or
after a specified value. Both traverse the list, so use them for short lists.

```redis:[run_confirmation=true] Change elements by position and value
LSET tutorial:recent:ada 0 "/contact-us"
LINSERT tutorial:recent:ada AFTER "/blog" "/blog/archive"
LRANGE tutorial:recent:ada 0 -1
```

## Clean up

Run this block to delete the keys that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:jobs tutorial:jobs:processing tutorial:recent:ada
```

## Further reading

Use these references to continue:

- [Lists](https://redis.io/docs/latest/develop/data-types/lists/)
- [LMOVE command](https://redis.io/docs/latest/commands/lmove/)
- [Sets and sorted sets](sets.md), the next tutorial
