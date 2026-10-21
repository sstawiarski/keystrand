# JSON

> This tutorial requires the JSON data type. Redis 8 and Redis Stack include
> this data type. On other servers, load the RedisJSON module. Keystrand reports
> missing modules before it runs commands that need them.

The JSON data type stores a JSON document under one key. Read or change part of
the document by path without fetching and rewriting the whole document.
Redis can update numbers and arrays atomically on the server.

Paths use JSONPath syntax. `$` identifies the document root. `$.title`
identifies a field. `$.chapters[0]` identifies the first array element.

## Store a document

`JSON.SET` writes a document or a value at a path in an existing document.
Wrap JSON in single quotes to preserve its double quotes. To split a long
command across lines, start each continuation line with spaces. Keystrand
joins these lines before it sends the command.

```redis:[run_confirmation=true] Store a book
JSON.SET tutorial:book:1 $ '{"title": "Deep Water", "year": 2019,
  "author": {"name": "M. Ito", "country": "JP"},
  "price": 18.5, "tags": ["mystery", "sea"],
  "chapters": [{"title": "Low Tide", "pages": 24},
    {"title": "The Wreck", "pages": 41},
    {"title": "Ashore", "pages": 33}]}'
JSON.TYPE tutorial:book:1 $
```

## Read parts of a document

`JSON.GET` returns values that match one or more paths. For these JSONPath
expressions, each path returns an array because it can match several values.

```redis Read fields and nested values
JSON.GET tutorial:book:1 $.title
JSON.GET tutorial:book:1 $.author.name $.year
JSON.GET tutorial:book:1 $.chapters[*].title
JSON.GET tutorial:book:1 $..pages
JSON.OBJKEYS tutorial:book:1 $.author
```

`$..pages` recursively searches the whole document for every `pages` value.

## Filter arrays

The filter expression `?()` keeps only matching elements. `@` identifies the
element that the filter checks.

```redis Find chapters by length
JSON.GET tutorial:book:1 '$.chapters[?(@.pages > 30)].title'
JSON.GET tutorial:book:1 '$.chapters[?(@.title == "Ashore")]'
JSON.ARRLEN tutorial:book:1 $.chapters
```

## Update in place

Each command in this block changes one part of the document. The other parts
remain unchanged.

```redis:[run_confirmation=true] Change fields, numbers, and arrays
JSON.SET tutorial:book:1 $.price 15.99
JSON.NUMINCRBY tutorial:book:1 $.year 1
JSON.ARRAPPEND tutorial:book:1 $.tags '"bestseller"'
JSON.ARRINSERT tutorial:book:1 $.chapters 0 '{"title":"Prologue","pages":6}'
JSON.STRAPPEND tutorial:book:1 $.title '" (2nd ed.)"'
JSON.DEL tutorial:book:1 $.author.country
JSON.GET tutorial:book:1
```

These commands take JSON values. Enclose a string's double quotes in single
quotes, as in `'"bestseller"'`.

## Work with several documents

`JSON.MSET` writes to several keys in one command. `JSON.MGET` reads the same
path from several keys. To query documents by content, create a Search index.
See [Indexes and queries](../sq/indexing.md).

```redis:[run_confirmation=true] Store and read a second book
JSON.MSET tutorial:book:2 $ '{"title": "Paper Moons", "year": 2021}'
  tutorial:book:1 $.year 2020
JSON.MGET tutorial:book:1 tutorial:book:2 $.title
```

## Clean up

Run this block to delete the keys that this page creates.

```redis:[run_confirmation=true] Delete this page's keys
UNLINK tutorial:book:1 tutorial:book:2
```

## Further reading

Use these references to continue:

- [JSON](https://redis.io/docs/latest/develop/data-types/json/)
- [JSONPath syntax](https://redis.io/docs/latest/develop/data-types/json/path/)
- [Time series](time-series.md), the next tutorial
