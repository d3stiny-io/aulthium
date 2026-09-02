# betterwebsearch

Upgrades the stock `WEB_SEARCH` tool with real article text instead of
search-engine snippets.

## What it does

The built-in `WEB_SEARCH` tool scrapes DuckDuckGo's results page and hands
the AI a title plus a one-line snippet per hit. That's often not enough
to actually answer a real-time question correctly — snippets get cut
mid-sentence, miss the number/date/fact that mattered, or are just
marketing copy pulled from a meta description.

`betterwebsearch` does one extra hop: for the top N results, it fetches
the actual page and uses BeautifulSoup to extract the real body text
(not nav bars, cookie banners, ads, or scripts), then hands back a richer
per-result digest:

```
TITLE
URL
Published/updated date (if the page exposes one)
~1200 chars of actual extracted article text
---
```

## Requirements

BeautifulSoup is a **hard requirement** here (unlike `webchat`'s optional
regex fallback) — a regex can approximate "grab the two DuckDuckGo result
cells," but it can't reliably approximate "find the main content block in
an arbitrary page and discard the boilerplate around it."

```bash
pip install beautifulsoup4 --break-system-packages
```

## Usage

**As a hook** (default): this plugin registers on the `web_search` hook
with `autostart: true`, so once enabled it transparently upgrades every
`WEB_SEARCH` call the model makes — no extra action needed.

**As a standalone plugin:**

```
t> plugin run betterwebsearch "your query"
```

Runs the search and prints the digest to stdout.

**As a library**, from another plugin:

```python
from betterwebsearch import better_web_search

results = better_web_search("your query")
```

Useful if you're writing a plugin (like `webchat`) that wants a richer
`WEB_SEARCH` result than the snippet-only default.

## Configuration

Set with `t> plugin config betterwebsearch set <key> <value>`:

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `num_results` | `5` | Number of results to fetch full pages for |
| `fetch_workers` | `4` | Parallel page fetches |
| `excerpt_chars` | `1200` | Max characters of extracted body text per result |
| `search_timeout` | `15` | Timeout (seconds) for the initial search request |
| `fetch_timeout` | `10` | Timeout (seconds) per individual page fetch |

Toggle this plugin on/off at the `bws>` prefix (its `toggle_prefix`).

## Permissions

Declares `network` in `plugin.json` — it fetches search results and the
linked pages over HTTP(S). It does not touch the filesystem or shell.
