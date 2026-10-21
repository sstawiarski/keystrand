# Probabilistic data structures

> Bloom filters, Cuckoo filters, Count-min sketch, and Top-K require the
> probabilistic data types. Redis 8 and Redis Stack include these data types.
> On other servers, load the RedisBloom module. HyperLogLog belongs to core
> Redis and needs no module.

Probabilistic data structures answer questions about large collections with
less memory than exact structures. Their answers are estimates. For structures
with configurable error rates, choose the rate before you add data. Use them
if an exact answer needs more memory than the application can justify.

Choose a structure based on the question you need to answer:

| Structure | Question | Typical use |
| --- | --- | --- |
| HyperLogLog | How many distinct items exist? | Unique visitors |
| Bloom filter | Is an item present? | Check known usernames or URLs |
| Cuckoo filter | Is an item present, with support for deletion? | Allow and block lists |
| Count-min sketch | How often does an item occur? | Event frequency |
| Top-K | Which items occur most often? | Trending searches |

## Count distinct items with HyperLogLog

A HyperLogLog estimates the number of distinct items with at most 12 KB per
key and a standard error below 1%. Adding an item again leaves the count
unchanged. `PFMERGE` combines several counters.

```redis:[run_confirmation=true] Count unique visitors per day
PFADD tutorial:visitors:mon ada ben cy dee ada ben
PFADD tutorial:visitors:tue ben eve fay ben
PFCOUNT tutorial:visitors:mon
PFCOUNT tutorial:visitors:mon tutorial:visitors:tue
PFMERGE tutorial:visitors:week tutorial:visitors:mon tutorial:visitors:tue
PFCOUNT tutorial:visitors:week
```

## Check membership with a Bloom filter

A Bloom filter reports an item as definitely absent or probably present.
It never reports an added item as absent. False positives occur at about the
configured rate. `BF.RESERVE` takes that error rate and the expected item count.

```redis:[run_confirmation=true] Check usernames against a filter
BF.RESERVE tutorial:usernames 0.001 10000
BF.MADD tutorial:usernames ada ben cy
BF.EXISTS tutorial:usernames ada
BF.MEXISTS tutorial:usernames ben zed
BF.INFO tutorial:usernames
```

## Remove items with a Cuckoo filter

A Cuckoo filter checks membership like a Bloom filter. It also supports deletion
at a similar memory cost.

```redis:[run_confirmation=true] Add, delete, and check
CF.RESERVE tutorial:blocked 1000
CF.ADD tutorial:blocked 203.0.113.7
CF.ADD tutorial:blocked 198.51.100.23
CF.EXISTS tutorial:blocked 203.0.113.7
CF.DEL tutorial:blocked 203.0.113.7
CF.EXISTS tutorial:blocked 203.0.113.7
```

## Estimate frequencies with a Count-min sketch

A Count-min sketch estimates the count for each item. An estimate can exceed
the actual count but cannot fall below it. `CMS.INITBYPROB` sizes the sketch
from an error and a probability.

```redis:[run_confirmation=true] Count page events
CMS.INITBYPROB tutorial:events 0.001 0.01
CMS.INCRBY tutorial:events home 5 pricing 2 docs 9
CMS.INCRBY tutorial:events home 1
CMS.QUERY tutorial:events home docs signup
```

## Track the most frequent items with Top-K

Top-K tracks the K most frequent items in a stream of events.

```redis:[run_confirmation=true] Find the top three searches
TOPK.RESERVE tutorial:searches 3
TOPK.ADD tutorial:searches redis json redis vector redis json search
TOPK.LIST tutorial:searches WITHCOUNT
TOPK.QUERY tutorial:searches redis search
```

## Clean up

Run this block to delete the keys that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:visitors:mon tutorial:visitors:tue tutorial:visitors:week
UNLINK tutorial:usernames tutorial:blocked tutorial:events tutorial:searches
```

## Further reading

Use these references to continue:

- [Probabilistic data types](https://redis.io/docs/latest/develop/data-types/probabilistic/)
- [HyperLogLog](https://redis.io/docs/latest/develop/data-types/probabilistic/hyperloglogs/)
- [Bloom filter](https://redis.io/docs/latest/develop/data-types/probabilistic/bloom-filter/)
- [Indexes and queries](../sq/indexing.md), the next tutorial
