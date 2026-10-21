# Aggregations

> This tutorial requires Redis Search. Redis 8 and Redis Stack include Search.
> On other servers, load the RediSearch module. Search indexes work only in
> logical database 0. Connect to database 0 before you run these commands.

`FT.AGGREGATE` processes matching documents through a pipeline that groups,
computes, filters, and sorts rows. It supports operations like SQL `GROUP BY`.
`FT.SEARCH` returns matching documents directly. Each aggregation step processes
the previous step's output, so the order matters.

An aggregation pipeline supports these steps:

| Step | Behavior |
| --- | --- |
| `GROUPBY` | Groups rows by one or more fields |
| `REDUCE` | Computes a value per group, such as `COUNT` or `SUM` |
| `APPLY` | Adds a computed field to each row |
| `FILTER` | Keeps rows that match an expression |
| `SORTBY` | Orders rows |
| `LIMIT` | Keeps a range of rows |

## Create an index and sales records

The pipeline reads fields marked `SORTABLE`. This option keeps a copy of each
field's values in the index for fast access.

```redis:[run_confirmation=true] Create an index of coffee shop sales
FT.CREATE idx:tutorial:sales ON HASH PREFIX 1 tutorial:sale:
  SCHEMA product TAG SORTABLE category TAG SORTABLE city TAG SORTABLE
  price NUMERIC SORTABLE qty NUMERIC SORTABLE
HSET tutorial:sale:1 product espresso category coffee city Lisbon
  price 2.5 qty 3
HSET tutorial:sale:2 product latte category coffee city Lisbon
  price 3.5 qty 2
HSET tutorial:sale:3 product croissant category bakery city Lisbon
  price 2 qty 4
HSET tutorial:sale:4 product espresso category coffee city Porto
  price 2.5 qty 5
HSET tutorial:sale:5 product bagel category bakery city Porto
  price 3 qty 2
HSET tutorial:sale:6 product latte category coffee city Porto
  price 3.5 qty 1
HSET tutorial:sale:7 product matcha category tea city Lisbon
  price 3 qty 2
HSET tutorial:sale:8 product croissant category bakery city Porto
  price 2 qty 6
```

## Group and count

`GROUPBY` takes a field count followed by the fields. Each `REDUCE` takes a
function, an argument count, the arguments, and an `AS` name for the result.
The query `*` selects every document.

```redis Sales and units per category
FT.AGGREGATE idx:tutorial:sales *
  GROUPBY 1 @category REDUCE COUNT 0 AS sales
FT.AGGREGATE idx:tutorial:sales *
  GROUPBY 1 @category
  REDUCE SUM 1 @qty AS units
  REDUCE AVG 1 @price AS avg_price
  REDUCE TOLIST 1 @product AS products
```

## Compute values and sort

`APPLY` evaluates an expression for each row. This example computes each sale's
revenue before it groups rows by city. `SORTBY` takes an argument count
followed by fields with optional sort directions.

```redis Revenue per city
FT.AGGREGATE idx:tutorial:sales *
  APPLY "@price * @qty" AS revenue
  GROUPBY 1 @city REDUCE SUM 1 @revenue AS total
  SORTBY 2 @total DESC
```

## Filter groups and combine with a query

`FILTER` after `GROUPBY` keeps only matching groups, like SQL `HAVING`.
The query string filters documents before the pipeline starts. The second
command therefore includes only Porto sales.

```redis Best sellers overall and in Porto
FT.AGGREGATE idx:tutorial:sales *
  GROUPBY 1 @product REDUCE SUM 1 @qty AS units
  FILTER "@units >= 5" SORTBY 2 @units DESC
FT.AGGREGATE idx:tutorial:sales "@city:{Porto}"
  GROUPBY 1 @product REDUCE SUM 1 @qty AS units
  SORTBY 2 @units DESC LIMIT 0 2
```

## Group by more than one field

Grouping by two fields returns one row for each combination present in the data.

```redis Units per city and category
FT.AGGREGATE idx:tutorial:sales *
  GROUPBY 2 @city @category REDUCE SUM 1 @qty AS units
  SORTBY 4 @city ASC @units DESC
```

Other reducers include `MIN`, `MAX`, `COUNT_DISTINCT`, `QUANTILE`, and
`FIRST_VALUE`. `APPLY` also supports string, math, and date functions, such as
`upper()`, `floor()`, and `timefmt()`.

## Clean up

Run this block to remove the index and the keys that this page creates.

```redis:[run_confirmation=true] Drop the index and delete this page's keys
FT.DROPINDEX idx:tutorial:sales
UNLINK tutorial:sale:1 tutorial:sale:2 tutorial:sale:3 tutorial:sale:4
UNLINK tutorial:sale:5 tutorial:sale:6 tutorial:sale:7 tutorial:sale:8
```

## Further reading

Use these references to continue:

- [Aggregations](https://redis.io/docs/latest/develop/ai/search-and-query/advanced-concepts/aggregations/)
- [FT.AGGREGATE command](https://redis.io/docs/latest/commands/ft.aggregate/)
- [Vector search](vectors.md), the next tutorial
