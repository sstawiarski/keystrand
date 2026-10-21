# Indexes and queries

> This tutorial requires Redis Search. Redis 8 and Redis Stack include Search.
> On other servers, load the RediSearch module. Search indexes work only in
> logical database 0. Connect to database 0 before you run these commands.

Redis Search maintains a secondary index over hashes or JSON documents.
If a key matches the index prefix, Redis indexes each write to that key.
Query the index to find keys by words, tags, numbers, or locations.

## Create an index

`FT.CREATE` names an index and defines its keys and fields. `ON HASH` selects
hashes. `PREFIX` selects key prefixes. `SCHEMA` defines fields with these types:

- `TEXT` fields support full-text search through tokenization. `WEIGHT`
  increases the contribution of a field's matches to the score.
- `TAG` fields store exact values, such as categories separated by commas.
- `NUMERIC` fields support range queries. `SORTABLE` speeds up sorting by a field.
- `GEO` fields store `longitude,latitude` pairs.

Create the index before you add documents. Redis indexes later writes as part
of each write, so you can search the documents immediately.

```redis:[run_confirmation=true] Create an index of cafes
FT.CREATE idx:tutorial:cafes ON HASH PREFIX 1 tutorial:cafe:
  SCHEMA name TEXT WEIGHT 2 description TEXT tags TAG
  rating NUMERIC SORTABLE location GEO
FT._LIST
```

## Add documents

Each hash with the selected prefix becomes a document in the index.

```redis:[run_confirmation=true] Add five cafes in Amsterdam
HSET tutorial:cafe:1 name "Copper Kettle"
  description "Espresso roasted in house, oat milk, and quiet corners"
  tags "espresso,wifi,vegan" rating 4.7 location "4.8897,52.3731"
HSET tutorial:cafe:2 name "Night Owl Coffee"
  description "Filter coffee and board games until late"
  tags "filter,late,wifi" rating 4.2 location "4.9041,52.3676"
HSET tutorial:cafe:3 name "Harbour Roasters"
  description "Single-origin pour-over and pastries by the water"
  tags "filter,pastries,roastery" rating 4.8 location "4.9147,52.3780"
HSET tutorial:cafe:4 name "The Daily Grind"
  description "Quick espresso and sandwiches for commuters"
  tags "espresso,takeaway" rating 3.9 location "4.9003,52.3791"
HSET tutorial:cafe:5 name "Green Leaf Tea Room"
  description "Loose leaf tea, vegan cakes, and a sunny terrace"
  tags "tea,vegan,terrace" rating 4.5 location "4.8790,52.3600"
FT.INFO idx:tutorial:cafes
```

## Full-text search

A bare word searches every `TEXT` field. Stemming lets `roast` match
"roasted". A trailing `*` matches a prefix. Double quotes match an exact
phrase. `@field:` limits a search to one field.

```redis Search by words
FT.SEARCH idx:tutorial:cafes espresso RETURN 1 name
FT.SEARCH idx:tutorial:cafes roast* RETURN 1 name
FT.SEARCH idx:tutorial:cafes '"filter coffee"' RETURN 1 name
FT.SEARCH idx:tutorial:cafes "@name:(tea | grind)" RETURN 1 name
```

## Tags, numbers, and locations

Tag queries match exact values inside braces. `|` accepts any of the listed
values. Numeric ranges use square brackets. Prefix a bound with `(` to exclude
it. Use `-inf` or `+inf` for an unbounded end. A geo filter takes longitude,
latitude, radius, and unit.

```redis Filter by tag, rating, and distance
FT.SEARCH idx:tutorial:cafes "@tags:{vegan}" RETURN 1 name
FT.SEARCH idx:tutorial:cafes "@tags:{late | takeaway}" RETURN 1 name
FT.SEARCH idx:tutorial:cafes "@rating:[(4.5 +inf]" RETURN 2 name rating
FT.SEARCH idx:tutorial:cafes "@location:[4.8897 52.3731 1.5 km]"
  RETURN 1 name
```

## Combine conditions and sort

Terms separated by spaces must all match. `-` excludes a condition.
`|` accepts alternatives. `SORTBY` orders results by a sortable field.
`LIMIT` takes an offset and a count to page through results.

```redis Combine filters
FT.SEARCH idx:tutorial:cafes "@tags:{wifi} @rating:[4 +inf]"
  RETURN 2 name rating
FT.SEARCH idx:tutorial:cafes "espresso -@tags:{takeaway}"
  RETURN 1 name
FT.SEARCH idx:tutorial:cafes "*" SORTBY rating DESC LIMIT 0 3
  RETURN 2 name rating
```

`*` matches every document in the index. Workbench shows search results as a
table. Switch the result view to read the raw reply.

## Clean up

`FT.DROPINDEX` removes only the index. The hashes remain until you delete them.
Run this block to remove the index and the hashes that this page creates.

```redis:[run_confirmation=true] Drop the index and delete this page's keys
FT.DROPINDEX idx:tutorial:cafes
UNLINK tutorial:cafe:1 tutorial:cafe:2 tutorial:cafe:3
UNLINK tutorial:cafe:4 tutorial:cafe:5
```

## Further reading

Use these references to continue:

- [Redis Search](https://redis.io/docs/latest/develop/ai/search-and-query/)
- [Query syntax](https://redis.io/docs/latest/develop/ai/search-and-query/query/)
- [FT.CREATE command](https://redis.io/docs/latest/commands/ft.create/)
- [Aggregations](aggregations.md), the next tutorial
