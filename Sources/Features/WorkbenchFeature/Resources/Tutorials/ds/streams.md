# Streams

A stream stores an append-only log. Each entry contains an ID and field-value
pairs. Use streams for event sourcing, activity feeds, and sensor data.
Consumer groups let several workers share entries from one stream.

## Append entries

`XADD` appends an entry. Each ID contains a time in milliseconds and a sequence
number. Each new ID must exceed the previous ID. This page uses fixed IDs so
later commands can refer to them. In an application, pass `*` to let Redis
create an ID from the current time.

```redis:[run_confirmation=true] Log three orders
XADD tutorial:orders 1735725600000-0 order_id 5001 item espresso qty 2
XADD tutorial:orders 1735725660000-0 order_id 5002 item latte qty 1
XADD tutorial:orders 1735725720000-0 order_id 5003 item croissant qty 3
XLEN tutorial:orders
```

## Read a range

`XRANGE` reads entries between two IDs, starting with the oldest. `XREVRANGE`
starts with the newest. `-` and `+` specify the smallest and largest possible
IDs. To read the next page, prefix the last ID you received with `(`. This
excludes that ID from the next range.

```redis Read the log
XRANGE tutorial:orders - +
XREVRANGE tutorial:orders + - COUNT 1
XRANGE tutorial:orders - + COUNT 2
XRANGE tutorial:orders (1735725660000-0 + COUNT 2
```

## Share work with a consumer group

A consumer group tracks which entries it delivers to each consumer.
`XGROUP CREATE` with ID `0` starts at the beginning of the stream.
`XREADGROUP` with ID `>` requests entries that no consumer in the group
received yet.

```redis:[run_confirmation=true] Create a group and read as two baristas
XGROUP CREATE tutorial:orders baristas 0
XREADGROUP GROUP baristas alice COUNT 2 STREAMS tutorial:orders >
XREADGROUP GROUP baristas bob COUNT 2 STREAMS tutorial:orders >
```

Alice receives the first two orders. Bob receives the third order.
Within the group, Redis delivers each new entry to only one consumer.

## Acknowledge and recover work

A delivered entry remains pending until a consumer acknowledges it with `XACK`.
`XPENDING` lists pending entries, including work from a consumer that crashed.
`XCLAIM` assigns a pending entry to another consumer.

```redis:[run_confirmation=true] Finish, reassign, and inspect orders
XACK tutorial:orders baristas 1735725600000-0
XPENDING tutorial:orders baristas - + 10
XCLAIM tutorial:orders baristas bob 0 1735725660000-0
XACK tutorial:orders baristas 1735725660000-0 1735725720000-0
XPENDING tutorial:orders baristas
XINFO GROUPS tutorial:orders
```

The `0` in `XCLAIM` sets the minimum idle time in milliseconds. In a recovery
job, use a larger value to take only entries that remain idle for that period.
`XAUTOCLAIM` scans and claims entries in one command.

## Cap the length

A stream grows until you trim it. `MAXLEN` keeps the newest entries. Add `~`
to trim whole internal nodes at a lower cost. This can keep some extra entries.
`XADD` accepts the same option to trim while it appends.

```redis:[run_confirmation=true] Append with a cap, then keep the newest two
XADD tutorial:orders MAXLEN ~ 1000 * order_id 5004 item mocha qty 1
XTRIM tutorial:orders MAXLEN 2
XLEN tutorial:orders
XINFO STREAM tutorial:orders
```

## Clean up

Run this block to delete the stream and its consumer groups.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:orders
```

## Further reading

Use these references to continue:

- [Streams](https://redis.io/docs/latest/develop/data-types/streams/)
- [XREADGROUP command](https://redis.io/docs/latest/commands/xreadgroup/)
- [JSON](json.md), the next tutorial
