# Vector search

> This tutorial requires Redis Search and JSON. Redis 8 and Redis Stack include
> both. On other servers, load the RediSearch and RedisJSON modules. Search
> indexes work only in logical database 0. Connect to database 0 before you run
> the search commands. The vector set examples require Redis 8.0 or later.

A vector is a list of numbers that describes an item. A machine learning model
can produce a vector, called an embedding, from text or an image. Items with
similar meaning have vectors that point in similar directions. Redis indexes
vectors to answer k-nearest-neighbor (KNN) queries, which find the nearest vectors.

Real embeddings contain hundreds of dimensions. This page uses four dimensions
with values from 0 to 1. They describe how sweet, salty, spicy, and sour a dish is.

## Index vectors in JSON documents

A `VECTOR` field takes an algorithm, an attribute count, and the attributes.
The attributes specify the element `TYPE`, dimension count `DIM`, and
`DISTANCE_METRIC`. `FLAT` compares the query with every vector for an exact
result. Use it for small sets. `HNSW` builds a graph for faster searches over
large sets, with a small loss of accuracy.

```redis:[run_confirmation=true] Create a vector index of dishes
FT.CREATE idx:tutorial:dishes ON JSON PREFIX 1 tutorial:dish:
  SCHEMA $.name AS name TEXT $.course AS course TAG
  $.taste AS taste VECTOR FLAT 6 TYPE FLOAT32 DIM 4
  DISTANCE_METRIC COSINE
JSON.SET tutorial:dish:1 $
  '{"name": "Lemon tart", "course": "dessert", "taste": [0.9, 0.1, 0, 0.7]}'
JSON.SET tutorial:dish:2 $
  '{"name": "Chocolate cake", "course": "dessert", "taste": [1, 0.1, 0, 0]}'
JSON.SET tutorial:dish:3 $
  '{"name": "Salted fries", "course": "side", "taste": [0, 1, 0.3, 0]}'
JSON.SET tutorial:dish:4 $
  '{"name": "Green curry", "course": "main", "taste": [0.3, 0.4, 0.9, 0.2]}'
JSON.SET tutorial:dish:5 $ '{"name": "Sweet and sour pork",
  "course": "main", "taste": [0.7, 0.5, 0.1, 0.6]}'
JSON.SET tutorial:dish:6 $
  '{"name": "Kimchi", "course": "side", "taste": [0.1, 0.5, 0.8, 0.7]}'
```

## Find the nearest neighbors

A KNN query takes the query vector as a parameter. JSON documents store vectors
as arrays. The query parameter requires raw bytes of 32-bit little-endian floats.
Client libraries convert the values to bytes for you. Vector queries require
`DIALECT 2` or later.

The string in this block encodes `[1, 0, 0, 0.5]`. These values describe a
sweet dish with some sourness.

```redis Three dishes closest to sweet and a little sour
FT.SEARCH idx:tutorial:dishes "*=>[KNN 3 @taste $q AS distance]"
  PARAMS 2 q "\x00\x00\x80\x3f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x3f"
  SORTBY distance RETURN 2 name distance DIALECT 2
```

With the cosine metric, distance 0 means the vectors point in the same direction.
Larger distances indicate less similarity.

## Combine vectors with filters

The expression before `=>` is an ordinary query. KNN ranks only documents that
match that query. This combination is called hybrid search. A vector range query
returns every vector within a specified distance.

```redis Filtered and range vector queries
FT.SEARCH idx:tutorial:dishes "(@course:{main})=>[KNN 2 @taste $q AS distance]"
  PARAMS 2 q "\x00\x00\x80\x3f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x3f"
  SORTBY distance RETURN 2 name distance DIALECT 2
FT.SEARCH idx:tutorial:dishes
  "@taste:[VECTOR_RANGE 0.13 $q]=>{$YIELD_DISTANCE_AS: distance}"
  PARAMS 2 q "\x00\x00\x80\x3f\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x3f"
  SORTBY distance RETURN 2 name distance DIALECT 2
```

## Vector sets (Redis 8.0 and later)

A vector set is a core data type whose members are vectors. It resembles a sorted
set. Vector sets need no index and accept plain numbers with `VALUES`.
`VSIM` returns the most similar members. Use `SETATTR` to attach JSON attributes.
Use `FILTER` to narrow the search by those attributes.

```redis:[run_confirmation=true] Store tastes in a vector set and query it
VADD tutorial:tastes VALUES 4 0.9 0.1 0 0.7 lemon-tart
  SETATTR '{"course": "dessert"}'
VADD tutorial:tastes VALUES 4 1 0.1 0 0 chocolate-cake
  SETATTR '{"course": "dessert"}'
VADD tutorial:tastes VALUES 4 0.1 0.5 0.8 0.7 kimchi
  SETATTR '{"course": "side"}'
VSIM tutorial:tastes VALUES 4 1 0 0 0.5 WITHSCORES COUNT 2
VSIM tutorial:tastes ELE kimchi WITHSCORES
VSIM tutorial:tastes VALUES 4 0 0 1 1 FILTER '.course == "dessert"'
VCARD tutorial:tastes
```

`VSIM` scores range from 1 for identical vectors to 0 for opposite vectors.
Higher scores indicate greater similarity.

## Clean up

Run this block to remove the index and the keys that this page creates.

```redis:[run_confirmation=true] Drop the index and delete this page's keys
FT.DROPINDEX idx:tutorial:dishes
UNLINK tutorial:dish:1 tutorial:dish:2 tutorial:dish:3 tutorial:dish:4
UNLINK tutorial:dish:5 tutorial:dish:6 tutorial:tastes
```

## Further reading

Use these references to continue:

- [Vector search](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/)
- [Vector sets](https://redis.io/docs/latest/develop/data-types/vector-sets/)
- [VSIM command](https://redis.io/docs/latest/commands/vsim/)
- [Working in Keystrand](../keystrand/workbench.md), the next tutorial
