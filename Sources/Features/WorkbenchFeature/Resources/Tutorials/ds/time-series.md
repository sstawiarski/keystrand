# Time series

> This tutorial requires the time series data type. Redis 8 and Redis Stack
> include this data type. On other servers, load the RedisTimeSeries module.

A time series key stores samples. Each sample pairs a timestamp in milliseconds
with a floating-point value. Redis compresses the samples and orders them by
time. It can downsample, aggregate, or expire samples. Labels let you query
several series at once, such as every sensor in a room.

This page uses fixed timestamps from the morning of January 1, 2025, so repeated
queries return the same results. In an application, pass `*` to use the server's clock.

## Create series with labels

`RETENTION` removes samples older than the specified age, measured from the
newest sample. `LABELS` attaches name-value pairs that you can use in filters.

```redis:[run_confirmation=true] Create two temperature series
TS.CREATE tutorial:temp:kitchen RETENTION 86400000
  LABELS room kitchen kind temperature resolution raw
TS.CREATE tutorial:temp:garden RETENTION 86400000
  LABELS room garden kind temperature resolution raw
TS.INFO tutorial:temp:kitchen
```

## Downsample automatically

Create a compaction rule before you add samples. The rule processes only
samples that arrive after you create it. It writes an aggregate for each time
bucket to another series. In this example, the rule writes an hourly average
of kitchen readings.

```redis:[run_confirmation=true] Add an hourly average rule
TS.CREATE tutorial:temp:kitchen:hourly
  LABELS room kitchen kind temperature resolution 1h
TS.CREATERULE tutorial:temp:kitchen tutorial:temp:kitchen:hourly
  AGGREGATION avg 3600000
```

## Add samples

`TS.ADD` adds one sample. `TS.MADD` adds several samples, which can belong to
different series.

```redis:[run_confirmation=true] Record two hours of readings
TS.MADD tutorial:temp:kitchen 1735689600000 21.5
  tutorial:temp:kitchen 1735690500000 21.9
  tutorial:temp:kitchen 1735691400000 22.4
  tutorial:temp:kitchen 1735692300000 22.8
  tutorial:temp:garden 1735689600000 4.2
  tutorial:temp:garden 1735693200000 3.8
TS.ADD tutorial:temp:kitchen 1735693200000 23.1
TS.ADD tutorial:temp:kitchen 1735695000000 22.0
TS.ADD tutorial:temp:kitchen 1735696800000 21.4
TS.ADD tutorial:temp:garden 1735696800000 3.1
TS.GET tutorial:temp:kitchen
```

## Query a range

`TS.RANGE` returns samples between two timestamps. `-` and `+` specify the
oldest and newest samples. `AGGREGATION` groups samples into buckets. It reduces
each bucket with a function such as `avg`, `min`, `max`, `sum`, or `count`.

```redis Read raw and aggregated values
TS.RANGE tutorial:temp:kitchen - +
TS.RANGE tutorial:temp:kitchen - + AGGREGATION max 3600000
TS.REVRANGE tutorial:temp:kitchen - + COUNT 2
TS.RANGE tutorial:temp:kitchen:hourly - +
```

The hourly series contains only the first two buckets. Redis writes a bucket
when the first sample of the next bucket arrives. The 02:00 bucket remains open.

## Query several series by label

`TS.MRANGE` and `TS.MGET` select series by label filters instead of key names.
`WITHLABELS` includes the labels of each series in the reply. `GROUPBY` with
`REDUCE` combines the selected series.

```redis Compare rooms
TS.MGET FILTER kind=temperature resolution=raw
TS.MRANGE - + WITHLABELS AGGREGATION avg 3600000
  FILTER kind=temperature resolution=raw
TS.MRANGE - + FILTER kind=temperature resolution=raw
  GROUPBY kind REDUCE max
TS.QUERYINDEX room=kitchen
```

## Delete samples

`TS.DEL` removes samples in a time range and returns the number it removes.

```redis:[run_confirmation=true] Remove the first reading
TS.DEL tutorial:temp:kitchen 1735689600000 1735689600000
TS.RANGE tutorial:temp:kitchen - + COUNT 2
```

## Clean up

Run this block to delete the keys that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:temp:kitchen tutorial:temp:kitchen:hourly tutorial:temp:garden
```

## Further reading

Use these references to continue:

- [Time series](https://redis.io/docs/latest/develop/data-types/timeseries/)
- [TS.RANGE command](https://redis.io/docs/latest/commands/ts.range/)
- [Probabilistic data structures](probabilistic.md), the next tutorial
