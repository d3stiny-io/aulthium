"""
Aulthium plugin: better-websearch

Upgrades the stock WEB_SEARCH tool. The built-in version that only scrapes
DuckDuckGo's *results page* and hands the AI a title + one-line snippet
per hit. That's often not enough for the AI to actually answer a
real-time question correctly — snippets get cut mid-sentence, miss the
number/date/fact that mattered, or are just marketing copy from the
meta description.

This plugin does one extra hop: for the top N results, it fetches the
actual page and uses BeautifulSoup to pull out the real body text (not
nav bars, cookie banners, ads, or scripts), then hands the AI a much
richer per-result digest:

    1. TITLE
       URL
       Published/updated date (if the page exposes one)
       ~1200 chars of actual extracted article text
       ---

BeautifulSoup is a hard requirement here (unlike webchat.py's optional
regex fallback) because a regex can approximate "grab the two DDG result
cells" but it cannot reliably approximate "find the main content block
in an arbitrary page and discard the boilerplate around it." Install it
with:

    pip install beautifulsoup4 --break-system-packages

Two ways to use this:

  1. As a plugin: `t> plugin run better-websearch "your query"` runs it
     standalone and prints the digest to stdout.

  2. As a library: other plugins (webchat, the terminal file agent, or
     your own) can `from betterwebsearch import better_web_search` and
     call it directly to build a richer WEB_SEARCH tool result instead
     of the snippet-only version.

See BUILD_PLUGIN.md in the Aulthium repo for the full plugin contract.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    from bs4 import BeautifulSoup
except ImportError:
    sys.stderr.write(
        "better-websearch: this plugin requires BeautifulSoup.\n"
        "Install it with: pip install beautifulsoup4 --break-system-packages\n"
    )
    sys.exit(1)

USER_AGENT = "Mozilla/5.0 (compatible; AulthiumBetterWebSearch/1.0)"
SEARCH_TIMEOUT = 15
FETCH_TIMEOUT = 10
MAX_EXCERPT_CHARS = 1200
DEFAULT_NUM_RESULTS = 5
DEFAULT_FETCH_WORKERS = 4

# Tags that are never article content, stripped before any extraction.
STRIP_TAGS = ["script", "style", "noscript", "nav", "header", "footer",
              "aside", "form", "iframe", "svg", "button"]

# Loose signal that a class/id belongs to boilerplate, not the article.
BOILERPLATE_HINTS = re.compile(
    r"nav|menu|sidebar|footer|header|banner|cookie|consent|advert|social|"
    r"share|comment|related|subscribe|newsletter|breadcrumb|popup|modal",
    re.I,
)


def _get(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return raw.decode("utf-8", "replace")


def _ddg_search(query, num_results):
    """Query DuckDuckGo's lite HTML endpoint and return [(title, url, snippet), ...]."""
    url = "https://lite.duckduckgo.com/lite/?q=" + urllib.parse.quote(query)
    try:
        html = _get(url, SEARCH_TIMEOUT)
    except Exception as e:
        raise RuntimeError("search request failed: %s" % e)

    soup = BeautifulSoup(html, "html.parser")
    links = soup.select("a.result-link")
    snippets = soup.select("td.result-snippet")

    results = []
    for i in range(len(links)):
        a = links[i]
        title = " ".join(a.get_text(" ", strip=True).split())
        href = a.get("href", "")
        # DDG lite sometimes wraps the real URL behind a redirect param.
        parsed = urllib.parse.urlparse(href)
        if parsed.netloc.endswith("duckduckgo.com"):
            qs = urllib.parse.parse_qs(parsed.query)
            href = qs.get("uddg", [href])[0]
        snippet = ""
        if i < len(snippets):
            snippet = " ".join(snippets[i].get_text(" ", strip=True).split())
        if title and href:
            results.append({"title": title, "url": href, "snippet": snippet})
        if len(results) >= num_results:
            break
    return results


def _page_date(soup):
    """Best-effort published/updated date from common meta tag conventions."""
    candidates = [
        ("meta", {"property": "article:published_time"}),
        ("meta", {"property": "article:modified_time"}),
        ("meta", {"name": "date"}),
        ("meta", {"itemprop": "datePublished"}),
        ("time", {}),
    ]
    for tag, attrs in candidates:
        el = soup.find(tag, attrs=attrs) if attrs else soup.find(tag)
        if el is None:
            continue
        val = el.get("content") or el.get("datetime") or el.get_text(strip=True)
        if val:
            return val.strip()[:32]
    return None


def _extract_main_text(html):
    """
    Strip boilerplate and return (title, date, main_text).

    Heuristic: after removing script/style/nav/etc, score every
    container by how much paragraph text it directly holds, and take
    the highest-scoring one. Falls back to all <p> tags on the page if
    nothing scores well (common on very simple/static pages).
    """
    soup = BeautifulSoup(html, "html.parser")

    title_el = soup.find("title")
    title = title_el.get_text(strip=True) if title_el else ""
    date = _page_date(soup)

    for tag_name in STRIP_TAGS:
        for el in soup.find_all(tag_name):
            el.decompose()

    # Drop obvious boilerplate containers by class/id before scoring.
    for el in soup.find_all(True):
        ident = " ".join([el.get("class") and " ".join(el.get("class")) or "",
                           el.get("id") or ""])
        if ident.strip() and BOILERPLATE_HINTS.search(ident):
            el.decompose()

    best_el, best_score = None, 0
    for container in soup.find_all(["article", "main", "div", "section"]):
        paras = container.find_all("p", recursive=False)
        text = " ".join(p.get_text(" ", strip=True) for p in paras)
        score = len(text)
        if score > best_score:
            best_score, best_el = score, container

    if best_el is not None and best_score > 200:
        text = " ".join(p.get_text(" ", strip=True)
                         for p in best_el.find_all("p", recursive=False))
    else:
        # Fallback: every paragraph on the page, boilerplate already stripped.
        text = " ".join(p.get_text(" ", strip=True) for p in soup.find_all("p"))

    text = " ".join(text.split())
    return title, date, text


def _fetch_and_extract(result):
    try:
        html = _get(result["url"], FETCH_TIMEOUT)
        page_title, date, text = _extract_main_text(html)
        excerpt = text[:MAX_EXCERPT_CHARS]
        if len(text) > MAX_EXCERPT_CHARS:
            excerpt = excerpt.rsplit(" ", 1)[0] + "..."
        result["page_title"] = page_title or result["title"]
        result["date"] = date
        result["excerpt"] = excerpt or "(could not extract article text; page may be JS-rendered)"
        result["fetched"] = bool(excerpt)
    except Exception as e:
        result["page_title"] = result["title"]
        result["date"] = None
        result["excerpt"] = None
        result["fetched"] = False
        result["fetch_error"] = str(e)
    return result


def better_web_search(query, num_results=DEFAULT_NUM_RESULTS, fetch_pages=True,
                       max_workers=DEFAULT_FETCH_WORKERS):
    """
    Returns a list of dicts:
      {title, url, snippet, page_title, date, excerpt, fetched, fetch_error?}

    Set fetch_pages=False to get DDG-snippet-only behavior (fast, matches
    the old tool_web_search), or True (default) for the full upgrade.
    """
    results = _ddg_search(query, num_results)
    if not fetch_pages or not results:
        for r in results:
            r.update(page_title=r["title"], date=None, excerpt=None, fetched=False)
        return results

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(_fetch_and_extract, r): r for r in results}
        for fut in as_completed(futures):
            fut.result()  # results list items are mutated in place

    return results


def format_for_ai(results):
    """Render results as plain text meant to be fed straight back to the AI as tool output."""
    if not results:
        return "No results found."
    blocks = []
    for i, r in enumerate(results, 1):
        lines = ["%d. %s" % (i, r.get("page_title") or r["title"]), "   %s" % r["url"]]
        if r.get("date"):
            lines.append("   Published/updated: %s" % r["date"])
        if r.get("fetched") and r.get("excerpt"):
            lines.append("   %s" % r["excerpt"])
        elif r.get("snippet"):
            lines.append("   (page fetch failed, using search snippet) %s" % r["snippet"])
        else:
            lines.append("   (no content available)")
        blocks.append("\n".join(lines))
    return "\n\n".join(blocks)


def main():
    # This plugin is registered as a "hook" (see plugin.json) — Aulthium
    # calls it once per web search, passing the query as argv, and stays
    # in normal chat the whole time ("User>", not a plugin-owned prompt).
    # It never prompts interactively; run with no query and it just prints
    # usage and exits, same as any other one-shot CLI tool would.
    if len(sys.argv) <= 1:
        sys.stderr.write("usage: betterwebsearch.py <query>\n")
        sys.exit(1)
    query = " ".join(sys.argv[1:]).strip()
    if not query:
        sys.stderr.write("usage: betterwebsearch.py <query>\n")
        sys.exit(1)

    try:
        results = better_web_search(query)
    except RuntimeError as e:
        print("ERROR: %s" % e)
        return

    print(format_for_ai(results))

    # Also emit JSON on stderr-free stdout marker for callers that want to
    # parse this programmatically instead of reading the printed text.
    if os.environ.get("AULTHIUM_BETTER_WEBSEARCH_JSON") == "1":
        print("\n<<<JSON>>>")
        print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
