"""
Aulthium built-in plugin: webchat

Serves a small local chat webpage, backed by whatever AI provider/model
Aulthium is currently configured with, so you can chat from a browser tab
instead of the terminal. Stdlib-only at its core — python3 itself is the
only hard requirement (that's why "python is needed" for this particular
plugin; other plugins are free to need nothing, or something else
entirely) — but WEB_SEARCH prefers BeautifulSoup for parsing results when
it's installed (`pip install beautifulsoup4` --break-system-packages on
Termux) and falls back to the old regex-based parser automatically if
it's not, so the plugin still works with zero extra installs either way.

Two things it mirrors from the terminal session, on top of plain chat:

  - HTTP 429 retry-with-backoff, same shape as call_provider_with_retry in
    the main script: temporary throttling gets retried (Retry-After header
    if present, otherwise exponential backoff + jitter, capped), exhausted
    daily/monthly quota fails fast with a clear message instead of burning
    retries. The browser sees this live (a "rate limited, retrying in Xs"
    status) instead of just staring at a spinner.

  - The same marker-based tool protocol as the terminal file agent
    (FILE_READ / DIR_LIST / WEB_SEARCH run immediately; FILE_WRITE /
    FILE_DELETE / SHELL_RUN are gated behind an explicit yes/no in the
    browser, same as confirm_action does in the terminal). SHELL_RUN runs
    with the same $WORKSPACE_DIR cwd and timeout the terminal's SHELL_RUN
    uses, and is equally NOT sandboxed to that folder — the command itself
    can reach anything this device's shell can. The confirm gate *starts*
    synced to whatever 't> confirm on/off' was set to in the
    terminal at the moment this plugin was launched
    (AULTHIUM_SKIP_CONFIRMATIONS), and can be flipped independently from
    the page itself after that.

Launched by Aulthium via 't> plugin run webchat', which exports the
connection details below as env vars before starting this process. See
BUILD_PLUGIN.md for the full contract if you're writing your own plugin.
"""
import json
import os
import random
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

try:
    from bs4 import BeautifulSoup
    HAVE_BS4 = True
except ImportError:
    HAVE_BS4 = False

API_KIND = os.environ.get("AULTHIUM_API_KIND", "openai")
API_URL = os.environ.get("AULTHIUM_API_URL", "")
API_KEY = os.environ.get("AULTHIUM_API_KEY", "")
MODEL = os.environ.get("AULTHIUM_MODEL", "")
PROVIDER_LABEL = os.environ.get("AULTHIUM_PROVIDER_LABEL", "your AI provider")
APP_NAME = os.environ.get("AULTHIUM_APP_NAME", "Aulthium")
WORKSPACE_DIR = os.environ.get("AULTHIUM_WORKSPACE_DIR", "")
HOST = "127.0.0.1"

def _env_int(name, default):
    try:
        return int(os.environ.get(name, "") or default)
    except (TypeError, ValueError):
        return default

MAX_RATE_LIMIT_RETRIES = _env_int("AULTHIUM_MAX_RATE_LIMIT_RETRIES", 6)
MAX_RATE_LIMIT_WAIT = _env_int("AULTHIUM_MAX_RATE_LIMIT_WAIT", 60)
SHELL_TIMEOUT_SECS = _env_int("AULTHIUM_SHELL_TIMEOUT_SECS", 60)

if not API_URL:
    sys.stderr.write(
        "webchat: no AULTHIUM_API_URL in the environment — this plugin is meant to be\n"
        "launched via 't> plugin run webchat' inside Aulthium, not run standalone.\n"
    )
    sys.exit(1)

WORKSPACE_ABS = os.path.realpath(WORKSPACE_DIR) if WORKSPACE_DIR else None

CONFIRM_STATE = {"on": os.environ.get("AULTHIUM_SKIP_CONFIRMATIONS", "0") != "1"}
STATE_LOCK = threading.Lock()

TOOL_SYSTEM_PROMPT = """You are """ + APP_NAME + """, a helpful AI assistant reachable through a browser chat page. Answer clearly and concisely, and be practical, friendly, and accurate.

The page renders your replies as markdown (headers, **bold**, *italic*, `inline code`, fenced ``` code blocks, links, lists, blockquotes) — feel free to use it where it helps readability, but don't overdo it for short answers.

You have a small set of optional tools, available only if the person's request calls for them — most replies need none of them at all.

=== READING / INSPECTING (run immediately, no confirmation, results are sent back to you) ===

To read a text file's contents, output a line EXACTLY like this:
<<<FILE_READ path="relative/path.txt">>>

To list the contents of a folder, output a line EXACTLY like this:
<<<DIR_LIST path="relative/folder">>>
(use path="." for the workspace root)

To search the live web for current information you don't already know, output a line EXACTLY like this:
<<<WEB_SEARCH query="your search terms">>>

=== CHANGING FILES (shown to the user in the browser, requires an explicit yes/no click before it runs) ===

To create or overwrite a file, output a block EXACTLY like this (nothing else on those marker lines):
<<<FILE_WRITE path="relative/path.txt">>>
the full file content goes here
<<<END_FILE_WRITE>>>

To delete a file, output a line EXACTLY like this:
<<<FILE_DELETE path="relative/path.txt">>>

To run a shell command, output a block EXACTLY like this:
<<<SHELL_RUN>>>
the shell command(s) go here
<<<END_SHELL_RUN>>>
This runs with the workspace folder as its current directory, using the user's real shell privileges — it is
NOT confined to the sandbox the way file actions are, so only propose commands you're confident are safe,
relevant, and non-destructive, and never target files or paths outside the workspace. The user always sees the
exact command text and must approve it before it runs. Prefer FILE_READ / FILE_WRITE / DIR_LIST for simple
file inspection or edits; reach for SHELL_RUN when you actually need to execute something (running a build, a
script, git, or a CLI tool). Output is truncated if very large and sent back to you the same way as the other
markers.

Rules:
- Every path must be relative and must stay inside your sandbox folder — never an absolute path, never "..".
- You can issue several of the above in one reply. Their results are appended to the conversation and you'll
  automatically be prompted again with that information, so request something, wait for the result, and then
  give your real answer or take further action in a later turn.
- If the person declines a FILE_WRITE/FILE_DELETE confirmation, don't repeat the same request — acknowledge it
  and ask what they'd like instead.
- Never show raw marker syntax to the user as if it were your answer; markers are instructions to the system,
  not something to display or explain line-by-line unless asked.
"""

def _do_request(url, data_bytes, headers):
    """POST and return (status, body_text, headers_dict). status is 0 on a
    connection-level failure (DNS, timeout, refused, etc), with the error
    message stuffed into body_text as a JSON error object so callers can
    treat it uniformly."""
    req = urllib.request.Request(url, data=data_bytes, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, resp.read().decode("utf-8", "replace"), dict(resp.headers)
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            body = ""
        return e.code, body, dict(e.headers or {})
    except Exception as e:
        return 0, json.dumps({"error": {"message": str(e)}}), {}

def call_openai_compatible_raw(messages):
    payload = json.dumps({
        "model": MODEL,
        "messages": messages,
        "temperature": 0.7,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if API_KEY:
        headers["Authorization"] = "Bearer " + API_KEY
    return _do_request(API_URL, payload, headers)

def call_google_raw(messages):
    contents = []
    system_text = None
    for m in messages:
        role = m.get("role")
        text = m.get("content", "")
        if role == "system":
            system_text = (system_text + "\n\n" + text) if system_text else text
            continue
        contents.append({
            "role": "model" if role == "assistant" else "user",
            "parts": [{"text": text}],
        })
    body_obj = {"contents": contents}
    if system_text:
        body_obj["systemInstruction"] = {"parts": [{"text": system_text}]}
    payload = json.dumps(body_obj).encode("utf-8")
    url = API_URL.rstrip("/") + "/models/" + MODEL + ":generateContent?key=" + urllib.parse.quote(API_KEY)
    return _do_request(url, payload, {"Content-Type": "application/json"})

def extract_reply(body_text):
    obj = json.loads(body_text)
    if API_KIND == "google":
        parts = obj["candidates"][0]["content"]["parts"]
        return "".join(p.get("text", "") for p in parts)
    return obj["choices"][0]["message"]["content"]

QUOTA_RE = re.compile(r"per-day|per-month|daily|quota|free-models-per|RESOURCE_EXHAUSTED", re.I)

def call_with_retry(messages, job):
    """Same shape as call_provider_with_retry in the terminal script: retry
    HTTP 429s with backoff + jitter (honoring Retry-After when present),
    fail fast on an exhausted free-tier quota, give up after
    MAX_RATE_LIMIT_RETRIES. Reports live status onto `job` as it goes.
    Returns (reply_text, error_text) — exactly one of them is set."""
    attempt = 0
    wait_secs = 2
    while True:
        job.set_status("working", "thinking...")
        if API_KIND == "google":
            status, body, headers = call_google_raw(messages)
        else:
            status, body, headers = call_openai_compatible_raw(messages)

        if job.cancelled:
            return None, "cancelled"

        if status == 0:
            try:
                msg = json.loads(body).get("error", {}).get("message", body)
            except Exception:
                msg = body
            return None, "Connection error: %s" % msg

        if status != 429:
            if 200 <= status < 300:
                try:
                    return extract_reply(body), None
                except Exception as e:
                    return None, "Could not parse the response: %s" % e
            return None, "HTTP %s: %s" % (status, body[:500])

        err_msg = ""
        try:
            err_msg = json.loads(body).get("error", {}).get("message", "") or ""
        except Exception:
            pass

        if QUOTA_RE.search(err_msg or ""):
            return None, (
                "%s free-tier quota exhausted: %s — retrying won't help until it resets. "
                "Switch models in the terminal (t> model), check billing, or wait for the reset."
                % (PROVIDER_LABEL, err_msg or "rate limit exceeded")
            )

        if attempt >= MAX_RATE_LIMIT_RETRIES:
            return None, "HTTP 429 (rate limited): %s" % (err_msg or body[:300])

        attempt += 1
        retry_after = headers.get("Retry-After") or headers.get("retry-after")
        if retry_after and str(retry_after).strip().isdigit():
            wait_secs = int(retry_after)
        wait_secs = min(wait_secs, MAX_RATE_LIMIT_WAIT)
        wait_secs = max(wait_secs, 1)
        jitter = random.randint(1, 3)
        total_wait = wait_secs + jitter

        job.set_status(
            "retrying",
            "Rate limited by %s (HTTP 429). Retrying in %ss... (%s/%s)"
            % (PROVIDER_LABEL, total_wait, attempt, MAX_RATE_LIMIT_RETRIES),
        )
        remaining = total_wait
        while remaining > 0 and not job.cancelled:
            time.sleep(1 if remaining > 1 else remaining)
            remaining -= 1

        wait_secs *= 2

def safe_path(rel):
    if not WORKSPACE_ABS:
        raise ValueError("no sandbox workspace is configured for this session")
    rel = (rel or "").strip()
    if rel in ("", "."):
        return WORKSPACE_ABS
    if rel.startswith("/") or rel.startswith("~") or ".." in rel.replace("\\", "/").split("/"):
        raise ValueError("path must be relative and stay inside the workspace")
    target = os.path.realpath(os.path.join(WORKSPACE_ABS, rel))
    if target != WORKSPACE_ABS and not target.startswith(WORKSPACE_ABS + os.sep):
        raise ValueError("path escapes the workspace")
    return target

def tool_file_read(rel):
    path = safe_path(rel)
    if not os.path.isfile(path):
        return "ERROR: no such file: %s" % rel
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        data = f.read(200_000)
    if len(data) >= 200_000:
        data += "\n...[truncated]"
    return data

def tool_dir_list(rel):
    path = safe_path(rel)
    if not os.path.isdir(path):
        return "ERROR: no such folder: %s" % rel
    entries = sorted(os.listdir(path))
    if not entries:
        return "(empty folder)"
    lines = []
    for name in entries:
        full = os.path.join(path, name)
        lines.append(("dir   " if os.path.isdir(full) else "file  ") + name)
    return "\n".join(lines)

def tool_file_write(rel, content):
    path = safe_path(rel)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    return "OK: wrote %d bytes to %s" % (len(content.encode("utf-8")), rel)

def tool_file_delete(rel):
    path = safe_path(rel)
    if not os.path.isfile(path):
        return "ERROR: no such file: %s" % rel
    os.remove(path)
    return "OK: deleted %s" % rel

def tool_shell_run(cmd_text):
    """Mirrors the terminal's handle_shell_run_action: cwd = the workspace
    folder (falling back to this process's cwd if none is configured),
    NOT path-sandboxed like the file tools — the command can reach
    anywhere this device's shell can. Capped timeout, output capped and
    combined stdout+stderr, same shape as the terminal's cap_preview."""
    cwd = WORKSPACE_ABS or os.getcwd()
    try:
        proc = subprocess.run(
            cmd_text,
            shell=True,
            cwd=cwd,
            timeout=SHELL_TIMEOUT_SECS,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        output = proc.stdout.decode("utf-8", "replace")
        exit_code = proc.returncode
    except subprocess.TimeoutExpired as e:
        output = (e.stdout or b"").decode("utf-8", "replace")
        output += "\n...[timed out after %ds]" % SHELL_TIMEOUT_SECS
        exit_code = 124
    except Exception as e:
        return "ERROR: %s" % e
    if len(output) > 8000:
        output = output[:8000] + "\n...[truncated]"
    return "exit=%d\n%s" % (exit_code, output or "(no output)")

def _web_search_parse_bs4(html):
    """Preferred parser: BeautifulSoup over DuckDuckGo lite's result markup
    (each result is an <a class="result-link"> followed by a
    <td class="result-snippet">). Far more forgiving of markup quirks than
    the regex fallback below."""
    soup = BeautifulSoup(html, "html.parser")
    links = soup.select(".result-link")
    snippets = soup.select(".result-snippet")
    results = []
    for i in range(min(len(links), len(snippets))):
        title = " ".join(links[i].get_text(" ", strip=True).split())
        snippet = " ".join(snippets[i].get_text(" ", strip=True).split())
        if title:
            results.append((title, snippet))
    return results

def _web_search_parse_regex(html):
    """Fallback used when BeautifulSoup isn't installed — the original
    regex-based scrape, kept so WEB_SEARCH still works with zero extra
    installs."""
    raw = re.findall(
        r'class="result-link"[^>]*>(.*?)</a>.*?class="result-snippet">(.*?)</td>', html, re.S
    )
    results = []
    for title, snippet in raw:
        clean_title = re.sub("<[^>]+>", "", title).strip()
        clean_snippet = re.sub("<[^>]+>", "", snippet).strip()
        if clean_title:
            results.append((clean_title, clean_snippet))
    return results

def tool_web_search(query):
    try:
        url = "https://lite.duckduckgo.com/lite/?q=" + urllib.parse.quote(query)
        req = urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0 (compatible; AulthiumWebchat/1.0)"}
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            html = resp.read().decode("utf-8", "replace")
    except Exception as e:
        return "ERROR: web search failed: %s" % e

    results = []
    if HAVE_BS4:
        try:
            results = _web_search_parse_bs4(html)
        except Exception:
            results = []
    if not results:
        results = _web_search_parse_regex(html)

    if not results:
        return "No results found."
    out = []
    for i, (title, snippet) in enumerate(results[:5], 1):
        out.append("%d. %s\n   %s" % (i, title, snippet))
    return "\n".join(out)

BLOCK_RE = re.compile(
    r'<<<FILE_WRITE\s+path="([^"]*)">>>\n(.*?)\n<<<END_FILE_WRITE>>>', re.S
)
SHELL_BLOCK_RE = re.compile(r'<<<SHELL_RUN>>>\n(.*?)\n<<<END_SHELL_RUN>>>', re.S)
SIMPLE_RE = re.compile(r'<<<(FILE_READ|DIR_LIST|WEB_SEARCH|FILE_DELETE)\s+(?:path|query)="([^"]*)">>>')

NEEDS_CONFIRM = {"FILE_WRITE", "FILE_DELETE", "SHELL_RUN"}

def extract_tool_calls(text):
    calls = []
    for m in BLOCK_RE.finditer(text):
        calls.append({"pos": m.start(), "kind": "FILE_WRITE", "path": m.group(1), "content": m.group(2)})
    for m in SHELL_BLOCK_RE.finditer(text):
        calls.append({"pos": m.start(), "kind": "SHELL_RUN", "command": m.group(1)})
    for m in SIMPLE_RE.finditer(text):
        kind, val = m.group(1), m.group(2)
        calls.append({"pos": m.start(), "kind": kind, "path": val, "query": val})
    calls.sort(key=lambda c: c["pos"])
    return calls

def strip_markers(text):
    text = BLOCK_RE.sub("", text)
    text = SHELL_BLOCK_RE.sub("", text)
    text = SIMPLE_RE.sub("", text)
    return text

def describe_call(call):
    kind = call["kind"]
    if kind == "FILE_READ":
        return "Read %s" % call["path"]
    if kind == "DIR_LIST":
        return "List %s" % (call["path"] or ".")
    if kind == "WEB_SEARCH":
        return "Web search: %s" % call["query"]
    if kind == "FILE_WRITE":
        return "Write %s (%d chars)" % (call["path"], len(call.get("content", "")))
    if kind == "FILE_DELETE":
        return "Delete %s" % call["path"]
    if kind == "SHELL_RUN":
        first_line = (call.get("command") or "").strip().splitlines()[0:1]
        return "Shell: %s" % (first_line[0] if first_line else "(empty command)")
    return kind

def execute_call(call):
    try:
        kind = call["kind"]
        if kind == "FILE_READ":
            return tool_file_read(call["path"])
        if kind == "DIR_LIST":
            return tool_dir_list(call["path"])
        if kind == "WEB_SEARCH":
            return tool_web_search(call["query"])
        if kind == "FILE_WRITE":
            return tool_file_write(call["path"], call.get("content", ""))
        if kind == "FILE_DELETE":
            return tool_file_delete(call["path"])
        if kind == "SHELL_RUN":
            return tool_shell_run(call.get("command", ""))
        return "ERROR: unknown tool %s" % kind
    except Exception as e:
        return "ERROR: %s" % e

class Job:
    def __init__(self, messages):
        self.id = uuid.uuid4().hex
        self.messages = messages
        self.status = "working"
        self.detail = "thinking..."
        self.reply = None
        self.error = None
        self.action = None
        self.events = []
        self.lock = threading.Lock()
        self.confirm_event = threading.Event()
        self.confirm_result = False
        self.cancelled = False
        self.created = time.time()

    def set_status(self, status, detail=""):
        with self.lock:
            self.status = status
            self.detail = detail

    def push_event(self, etype, text):
        with self.lock:
            self.events.append({"type": etype, "text": text})

    def snapshot(self, since=0):
        with self.lock:
            return {
                "status": self.status,
                "detail": self.detail,
                "reply": self.reply,
                "error": self.error,
                "action": self.action,
                "events": self.events[since:],
                "event_count": len(self.events),
            }

JOBS = {}
JOBS_LOCK = threading.Lock()

def _gc_jobs():
    cutoff = time.time() - 3600
    with JOBS_LOCK:
        stale = [jid for jid, j in JOBS.items() if j.created < cutoff]
        for jid in stale:
            JOBS.pop(jid, None)

def need_confirm_and_wait(job, call):
    with STATE_LOCK:
        confirm_on = CONFIRM_STATE["on"]
    if not confirm_on:
        job.push_event("auto", describe_call(call) + " (auto-approved, confirmations off)")
        return True

    with job.lock:
        job.action = {
            "kind": call["kind"],
            "path": call.get("path"),
            "content": call.get("content") or call.get("command", ""),
        }
        job.status = "confirm"
        job.detail = "Waiting for confirmation..."
    job.confirm_event.clear()
    job.confirm_event.wait(timeout=600)
    approved = job.confirm_result
    with job.lock:
        job.action = None
    return approved

def run_job(job):
    messages = job.messages
    if not messages or messages[0].get("role") != "system":
        messages = [{"role": "system", "content": TOOL_SYSTEM_PROMPT}] + messages

    for _round in range(6):
        reply_text, err = call_with_retry(messages, job)
        if job.cancelled:
            return
        if err:
            with job.lock:
                job.status, job.error = "error", err
            return

        calls = extract_tool_calls(reply_text)
        if not calls:
            clean = strip_markers(reply_text).strip()
            with job.lock:
                job.status, job.reply = "done", (clean or reply_text)
            return

        messages.append({"role": "assistant", "content": reply_text})
        results = []
        for call in calls:
            if call["kind"] in NEEDS_CONFIRM:
                approved = need_confirm_and_wait(job, call)
                if not approved:
                    target = call.get("path") or call.get("command", "")
                    results.append("%s on '%s' was declined by the user." % (call["kind"], target))
                    continue
            else:
                job.push_event("tool", describe_call(call))
            out = execute_call(call) if (call["kind"] not in NEEDS_CONFIRM or approved) else None
            if out is not None:
                label = call.get("path") or call.get("query") or call.get("command", "")
                results.append("Result of %s(%s):\n%s" % (call["kind"], label, out))
        messages.append({"role": "user", "content": "\n\n".join(results) if results else "(no tool output)"})

    with job.lock:
        job.status = "done"
        job.reply = "(stopped after several tool rounds without a final answer — try rephrasing, or ask for one step at a time)"

PAGE_TEMPLATE = """<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>__APP_NAME__ webchat</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0c0d14;
    --bg-elevated: #13141f;
    --panel: #181926;
    --panel-2: #1e1f2e;
    --border: #2a2c3d;
    --border-subtle: #1f2130;
    --text: #ececf3;
    --text-secondary: #a0a3b8;
    --text-tertiary: #6b6f85;
    --accent: #8b7cf7;
    --accent-2: #5aa8ff;
    --accent-grad: linear-gradient(135deg, #8b7cf7, #5aa8ff);
    --accent-glow: rgba(139,124,247,0.15);
    --warn: #f0c040;
    --warn-bg: #2a2210;
    --warn-border: #5c4a18;
    --danger: #ff7a85;
    --danger-bg: #2b1418;
    --danger-border: #5c2229;
    --ok: #5ee090;
    --ok-bg: #0f2a18;
    --shadow: 0 2px 12px rgba(0,0,0,0.35);
    --shadow-lg: 0 8px 32px rgba(0,0,0,0.45);
    --radius: 16px;
    --radius-sm: 10px;
    --radius-xs: 6px;
    --transition: 0.25s cubic-bezier(0.4, 0, 0.2, 1);
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { height: 100%; overscroll-behavior-y: none; }
  body {
    margin: 0; display: flex; flex-direction: column;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
  }
  header {
    padding: 14px 18px 12px; border-bottom: 1px solid var(--border-subtle);
    background: rgba(19, 20, 31, 0.85); backdrop-filter: blur(16px) saturate(1.2);
    position: sticky; top: 0; z-index: 10;
    transition: box-shadow var(--transition);
  }
  header.scrolled { box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
  .header-top { display: flex; justify-content: space-between; align-items: center; gap: 10px; }
  .brand { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .brand h1 { font-size: 16px; margin: 0; font-weight: 700; letter-spacing: 0.3px; white-space: nowrap; }
  .dot {
    width: 9px; height: 9px; border-radius: 50%; flex: none;
    background: var(--ok); box-shadow: 0 0 0 0 rgba(94,224,144,0.4);
    animation: pulse-dot 2.5s ease-in-out infinite;
  }
  @keyframes pulse-dot {
    0%, 100% { box-shadow: 0 0 0 0 rgba(94,224,144,0.4); }
    50% { box-shadow: 0 0 0 6px rgba(94,224,144,0); }
  }
  .header-actions { display: flex; gap: 8px; flex: none; }
  .pill {
    border: 1px solid var(--border); background: var(--panel-2); color: var(--text);
    border-radius: 999px; padding: 7px 14px; font-size: 12.5px; cursor: pointer;
    transition: all var(--transition); white-space: nowrap; font-weight: 500;
    touch-action: manipulation;
  }
  .pill:hover { border-color: var(--accent); background: var(--panel); }
  .pill:active { transform: scale(0.96); }
  .pill.off { color: var(--warn); border-color: var(--warn-border); background: var(--warn-bg); }
  .pill.ghost { background: transparent; }
  .subtitle { margin-top: 6px; font-size: 12px; color: var(--text-tertiary); font-weight: 400; }
  #log {
    flex: 1; overflow-y: auto; padding: 18px 16px 8px; display: flex;
    flex-direction: column; gap: 10px; max-width: 840px; width: 100%;
    margin: 0 auto; scroll-behavior: smooth;
  }
  .msg {
    max-width: 84%; padding: 12px 16px; border-radius: var(--radius); line-height: 1.55;
    white-space: pre-wrap; word-wrap: break-word; font-size: 15px;
    box-shadow: var(--shadow);
    animation: msg-in 0.35s cubic-bezier(0.22, 1, 0.36, 1) forwards;
    opacity: 0; transform: translateY(10px) scale(0.98);
    transition: transform var(--transition), box-shadow var(--transition);
  }
  .msg:hover { transform: translateY(-1px); box-shadow: var(--shadow-lg); }
  @keyframes msg-in {
    to { opacity: 1; transform: translateY(0) scale(1); }
  }
  .user {
    align-self: flex-end; background: var(--accent-grad); color: white;
    border-bottom-right-radius: var(--radius-xs); font-weight: 450;
  }
  .assistant {
    align-self: flex-start; background: var(--panel); border: 1px solid var(--border);
    border-bottom-left-radius: var(--radius-xs);
  }
  .assistant.pending {
    color: var(--text-secondary); font-style: normal;
    display: flex; align-items: center; gap: 6px; min-height: 48px;
  }
  .assistant.pending.retrying { color: var(--warn); }
  .typing-dots { display: flex; gap: 4px; align-items: center; }
  .typing-dots span {
    width: 6px; height: 6px; border-radius: 50%; background: var(--text-tertiary);
    animation: typing-bounce 1.4s ease-in-out infinite;
  }
  .typing-dots span:nth-child(1) { animation-delay: 0s; }
  .typing-dots span:nth-child(2) { animation-delay: 0.2s; }
  .typing-dots span:nth-child(3) { animation-delay: 0.4s; }
  @keyframes typing-bounce {
    0%, 60%, 100% { transform: translateY(0); opacity: 0.4; }
    30% { transform: translateY(-5px); opacity: 1; }
  }
  .error {
    align-self: flex-start; background: var(--danger-bg); border: 1px solid var(--danger-border);
    color: var(--danger); border-bottom-left-radius: var(--radius-xs);
    animation: shake 0.5s ease-in-out;
  }
  @keyframes shake {
    0%, 100% { transform: translateX(0); }
    20% { transform: translateX(-6px); }
    40% { transform: translateX(6px); }
    60% { transform: translateX(-4px); }
    80% { transform: translateX(4px); }
  }
  .tool-note {
    align-self: flex-start; max-width: 84%; font-size: 12px; color: var(--text-tertiary);
    padding: 6px 14px; border-radius: 999px; background: var(--panel-2);
    border: 1px solid var(--border-subtle);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    animation: fade-in 0.3s ease-out;
  }
  .tool-note.auto { color: var(--ok); border-color: rgba(94,224,144,0.2); background: var(--ok-bg); }
  @keyframes fade-in { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: translateY(0); } }
  .msg.markdown { white-space: normal; }
  .msg.markdown > *:first-child { margin-top: 0; }
  .msg.markdown > *:last-child { margin-bottom: 0; }
  .msg.markdown p { margin: 0 0 10px; line-height: 1.6; }
  .msg.markdown h1, .msg.markdown h2, .msg.markdown h3 {
    margin: 14px 0 8px; line-height: 1.3; font-weight: 700; color: var(--text);
  }
  .msg.markdown h1 { font-size: 1.3em; }
  .msg.markdown h2 { font-size: 1.18em; }
  .msg.markdown h3 { font-size: 1.06em; }
  .msg.markdown ul, .msg.markdown ol { margin: 0 0 10px; padding-left: 24px; }
  .msg.markdown li { margin: 4px 0; }
  .msg.markdown blockquote {
    margin: 0 0 10px; padding: 4px 14px; border-left: 3px solid var(--accent);
    color: var(--text-secondary); background: rgba(139,124,247,0.06);
    border-radius: 0 var(--radius-xs) var(--radius-xs) 0;
  }
  .msg.markdown code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.88em;
    background: rgba(255,255,255,0.07); padding: 2px 6px; border-radius: var(--radius-xs);
  }
  .msg.markdown pre.code-block {
    margin: 0 0 10px; padding: 14px 16px; background: #0a0b12;
    border: 1px solid var(--border-subtle); border-radius: var(--radius-sm);
    overflow-x: auto; position: relative;
  }
  .msg.markdown pre.code-block code { background: none; padding: 0; font-size: 0.84em; line-height: 1.6; }
  .msg.markdown a { color: var(--accent-2); text-decoration: none; transition: opacity 0.15s; }
  .msg.markdown a:hover { opacity: 0.8; text-decoration: underline; }
  .confirm-card {
    align-self: flex-start; max-width: 92%; width: 100%;
    background: var(--warn-bg); border: 1px solid var(--warn-border);
    border-radius: var(--radius); padding: 16px 18px;
    animation: slide-up 0.4s cubic-bezier(0.22, 1, 0.36, 1) forwards;
    box-shadow: var(--shadow-lg);
  }
  @keyframes slide-up {
    from { opacity: 0; transform: translateY(16px) scale(0.97); }
    to { opacity: 1; transform: translateY(0) scale(1); }
  }
  .confirm-title { font-size: 14px; font-weight: 600; color: var(--warn); margin-bottom: 8px; display: flex; align-items: center; gap: 6px; }
  .confirm-path { font-size: 13px; color: var(--text-tertiary); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  .confirm-preview {
    margin: 8px 0 12px; max-height: 240px; overflow: auto; padding: 12px 14px;
    background: #0a0b12; border: 1px solid var(--border-subtle); border-radius: var(--radius-sm);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
    white-space: pre-wrap; word-wrap: break-word; line-height: 1.5;
  }
  .confirm-actions { display: flex; gap: 10px; margin-top: 10px; }
  .confirm-actions button {
    border: none; border-radius: var(--radius-sm); padding: 9px 18px; font-size: 13.5px; cursor: pointer;
    font-weight: 600; transition: all 0.2s; touch-action: manipulation;
  }
  .confirm-actions button:hover { transform: translateY(-1px); }
  .confirm-actions button:active { transform: scale(0.97); }
  .confirm-yes { background: var(--ok); color: #0a2a14; }
  .confirm-no { background: var(--panel-2); color: var(--text); border: 1px solid var(--border) !important; }
  .confirm-actions button:disabled { opacity: 0.45; cursor: default; transform: none !important; }
  form {
    display: flex; gap: 10px; padding: 12px 16px 20px; border-top: 1px solid var(--border-subtle);
    max-width: 840px; width: 100%; margin: 0 auto; box-sizing: border-box;
    background: rgba(12, 13, 20, 0.8); backdrop-filter: blur(12px);
    position: sticky; bottom: 0;
  }
  textarea {
    flex: 1; resize: none; border-radius: var(--radius-sm); border: 1px solid var(--border);
    background: var(--panel-2); color: var(--text); padding: 12px 14px; font-size: 15px;
    font-family: inherit; min-height: 48px; max-height: 140px; outline: none;
    transition: all var(--transition); line-height: 1.5;
    -webkit-appearance: none; appearance: none;
  }
  textarea:focus { border-color: var(--accent); background: var(--panel); box-shadow: 0 0 0 3px var(--accent-glow); }
  textarea::placeholder { color: var(--text-tertiary); }
  button#send {
    border: none; border-radius: var(--radius-sm); background: var(--accent-grad); color: white;
    padding: 0 22px; font-size: 14.5px; font-weight: 600; cursor: pointer;
    transition: all 0.2s; touch-action: manipulation; min-height: 48px;
    box-shadow: 0 2px 8px rgba(139,124,247,0.25);
  }
  button#send:hover { transform: translateY(-1px); box-shadow: 0 4px 14px rgba(139,124,247,0.35); }
  button#send:active { transform: scale(0.96); }
  button#send:disabled { opacity: 0.4; cursor: default; transform: none !important; box-shadow: none; }
  #log::-webkit-scrollbar { width: 6px; }
  #log::-webkit-scrollbar-track { background: transparent; }
  #log::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
  #log::-webkit-scrollbar-thumb:hover { background: var(--text-tertiary); }

  @media (max-width: 640px) {
    header { padding: 12px 14px 10px; }
    .brand h1 { font-size: 15px; }
    .pill { padding: 6px 11px; font-size: 12px; }
    #log { padding: 14px 12px 6px; gap: 8px; }
    .msg { max-width: 90%; padding: 11px 14px; font-size: 15px; border-radius: var(--radius-sm); }
    .tool-note { max-width: 90%; padding: 5px 12px; font-size: 11.5px; }
    .confirm-card { max-width: 95%; padding: 14px; }
    .confirm-preview { max-height: 180px; padding: 10px 12px; font-size: 12px; }
    form { padding: 10px 12px 18px; gap: 8px; }
    textarea { padding: 11px 12px; font-size: 16px; min-height: 46px; }
    button#send { padding: 0 18px; font-size: 14px; min-height: 46px; }
  }
  @media (max-width: 380px) {
    .brand h1 { font-size: 14px; }
    .pill { padding: 5px 9px; font-size: 11px; }
    .msg { font-size: 14.5px; padding: 10px 12px; }
  }
  @media (prefers-reduced-motion: reduce) {
    .msg, .tool-note, .confirm-card, .error { animation: none; opacity: 1; transform: none; }
    .dot { animation: none; box-shadow: none; }
    .typing-dots span { animation: none; opacity: 0.6; }
    .pill, button, textarea { transition: none; }
  }
</style>
</head>
<body>
<header id="header">
  <div class="header-top">
    <div class="brand"><span class="dot"></span><h1>__APP_NAME__ webchat</h1></div>
    <div class="header-actions">
      <button id="confirmToggle" class="pill">Confirmations: ON</button>
      <button id="newChat" class="pill ghost">New chat</button>
    </div>
  </div>
  <div class="subtitle">__PROVIDER_LABEL__ &middot; __MODEL__</div>
</header>
<div id="log"></div>
<form id="form">
  <textarea id="input" placeholder="Message..." autofocus></textarea>
  <button type="submit" id="send">Send</button>
</form>
<script>
  const log = document.getElementById("log");
  const form = document.getElementById("form");
  const input = document.getElementById("input");
  const sendBtn = document.getElementById("send");
  const confirmToggle = document.getElementById("confirmToggle");
  const newChatBtn = document.getElementById("newChat");
  const header = document.getElementById("header");
  let messages = [];
  let confirmOn = true;

  function make(cls, text) {
    const d = document.createElement("div");
    d.className = cls;
    if (text !== undefined) d.textContent = text;
    return d;
  }

  function escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function renderMarkdown(text) {
    const blocks = [];
    let src = text.replace(/```(\w*)\n?([\s\S]*?)```/g, (m, lang, code) => {
      blocks.push('<pre class="code-block"><code>' + escapeHtml(code.replace(/\n$/, "")) + '</code></pre>');
      return "\x00BLOCK" + (blocks.length - 1) + "\x00";
    });

    src = escapeHtml(src);

    src = src.replace(/`([^`\n]+)`/g, (m, code) => '<code>' + code + '</code>');
    src = src.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
    src = src.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    src = src.replace(/__([^_\n]+)__/g, '<strong>$1</strong>');
    src = src.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>');
    src = src.replace(/(^|[^\w_])_([^_\n]+)_(?!\w)/g, '$1<em>$2</em>');
    src = src.replace(/^### (.*)$/gm, '<h3>$1</h3>');
    src = src.replace(/^## (.*)$/gm, '<h2>$1</h2>');
    src = src.replace(/^# (.*)$/gm, '<h1>$1</h1>');
    src = src.replace(/^&gt; ?(.*)$/gm, '<blockquote>$1</blockquote>');

    src = src.replace(/(^|\n)((?:[-*] .*(?:\n|$))+)/g, (m, lead, block) => {
      const items = block.trim().split("\n").map(l => l.replace(/^[-*] /, ""));
      return lead + "<ul>" + items.map(i => "<li>" + i + "</li>").join("") + "</ul>\n";
    });
    src = src.replace(/(^|\n)((?:\d+\. .*(?:\n|$))+)/g, (m, lead, block) => {
      const items = block.trim().split("\n").map(l => l.replace(/^\d+\.\s/, ""));
      return lead + "<ol>" + items.map(i => "<li>" + i + "</li>").join("") + "</ol>\n";
    });

    const blockTagRe = /^<(h1|h2|h3|ul|ol|li|blockquote|pre)/;
    const out = [];
    let para = [];
    const flush = () => {
      if (para.length) { out.push("<p>" + para.join("<br>") + "</p>"); para = []; }
    };
    for (const line of src.split("\n")) {
      if (line.trim() === "") { flush(); continue; }
      if (blockTagRe.test(line.trim())) { flush(); out.push(line); continue; }
      para.push(line);
    }
    flush();

    return out.join("\n").replace(/\x00BLOCK(\d+)\x00/g, (m, i) => blocks[parseInt(i, 10)]);
  }

  function addBubble(role, text) {
    const div = make("msg " + role, text);
    log.appendChild(div);
    log.scrollTop = log.scrollHeight;
    return div;
  }

  function setBubbleMarkdown(el, text) {
    el.classList.add("markdown");
    el.innerHTML = renderMarkdown(text);
    log.scrollTop = log.scrollHeight;
  }

  function addToolNote(text, extraCls) {
    log.appendChild(make("tool-note " + (extraCls || ""), text));
    log.scrollTop = log.scrollHeight;
  }

  function actionTitle(action) {
    if (action.kind === "FILE_WRITE") return "✏️ Write to " + action.path + "?";
    if (action.kind === "FILE_DELETE") return "🗑️ Delete " + action.path + "?";
    if (action.kind === "SHELL_RUN") return "⚠️ Run this shell command? (not sandboxed)";
    return "Proceed with " + action.kind + "?";
  }

  function addConfirmCard(action, onDecide) {
    const card = make("confirm-card");
    const title = make("confirm-title", actionTitle(action));
    card.appendChild(title);
    if (action.content) {
      const pre = document.createElement("pre");
      pre.className = "confirm-preview";
      pre.textContent = action.content;
      card.appendChild(pre);
    } else if (action.path) {
      card.appendChild(make("confirm-path", action.path));
    }
    const row = make("confirm-actions");
    const yes = document.createElement("button");
    yes.textContent = "Yes, proceed"; yes.className = "confirm-yes";
    const no = document.createElement("button");
    no.textContent = "No, decline"; no.className = "confirm-no";
    yes.onclick = () => { row.querySelectorAll("button").forEach(b => b.disabled = true); title.textContent += "  ✓ approved"; onDecide(true); };
    no.onclick = () => { row.querySelectorAll("button").forEach(b => b.disabled = true); title.textContent += "  ✕ declined"; onDecide(false); };
    row.appendChild(yes); row.appendChild(no);
    card.appendChild(row);
    log.appendChild(card);
    log.scrollTop = log.scrollHeight;
  }

  function applyConfirmState(on) {
    confirmOn = on;
    confirmToggle.textContent = "Confirmations: " + (on ? "ON" : "OFF");
    confirmToggle.classList.toggle("off", !on);
  }

  async function refreshStatus() {
    try {
      const res = await fetch("/api/status");
      const data = await res.json();
      applyConfirmState(!!data.confirm);
    } catch (e) {}
  }

  confirmToggle.addEventListener("click", async () => {
    try {
      const res = await fetch("/api/confirm-toggle", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ value: !confirmOn }),
      });
      const data = await res.json();
      applyConfirmState(!!data.confirm);
    } catch (e) {}
  });

  newChatBtn.addEventListener("click", () => {
    messages = [];
    log.innerHTML = "";
  });

  log.addEventListener("scroll", () => {
    header.classList.toggle("scrolled", log.scrollTop > 4);
  });

  function pollJob(jobId, pending) {
    return new Promise((resolve) => {
      let since = 0;
      const tick = async () => {
        let data;
        try {
          const res = await fetch("/api/chat/poll?id=" + jobId + "&since=" + since);
          data = await res.json();
        } catch (e) {
          setTimeout(tick, 800);
          return;
        }
        since = data.event_count;
        (data.events || []).forEach((ev) => {
          if (ev.type === "tool") addToolNote("⚙️ " + ev.text);
          else if (ev.type === "auto") addToolNote("✓ " + ev.text, "auto");
        });

        if (data.status === "working" || data.status === "retrying") {
          pending.className = "msg assistant pending" + (data.status === "retrying" ? " retrying" : "");
          if (data.status === "working") {
            pending.innerHTML = '<span class="typing-dots"><span></span><span></span><span></span></span>';
          } else {
            pending.textContent = data.detail || "thinking...";
          }
          setTimeout(tick, 500);
          return;
        }

        if (data.status === "confirm" && data.action) {
          pending.remove();
          addConfirmCard(data.action, async (approved) => {
            try {
              await fetch("/api/chat/confirm", {
                method: "POST", headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ id: jobId, approved }),
              });
            } catch (e) {}
            pending = addBubble("assistant pending", "");
            pending.innerHTML = '<span class="typing-dots"><span></span><span></span><span></span></span>';
            setTimeout(tick, 300);
          });
          return;
        }

        if (data.status === "done") {
          pending.classList.remove("pending", "retrying");
          setBubbleMarkdown(pending, data.reply);
          messages.push({ role: "assistant", content: data.reply });
          resolve();
          return;
        }

        if (data.status === "error") {
          pending.className = "msg error";
          pending.textContent = "Error: " + data.error;
          resolve();
          return;
        }

        setTimeout(tick, 500);
      };
      tick();
    });
  }

  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    input.value = "";
    input.style.height = "48px";
    addBubble("user", text);
    messages.push({ role: "user", content: text });
    sendBtn.disabled = true;
    const pending = addBubble("assistant pending", "");
    pending.innerHTML = '<span class="typing-dots"><span></span><span></span><span></span></span>';

    try {
      const res = await fetch("/api/chat", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ messages }),
      });
      const started = await res.json();
      if (started.error) throw new Error(started.error);
      await pollJob(started.job_id, pending);
    } catch (err) {
      pending.className = "msg error";
      pending.textContent = "Error: " + err;
    } finally {
      sendBtn.disabled = false;
      log.scrollTop = log.scrollHeight;
      input.focus();
    }
  });

  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      form.requestSubmit();
    }
  });
  input.addEventListener("input", () => {
    input.style.height = "48px";
    input.style.height = Math.min(input.scrollHeight, 140) + "px";
  });

  refreshStatus();
</script>
</body>
</html>
"""

PAGE = (
    PAGE_TEMPLATE
    .replace("__APP_NAME__", APP_NAME)
    .replace("__PROVIDER_LABEL__", PROVIDER_LABEL)
    .replace("__MODEL__", MODEL or "(no model set)")
).encode("utf-8")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send(self, code, body_bytes, content_type="text/html; charset=utf-8"):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path in ("/", "/index.html"):
            self._send(200, PAGE)
            return
        if parsed.path == "/api/status":
            with STATE_LOCK:
                confirm_on = CONFIRM_STATE["on"]
            self._send_json(200, {
                "provider": PROVIDER_LABEL, "model": MODEL, "confirm": confirm_on,
            })
            return
        if parsed.path == "/api/chat/poll":
            qs = urllib.parse.parse_qs(parsed.query)
            job_id = (qs.get("id") or [""])[0]
            since = int((qs.get("since") or ["0"])[0] or 0)
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                self._send_json(404, {"status": "error", "error": "unknown job", "events": [], "event_count": 0})
                return
            self._send_json(200, job.snapshot(since))
            return
        self._send(404, b"not found", "text/plain")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/chat":
            try:
                data = self._read_json()
                messages = data.get("messages", [])
            except Exception:
                self._send_json(400, {"error": "bad request"})
                return
            _gc_jobs()
            job = Job(list(messages))
            with JOBS_LOCK:
                JOBS[job.id] = job
            threading.Thread(target=run_job, args=(job,), daemon=True).start()
            self._send_json(200, {"job_id": job.id})
            return

        if parsed.path == "/api/chat/confirm":
            try:
                data = self._read_json()
                job_id = data.get("id", "")
                approved = bool(data.get("approved"))
            except Exception:
                self._send_json(400, {"error": "bad request"})
                return
            with JOBS_LOCK:
                job = JOBS.get(job_id)
            if not job:
                self._send_json(404, {"error": "unknown job"})
                return
            job.confirm_result = approved
            job.confirm_event.set()
            self._send_json(200, {"ok": True})
            return

        if parsed.path == "/api/confirm-toggle":
            try:
                data = self._read_json()
                value = bool(data.get("value"))
            except Exception:
                self._send_json(400, {"error": "bad request"})
                return
            with STATE_LOCK:
                CONFIRM_STATE["on"] = value
            self._send_json(200, {"confirm": value})
            return

        self._send(404, b"not found", "text/plain")

def find_free_port(start):
    port = start
    for _ in range(30):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind((HOST, port))
                return port
            except OSError:
                port += 1
    return start

def main():
    start_port = int(os.environ.get("AULTHIUM_WEBCHAT_PORT", "8420"))
    port = find_free_port(start_port)
    server = ThreadingHTTPServer((HOST, port), Handler)
    url = "http://%s:%d/" % (HOST, port)
    print("webchat: serving at %s (model: %s via %s)" % (url, MODEL or "?", PROVIDER_LABEL))
    print("webchat: confirmations start %s (matches this terminal's 't> confirm' setting)"
          % ("ON" if CONFIRM_STATE["on"] else "OFF"))
    print("webchat: WEB_SEARCH parser: %s" % ("BeautifulSoup" if HAVE_BS4 else "regex fallback (pip install beautifulsoup4 for a more robust parser)"))
    print("webchat: Ctrl+C here to stop.")
    threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nwebchat: stopped.")

if __name__ == "__main__":
    main()
