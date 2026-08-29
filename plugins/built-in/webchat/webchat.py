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

  - HTTP 429/5xx retry-with-backoff (up to 6 attempts by default), same
    shape as call_provider_with_retry in the main script: temporary
    throttling or a transient server error (429/500/502/503/504) gets
    retried (Retry-After header if present, otherwise exponential backoff
    + jitter, capped), exhausted daily/monthly quota fails fast with a
    clear message instead of burning retries, and non-retryable errors
    (4xx other than 429, connection failures) fail immediately. The
    browser sees this live (a "rate limited, retrying in Xs" status)
    instead of just staring at a spinner.

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

Tunable via `t> plugin config webchat set <key> <value>` (see plugin.json
for the defaults): port, max_rate_limit_retries, max_rate_limit_wait,
shell_timeout_secs.
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

# --- effective plugin config (plugin.json "config" defaults, overridden by
# `t> plugin config webchat set <key> <value>`) -----------------------------
# Aulthium hands the merged result down two ways: the whole thing as JSON in
# AULTHIUM_PLUGIN_CONFIG_JSON, and each key individually as
# AULTHIUM_PLUGIN_CFG_<KEY> (upper-cased). We accept either, per-key env
# taking precedence, and fall back to this plugin's old dedicated env vars
# (AULTHIUM_WEBCHAT_PORT etc.) so anything set that way still works.
try:
    _CONFIG = json.loads(os.environ.get("AULTHIUM_PLUGIN_CONFIG_JSON", "") or "{}")
except (TypeError, ValueError):
    _CONFIG = {}

def _cfg(key, legacy_env=None, default=""):
    v = os.environ.get("AULTHIUM_PLUGIN_CFG_" + key.upper())
    if v is None:
        v = _CONFIG.get(key)
    if v is None and legacy_env:
        v = os.environ.get(legacy_env)
    return default if v is None else v

def _cfg_int(key, legacy_env, default):
    try:
        return int(_cfg(key, legacy_env, default))
    except (TypeError, ValueError):
        return default

MAX_RATE_LIMIT_RETRIES = _cfg_int("max_rate_limit_retries", "AULTHIUM_MAX_RATE_LIMIT_RETRIES", 9)
MAX_RATE_LIMIT_WAIT = _cfg_int("max_rate_limit_wait", "AULTHIUM_MAX_RATE_LIMIT_WAIT", 60)
SHELL_TIMEOUT_SECS = _cfg_int("shell_timeout_secs", "AULTHIUM_SHELL_TIMEOUT_SECS", 60)

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
RETRYABLE_STATUS = {401, 429, 500, 502, 503, 504}

def call_with_retry(messages, job):
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

        if status not in RETRYABLE_STATUS:
            if status == 0:
                try:
                    msg = json.loads(body).get("error", {}).get("message", body)
                except Exception:
                    msg = body
                return None, "Connection error: %s" % msg
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

        if status == 429 and QUOTA_RE.search(err_msg or ""):
            return None, (
                "%s free-tier quota exhausted: %s — retrying won't help until it resets. "
                "Switch models in the terminal (t> model), check billing, or wait for the reset."
                % (PROVIDER_LABEL, err_msg or "rate limit exceeded")
            )

        if attempt >= MAX_RATE_LIMIT_RETRIES:
            if status == 429:
                return None, "HTTP 429 (rate limited): %s" % (err_msg or body[:300])
            if status == 401:
                return None, "HTTP 401 (authentication failed) after %s retries: %s" % (
                    MAX_RATE_LIMIT_RETRIES, err_msg or body[:300])
            return None, "HTTP %s (server error) after %s retries: %s" % (
                status, MAX_RATE_LIMIT_RETRIES, err_msg or body[:300])

        attempt += 1
        retry_after = headers.get("Retry-After") or headers.get("retry-after")
        if retry_after and str(retry_after).strip().isdigit():
            wait_secs = int(retry_after)
        wait_secs = min(wait_secs, MAX_RATE_LIMIT_WAIT)
        wait_secs = max(wait_secs, 1)
        jitter = random.randint(1, 3)
        total_wait = wait_secs + jitter

        reason = "Rate limited by %s (HTTP 429)" % PROVIDER_LABEL if status == 429 \
            else "%s returned HTTP 401 (authentication error)" % PROVIDER_LABEL if status == 401 \
            else "%s returned HTTP %s (server error)" % (PROVIDER_LABEL, status)
        job.set_status(
            "retrying",
            "%s. Retrying in %ss... (%s/%s)"
            % (reason, total_wait, attempt, MAX_RATE_LIMIT_RETRIES),
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

PAGE_TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#000000">
<title>__APP_NAME__ webchat</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    color-scheme: dark;
    --bg: #000000;
    --glass: rgba(255,255,255,0.045);
    --glass-2: rgba(255,255,255,0.08);
    --glass-3: rgba(255,255,255,0.13);
    --stroke: rgba(255,255,255,0.09);
    --stroke-2: rgba(255,255,255,0.16);
    --stroke-3: rgba(255,255,255,0.3);
    --text: #f4f4f5;
    --text-2: #a1a1aa;
    --text-3: #63636c;
    --white: #ffffff;
    --ink: #0a0a0b;
    --r-xl: 26px; --r-lg: 20px; --r-md: 14px; --r-sm: 10px; --r-xs: 7px;
    --blur: blur(18px) saturate(1.6);
    --ease-spring: cubic-bezier(0.34, 1.35, 0.4, 1);
    --ease-out: cubic-bezier(0.16, 1, 0.3, 1);
    --t: 0.26s cubic-bezier(0.16, 1, 0.3, 1);
    --font: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    --mono: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    --shadow-1: 0 2px 10px rgba(0,0,0,0.35);
    --shadow-2: 0 12px 40px rgba(0,0,0,0.5);
    --shadow-3: 0 28px 80px rgba(0,0,0,0.65);
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body { height: 100%; margin: 0; overscroll-behavior-y: none; }
  body {
    font-family: var(--font);
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
    text-rendering: optimizeLegibility;
    -webkit-text-size-adjust: 100%;
    overflow: hidden;
  }
  ::selection { background: #ffffff; color: #000000; }
  button { font-family: inherit; }
  :focus-visible { outline: 2px solid rgba(255,255,255,0.7); outline-offset: 2px; border-radius: 6px; }

  /* ---------- background ---------- */
  .bg { position: fixed; inset: 0; z-index: 0; overflow: hidden; pointer-events: none;
    background: radial-gradient(1100px 700px at 75% -12%, rgba(255,255,255,0.075), transparent 60%),
                radial-gradient(900px 600px at -10% 110%, rgba(255,255,255,0.055), transparent 55%),
                #000000; }
  .bg-grid { position: absolute; inset: -1px;
    background-image: linear-gradient(rgba(255,255,255,0.037) 1px, transparent 1px),
                      linear-gradient(90deg, rgba(255,255,255,0.037) 1px, transparent 1px);
    background-size: 46px 46px;
    -webkit-mask-image: radial-gradient(ellipse 95% 65% at 50% -5%, #000 25%, transparent 78%);
    mask-image: radial-gradient(ellipse 95% 65% at 50% -5%, #000 25%, transparent 78%); }
  .orb { position: absolute; border-radius: 50%; filter: blur(64px); will-change: transform; }
  .orb-a { width: 560px; height: 560px; top: -190px; left: -130px;
    background: radial-gradient(circle, rgba(255,255,255,0.17), rgba(255,255,255,0.03) 58%, transparent 70%);
    animation: drift-a 36s ease-in-out infinite alternate; }
  .orb-b { width: 470px; height: 470px; right: -150px; bottom: -170px;
    background: radial-gradient(circle, rgba(255,255,255,0.13), transparent 62%);
    animation: drift-b 30s ease-in-out infinite alternate; }
  .orb-c { width: 320px; height: 320px; top: 38%; left: 58%;
    background: radial-gradient(circle, rgba(255,255,255,0.085), transparent 60%);
    animation: drift-c 44s ease-in-out infinite alternate; }
  @keyframes drift-a { from { transform: translate3d(0,0,0) scale(1); } to { transform: translate3d(90px, 70px, 0) scale(1.18); } }
  @keyframes drift-b { from { transform: translate3d(0,0,0) scale(1.1); } to { transform: translate3d(-80px,-60px,0) scale(0.95); } }
  @keyframes drift-c { from { transform: translate3d(0,0,0) scale(0.9); } to { transform: translate3d(-110px,-50px,0) scale(1.2); } }
  .bg-noise { position: absolute; inset: 0; opacity: 0.06;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='2' stitchTiles='stitch'/%3E%3CfeColorMatrix type='saturate' values='0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.6'/%3E%3C/svg%3E"); }

  /* ---------- app shell ---------- */
  .app { position: relative; z-index: 1; display: flex; flex-direction: column; height: 100vh; height: 100dvh; height: var(--vvh, 100dvh); }
  .stage { flex: 1; min-height: 0; position: relative; display: flex; }

  /* ---------- header ---------- */
  .header { flex: none; position: relative; z-index: 20; }
  .header-glass { backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    background: rgba(0,0,0,0.52); border-bottom: 1px solid var(--stroke);
    transition: box-shadow 0.35s ease, border-color 0.35s ease; }
  .header.scrolled .header-glass { box-shadow: 0 12px 40px rgba(0,0,0,0.55); border-bottom-color: var(--stroke-2); }
  .header-inner { max-width: 880px; margin: 0 auto; padding: 12px 20px; display: flex; align-items: center; justify-content: space-between; gap: 12px; }
  .brand { display: flex; align-items: center; gap: 12px; min-width: 0; }
  .brand-mark { width: 36px; height: 36px; flex: none; border-radius: 11px;
    background: linear-gradient(145deg, #ffffff 0%, #c9c9d0 100%);
    color: #000; font-weight: 800; font-size: 15px; letter-spacing: -0.5px;
    display: flex; align-items: center; justify-content: center;
    box-shadow: 0 2px 14px rgba(255,255,255,0.16), inset 0 1px 0 rgba(255,255,255,0.9);
    transition: transform 0.3s var(--ease-spring); }
  .brand:hover .brand-mark { transform: rotate(-4deg) scale(1.06); }
  .brand-text { min-width: 0; }
  .brand-title { font-size: 15.5px; font-weight: 700; letter-spacing: -0.015em; white-space: nowrap; margin: 0; line-height: 1.25; }
  .brand-dim { color: var(--text-3); font-weight: 500; }
  .brand-sub { display: flex; align-items: center; gap: 7px; margin-top: 2px;
    font-family: var(--mono); font-size: 10.5px; color: var(--text-3); letter-spacing: 0.02em;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 46vw; }
  .live-dot { width: 5px; height: 5px; flex: none; border-radius: 50%; background: #fff;
    animation: live-ping 2.6s cubic-bezier(0.4, 0, 0.6, 1) infinite; }
  @keyframes live-ping {
    0% { box-shadow: 0 0 0 0 rgba(255,255,255,0.45); }
    70% { box-shadow: 0 0 0 7px rgba(255,255,255,0); }
    100% { box-shadow: 0 0 0 0 rgba(255,255,255,0); } }
  .header-actions { display: flex; gap: 8px; flex: none; }

  /* ---------- pills / buttons ---------- */
  .pill { display: inline-flex; align-items: center; gap: 8px; padding: 8px 14px;
    border-radius: 999px; border: 1px solid var(--stroke-2); background: var(--glass);
    color: var(--text); font-size: 12.5px; font-weight: 550; cursor: pointer; white-space: nowrap;
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    transition: background var(--t), border-color var(--t), transform var(--t), opacity var(--t);
    touch-action: manipulation; -webkit-user-select: none; user-select: none; }
  .pill:hover { background: var(--glass-2); border-color: var(--stroke-3); transform: translateY(-1px); }
  .pill:active { transform: scale(0.95); }
  .pill.off { opacity: 0.55; }
  .pill .icon { width: 13px; height: 13px; }
  .pill-state { font-family: var(--mono); font-size: 10px; font-weight: 600; letter-spacing: 0.08em;
    padding: 2px 7px; border-radius: 999px; background: rgba(255,255,255,0.12); color: var(--text); }
  .pill.off .pill-state { background: rgba(255,255,255,0.05); color: var(--text-3); }
  .switch { position: relative; width: 26px; height: 15px; border-radius: 999px; flex: none;
    background: rgba(255,255,255,0.1); border: 1px solid var(--stroke-2); transition: background var(--t); }
  .switch::after { content: ""; position: absolute; top: 2px; left: 2.5px; width: 9px; height: 9px;
    border-radius: 50%; background: rgba(255,255,255,0.55); transition: transform 0.3s var(--ease-spring), background var(--t); }
  .pill.on .switch { background: rgba(255,255,255,0.85); border-color: transparent; }
  .pill.on .switch::after { transform: translateX(10.5px); background: #000; }
  .pill-label { transition: opacity var(--t); }

  .btn { display: inline-flex; align-items: center; justify-content: center; gap: 8px;
    border-radius: var(--r-md); padding: 10px 20px; font-size: 13.5px; font-weight: 600;
    cursor: pointer; border: none; touch-action: manipulation;
    transition: transform var(--t), box-shadow var(--t), background var(--t), border-color var(--t), opacity var(--t); }
  .btn:active { transform: scale(0.96); }
  .btn .icon { width: 15px; height: 15px; }
  .btn-primary { background: #ffffff; color: #000; box-shadow: 0 2px 16px rgba(255,255,255,0.14); }
  .btn-primary:hover:not(:disabled) { transform: translateY(-1px); box-shadow: 0 6px 26px rgba(255,255,255,0.24); }
  .btn-ghost { background: var(--glass); color: var(--text); border: 1px solid var(--stroke-2); }
  .btn-ghost:hover:not(:disabled) { background: var(--glass-2); border-color: var(--stroke-3); transform: translateY(-1px); }
  .btn:disabled { opacity: 0.4; cursor: default; transform: none !important; box-shadow: none; }

  /* ---------- log ---------- */
  .log { flex: 1; overflow-y: auto; overflow-x: hidden; padding: 26px 20px 14px;
    display: flex; flex-direction: column; gap: 12px; width: 100%; max-width: 880px; margin: 0 auto;
    scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.14) transparent; }
  .log::-webkit-scrollbar { width: 7px; }
  .log::-webkit-scrollbar-track { background: transparent; }
  .log::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 99px; }
  .log::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,0.26); }

  /* ---------- messages ---------- */
  .msg { position: relative; max-width: 80%; padding: 13px 17px; line-height: 1.62;
    font-size: 14.8px; word-wrap: break-word; overflow-wrap: break-word;
    animation: msg-in 0.5s var(--ease-spring) both; }
  @keyframes msg-in { from { opacity: 0; transform: translateY(14px) scale(0.97); } to { opacity: 1; transform: translateY(0) scale(1); } }
  .msg.user { align-self: flex-end; background: linear-gradient(180deg, #ffffff 0%, #e9e9ee 100%);
    color: var(--ink); font-weight: 500; border-radius: var(--r-lg) var(--r-lg) var(--r-xs) var(--r-lg);
    box-shadow: 0 5px 24px rgba(255,255,255,0.06), 0 3px 10px rgba(0,0,0,0.45);
    transition: transform var(--t), box-shadow var(--t); }
  .msg.user:hover { transform: translateY(-1px); box-shadow: 0 8px 30px rgba(255,255,255,0.1), 0 4px 14px rgba(0,0,0,0.5); }
  .msg.assistant { align-self: flex-start; background: var(--glass); border: 1px solid var(--stroke);
    border-radius: var(--r-lg) var(--r-lg) var(--r-lg) var(--r-xs);
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    box-shadow: var(--shadow-1); transition: border-color var(--t), transform var(--t); }
  .msg.assistant:hover { border-color: var(--stroke-2); }
  .msg.pending { display: flex; align-items: center; min-height: 46px; }
  .typing { display: inline-flex; gap: 5px; align-items: center; padding: 3px 2px; }
  .typing i { width: 7px; height: 7px; border-radius: 50%; background: var(--text-2);
    animation: dot-bounce 1.35s ease-in-out infinite; }
  .typing i:nth-child(2) { animation-delay: 0.16s; }
  .typing i:nth-child(3) { animation-delay: 0.32s; }
  @keyframes dot-bounce { 0%, 60%, 100% { transform: translateY(0); opacity: 0.32; } 30% { transform: translateY(-6px); opacity: 1; } }
  .retry-row { display: inline-flex; align-items: center; gap: 9px; color: var(--text-2); font-size: 13.2px; }
  .retry-row .spin { animation: rotate 0.9s linear infinite; }
  @keyframes rotate { to { transform: rotate(360deg); } }
  .msg.error { align-self: flex-start; display: flex; gap: 10px; align-items: flex-start;
    background: rgba(255,255,255,0.04); border: 1px solid var(--stroke-3); color: var(--text);
    border-radius: var(--r-lg) var(--r-lg) var(--r-lg) var(--r-xs); font-size: 13.8px;
    animation: msg-in 0.5s var(--ease-spring) both, shake 0.5s ease-in-out 0.15s; }
  .msg.error .icon { width: 16px; height: 16px; flex: none; margin-top: 3px; opacity: 0.9; }
  @keyframes shake { 0%, 100% { transform: translateX(0); } 20% { transform: translateX(-6px); } 40% { transform: translateX(6px); } 60% { transform: translateX(-4px); } 80% { transform: translateX(4px); } }

  /* ---------- tool notes ---------- */
  .tool-note { align-self: flex-start; display: inline-flex; align-items: center; gap: 8px;
    max-width: 88%; font-size: 11.8px; font-weight: 500; color: var(--text-2); padding: 6px 13px;
    border-radius: 999px; background: var(--glass); border: 1px solid var(--stroke);
    font-family: var(--mono); letter-spacing: 0.01em;
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    animation: note-in 0.45s var(--ease-out) both; }
  .tool-note .icon { width: 12px; height: 12px; flex: none; opacity: 0.75; }
  .tool-note span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tool-note.auto { color: var(--text-3); background: rgba(255,255,255,0.025); border-color: var(--stroke); }
  @keyframes note-in { from { opacity: 0; transform: translateX(-10px); } to { opacity: 1; transform: translateX(0); } }

  /* ---------- markdown ---------- */
  .markdown { white-space: normal; }
  .markdown > * { animation: md-in 0.5s var(--ease-out) both; }
  .markdown > *:nth-child(1) { animation-delay: 0.03s; } .markdown > *:nth-child(2) { animation-delay: 0.08s; }
  .markdown > *:nth-child(3) { animation-delay: 0.13s; } .markdown > *:nth-child(4) { animation-delay: 0.18s; }
  .markdown > *:nth-child(5) { animation-delay: 0.23s; } .markdown > *:nth-child(6) { animation-delay: 0.28s; }
  .markdown > *:nth-child(7) { animation-delay: 0.33s; } .markdown > *:nth-child(n+8) { animation-delay: 0.38s; }
  @keyframes md-in { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: translateY(0); } }
  .markdown > *:first-child { margin-top: 0; }
  .markdown > *:last-child { margin-bottom: 0; }
  .markdown p { margin: 0 0 10px; }
  .markdown h1, .markdown h2, .markdown h3 { margin: 16px 0 8px; line-height: 1.3; font-weight: 700; color: var(--text); letter-spacing: -0.015em; }
  .markdown h1 { font-size: 1.28em; } .markdown h2 { font-size: 1.16em; } .markdown h3 { font-size: 1.05em; }
  .markdown ul, .markdown ol { margin: 0 0 10px; padding-left: 22px; }
  .markdown li { margin: 5px 0; }
  .markdown li::marker { color: var(--text-3); }
  .markdown blockquote { margin: 0 0 10px; padding: 7px 14px; border-left: 2px solid var(--stroke-3);
    color: var(--text-2); background: rgba(255,255,255,0.035); border-radius: 0 var(--r-sm) var(--r-sm) 0; }
  .markdown code { font-family: var(--mono); font-size: 0.85em; background: rgba(255,255,255,0.075);
    border: 1px solid var(--stroke); padding: 2px 6px; border-radius: 6px; }
  .markdown a { color: #ffffff; text-decoration: underline; text-decoration-color: rgba(255,255,255,0.35);
    text-underline-offset: 3px; transition: text-decoration-color var(--t); }
  .markdown a:hover { text-decoration-color: #ffffff; }
  .markdown strong { color: #ffffff; font-weight: 650; }

  /* code blocks with header + copy */
  .code-wrap { margin: 12px 0; border: 1px solid var(--stroke); border-radius: var(--r-md);
    overflow: hidden; background: rgba(0,0,0,0.55); }
  .code-head { display: flex; align-items: center; justify-content: space-between; gap: 10px;
    padding: 7px 8px 7px 14px; background: rgba(255,255,255,0.045); border-bottom: 1px solid var(--stroke); }
  .code-lang { font-family: var(--mono); font-size: 10px; font-weight: 600; letter-spacing: 0.1em;
    text-transform: uppercase; color: var(--text-3); }
  .copy-btn { display: inline-flex; align-items: center; gap: 6px; padding: 4px 10px;
    border-radius: 7px; border: 1px solid transparent; background: transparent; color: var(--text-2);
    font-family: var(--mono); font-size: 10.5px; letter-spacing: 0.04em; cursor: pointer;
    transition: background var(--t), color var(--t), border-color var(--t); }
  .copy-btn:hover { background: rgba(255,255,255,0.08); color: var(--text); border-color: var(--stroke); }
  .copy-btn:active { transform: scale(0.95); }
  .copy-btn svg { width: 12px; height: 12px; }
  .copy-btn.copied { color: #ffffff; background: rgba(255,255,255,0.1); border-color: var(--stroke-2); }
  .code-block { margin: 0; padding: 13px 15px; overflow-x: auto; scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.14) transparent; }
  .code-block::-webkit-scrollbar { height: 6px; }
  .code-block::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.12); border-radius: 99px; }
  .code-block code { font-family: var(--mono); font-size: 12.6px; line-height: 1.68; color: #e4e4e7; background: none; border: none; padding: 0; white-space: pre; }

  /* ---------- confirm card ---------- */
  .confirm-card { align-self: stretch; max-width: 100%;
    background: linear-gradient(180deg, rgba(255,255,255,0.075), rgba(255,255,255,0.03));
    border: 1px solid var(--stroke-2); border-radius: var(--r-lg); padding: 18px;
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    box-shadow: var(--shadow-2); animation: card-in 0.55s var(--ease-spring) both; }
  .confirm-card.awaiting { animation: card-in 0.55s var(--ease-spring) both, glow-pulse 2.8s ease-in-out infinite 0.6s; }
  @keyframes card-in { from { opacity: 0; transform: translateY(18px) scale(0.97); } to { opacity: 1; transform: translateY(0) scale(1); } }
  @keyframes glow-pulse {
    0%, 100% { box-shadow: var(--shadow-2), 0 0 0 3px rgba(255,255,255,0.03); }
    50% { box-shadow: var(--shadow-2), 0 0 0 3px rgba(255,255,255,0.1); } }
  .confirm-head { display: flex; align-items: flex-start; gap: 12px; }
  .confirm-ico { width: 34px; height: 34px; flex: none; border-radius: 10px; display: flex;
    align-items: center; justify-content: center; background: rgba(255,255,255,0.09);
    border: 1px solid var(--stroke-2); color: var(--text); }
  .confirm-ico .icon { width: 16px; height: 16px; }
  .confirm-titles { flex: 1; min-width: 0; }
  .confirm-title { font-size: 14.5px; font-weight: 650; letter-spacing: -0.01em; }
  .confirm-sub { font-size: 12px; color: var(--text-3); font-family: var(--mono); margin-top: 3px;
    word-break: break-all; line-height: 1.45; }
  .badge { flex: none; display: inline-flex; align-items: center; gap: 5px; font-family: var(--mono);
    font-size: 10.5px; font-weight: 600; letter-spacing: 0.06em; text-transform: uppercase;
    padding: 4px 10px; border-radius: 999px; animation: note-in 0.4s var(--ease-out) both; }
  .badge.ok { background: #ffffff; color: #000; }
  .badge.no { background: rgba(255,255,255,0.06); color: var(--text-2); border: 1px solid var(--stroke-2); }
  .confirm-preview { margin: 14px 0 0; max-height: 250px; overflow: auto; padding: 13px 15px;
    background: rgba(0,0,0,0.55); border: 1px solid var(--stroke); border-radius: var(--r-md);
    font-family: var(--mono); font-size: 12.4px; line-height: 1.55; color: #e4e4e7;
    white-space: pre-wrap; word-break: break-word;
    scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.14) transparent; }
  .confirm-actions { display: flex; gap: 10px; margin-top: 16px; flex-wrap: wrap; }

  /* ---------- composer ---------- */
  .composer-wrap { flex: none; position: relative; z-index: 20;
    padding: 10px 16px calc(14px + env(safe-area-inset-bottom, 0px)); }
  .composer-glass { max-width: 880px; margin: 0 auto; display: flex; align-items: flex-end; gap: 10px;
    padding: 10px 10px 10px 18px; border-radius: var(--r-xl);
    background: rgba(0,0,0,0.52); border: 1px solid var(--stroke-2);
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    box-shadow: var(--shadow-2); transition: border-color var(--t), box-shadow var(--t); }
  .composer-glass:focus-within { border-color: var(--stroke-3);
    box-shadow: 0 0 0 4px rgba(255,255,255,0.05), var(--shadow-2); }
  .composer-glass textarea { flex: 1; background: transparent; border: none; outline: none; resize: none;
    color: var(--text); font-family: inherit; font-size: 15px; line-height: 1.5; padding: 10px 0;
    min-height: 44px; max-height: 150px; -webkit-appearance: none; appearance: none; }
  .composer-glass textarea::placeholder { color: var(--text-3); }
  .send { width: 44px; height: 44px; min-width: 44px; border-radius: 50%; border: none; cursor: pointer;
    background: #ffffff; color: #000000; display: flex; align-items: center; justify-content: center;
    box-shadow: 0 2px 14px rgba(255,255,255,0.13); flex: none; touch-action: manipulation;
    transition: transform var(--t), box-shadow var(--t), background var(--t), opacity var(--t); }
  .send .icon { width: 17px; height: 17px; transition: transform var(--t); }
  .send:hover:not(:disabled) { transform: translateY(-2px) scale(1.05); box-shadow: 0 6px 26px rgba(255,255,255,0.25); }
  .send:hover:not(:disabled) .icon { transform: translateY(-1px); }
  .send:active:not(:disabled) { transform: scale(0.88); }
  .send:disabled { background: rgba(255,255,255,0.1); color: rgba(255,255,255,0.3); box-shadow: none; cursor: default; }
  .composer-hint { text-align: center; margin-top: 9px; font-family: var(--mono); font-size: 10px;
    letter-spacing: 0.05em; color: var(--text-3); opacity: 0.8; }
  @media (hover: none) { .composer-hint { display: none; } }

  /* ---------- welcome ---------- */
  .welcome { flex: 1; display: flex; align-items: center; justify-content: center;
    padding: 28px 20px; overflow-y: auto; }
  .welcome-inner { text-align: center; max-width: 540px; animation: welcome-in 0.7s var(--ease-spring) both; }
  @keyframes welcome-in { from { opacity: 0; transform: translateY(22px) scale(0.97); } to { opacity: 1; transform: translateY(0) scale(1); } }
  .welcome-mark { width: 58px; height: 58px; margin: 0 auto; border-radius: 17px;
    background: linear-gradient(145deg, #ffffff 0%, #c4c4cc 100%); color: #000; font-weight: 800;
    font-size: 24px; display: flex; align-items: center; justify-content: center;
    box-shadow: 0 6px 32px rgba(255,255,255,0.16), inset 0 1px 0 rgba(255,255,255,0.9);
    animation: float 5s ease-in-out infinite; }
  @keyframes float { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-7px); } }
  .welcome h2 { margin: 20px 0 12px; font-size: clamp(26px, 6vw, 36px); font-weight: 750;
    letter-spacing: -0.035em; line-height: 1.12; color: var(--text); }
  .welcome-dim { color: var(--text-3); font-weight: 500; }
  .welcome p { margin: 0 auto; max-width: 400px; color: var(--text-2); font-size: 14.5px; line-height: 1.65; }
  .chips { display: flex; flex-wrap: wrap; gap: 10px; justify-content: center; margin-top: 28px; }
  .chip { display: inline-flex; align-items: center; gap: 8px; padding: 10px 16px; border-radius: 999px;
    background: var(--glass); border: 1px solid var(--stroke); color: var(--text-2); cursor: pointer;
    font-size: 12.8px; font-weight: 550; backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    transition: background var(--t), border-color var(--t), transform var(--t), color var(--t);
    animation: chip-in 0.6s var(--ease-spring) both; touch-action: manipulation; }
  .chip:nth-child(1) { animation-delay: 0.25s; } .chip:nth-child(2) { animation-delay: 0.34s; }
  .chip:nth-child(3) { animation-delay: 0.43s; } .chip:nth-child(4) { animation-delay: 0.52s; }
  @keyframes chip-in { from { opacity: 0; transform: translateY(12px) scale(0.92); } to { opacity: 1; transform: translateY(0) scale(1); } }
  .chip .icon { width: 14px; height: 14px; opacity: 0.75; transition: transform var(--t), opacity var(--t); }
  .chip:hover { background: var(--glass-2); border-color: var(--stroke-3); color: var(--text); transform: translateY(-2px); }
  .chip:hover .icon { transform: scale(1.12); opacity: 1; }
  .chip:active { transform: scale(0.95); }

  /* ---------- jump to latest ---------- */
  .jump { position: absolute; left: 50%; bottom: 16px; transform: translateX(-50%); z-index: 15;
    width: 40px; height: 40px; border-radius: 50%; border: 1px solid var(--stroke-2);
    background: rgba(12,12,14,0.82); color: var(--text); cursor: pointer;
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur);
    display: flex; align-items: center; justify-content: center;
    box-shadow: var(--shadow-2); animation: pop-in 0.35s var(--ease-spring) both; touch-action: manipulation;
    transition: border-color var(--t), transform var(--t), box-shadow var(--t); }
  @keyframes pop-in { from { opacity: 0; transform: translateX(-50%) translateY(10px) scale(0.8); } to { opacity: 1; transform: translateX(-50%) translateY(0) scale(1); } }
  .jump:hover { border-color: var(--stroke-3); transform: translateX(-50%) translateY(-2px); }
  .jump:active { transform: translateX(-50%) scale(0.9); }
  .jump .icon { width: 17px; height: 17px; }

  /* ---------- boot screen ---------- */
  #boot { position: fixed; inset: 0; z-index: 60; display: flex; align-items: center; justify-content: center;
    background: #000; transition: opacity 0.5s ease, visibility 0.5s ease; }
  #boot.done { opacity: 0; visibility: hidden; pointer-events: none; }
  .boot-card { text-align: center; padding: 36px 44px; border-radius: var(--r-xl);
    background: var(--glass); border: 1px solid var(--stroke);
    backdrop-filter: var(--blur); -webkit-backdrop-filter: var(--blur); box-shadow: var(--shadow-2); }
  .boot-ring { width: 42px; height: 42px; margin: 0 auto 18px; border-radius: 50%;
    border: 2px solid rgba(255,255,255,0.12); border-top-color: #fff; animation: rotate 0.9s linear infinite; }
  .boot-title { font-size: 14.5px; font-weight: 650; letter-spacing: -0.01em; }
  .boot-msg { margin-top: 7px; font-family: var(--mono); font-size: 11px; color: var(--text-3); letter-spacing: 0.03em; }
  #boot.error .boot-ring { display: none; }
  #boot.error .boot-card { border-color: var(--stroke-3); }

  /* ---------- responsive ---------- */
  @media (max-width: 640px) {
    .header-inner { padding: 11px 14px; gap: 8px; }
    .brand-mark { width: 32px; height: 32px; border-radius: 9px; font-size: 13px; }
    .brand-title { font-size: 14.5px; }
    .brand-sub { font-size: 9.5px; max-width: 44vw; }
    .pill { padding: 7px 11px; font-size: 11.5px; gap: 6px; }
    .log { padding: 16px 12px 10px; gap: 10px; }
    .msg { max-width: 92%; font-size: 14.4px; padding: 12px 15px; }
    .msg.error { max-width: 92%; }
    .tool-note { max-width: 94%; }
    .confirm-card { padding: 14px; border-radius: var(--r-lg); }
    .confirm-preview { max-height: 190px; padding: 11px 12px; font-size: 11.8px; }
    .confirm-actions .btn { flex: 1; padding: 10px 14px; }
    .composer-wrap { padding: 8px 10px calc(10px + env(safe-area-inset-bottom, 0px)); }
    .composer-glass { padding: 8px 8px 8px 15px; border-radius: 24px; }
    .composer-glass textarea { font-size: 16px; min-height: 42px; }
    .send { width: 42px; height: 42px; min-width: 42px; }
    .welcome { padding: 20px 16px; }
    .welcome-mark { width: 52px; height: 52px; font-size: 21px; border-radius: 15px; }
    .chips { gap: 8px; }
    .chip { padding: 9px 13px; font-size: 12px; }
    .orb { filter: blur(42px); }
    .orb-a { width: 320px; height: 320px; } .orb-b { width: 280px; height: 280px; } .orb-c { width: 180px; height: 180px; }
  }
  @media (max-width: 400px) {
    .brand-dim { display: none; }
    .brand-title { font-size: 14px; }
    .pill { padding: 6px 9px; font-size: 11px; }
    .msg { max-width: 94%; font-size: 14px; }
    .markdown code { font-size: 0.83em; }
    .code-block code { font-size: 11.8px; }
  }
  @media (max-width: 340px) {
    .brand-sub { display: none; }
    .header-actions { gap: 6px; }
  }
  @media (min-width: 1600px) {
    .log, .composer-glass, .header-inner { max-width: 960px; }
  }
  @media (max-height: 480px) and (orientation: landscape) {
    .welcome { padding: 14px 16px; }
    .welcome h2 { margin: 12px 0 8px; }
    .chips { margin-top: 16px; }
    .log { padding: 12px 16px 8px; }
    .header-inner { padding: 8px 16px; }
    .brand-sub { display: none; }
  }
  @supports not ((backdrop-filter: blur(4px)) or (-webkit-backdrop-filter: blur(4px))) {
    .header-glass, .composer-glass, .msg.assistant, .tool-note, .confirm-card, .chip, .pill, .boot-card {
      background: rgba(8, 8, 10, 0.92); }
  }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation-duration: 0.001s !important; animation-iteration-count: 1 !important; transition-duration: 0.001s !important; }
    .orb { animation: none; }
  }
</style>
</head>
<body>
<div id="boot" aria-live="polite">
  <div class="boot-card">
    <div class="boot-ring"></div>
    <div class="boot-title">__APP_NAME__ webchat</div>
    <div class="boot-msg" id="boot-msg">Loading interface…</div>
  </div>
</div>
<div id="root"></div>
<script>
!function(){var n=function(t,e,s,u){var r;e[0]=0;for(var h=1;h<e.length;h++){var p=e[h++],a=e[h]?(e[0]|=p?1:2,s[e[h++]]):e[++h];3===p?u[0]=a:4===p?u[1]=Object.assign(u[1]||{},a):5===p?(u[1]=u[1]||{})[e[++h]]=a:6===p?u[1][e[++h]]+=a+"":p?(r=t.apply(a,n(t,a,s,["",null])),u.push(r),a[0]?e[0]|=2:(e[h-2]=0,e[h]=r)):u.push(a)}return u},t=new Map,e=function(e){var s=t.get(this);return s||(s=new Map,t.set(this,s)),(s=n(this,s.get(e)||(s.set(e,s=function(n){for(var t,e,s=1,u="",r="",h=[0],p=function(n){1===s&&(n||(u=u.replace(/^\s*\n\s*|\s*\n\s*$/g,"")))?h.push(0,n,u):3===s&&(n||u)?(h.push(3,n,u),s=2):2===s&&"..."===u&&n?h.push(4,n,0):2===s&&u&&!n?h.push(5,0,!0,u):s>=5&&((u||!n&&5===s)&&(h.push(s,0,u,e),s=6),n&&(h.push(s,n,0,e),s=6)),u=""},a=0;a<n.length;a++){a&&(1===s&&p(),p(a));for(var o=0;o<n[a].length;o++)t=n[a][o],1===s?"<"===t?(p(),h=[h],s=3):u+=t:4===s?"--"===u&&">"===t?(s=1,u=""):u=t+u[0]:r?t===r?r="":u+=t:'"'===t||"'"===t?r=t:">"===t?(p(),s=1):s&&("="===t?(s=5,e=u,u=""):"/"===t&&(s<5||">"===n[a][o+1])?(p(),3===s&&(h=h[0]),s=h,(h=h[0]).push(2,0,s),s=0):" "===t||"\t"===t||"\n"===t||"\r"===t?(p(),s=2):u+=t),3===s&&"!--"===u&&(s=4,h=h[0])}return p(),h}(e)),s),arguments,[])).length>1?s:s[0]};"undefined"!=typeof module?module.exports=e:self.htm=e}();
</script>
<script>
window.__WC_CONFIG__ = __CONFIG_JSON__;
window.__WEBCHAT_APP__ = function () {
  "use strict";
  var React = window.React;
  var ReactDOM = window.ReactDOM;
  var html = window.htm.bind(React.createElement);
  var useState = React.useState, useEffect = React.useEffect, useRef = React.useRef, useCallback = React.useCallback;

  var CONFIG = window.__WC_CONFIG__ || {};
  var APP_NAME = CONFIG.app || "Aulthium";
  var MONOGRAM = (APP_NAME.trim().charAt(0) || "A").toUpperCase();
  var UID = 0;
  function uid() { return "i" + (++UID); }
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  /* ---------- icons (feather-style, monochrome) ---------- */
  var P = {
    send: '<line x1="12" y1="19" x2="12" y2="5"></line><polyline points="5 12 12 5 19 12"></polyline>',
    plus: '<line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line>',
    alert: '<path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"></path><line x1="12" y1="9" x2="12" y2="13"></line><line x1="12" y1="17" x2="12.01" y2="17"></line>',
    zap: '<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>',
    check: '<polyline points="20 6 9 17 4 12"></polyline>',
    checkCircle: '<path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline>',
    chevronDown: '<polyline points="6 9 12 15 18 9"></polyline>',
    fileText: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line>',
    search: '<circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line>',
    terminal: '<polyline points="4 17 10 11 4 5"></polyline><line x1="12" y1="19" x2="20" y2="19"></line>',
    folder: '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path>',
    refresh: '<polyline points="23 4 23 10 17 10"></polyline><path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"></path>',
    x: '<line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line>'
  };
  function icon(name, cls) {
    return html`<svg className=${cls ? "icon " + cls : "icon"} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"
      aria-hidden="true" dangerouslySetInnerHTML=${{ __html: P[name] }} />`;
  }
  var COPY_BTN_HTML = '<button type="button" class="copy-btn"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg><span>Copy</span></button>';

  /* ---------- markdown ---------- */
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function renderMarkdown(text) {
    var blocks = [];
    var src = String(text).replace(/```(\w*)\n?([\s\S]*?)```/g, function (m, lang, code) {
      blocks.push(
        '<div class="code-wrap"><div class="code-head"><span class="code-lang">' + escapeHtml(lang || "text") +
        "</span>" + COPY_BTN_HTML + '</div><pre class="code-block"><code>' + escapeHtml(code.replace(/\n$/, "")) + "</code></pre></div>"
      );
      return "\x00BLOCK" + (blocks.length - 1) + "\x00";
    });
    src = escapeHtml(src);
    src = src.replace(/`([^`\n]+)`/g, "<code>$1</code>");
    src = src.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
    src = src.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
    src = src.replace(/__([^_\n]+)__/g, "<strong>$1</strong>");
    src = src.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
    src = src.replace(/(^|[^\w_])_([^_\n]+)_(?!\w)/g, "$1<em>$2</em>");
    src = src.replace(/^### (.*)$/gm, "<h3>$1</h3>");
    src = src.replace(/^## (.*)$/gm, "<h2>$1</h2>");
    src = src.replace(/^# (.*)$/gm, "<h1>$1</h1>");
    src = src.replace(/^&gt; ?(.*)$/gm, "<blockquote>$1</blockquote>");
    src = src.replace(/(^|\n)((?:[-*] .*(?:\n|$))+)/g, function (m, lead, block) {
      var items = block.trim().split("\n").map(function (l) { return l.replace(/^[-*] /, ""); });
      return lead + "<ul>" + items.map(function (i) { return "<li>" + i + "</li>"; }).join("") + "</ul>\n";
    });
    src = src.replace(/(^|\n)((?:\d+\. .*(?:\n|$))+)/g, function (m, lead, block) {
      var items = block.trim().split("\n").map(function (l) { return l.replace(/^\d+\.\s/, ""); });
      return lead + "<ol>" + items.map(function (i) { return "<li>" + i + "</li>"; }).join("") + "</ol>\n";
    });
    var blockTagRe = /^<(h1|h2|h3|ul|ol|li|blockquote|pre|div)/;
    var out = [];
    var para = [];
    var flush = function () {
      if (para.length) { out.push("<p>" + para.join("<br>") + "</p>"); para = []; }
    };
    src.split("\n").forEach(function (line) {
      if (line.trim() === "") { flush(); return; }
      if (blockTagRe.test(line.trim())) { flush(); out.push(line); return; }
      para.push(line);
    });
    flush();
    return out.join("\n").replace(/\x00BLOCK(\d+)\x00/g, function (m, i) { return blocks[parseInt(i, 10)]; });
  }

  /* ---------- background ---------- */
  function Background() {
    return html`<div className="bg" aria-hidden="true">
      <div className="bg-grid"></div>
      <div className="orb orb-a"></div>
      <div className="orb orb-b"></div>
      <div className="orb orb-c"></div>
      <div className="bg-noise"></div>
    </div>`;
  }

  /* ---------- header ---------- */
  function Header(props) {
    return html`<header className=${"header" + (props.scrolled ? " scrolled" : "")}>
      <div className="header-glass">
        <div className="header-inner">
          <div className="brand">
            <span className="brand-mark">${MONOGRAM}</span>
            <div className="brand-text">
              <h1 className="brand-title">${APP_NAME} <span className="brand-dim">webchat</span></h1>
              <div className="brand-sub"><span className="live-dot"></span><span>${props.provider || "provider"} · ${props.model || "model"}</span></div>
            </div>
          </div>
          <div className="header-actions">
            <button type="button" title="Toggle confirmation gates for file writes, deletes and shell commands"
              className=${"pill" + (props.confirmOn ? " on" : " off")}
              onClick=${props.onToggle}>
              <span className="switch" aria-hidden="true"></span>
              <span className="pill-label">Confirmations</span>
              <span className="pill-state">${props.confirmOn ? "ON" : "OFF"}</span>
            </button>
            <button type="button" title="Start a new chat" className="pill" onClick=${props.onNew}>
              ${icon("plus")}<span className="pill-label">New chat</span>
            </button>
          </div>
        </div>
      </div>
    </header>`;
  }

  /* ---------- confirm card ---------- */
  function ConfirmCard(props) {
    var item = props.item;
    var action = item.action || {};
    var title, sub;
    if (action.kind === "FILE_WRITE") { title = "Write to file"; sub = action.path; }
    else if (action.kind === "FILE_DELETE") { title = "Delete file"; sub = action.path; }
    else if (action.kind === "SHELL_RUN") { title = "Run shell command"; sub = "runs with your real shell privileges — not sandboxed"; }
    else { title = "Proceed with " + action.kind + "?"; sub = action.path || ""; }
    return html`<div className=${"confirm-card" + (item.decided ? "" : " awaiting")}>
      <div className="confirm-head">
        <span className="confirm-ico">${icon("alert")}</span>
        <div className="confirm-titles">
          <div className="confirm-title">${title}</div>
          ${sub ? html`<div className="confirm-sub">${sub}</div>` : null}
        </div>
        ${item.decided
          ? html`<span className=${"badge " + (item.decided === "yes" ? "ok" : "no")}>${item.decided === "yes" ? "Approved" : "Declined"}</span>`
          : null}
      </div>
      ${action.content ? html`<pre className="confirm-preview">${action.content}</pre>` : null}
      ${item.decided ? null : html`<div className="confirm-actions">
        <button type="button" className="btn btn-primary" onClick=${function () { props.onDecide(item, true); }}>${icon("check")} Yes, proceed</button>
        <button type="button" className="btn btn-ghost" onClick=${function () { props.onDecide(item, false); }}>${icon("x")} No, decline</button>
      </div>`}
    </div>`;
  }

  /* ---------- welcome ---------- */
  var SUGGESTIONS = [
    { icon: "folder", label: "List workspace files", text: "List the files in my workspace" },
    { icon: "fileText", label: "Read & summarize a file", text: "Read notes.md and summarize it for me" },
    { icon: "search", label: "Search the web", text: "Search the web for the latest AI news" },
    { icon: "terminal", label: "Run a shell command", text: "Run ls -la in the workspace and explain the output" }
  ];
  function Welcome(props) {
    return html`<div className="welcome">
      <div className="welcome-inner">
        <div className="welcome-mark">${MONOGRAM}</div>
        <h2>${APP_NAME} <span className="welcome-dim">webchat</span></h2>
        <p>Your terminal assistant, in a browser tab — it can read and write files, search the live web, and run shell commands in your workspace.</p>
        <div className="chips">
          ${SUGGESTIONS.map(function (s) {
            return html`<button type="button" key=${s.label} className="chip" onClick=${function () { props.onPick(s.text); }}>
              ${icon(s.icon)}<span>${s.label}</span>
            </button>`;
          })}
        </div>
      </div>
    </div>`;
  }

  /* ---------- composer ---------- */
  function Composer(props) {
    return html`<form className="composer-wrap" onSubmit=${props.onSubmit}>
      <div className="composer-glass">
        <textarea ref=${props.taRef} rows=${1} placeholder=${"Message " + APP_NAME + "\u2026"}
          value=${props.value} onChange=${function (e) { props.onChange(e.target.value); }}
          onKeyDown=${function (e) {
            if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); if (e.target.form) e.target.form.requestSubmit(); }
          }} aria-label="Message input"></textarea>
        <button type="submit" className="send" disabled=${props.busy || !props.value.trim()} aria-label="Send message">${icon("send")}</button>
      </div>
      <div className="composer-hint">Enter to send · Shift + Enter for a new line</div>
    </form>`;
  }

  /* ---------- app ---------- */
  function App() {
    var itemsState = useState([]);
    var items = itemsState[0], setItems = itemsState[1];
    var inputState = useState("");
    var input = inputState[0], setInput = inputState[1];
    var busyState = useState(false);
    var busy = busyState[0], setBusy = busyState[1];
    var confirmState = useState(true);
    var confirmOn = confirmState[0], setConfirmOn = confirmState[1];
    var jumpState = useState(false);
    var showJump = jumpState[0], setShowJump = jumpState[1];
    var scrollState = useState(false);
    var scrolled = scrollState[0], setScrolled = scrollState[1];

    var messagesRef = useRef([]);
    var busyRef = useRef(false);
    var logRef = useRef(null);
    var taRef = useRef(null);
    var nearBottomRef = useRef(true);

    function updateItem(id, patch) {
      setItems(function (prev) {
        return prev.map(function (it) { return it.id === id ? Object.assign({}, it, patch) : it; });
      });
    }
    function addNote(auto, text) {
      setItems(function (prev) { return prev.concat([{ id: uid(), kind: "note", auto: auto, text: text }]); });
    }

    var scrollToBottom = useCallback(function (smooth) {
      var el = logRef.current;
      if (!el) return;
      if (smooth && el.scrollTo) el.scrollTo({ top: el.scrollHeight, behavior: "smooth" });
      else el.scrollTop = el.scrollHeight;
    }, []);

    useEffect(function () {
      if (nearBottomRef.current) scrollToBottom(true);
    }, [items]);

    function onLogScroll() {
      var el = logRef.current;
      if (!el) return;
      var near = el.scrollHeight - el.scrollTop - el.clientHeight < 90;
      nearBottomRef.current = near;
      setShowJump(!near && el.scrollHeight > el.clientHeight + 120);
      setScrolled(el.scrollTop > 6);
    }

    function onLogClick(e) {
      var btn = e.target && e.target.closest ? e.target.closest(".copy-btn") : null;
      if (!btn) return;
      var wrap = btn.closest(".code-wrap");
      var codeEl = wrap ? wrap.querySelector("code") : null;
      if (!codeEl) return;
      var txt = codeEl.textContent;
      function done(ok) {
        btn.classList.toggle("copied", ok);
        var span = btn.querySelector("span");
        if (span) span.textContent = ok ? "Copied" : "Failed";
        setTimeout(function () {
          btn.classList.remove("copied");
          var s2 = btn.querySelector("span");
          if (s2) s2.textContent = "Copy";
        }, 1600);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(txt).then(function () { done(true); }, function () { done(false); });
      } else {
        try {
          var ta = document.createElement("textarea");
          ta.value = txt; ta.style.position = "fixed"; ta.style.opacity = "0";
          document.body.appendChild(ta); ta.select();
          document.execCommand("copy"); document.body.removeChild(ta);
          done(true);
        } catch (err) { done(false); }
      }
    }

    async function pollJob(jobId, pid) {
      var since = 0;
      for (;;) {
        var data;
        try {
          var res = await fetch("/api/chat/poll?id=" + encodeURIComponent(jobId) + "&since=" + since);
          data = await res.json();
        } catch (e) { await sleep(800); continue; }
        since = data.event_count || since;
        (data.events || []).forEach(function (ev) { addNote(ev.type === "auto", ev.text); });
        if (data.status === "working" || data.status === "retrying") {
          updateItem(pid, { kind: "pending", state: data.status, detail: data.detail || "thinking..." });
          await sleep(500);
          continue;
        }
        if (data.status === "confirm" && data.action) {
          var cid = uid();
          setItems(function (prev) {
            return prev.filter(function (it) { return it.id !== pid; })
              .concat([{ id: cid, kind: "confirm", action: data.action, jobId: jobId, decided: null }]);
          });
          return;
        }
        if (data.status === "done") {
          var reply = data.reply || "";
          messagesRef.current.push({ role: "assistant", content: reply });
          updateItem(pid, { kind: "assistant", html: renderMarkdown(reply), state: null, detail: null });
          return;
        }
        if (data.status === "error") {
          updateItem(pid, { kind: "error", text: "Error: " + (data.error || "unknown error"), state: null, detail: null });
          return;
        }
        await sleep(500);
      }
    }

    async function handleConfirm(item, approved) {
      updateItem(item.id, { decided: approved ? "yes" : "no" });
      try {
        await fetch("/api/chat/confirm", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ id: item.jobId, approved: approved })
        });
      } catch (e) { /* keep going — the server times out on its own */ }
      var pid = uid();
      nearBottomRef.current = true;
      setItems(function (prev) { return prev.concat([{ id: pid, kind: "pending", state: "working" }]); });
      await sleep(300);
      await pollJob(item.jobId, pid);
    }

    async function send(text) {
      if (busyRef.current) return;
      busyRef.current = true;
      setBusy(true);
      nearBottomRef.current = true;
      messagesRef.current.push({ role: "user", content: text });
      var pid = uid();
      setItems(function (prev) {
        return prev.concat([{ id: uid(), kind: "user", text: text }, { id: pid, kind: "pending", state: "working" }]);
      });
      try {
        var res = await fetch("/api/chat", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ messages: messagesRef.current })
        });
        var started = await res.json();
        if (started.error) throw new Error(started.error);
        await pollJob(started.job_id, pid);
      } catch (err) {
        updateItem(pid, { kind: "error", text: "Error: " + (err && err.message ? err.message : String(err)), state: null, detail: null });
      } finally {
        busyRef.current = false;
        setBusy(false);
        var ta = taRef.current;
        if (ta && window.matchMedia && window.matchMedia("(pointer: fine)").matches) ta.focus();
      }
    }

    async function handleSubmit(e) {
      e.preventDefault();
      if (busyRef.current) return;
      var text = input.trim();
      if (!text) return;
      setInput("");
      await send(text);
    }

    function newChat() {
      messagesRef.current = [];
      setItems([]);
      setInput("");
      setShowJump(false);
      var ta = taRef.current;
      if (ta && window.matchMedia && window.matchMedia("(pointer: fine)").matches) ta.focus();
    }

    async function toggleConfirm() {
      try {
        var res = await fetch("/api/confirm-toggle", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ value: !confirmOn })
        });
        var d = await res.json();
        setConfirmOn(!!d.confirm);
      } catch (e) { }
    }

    useEffect(function () {
      fetch("/api/status").then(function (r) { return r.json(); }).then(function (d) {
        setConfirmOn(!!d.confirm);
      }).catch(function () { });
    }, []);

    useEffect(function () {
      var ta = taRef.current;
      if (!ta) return;
      ta.style.height = "auto";
      ta.style.height = Math.min(ta.scrollHeight, 150) + "px";
    }, [input]);

    useEffect(function () {
      var favicon = document.createElement("link");
      favicon.rel = "icon";
      favicon.href = "data:image/svg+xml," + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="15" fill="#ffffff"/><text x="32" y="44" font-family="Arial,Helvetica,sans-serif" font-size="34" font-weight="800" text-anchor="middle" fill="#000000">' + MONOGRAM + "</text></svg>"
      );
      document.head.appendChild(favicon);
      if (window.visualViewport) {
        var vv = window.visualViewport;
        var onVV = function () {
          document.documentElement.style.setProperty("--vvh", vv.height + "px");
          if (nearBottomRef.current && logRef.current) scrollToBottom(false);
        };
        vv.addEventListener("resize", onVV);
        onVV();
      }
    }, []);

    function renderItem(it) {
      if (it.kind === "user") {
        return html`<div key=${it.id} className="msg user">${it.text}</div>`;
      }
      if (it.kind === "assistant") {
        return html`<div key=${it.id} className="msg assistant markdown" dangerouslySetInnerHTML=${{ __html: it.html }}></div>`;
      }
      if (it.kind === "pending") {
        return html`<div key=${it.id} className="msg assistant pending">
          ${it.state === "retrying"
            ? html`<span className="retry-row">${icon("refresh", "spin")}<span>${it.detail || "thinking..."}</span></span>`
            : html`<span className="typing" aria-label="Assistant is thinking"><i></i><i></i><i></i></span>`}
        </div>`;
      }
      if (it.kind === "error") {
        return html`<div key=${it.id} className="msg error">${icon("alert")}<div>${it.text}</div></div>`;
      }
      if (it.kind === "note") {
        return html`<div key=${it.id} className=${"tool-note" + (it.auto ? " auto" : "")}>
          ${icon(it.auto ? "checkCircle" : "zap")}<span>${it.text}</span>
        </div>`;
      }
      if (it.kind === "confirm") {
        return html`<${ConfirmCard} key=${it.id} item=${it} onDecide=${handleConfirm} />`;
      }
      return null;
    }

    return html`<div className="app">
      <${Background} />
      <${Header} scrolled=${scrolled} confirmOn=${confirmOn} onToggle=${toggleConfirm}
        onNew=${newChat} provider=${CONFIG.provider} model=${CONFIG.model} />
      <div className="stage">
        ${items.length === 0
          ? html`<${Welcome} onPick=${function (t) { setInput(t); var ta = taRef.current; if (ta) ta.focus(); }} />`
          : html`<div className="log" ref=${logRef} onScroll=${onLogScroll} onClick=${onLogClick} role="log" aria-live="polite">
              ${items.map(renderItem)}
            </div>`}
        ${showJump
          ? html`<button type="button" className="jump" aria-label="Jump to latest message"
              onClick=${function () { nearBottomRef.current = true; scrollToBottom(true); }}>${icon("chevronDown")}</button>`
          : null}
      </div>
      <${Composer} value=${input} onChange=${setInput} onSubmit=${handleSubmit} busy=${busy} taRef=${taRef} />
    </div>`;
  }

  var root = ReactDOM.createRoot(document.getElementById("root"));
  root.render(html`<${App} />`);
  var boot = document.getElementById("boot");
  if (boot) boot.classList.add("done");
};
</script>
<script>
(function () {
  function load(src) {
    return new Promise(function (res, rej) {
      var s = document.createElement("script");
      s.src = src;
      s.async = true;
      s.onload = function () { res(); };
      s.onerror = function () { rej(new Error("failed to load " + src)); };
      document.head.appendChild(s);
    });
  }
  function loadPair(primary, fallback) {
    return load(primary).catch(function () { return load(fallback); });
  }
  var REACT = ["https://cdn.jsdelivr.net/npm/react@18.3.1/umd/react.production.min.js",
               "https://unpkg.com/react@18.3.1/umd/react.production.min.js"];
  var REACT_DOM = ["https://cdn.jsdelivr.net/npm/react-dom@18.3.1/umd/react-dom.production.min.js",
                   "https://unpkg.com/react-dom@18.3.1/umd/react-dom.production.min.js"];
  function bootFail() {
    var boot = document.getElementById("boot");
    var msg = document.getElementById("boot-msg");
    if (boot) boot.classList.add("error");
    if (msg) msg.textContent = "Could not load React from CDN — check your internet connection and reload.";
  }
  loadPair(REACT[0], REACT[1])
    .then(function () { return loadPair(REACT_DOM[0], REACT_DOM[1]); })
    .then(function () {
      try {
        if (!window.React || !window.ReactDOM || !window.htm) throw new Error("React did not initialize");
        window.__WEBCHAT_APP__();
      } catch (e) {
        var boot = document.getElementById("boot");
        var msg = document.getElementById("boot-msg");
        if (boot) boot.classList.add("error");
        if (msg) msg.textContent = "Interface error: " + (e && e.message ? e.message : e);
      }
    })
    .catch(bootFail);
})();
</script>
</body>
</html>
"""

PAGE = (
    PAGE_TEMPLATE
    .replace("__APP_NAME__", APP_NAME)
    .replace("__PROVIDER_LABEL__", PROVIDER_LABEL)
    .replace("__MODEL__", MODEL or "(no model set)")
    .replace(
        "__CONFIG_JSON__",
        json.dumps({
            "app": APP_NAME,
            "provider": PROVIDER_LABEL,
            "model": MODEL or "(no model set)",
        }).replace("</", "<\\/"),
    )
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
    start_port = _cfg_int("port", "AULTHIUM_WEBCHAT_PORT", 8420)
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
