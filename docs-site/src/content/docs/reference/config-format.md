---
title: Config format
description: The declarative source config shape. The five operations, and the advanced features.
---

A source config is one JSON object. This page is the map;
[`docs/extensions.md`](https://github.com/zenbaku/koni_dojo/blob/main/docs/extensions.md)
is the exhaustive field-by-field reference.

## The shape

```json
{
  "id": "example",
  "name": "Example",
  "lang": "en",
  "baseUrl": "https://example.com",
  "headers": { "Referer": "https://example.com/" },

  "popular": {
    "path": "/popular?page={page}",
    "itemSelector": "div.item",
    "titleSelector": "a.title",
    "urlSelector": "a.title", "urlAttr": "href",
    "coverSelector": "img", "coverAttr": "src",
    "nextPageSelector": "a.next"
  },
  "search":  { "path": "/search?q={query}&page={page}", "itemSelector": "div.item", "titleSelector": "a.title" },
  "details": { "titleSelector": "h1", "authorSelector": "span.author", "descriptionSelector": "p.summary", "coverSelector": "img.cover" },
  "chapters":{ "itemSelector": "li.chapter", "nameSelector": "a", "urlSelector": "a", "urlAttr": "href", "dateSelector": "span.date", "reversed": true },
  "pages":   { "imageSelector": "div.reader img", "imageAttr": "src" }
}
```

## The rules that trip people up

- `{page}` and `{query}` are substituted into `path`.
- Scraped URLs (manga, covers, pages) may be relative or protocol-relative;
  they're resolved against `baseUrl`.
- For any `*Selector` / `*Attr` pair, an **empty attr means "use the element's
  text"** (the default for titles and chapter names). An **empty selector means
  "the item element itself"**, handy when the list item *is* the link.
- `chapters.reversed: true` (default) = the site lists newest-first; the engine
  flips them into reading order.
- `pages.imageAttr` falls back to `data-src` for lazy readers; the engine also
  trims whitespace in attribute values.
- `search` is optional.

## Advanced features

All optional, all composable with the basic shape above (full details in
`extensions.md`):

| Feature | For |
|---|---|
| **Cover chains**: an ordered list of `{selector, attr}` | try `data-src` then `src`, etc. |
| **Label rows** (`details.rows`) | author / status / genres from label→value tables |
| **Offset pagination** | "API-as-HTML" listings paged by offset |
| **Rate limiting** (`rateLimit`) | polite request pacing |
| **Query sanitization** | normalize search terms |
| **Derived request URLs** (`request.pattern`/`replace`/`suffix`) | rewrite a URL for a chapters/pages call |
| **POST requests** | Madara `ajax/chapters/`, form-encoded bodies |
| **Script-blob pages** | read images from `ts_reader.run({…})` |
| **`steps:` pipelines** | full control: two-phase lookups, cross-format, `js` steps |

## The API dialect

Sites with a JSON API use `"type": "api"`, the same declarative idea with
**JSON paths + templates** where the HTML dialect has CSS selectors. A
fictional but fully-worked reference example lives in this repo at
`test/fixtures/workspace/extensions/delta.json`. See the "API sources"
section of `extensions.md`.

## Validation

`task build-repo` parses every config through the real engine **and** does a
lossless round-trip (`fromJson` → `toJson` → compare). Anything the runtime
can't faithfully represent fails the build: a typo never ships silently.
