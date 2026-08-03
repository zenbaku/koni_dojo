// A known-good starter config (a fictional site on a real Madara-theme
// shape: the class names below are the theme's own, shared across many
// real sites, not any one site's fingerprint) so "Sample → Run" demonstrates
// the whole loop before you paste your own.
const sampleConfig = '''
{
  "id": "eta",
  "name": "Eta",
  "lang": "en",
  "baseUrl": "https://eta.example",
  "rateLimit": { "requests": 1, "perMs": 1000 },
  "popular": {
    "path": "/manga/page/{page}/?m_orderby=views",
    "itemSelector": "div.page-item-detail",
    "titleSelector": "div.post-title a",
    "urlSelector": "div.post-title a",
    "urlAttr": "href",
    "cover": [
      { "selector": "img", "attr": "data-src" },
      { "selector": "img", "attr": "src" }
    ],
    "nextPageSelector": "div.nav-previous, nav.navigation-ajax, a.nextpostslink"
  },
  "search": {
    "path": "/page/{page}/?s={query}&post_type=wp-manga",
    "itemSelector": "div.c-tabs-item__content",
    "titleSelector": "div.post-title a",
    "urlSelector": "div.post-title a",
    "urlAttr": "href",
    "cover": [
      { "selector": "img", "attr": "data-src" },
      { "selector": "img", "attr": "src" }
    ]
  },
  "details": {
    "titleSelector": "div.post-title h1, #manga-title h1",
    "descriptionSelector": "div.description-summary div.summary__content",
    "cover": [
      { "selector": "div.summary_image img", "attr": "data-src" },
      { "selector": "div.summary_image img", "attr": "src" }
    ],
    "rows": {
      "itemSelector": "div.post-content_item",
      "labelSelector": "div.summary-heading, h5",
      "fields": {
        "author": {
          "label": ["Author"],
          "valueSelector": "div.summary-content a, div.author-content a",
          "join": ", "
        },
        "genres": {
          "label": ["Genre", "Genres"],
          "valueSelector": "div.genres-content a, div.summary-content a"
        },
        "status": {
          "label": ["Status"],
          "valueSelector": "div.summary-content"
        }
      }
    },
    "statusMap": {
      "ongoing": "ongoing",
      "completed": "completed",
      "on hold": "hiatus"
    }
  },
  "chapters": {
    "request": { "suffix": "ajax/chapters/", "method": "POST" },
    "itemSelector": "li.wp-manga-chapter",
    "nameSelector": "a",
    "urlSelector": "a",
    "urlAttr": "href",
    "dateSelector": "span.chapter-release-date i",
    "reversed": true
  },
  "pages": {
    "imageSelector": "div.page-break img, div.reading-content img",
    "imageAttr": "src"
  }
}
''';
