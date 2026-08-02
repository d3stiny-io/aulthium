#!/usr/bin/env bash
set -u

# Resolved once, up front, before anything else touches $0 — this is the
# real on-disk path auto-update will eventually overwrite (via `mv`, see
# the "AUTO-UPDATE" section below). If Aulthium was piped straight into
# bash (curl ... | bash) instead of run from a saved file, this comes back
# empty/unusable and auto-update quietly disables itself — there's nothing
# on disk to replace.
SELF_SCRIPT_PATH="$(realpath -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"

# AULTHIUM
# Single-file Bash terminal AI client for Termux / Linux
# Talks to either OpenRouter or Google AI Studio, chosen via 't> provider'.
# Conversation stays in memory only while the process is running.

APP_NAME="AULTHIUM"
APP_VERSION="v1.0.3"
OPENROUTER_URL="https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_MODELS_URL="https://openrouter.ai/api/v1/models"
GOOGLE_API_BASE="https://generativelanguage.googleapis.com/v1beta"
DEFAULT_MODEL="openrouter/free"
DEFAULT_GOOGLE_MODEL="gemini-2.0-flash"

# Which backend we're talking to: "openrouter" or "google". Everything that
# depends on this (API key, endpoint, request/response shape, model list)
# is looked up through this single switch rather than duplicated per call
# site, so 't> provider' only ever needs to flip this one variable.
# Left empty on purpose — main() forces an explicit choice at startup via
# pick_provider_startup rather than silently defaulting to one backend.
PROVIDER=""

# Kept separate (rather than one shared API_KEY) so switching providers
# back and forth during a session never throws away a key you already
# entered for the other one.
OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"
GOOGLE_KEY="${GOOGLE_API_KEY:-}"

# "Other Providers" — any OpenAI-compatible /chat/completions endpoint the
# user points at directly (self-hosted: Ollama, LM Studio, llama.cpp, vLLM,
# text-generation-webui, or a third-party host using the same shape).
# CUSTOM_REQUIRES_KEY is set by the user at setup time ('Is an API key
# required?') — many self-hosted setups have no key at all, so this is
# never assumed to be 1 by default.
CUSTOM_URL="${CUSTOM_API_URL:-}"
CUSTOM_KEY="${CUSTOM_API_KEY:-}"
CUSTOM_REQUIRES_KEY=1

# Built-in OpenAI-compatible providers beyond OpenRouter/Google. Each has a
# fixed, known endpoint (unlike "Other Providers" above, which asks the user
# to type one), so picking one of these only ever prompts for an API key.
MISTRAL_URL="https://api.mistral.ai/v1/chat/completions"
MISTRAL_KEY="${MISTRAL_API_KEY:-}"
DEFAULT_MISTRAL_MODEL="mistral-large-latest"

# Hugging Face Inference Providers router — one OpenAI-compatible endpoint
# in front of many hosted backends (Together, Groq, Cerebras, etc). Model
# IDs take the form "<repo>:<provider>", e.g. "moonshotai/Kimi-K2-Instruct-0905:groq";
# ":auto" lets HF pick a provider for you.
HF_URL="https://router.huggingface.co/v1/chat/completions"
HF_KEY="${HF_API_KEY:-${HUGGINGFACE_API_KEY:-}}"
DEFAULT_HF_MODEL="meta-llama/Llama-3.3-70B-Instruct:auto"

# NVIDIA NIM (build.nvidia.com) — OpenAI-compatible endpoint fronting 100+
# hosted open-weight models on NVIDIA infra, free tier via a developer key
# (starts with "nvapi-"). Defaults to Kimi K2.6.
NVIDIA_URL="https://integrate.api.nvidia.com/v1/chat/completions"
NVIDIA_KEY="${NVIDIA_API_KEY:-}"
DEFAULT_NVIDIA_MODEL="moonshotai/kimi-k2.6"

# MCP (Model Context Protocol) — remote HTTP servers only (no local/stdio
# spawning). Each server is a JSON-RPC 2.0 endpoint speaking the MCP
# "Streamable HTTP" transport. Tools discovered from connected servers are
# folded into the system prompt alongside the built-in FILE_READ/WEB_SEARCH/
# etc markers, so the model can invoke them the same way — see
# mcp_tools_prompt_block and the MCP_CALL marker in build_system_prompt.
# Parallel arrays, one entry per configured server (index-aligned, like the
# write/edit arrays in process_agent_reply).
MCP_NAMES=()
MCP_URLS=()
MCP_KEYS=()
MCP_SESSION_IDS=()
MCP_PROTO_VERSIONS=() # protocolVersion the server actually negotiated at initialize; "" until connected
MCP_TOOLS_JSON=()   # one JSON array of {name,description,inputSchema} per server; "[]" until discovered
MCP_RPC_NEXT_ID=1

# Servers can be pre-configured at launch via the MCP_SERVERS env var:
#   MCP_SERVERS="name1=https://host1/mcp,name2=https://host2/mcp"
# with an optional per-server bearer key picked up from
# MCP_<NAME>_KEY (name uppercased, non-alphanumeric chars turned into "_").
# Anything beyond that is managed at runtime with 't> mcp add/remove/list/refresh'.

# ── Auto-update ──────────────────────────────────────────────────────────
# Point AULTHIUM_UPDATE_URL at a raw copy of this same script (e.g. a
# GitHub "raw" URL) to turn this on. Design goal: never interrupt a live
# session. Checks and downloads always happen in a detached background
# job — the chat loop is never blocked waiting on them. When a newer
# version is confirmed (version compare + syntax check + a sanity check
# that it's actually an Aulthium script), it's swapped onto disk via an
# atomic same-directory `mv`. That's the trick that makes it non-disruptive:
# this process still has the OLD file open, so it keeps running the old
# code uninterrupted no matter when the swap happens — the new file is
# just what's there the next time Aulthium is launched. See the
# "AUTO-UPDATE" functions below (autoupdate_worker and friends).
AUTOUPDATE_URL="${AULTHIUM_UPDATE_URL:-}"
AUTOUPDATE_ENABLED=1                                    # session toggle — 't> update on/off'
AUTOUPDATE_INTERVAL_SECS="${AULTHIUM_UPDATE_INTERVAL:-21600}"  # 6h between automatic checks
AUTOUPDATE_STATE_DIR=""       # session-scoped scratch dir (lock/ready/error markers)
AUTOUPDATE_LOCK_FILE=""
AUTOUPDATE_READY_FILE=""      # holds the new version string once a swap has been applied
AUTOUPDATE_ERROR_FILE=""      # holds the last check's failure reason, if any
AUTOUPDATE_LAST_CHECK_FILE="" # persists across runs so restarts don't re-check every launch
AUTOUPDATE_NOTIFIED=0         # so the "update is ready" notice only prints once per session

CURRENT_MODEL="$DEFAULT_MODEL"
CURRENT_MODEL_LABEL="$DEFAULT_MODEL"

# Sandbox directory the agent is allowed to create/edit/delete files in.
# Every file action is confined to this folder — nothing outside it is ever touched.
WORKSPACE_DIR=""

# Global on/off switch for the y/N confirmation blocker in front of every
# file-changing action, shell command, and MCP tool call. Defaults ON (1 =
# ask first) since that's the safe behavior; 't> confirm off' flips this to
# 0, at which point confirm_yes_no auto-approves everything instantly
# instead of prompting. The action is still always PRINTED to the screen
# either way — this only removes the "do you want to proceed?" gate, not
# the visibility.
SKIP_CONFIRMATIONS=0

# In-memory conversation history only.
# We keep the system prompt in the history from the start.
build_system_prompt() {
  cat <<EOF
You are Aulthium, a helpful terminal-based AI assistant. Answer clearly and concisely. Be practical, friendly, and accurate.

You operate on a single sandbox folder: $WORKSPACE_DIR
Every path you reference in a marker below MUST be a relative path inside that folder. Never use absolute paths, and never use ".." to escape it.

=== THINKING (optional, private — never shown to the user as text) ===

If a request needs real reasoning first — picking between actions, working out which path is right, planning
a multi-step change — you may open your reply with a block EXACTLY like this:
<<<THINKING>>>
your private reasoning goes here, kept short
<<<END_THINKING>>>

While you're generating a reply, the user only ever sees a generic loading spinner; this block is stripped
out and never displayed, so don't write anything in it you expect the user to read, and never leave it as
your only content. Keep it a few lines, not an essay, and skip it entirely for simple replies — most turns
don't need one. Always follow it with your real final answer or your action marker(s).

=== READING / INSPECTING (no confirmation needed, results are sent back to you) ===

To read a text file's contents, output a line EXACTLY like this:
<<<FILE_READ path="relative/path.txt">>>
The content comes back numbered as "N: text" (one line per source line). Those numbers are ONLY for you to
target lines with FILE_EDIT below — never show them to the user unless they specifically asked to see raw
line numbers.

To list the contents of a folder, output a line EXACTLY like this:
<<<DIR_LIST path="relative/folder">>>
(use path="." to list the workspace root)

To list the entries inside a zip archive without extracting it, output a line EXACTLY like this:
<<<ZIP_LIST path="relative/archive.zip">>>

To read one specific entry's contents from inside a zip archive, output a line EXACTLY like this:
<<<ZIP_READ path="relative/archive.zip" entry="path/inside/zip.txt">>>

To search the live web for current information you don't already know (news, prices, facts that may have
changed, anything time-sensitive), output a line EXACTLY like this:
<<<WEB_SEARCH query="your search terms">>>
This has nothing to do with the sandbox folder — it's a real, free web search, and results are a snapshot
from the moment you asked, not guaranteed up to the second. If it returns nothing useful, say so plainly
instead of guessing an answer.
$(mcp_tools_prompt_block)
You can issue several of the above in one reply. Their results are appended to the conversation as a
follow-up message and you will automatically be prompted again with that information, so you can request
something, wait for the result, and then give your real answer or take further action in a later turn.
Large or binary files are truncated/rejected — you'll be told when that happens.

=== CHANGING FILES (shown to the user, requires explicit yes/no confirmation) ===

To create or overwrite a file, output a block EXACTLY like this (nothing else on those marker lines):
<<<FILE_WRITE path="relative/path.txt">>>
the full file content goes here
<<<END_FILE_WRITE>>>

To change only SOME lines of an existing file (instead of retyping the whole file), output one of these
three block forms:

Replace a line range with new content:
<<<FILE_EDIT path="relative/path.txt" op="replace" start="5" end="8">>>
the lines that will replace old lines 5-8, one per line
<<<END_FILE_EDIT>>>

Insert new lines after a given line (use after="0" to insert at the very top):
<<<FILE_EDIT path="relative/path.txt" op="insert" after="12">>>
the new lines to insert, one per line
<<<END_FILE_EDIT>>>

Delete a line range (no body needed, leave it empty):
<<<FILE_EDIT path="relative/path.txt" op="delete" start="5" end="8">>>
<<<END_FILE_EDIT>>>

Line numbers refer to the file's CURRENT state as of your last FILE_READ of it — always FILE_READ the file
(or use a fresh result already in this conversation) before an edit if you're not certain line numbers still
match, since a prior edit in the same turn shifts every line after it. Only issue one FILE_EDIT per file per
round so the numbers stay valid; if you need several edits to the same file, do them one at a time, letting
each edit's confirmation apply before you reference line numbers again. Prefer FILE_EDIT over FILE_WRITE for
any change to an EXISTING file — it keeps your output small (less to type, less chance of hitting the round
limit or getting cut off mid-file) and the user sees exactly what changed. Reach for full FILE_WRITE only when
creating a brand-new file or when you genuinely mean to replace the entire contents.

To delete a single file, output a line EXACTLY like this:
<<<FILE_DELETE path="relative/path.txt">>>

To delete a folder and everything inside it, output a line EXACTLY like this:
<<<FOLDER_DELETE path="relative/folder">>>

To create an empty folder on its own (not just as a side effect of writing a file into it), output a line EXACTLY like this:
<<<FOLDER_CREATE path="relative/folder">>>

FILE_WRITE will also create any missing parent folders for that file as part of the same confirmation, so you
don't need a separate FOLDER_CREATE before writing a file into a new folder — only use FOLDER_CREATE when you
want an empty folder with no file in it yet. FOLDER_DELETE removes the folder and all of its contents
recursively — only propose it when you actually mean to delete everything inside that folder, and the user
must explicitly confirm it just like every other file-changing action.

To move or rename a file, output a line EXACTLY like this:
<<<FILE_MOVE path="relative/old/path.txt" to="relative/new/path.txt">>>

To move or rename a folder (and everything inside it), output a line EXACTLY like this:
<<<FOLDER_MOVE path="relative/old/folder" to="relative/new/folder">>>

A rename is just a move to a new name in the same parent folder — use FILE_MOVE/FOLDER_MOVE for both; there is
no separate "rename" marker. Both "path" and "to" are relative paths inside the sandbox, same rules as every
other marker. Missing parent folders in the destination are created automatically. If "to" is an existing
folder, the item is dropped inside it under its own name (same as the Unix \`mv\` command) — you do not need to
spell out the final filename yourself when moving something into a folder that already exists. Moving a folder
inside itself or its own subfolder is always refused, no matter what.

If "to" resolves to something that already exists (not counting the "move into an existing folder" case
above), add an optional conflict= attribute to say how to handle it — conflict="overwrite" replaces it,
conflict="rename" picks a free name like "name (1).txt" automatically, and conflict="skip" (the default when
conflict= is omitted) leaves it untouched and skips that move. Example:
<<<FILE_MOVE path="draft.txt" to="final/draft.txt" conflict="rename">>>

To zip up one or more existing sandboxed files/folders into a new archive, output a block EXACTLY like
this — one relative source path per line:
<<<ZIP_CREATE path="relative/archive.zip">>>
relative/source/file-or-folder-one
relative/source/file-or-folder-two
<<<END_ZIP_CREATE>>>
If the archive path already exists it is overwritten (the confirmation prompt says so).

To extract every entry of a sandboxed archive into a sandboxed destination folder, output a line EXACTLY
like this:
<<<ZIP_EXTRACT path="relative/archive.zip" to="relative/destination">>>
Add conflict="overwrite" to replace files that already exist at the destination; the default,
conflict="skip", leaves any existing file untouched and only extracts entries that don't already exist there.

=== BULK FILE/FOLDER OPERATIONS (scaffolding, cleanup — one confirmation for the whole batch) ===

FILE_WRITE / FOLDER_CREATE / FILE_DELETE / FOLDER_DELETE / FILE_MOVE / FOLDER_MOVE each get their own
individual yes/no prompt. That's fine for a single change, but for anything creating, writing, deleting, or
moving THREE OR MORE files/folders in one go (scaffolding a new project, generating a batch of related files,
cleaning up or reorganizing a set of old ones), use the bulk form instead — the user reviews and approves the
whole batch in one prompt instead of one per item.

To create or overwrite several files at once, output a block EXACTLY like this:
<<<BULK_WRITE>>>
<<<ITEM path="relative/path/one.txt">>>
full content of the first file
<<<END_ITEM>>>
<<<ITEM path="relative/path/two.txt">>>
full content of the second file
<<<END_ITEM>>>
<<<END_BULK_WRITE>>>
(any number of ITEM blocks, each with its own path and full content — same content rules as FILE_WRITE, and
missing parent folders are created automatically per item, same as FILE_WRITE)

To create several empty folders at once, output a block EXACTLY like this — one relative path per line,
nothing else on each line:
<<<BULK_FOLDER_CREATE>>>
relative/folder/one
relative/folder/two
relative/folder/three
<<<END_BULK_FOLDER_CREATE>>>

To delete several files and/or folders at once, output a block EXACTLY like this — one relative path per
line. You do NOT need to know or say whether each path is a file or a folder; that's detected automatically
and the right kind of removal is applied to each:
<<<BULK_DELETE>>>
relative/path/to/old-file.txt
relative/path/to/old-folder
<<<END_BULK_DELETE>>>

To move or rename several files and/or folders at once, output a block EXACTLY like this — one ITEM line per
entry, and unlike BULK_DELETE you DO need to say whether each one is a "file" or "folder" via kind=. The same
"move into an existing folder" behavior and optional conflict= attribute (overwrite/skip/rename, default
skip) from FILE_MOVE/FOLDER_MOVE apply to each item here too:
<<<BULK_MOVE>>>
<<<ITEM path="relative/old/one.txt" to="relative/new/one.txt" kind="file">>>
<<<ITEM path="relative/old-folder" to="relative/new-folder" kind="folder">>>
<<<ITEM path="relative/old/two.txt" to="relative/new/two.txt" kind="file" conflict="overwrite">>>
<<<END_BULK_MOVE>>>

For one or two items, still prefer the single-item FILE_WRITE/FOLDER_CREATE/FILE_DELETE/FOLDER_DELETE/
FILE_MOVE/FOLDER_MOVE markers — bulk markers exist to save the user from a wall of repeated prompts on a real
batch, not to be used for every change by default.

=== RUNNING SHELL COMMANDS (shown to the user, requires explicit yes/no confirmation) ===

To run one or more shell commands, output a block EXACTLY like this:
<<<SHELL_RUN>>>
the shell command(s) go here
<<<END_SHELL_RUN>>>

The command runs with the workspace folder ($WORKSPACE_DIR) as its current directory, using the user's real
shell privileges — it is NOT confined to the sandbox the way file actions are, so only propose commands you
are confident are safe, relevant, and non-destructive, and never propose a command aimed at files or paths
outside the workspace. The user always sees the exact command text and must approve it before it runs.
Prefer FILE_READ / FILE_WRITE / DIR_LIST for simple file inspection or edits; reach for SHELL_RUN when you
actually need to execute something (e.g. running a build, a script, git, or a CLI tool). Output from the
command (stdout/stderr, possibly truncated) is sent back to you the same way as the reading markers above.

=== NETWORK REQUESTS (shown to the user, requires explicit yes/no confirmation) ===

To send an HTTP GET request and see the response, output a line EXACTLY like this:
<<<NET_GET url="https://example.com/api/thing">>>

To send an HTTP POST request with a body, output a block EXACTLY like this (content_type= is optional,
defaults to application/json):
<<<NET_POST url="https://example.com/api/thing" content_type="application/json">>>
the request body goes here
<<<END_NET_POST>>>

To download a URL's content straight into a sandboxed file, output a line EXACTLY like this:
<<<NET_DOWNLOAD url="https://example.com/file.zip" path="relative/save/path.zip">>>

All three reach the real internet, not just the sandbox, so treat them like SHELL_RUN: only propose a request
you're confident is safe and relevant, and expect the user to review the exact URL (and body, for POST) before
approving it. Responses are truncated if very large, and NET_DOWNLOAD refuses anything over 100MB. Use
WEB_SEARCH instead of NET_GET when you just need to find information — reach for NET_GET/NET_POST when you
already know the specific URL/API endpoint to call, and NET_DOWNLOAD only when you want the raw response saved
as a file rather than read back to you as text.

=== TOOL USE POLICY (avoid wasting actions) ===

You get a limited number of action rounds per user message ($MAX_AGENT_ROUNDS) before you're cut off and
asked to wrap up, so spend them deliberately:
- Never call a read/inspect marker (FILE_READ, DIR_LIST, ZIP_LIST, ZIP_READ, WEB_SEARCH, NET_GET) for something
  already shown earlier in this same conversation — check what you already know before asking again.
- Only inspect something when the answer or action genuinely depends on it. Don't DIR_LIST or FILE_READ
  "just to be safe" when the user's request doesn't hinge on the current state of that path. Only WEB_SEARCH
  when the answer genuinely depends on current/real-time information — not for things you already know.
- If you already know you'll need several independent reads, issue them together in one reply instead of
  one per round.
- Never repeat the exact same marker with the exact same arguments — if it already ran once this
  conversation, reuse that result instead of asking again.
- For a file-changing or shell action, only precede it with a read/list check when there's real uncertainty
  about the current state (e.g. you don't know whether a target already exists). The user still confirms the
  exact path before anything happens, so a reflexive check-first-every-time habit is usually wasted.
- If the user's request is simple enough to answer or act on directly, skip tools altogether and just answer.
- For edits to an existing file, use FILE_EDIT for the specific lines that change rather than FILE_WRITE-ing
  the whole file — it uses far fewer of your output tokens per round, which is what actually causes the round
  limit or a mid-file cutoff, not the number of actions you take.

=== OUTPUT STYLE ===

Write your final answer as plain, direct terminal text a person can read at a glance:
- Lead with the actual answer, not a restatement of the question or a wall of setup.
- Keep it to short paragraphs or a plain hyphen list for multiple points — no heavy markdown headers or
  tables, this renders in a terminal.
- Don't paste back large tool output verbatim; the user already saw it above in its own box. Summarize or
  reference it instead.
- Be concise by default; go longer only when the task genuinely needs it (e.g. showing real file contents or
  command output the user asked to see).

If the user asks for something outside those bounds, explain the limitation instead.

IMPORTANT: The ONLY valid syntax for any action is the exact triple-angle-bracket markers shown above,
e.g. <<<DIR_LIST path=".">>> on its own line, character-for-character. Do NOT use any other format such as
<tool_call>, <function_call>, JSON, or anything resembling a generic tool-calling convention — none of those
are recognized and the action will silently fail to run. If you are not issuing one of the exact markers
above, just write plain text.

=== WORKED EXAMPLE ===

User: "what's in notes.txt?"
Your entire reply should be just:
<<<FILE_READ path="notes.txt">>>

(Nothing else on that line, no quotes around the whole thing, no backticks, no <tool_call> wrapper — just
that one line by itself. You'll be sent the file contents in a follow-up message, and only then should you
write your real answer as plain text.)

User: "create a file called hello.txt with 'hi there' in it"
Your entire reply should be just:
<<<FILE_WRITE path="hello.txt">>>
hi there
<<<END_FILE_WRITE>>>

User: "what's the current price of bitcoin?"
Your entire reply should be just:
<<<WEB_SEARCH query="bitcoin price today">>>

(Same rule as FILE_READ above — just that one line, nothing else. You'll get search results back in a
follow-up message, then answer using them, noting they're a snapshot from just now.)
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    echo "Install it first and run this script again."
    exit 1
  }
}

# ── Palette ────────────────────────────────────────────────────────────────
# Single source of truth for color. Everything else in the UI pulls from
# these instead of inlining escape codes, so the whole app reads as one
# consistent, deliberate visual identity rather than a patchwork.
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_ACCENT=$'\033[1;36m'    # cyan    — brand, headers, agent's spoken replies
C_ACCENT2=$'\033[1;35m'   # magenta — tool/action activity
C_OK=$'\033[1;32m'        # green   — success
C_WARN=$'\033[1;33m'      # yellow  — caution
C_ERR=$'\033[1;31m'       # red     — failure / danger
C_MUTED=$'\033[2;37m'     # dim     — secondary text, paths, meta

# ── Iconography ────────────────────────────────────────────────────────────
# One glyph per action type, used everywhere that action is shown so the eye
# learns to recognize it at a glance. Plain box-drawing/typographic symbols
# only — no emoji — so it renders identically on Termux, SSH, and desktop.
ICON_READ="▸"     # inspecting a file
ICON_DIR="▤"      # listing a folder
ICON_ZIP="▥"      # zip archive activity
ICON_WRITE="✎"    # writing/overwriting a file
ICON_EDIT="✐"     # editing specific lines of a file
ICON_DELETE="✕"   # deleting a file
ICON_FOLDER="+"   # creating a folder
ICON_MOVE="⇒"     # moving/renaming a file or folder
ICON_SHELL="❯"    # running a shell command
ICON_SEARCH="⌕"   # web search
ICON_MCP="⚡"      # MCP server tool call
ICON_NET="↯"      # HTTP request / download
ICON_UNDO="↺"     # undo/redo
ICON_OK="✓"
ICON_WARN="⚠"
ICON_ERR="✗"

say() {
  printf "${C_ACCENT}%s${C_RESET}\n" "$*" >&2
}

warn() {
  printf "${C_WARN}${ICON_WARN} %s${C_RESET}\n" "$*" >&2
}

err() {
  printf "${C_ERR}${ICON_ERR} %s${C_RESET}\n" "$*" >&2
}

ok() {
  printf "${C_OK}${ICON_OK} %s${C_RESET}\n" "$*" >&2
}

muted() {
  printf "${C_MUTED}%s${C_RESET}\n" "$*" >&2
}

# A single 48-char rule used to build boxed section headers/footers of a
# consistent width, regardless of title length.
RULE_LINE="────────────────────────────────────────────────"

# box_top "TITLE" "$ICON" "$COLOR" — opens a labeled section, e.g.:
#   ┌─ ▸ FILE READ ──────────────────────────────
# Appends the full rule after the label rather than padding to an exact
# total width — computing that padding via byte-offset substring slicing
# breaks multi-byte icons under a non-UTF-8 locale (common on minimal
# Termux/Linux installs), so this trades pixel-perfect alignment for
# correctness everywhere.
box_top() {
  local title="$1" icon="${2:-}" color="${3:-$C_ACCENT2}" label
  if [[ -n "$icon" ]]; then
    label="${icon} ${title}"
  else
    label="${title}"
  fi
  printf "\n%s┌─ %s %s%s\n" "$color" "$label" "$RULE_LINE" "$C_RESET"
}

# box_line "text" — a body line inside a box, prefixed with a dim rail so it
# visually nests under the header above it.
box_line() {
  printf "${C_MUTED}│${C_RESET} %s\n" "$*"
}

# box_bottom "$COLOR" — closes a section opened with box_top.
box_bottom() {
  local color="${1:-$C_ACCENT2}"
  printf "${color}└%s${C_RESET}\n" "$RULE_LINE"
}

# Renders the wordmark, picking a size that actually fits the current
# terminal instead of always drawing the full ~62-column block logo. Termux
# on a phone (often 30-45 cols in portrait) would otherwise wrap the big
# logo into a garbled mess, so we measure the real width via `tput cols`
# (falling back to $COLUMNS, then a safe 80) and pick the tallest logo that
# still fits with room to spare.
banner() {
  local cols
  cols="$(tput cols 2>/dev/null)"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="${COLUMNS:-80}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80

  printf "${C_ACCENT}"
  if (( cols >= 64 )); then
    # Full block logo — needs 62 display columns.
    cat <<'EOF'
 █████╗ ██╗   ██╗██╗  ████████╗██╗  ██╗██╗██╗   ██╗███╗   ███╗
██╔══██╗██║   ██║██║  ╚══██╔══╝██║  ██║██║██║   ██║████╗ ████║
███████║██║   ██║██║     ██║   ███████║██║██║   ██║██╔████╔██║
██╔══██║██║   ██║██║     ██║   ██╔══██║██║██║   ██║██║╚██╔╝██║
██║  ██║╚██████╔╝███████╗██║   ██║  ██║██║╚██████╔╝██║ ╚═╝ ██║
╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝   ╚═╝  ╚═╝╚═╝ ╚═════╝ ╚═╝     ╚═╝
EOF
    printf "${C_RESET}${C_DIM}                          A U L T H I U M${C_RESET}\n"
  elif (( cols >= 34 )); then
    # Compact two-line wordmark — needs 31 display columns. Fits typical
    # narrow phone terminals (Termux portrait, small SSH clients, etc).
    cat <<'EOF'
▄▀█ █░█ █░░ ▀█▀ █░█ █ █░█ █▀▄▀█
█▀█ █▄█ █▄▄ ░█░ █▀█ █ █▄█ █░▀░█
EOF
    printf "${C_RESET}"
  else
    # Extremely narrow terminal — plain spaced-out text, always fits.
    printf "${C_RESET}${C_ACCENT}AULTHIUM${C_RESET}\n"
  fi

  if (( cols >= 64 )); then
    printf "${C_MUTED}               AI Terminal Assistant · %s${C_RESET}\n\n" "$APP_VERSION"
  else
    printf "${C_MUTED}AI Terminal Assistant · %s${C_RESET}\n\n" "$APP_VERSION"
  fi
}

# Renders the "connected / model / sandbox" status panel shown at startup
# and after 't> clear'. Centralized so both call sites always match.
status_panel() {
  printf "${C_ACCENT2}┌─ SESSION ─────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} %-10s ${C_OK}%s${C_RESET}\n" "provider" "$(provider_label) — connected"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "model" "$CURRENT_MODEL"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "sandbox" "$WORKSPACE_DIR"
  if [[ "${#MCP_NAMES[@]}" -gt 0 ]]; then
    printf "${C_MUTED}│${C_RESET} %-10s %s\n" "mcp" "${#MCP_NAMES[@]} server(s) — t> mcp for details"
  fi
  if [[ -n "$MEMORY_FILE" ]]; then
    printf "${C_MUTED}│${C_RESET} %-10s %s\n" "memory" "connected — $MEMORY_FILE"
  fi
  if [[ "$SKIP_CONFIRMATIONS" -eq 1 ]]; then
    printf "${C_MUTED}│${C_RESET} %-10s ${C_WARN}%s${C_RESET}\n" "confirm" "OFF — actions auto-run, no y/N asked (t> confirm on to re-enable)"
  fi
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}Type ${C_RESET}t> help${C_MUTED} for commands · ${C_RESET}Ctrl+C${C_MUTED} to exit${C_RESET}\n"
  printf "${C_MUTED}While waiting on a reply: ${C_RESET}Ctrl+T${C_MUTED} cancel thinking · ${C_RESET}Ctrl+S${C_MUTED} stop prompt${C_RESET}\n\n"
}

# Clears the terminal and reprints the banner + status panel. This is what
# 't> clear' runs, and it's also run automatically right after a model
# switch finishes (see apply_model_switch) so what's on screen afterward is
# a clean session view showing the new model, not the picker's scrollback.
run_clear_screen() {
  clear
  banner
  status_panel
}

# Finalizes a confirmed model switch: runs the same clear-screen-and-
# reprint-status flow as 't> clear' FIRST, then announces the switch on
# the now-clean screen — so the confirmation is the last thing printed and
# actually stays visible, instead of being wiped by the clear that used to
# come after it. Called from every model-picking path (tier picker, fuzzy
# search, direct name, Google model picker, custom-provider free-text
# entry) so the post-switch behavior is identical no matter how the model
# was chosen.
apply_model_switch() {
  CURRENT_MODEL="$1"
  CURRENT_MODEL_LABEL="$CURRENT_MODEL"
  run_clear_screen
  ok "Switched to: $CURRENT_MODEL"
}

cleanup_exit() {
  stop_spinner
  restore_tty
  rm -f "${OPENROUTER_MODELS_CACHE_FILE:-}"
  [[ -n "${UNDO_DIR:-}" ]] && rm -rf "$UNDO_DIR" 2>/dev/null
  [[ -n "${AUTOUPDATE_STATE_DIR:-}" ]] && rm -rf "$AUTOUPDATE_STATE_DIR" 2>/dev/null
  printf '\n'
  printf "${C_OK}%s${C_RESET}\n" "Aulthium has been closed." >&2
  exit 0
}

trap cleanup_exit INT

# ── Terminal setup for Ctrl+T / Ctrl+S cancellation ────────────────────────
# Ctrl+S is XOFF under the terminal's software flow control (IXON) — by
# default the tty driver swallows it to pause output and never hands the
# byte to us at all. We turn IXON off for the life of the app so Ctrl+S (and
# Ctrl+Q) behave like ordinary keystrokes instead, and restore the original
# settings on exit. Ctrl+T has no such default binding on Linux, so it needs
# no special handling here.
ORIGINAL_STTY=""
setup_tty_for_cancel() {
  ORIGINAL_STTY="$(stty -g 2>/dev/null || true)"
  stty -ixon 2>/dev/null || true
}

restore_tty() {
  [[ -n "$ORIGINAL_STTY" ]] && stty "$ORIGINAL_STTY" 2>/dev/null || true
}

# ── Thinking spinner ─────────────────────────────────────────────────────
# The OpenRouter call is a single blocking, non-streaming request, so we
# can't show tokens as they're generated. Instead we show a small animated
# "thinking..." line for the duration of that blocking wait, then clear it
# in place the moment the response comes back — visually the same effect
# as the model "thinking" and then deleting that line once it's done.
SPINNER_PID=""

start_spinner() {
  local msg="${1:-thinking...}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  (
    local i=0
    printf '\033[?25l' >&2
    while true; do
      printf "\r${C_MUTED}%s %s${C_RESET}\033[K" "${frames[$i]}" "$msg" >&2
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.08
    done
  ) &
  SPINNER_PID=$!
  disown "$SPINNER_PID" 2>/dev/null
}

stop_spinner() {
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
  fi
  SPINNER_PID=""
  printf '\r\033[K\033[?25h' >&2
}

want_cmd() {
  # Like need_cmd but non-fatal: just remembers that a feature is unavailable
  # so we can tell the model/user instead of crashing the whole app.
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Optional dependency missing: $1 (some features will be disabled)"
    return 1
  fi
  return 0
}

check_deps() {
  need_cmd curl
  need_cmd jq
  need_cmd mktemp
  need_cmd sort
  need_cmd grep
  need_cmd realpath

  HAVE_UNZIP=1
  want_cmd unzip || HAVE_UNZIP=0
  HAVE_ZIP=1
  want_cmd zip || HAVE_ZIP=0
  HAVE_FILE=1
  want_cmd file || HAVE_FILE=0
  HAVE_TIMEOUT=1
  want_cmd timeout || HAVE_TIMEOUT=0
  HAVE_FLOCK=1
  want_cmd flock || HAVE_FLOCK=0
  if [[ "$HAVE_FLOCK" -eq 0 ]]; then
    warn "flock not found — DDG Lite's rate limiter will run without cross-process locking (fine for normal single-session use)."
  fi

  # Web search parses HTML results (3 SearXNG instances, then DuckDuckGo
  # Lite — see web_search_query) with PCRE (grep -P, needed for \K and non-greedy
  # matching) when available; otherwise it falls back to a plain POSIX-ERE
  # parser that's a bit less precise but still functional.
  HAVE_GREP_PCRE=1
  printf 'x' | grep -Pzo 'x' >/dev/null 2>&1 || HAVE_GREP_PCRE=0
  if [[ "$HAVE_GREP_PCRE" -eq 0 ]]; then
    warn "This system's grep lacks PCRE (-P) support — web search will use a simpler fallback parser."
  fi
}

# ── AUTO-UPDATE ──────────────────────────────────────────────────────────
# Everything here follows one rule: nothing in this section is ever allowed
# to block the chat loop. Network calls only ever happen inside a detached
# background job (autoupdate_worker); everything called from the main loop
# (autoupdate_poll, autoupdate_check_async) only ever touches small local
# marker files and returns instantly.

# autoupdate_version_gt A B — true (0) if version A is strictly newer than
# B. Both are compared as dot-separated numeric components ("v1.2.10" vs
# "1.9.0"); a leading "v" and any non-digit noise in a component is
# stripped, missing trailing components count as 0.
autoupdate_version_gt() {
  local a="${1#v}" b="${2#v}"
  local -a A B
  IFS='.' read -r -a A <<< "$a"
  IFS='.' read -r -a B <<< "$b"
  local n=${#A[@]}
  (( ${#B[@]} > n )) && n=${#B[@]}
  local i x y
  for (( i = 0; i < n; i++ )); do
    x="${A[i]:-0}"; x="${x//[^0-9]/}"; x="${x:-0}"
    y="${B[i]:-0}"; y="${y//[^0-9]/}"; y="${y:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 1
}

# Whether auto-update is actually usable right now: a source URL is
# configured, the session toggle is on, and this process can tell where it
# actually lives on disk (not the case for e.g. `curl ... | bash`).
autoupdate_available() {
  [[ -n "$AUTOUPDATE_URL" ]] || return 1
  [[ "$AUTOUPDATE_ENABLED" -eq 1 ]] || return 1
  [[ -n "$SELF_SCRIPT_PATH" && -f "$SELF_SCRIPT_PATH" ]] || return 1
  return 0
}

# One-time setup: scratch dir for this session's lock/ready/error markers,
# plus a small persistent file under $HOME so a burst of quick restarts
# doesn't re-hit the update URL every single launch.
autoupdate_init() {
  [[ -n "$AUTOUPDATE_URL" ]] || return 0

  AUTOUPDATE_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aulthium_update.XXXXXX" 2>/dev/null)" || AUTOUPDATE_STATE_DIR=""
  if [[ -z "$AUTOUPDATE_STATE_DIR" ]]; then
    AUTOUPDATE_ENABLED=0
    return 0
  fi
  AUTOUPDATE_LOCK_FILE="$AUTOUPDATE_STATE_DIR/lock.pid"
  AUTOUPDATE_READY_FILE="$AUTOUPDATE_STATE_DIR/ready"
  AUTOUPDATE_ERROR_FILE="$AUTOUPDATE_STATE_DIR/error"

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/aulthium"
  mkdir -p "$cache_dir" 2>/dev/null
  AUTOUPDATE_LAST_CHECK_FILE="$cache_dir/last_update_check"
}

# Does the actual work. ALWAYS run in a detached background subshell — see
# autoupdate_check_async — never call this directly from the foreground.
# Downloads the candidate straight into a temp file inside the SAME
# directory as the running script (not /tmp), so the final `mv` below is
# a same-filesystem rename: atomic, and safe to do at any moment because
# any process with the old file already open (this one included) just
# keeps reading the old inode until it exits.
autoupdate_worker() {
  local dir tmp new_version
  dir="$(dirname -- "$SELF_SCRIPT_PATH")"

  date +%s > "$AUTOUPDATE_LAST_CHECK_FILE" 2>/dev/null

  tmp="$(mktemp "$dir/.aulthium_update.XXXXXX" 2>/dev/null)" || {
    printf '%s' "can't stage an update in $dir (not writable) — grab it manually from $AUTOUPDATE_URL" \
      > "$AUTOUPDATE_ERROR_FILE"
    return 0
  }

  if ! curl -fsSL --max-time 25 "$AUTOUPDATE_URL" -o "$tmp" 2>/dev/null; then
    printf '%s' "couldn't reach the update URL" > "$AUTOUPDATE_ERROR_FILE"
    rm -f "$tmp"
    return 0
  fi

  # Sanity checks before we trust this enough to become the real script:
  # non-trivial size, looks like an Aulthium script, and valid bash syntax.
  if [[ ! -s "$tmp" ]] \
     || (( $(wc -c < "$tmp" 2>/dev/null || echo 0) < 2000 )) \
     || ! grep -q '^APP_NAME="AULTHIUM"' "$tmp" \
     || ! bash -n "$tmp" 2>/dev/null; then
    printf '%s' "the download didn't look like a valid Aulthium script — skipped it" \
      > "$AUTOUPDATE_ERROR_FILE"
    rm -f "$tmp"
    return 0
  fi

  new_version="$(grep -m1 '^APP_VERSION=' "$tmp" | sed -E 's/^APP_VERSION="?([^"]*)"?.*/\1/')"
  if [[ -z "$new_version" ]] || ! autoupdate_version_gt "$new_version" "$APP_VERSION"; then
    rm -f "$tmp"
    return 0
  fi

  chmod --reference="$SELF_SCRIPT_PATH" "$tmp" 2>/dev/null || chmod 755 "$tmp" 2>/dev/null

  if mv -f "$tmp" "$SELF_SCRIPT_PATH" 2>/dev/null; then
    printf '%s' "$new_version" > "$AUTOUPDATE_READY_FILE"
  else
    printf '%s' "downloaded v$new_version but couldn't move it into place" > "$AUTOUPDATE_ERROR_FILE"
    rm -f "$tmp"
  fi
}

# Fires autoupdate_worker in the background if it's worth doing right now.
# force=1 (from 't> update check') skips the time-based throttle; anything
# else respects it. Never blocks: the network call happens entirely inside
# the backgrounded subshell.
autoupdate_check_async() {
  local force="${1:-0}"
  autoupdate_available || return 0

  if [[ -f "$AUTOUPDATE_LOCK_FILE" ]]; then
    local lpid; lpid="$(cat "$AUTOUPDATE_LOCK_FILE" 2>/dev/null)"
    [[ -n "$lpid" ]] && kill -0 "$lpid" 2>/dev/null && return 0
  fi

  # Already have a verified update sitting on disk — no point re-checking.
  [[ -s "$AUTOUPDATE_READY_FILE" ]] && return 0

  if [[ "$force" -ne 1 && -f "$AUTOUPDATE_LAST_CHECK_FILE" ]]; then
    local last now
    last="$(cat "$AUTOUPDATE_LAST_CHECK_FILE" 2>/dev/null)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    now="$(date +%s)"
    (( now - last < AUTOUPDATE_INTERVAL_SECS )) && return 0
  fi

  rm -f "$AUTOUPDATE_ERROR_FILE"
  ( autoupdate_worker ) &
  local wpid=$!
  echo "$wpid" > "$AUTOUPDATE_LOCK_FILE"
  disown "$wpid" 2>/dev/null
}

# Cheap, called every loop iteration: just checks whether the background
# worker already dropped a "ready" marker, and if so prints one unobtrusive
# one-line notice (once) — the update is already applied to disk at this
# point, so this is purely informational, never a prompt or a blocker.
autoupdate_poll() {
  [[ "$AUTOUPDATE_NOTIFIED" -eq 1 ]] && return 0
  [[ -n "$AUTOUPDATE_STATE_DIR" && -s "$AUTOUPDATE_READY_FILE" ]] || return 0
  local v; v="$(cat "$AUTOUPDATE_READY_FILE" 2>/dev/null)"
  AUTOUPDATE_NOTIFIED=1
  echo
  ok "Update v$v is downloaded and already in place — this session keeps running $APP_VERSION, untouched."
  muted "Pick it up anytime: t> exit, then start Aulthium again."
}

# 't> update' with no argument.
autoupdate_status_cmd() {
  if [[ -z "$AUTOUPDATE_URL" ]]; then
    muted "Auto-update isn't configured — set AULTHIUM_UPDATE_URL to a raw URL of this"
    muted "script (e.g. a GitHub raw link) and restart to enable it."
    return 0
  fi
  if [[ -z "$SELF_SCRIPT_PATH" || ! -f "$SELF_SCRIPT_PATH" ]]; then
    warn "Auto-update is unavailable — Aulthium doesn't appear to be running from a saved"
    warn "file on disk (e.g. it was piped straight into bash)."
    return 0
  fi
  if [[ "$AUTOUPDATE_ENABLED" -eq 0 ]]; then
    warn "Auto-update is OFF for this session. Run 't> update on' to re-enable it."
    return 0
  fi

  ok "Auto-update is ON — checks quietly in the background every $(( AUTOUPDATE_INTERVAL_SECS / 3600 ))h, never interrupting chat."
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "source" "$AUTOUPDATE_URL"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "running" "$APP_VERSION"

  if [[ -s "$AUTOUPDATE_READY_FILE" ]]; then
    ok "v$(cat "$AUTOUPDATE_READY_FILE") is already downloaded and in place — restart to pick it up."
  elif [[ -f "$AUTOUPDATE_LOCK_FILE" ]] && kill -0 "$(cat "$AUTOUPDATE_LOCK_FILE" 2>/dev/null)" 2>/dev/null; then
    muted "A check is running in the background right now — keep chatting, it won't get in the way."
  elif [[ -s "$AUTOUPDATE_ERROR_FILE" ]]; then
    warn "Last check: $(cat "$AUTOUPDATE_ERROR_FILE")"
  else
    muted "Up to date (or no check has run yet this session)."
  fi
}

confirm_yes_no() {
  local prompt="$1" ans
  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} %s ${C_MUTED}[y/N]${C_RESET} " "$prompt")" ans || ans="n"
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Confirmation gate specifically for agent-PROPOSED actions (file writes,
# edits, deletes, folder create/delete, shell commands, MCP tool calls) —
# as opposed to one-off setup/config prompts (create workspace dir?, load
# this memory file?, switch model/provider?), which always use plain
# confirm_yes_no above and always ask regardless of this setting. Honors
# the 't> confirm off' toggle: the action is still always printed to the
# screen either way, this only decides whether the "do you want to
# proceed?" gate actually waits for a y/N or auto-approves instantly.
confirm_action() {
  local prompt="$1"
  if [[ "$SKIP_CONFIRMATIONS" -eq 1 ]]; then
    printf "${C_ACCENT2}?${C_RESET} %s ${C_WARN}[auto-yes, confirmations off]${C_RESET}\n" "$prompt"
    return 0
  fi
  confirm_yes_no "$prompt"
}

# 't> confirm' with no argument — reports the current state.
confirm_status() {
  if [[ "$SKIP_CONFIRMATIONS" -eq 1 ]]; then
    warn "Confirmations are OFF — file writes/edits/deletes, folder actions, shell"
    warn "commands, and MCP tool calls all run immediately without asking first."
    muted "Run 't> confirm on' to turn the y/N blocker back on."
  else
    ok "Confirmations are ON — every file/folder/shell/MCP action asks for a y/N first."
    muted "Run 't> confirm off' to disable it (not recommended)."
  fi
}

# 't> confirm on' — always safe, no extra prompt needed to turn safety back on.
enable_confirmations() {
  if [[ "$SKIP_CONFIRMATIONS" -eq 0 ]]; then
    muted "Confirmations are already on."
    return 0
  fi
  SKIP_CONFIRMATIONS=0
  ok "Confirmations enabled — every action will ask for a y/N before running."
}

# 't> confirm off' — requires an explicit extra confirmation of its own
# (via plain confirm_yes_no, which always asks regardless of this setting)
# since this is the one toggle that removes every other safety gate at once.
disable_confirmations() {
  if [[ "$SKIP_CONFIRMATIONS" -eq 1 ]]; then
    muted "Confirmations are already off."
    return 0
  fi
  echo
  warn "This turns OFF the y/N blocker for EVERY agent action: file writes, edits,"
  warn "deletes, folder creates/deletes, shell commands, and MCP tool calls will all"
  warn "run immediately, with no chance to review or decline first."
  muted "Everything the agent does is still shown on screen — this only removes the gate."
  if confirm_yes_no "Are you sure you want to disable confirmations?"; then
    SKIP_CONFIRMATIONS=1
    ok "Confirmations disabled. Actions will now run automatically."
    muted "Run 't> confirm on' anytime to turn the blocker back on."
  else
    muted "Cancelled — confirmations remain on."
  fi
}

# Refuses any workspace directory that IS or lives inside a critical system path.
# This is a hard block regardless of user confirmation — the point is that no
# path arithmetic inside the sandbox can ever reach these locations.
is_dangerous_root() {
  local abs="$1"
  case "$abs" in
    "/"|"/etc"|"/etc/"*|"/usr"|"/usr/"*|"/bin"|"/bin/"*|"/sbin"|"/sbin/"*| \
    "/boot"|"/boot/"*|"/lib"|"/lib/"*|"/lib64"|"/lib64/"*|"/proc"|"/proc/"*| \
    "/dev"|"/dev/"*|"/sys"|"/sys/"*|"/System"|"/System/"*|"/Windows"|"/Windows/"* | \
    "/root")
      return 0
      ;;
  esac
  return 1
}

# Validates and normalizes a candidate workspace directory.
# Prints the resolved absolute path on success, returns 1 on rejection.
validate_workspace_dir() {
  local dir="$1" abs
  abs="$(realpath -m "$dir" 2>/dev/null)" || return 1

  if is_dangerous_root "$abs"; then
    err "Refusing to use '$abs' as the workspace — it is (or is inside) a critical system directory."
    return 1
  fi

  printf '%s' "$abs"
  return 0
}

# Sets up the workspace at startup with no confirmation prompt (the point is
# it's fully automatic). Still runs through the same safety validation as
# every other path in this script — it just skips the "create it?" prompt.
init_workspace_auto() {
  local candidate abs
  candidate="$(default_workspace_dir)"
  abs="$(validate_workspace_dir "$candidate")" || return 1

  if [[ ! -e "$abs" ]]; then
    mkdir -p "$abs" || { err "Could not create '$abs'."; return 1; }
  elif [[ ! -d "$abs" ]]; then
    err "'$abs' exists and is not a directory."
    return 1
  fi

  WORKSPACE_DIR="$abs"
  return 0
}

set_workspace_dir() {
  local candidate="$1" abs
  abs="$(validate_workspace_dir "$candidate")" || return 1

  if [[ ! -e "$abs" ]]; then
    if ! confirm_yes_no "Directory '$abs' doesn't exist yet. Create it?"; then
      warn "Workspace not changed."
      return 1
    fi
    mkdir -p "$abs" || { err "Could not create '$abs'."; return 1; }
  elif [[ ! -d "$abs" ]]; then
    err "'$abs' exists and is not a directory."
    return 1
  fi

  WORKSPACE_DIR="$abs"
  ok "Workspace set to: $WORKSPACE_DIR"
  return 0
}

# Picks the default workspace location: a "aulthium-workspace" folder inside
# the device's real Downloads folder, so files are immediately visible in
# the normal file manager / Gallery-adjacent apps with no extra copy step.
# Falls back to the current directory only if no Downloads folder is found.
default_workspace_dir() {
  local name="aulthium-workspace"

  if [[ -n "${AULTHIUM_WORKDIR:-}" ]]; then
    printf '%s' "$AULTHIUM_WORKDIR"
    return 0
  fi

  # Termux: shared storage is exposed under ~/storage/downloads after
  # `termux-setup-storage` has been run once.
  if [[ -d "$HOME/storage/downloads" ]]; then
    printf '%s/%s' "$HOME/storage/downloads" "$name"
    return 0
  fi

  # Regular Linux / macOS.
  if [[ -d "$HOME/Downloads" ]]; then
    printf '%s/%s' "$HOME/Downloads" "$name"
    return 0
  fi

  warn "No Downloads folder found (on Termux, run 'termux-setup-storage' once)."
  printf './%s' "$name"
  return 0
}

# Resolves a model-proposed relative path against the workspace and guarantees
# the result stays inside it. This is the single choke point that keeps every
# file action confined to the sandbox — absolute paths, "..", and symlink
# escapes are all rejected here.
resolve_safe_path() {
  local rel="$1" abs

  if [[ -z "$rel" ]]; then
    err "Empty path rejected."
    return 1
  fi

  case "$rel" in
    /*)
      err "Absolute path rejected: $rel"
      return 1
      ;;
  esac

  abs="$(realpath -m "$WORKSPACE_DIR/$rel" 2>/dev/null)" || {
    err "Could not resolve path: $rel"
    return 1
  }

  case "$abs" in
    "$WORKSPACE_DIR"|"$WORKSPACE_DIR"/*)
      : ;;
    *)
      err "Path escapes the workspace sandbox, blocked: $rel"
      return 1
      ;;
  esac

  if is_dangerous_root "$abs"; then
    err "Path resolves to a critical system location, blocked: $abs"
    return 1
  fi

  printf '%s' "$abs"
  return 0
}

init_history() {
  local system_prompt
  system_prompt="$(build_system_prompt)"
  messages_json="$(jq -nc --arg content "$system_prompt" '[{role:"system", content:$content}]')"
}

# Path of the file the live conversation is "connected" to, or empty if
# none. While set, every append_message call also appends that turn to this
# file (see memory_append_message_to_file) — so nothing is lost even when
# check_chat_limit trims the in-memory context to stay under the local
# guardrail below. Reconnect to (or resume) any such file with
# 't> memory connect <file_path>'.
MEMORY_FILE=""

append_message() {
  local role="$1"
  local content="$2"
  local obj

  # Perf note: this used to be
  #   jq -c '. + [{role:$role, content:$content}]' <<< "$messages_json"
  # which re-parses AND re-serializes the *entire* growing conversation on
  # every single append (assistant replies, tool-result turns, etc — several
  # times per user message via run_agent_turns). That's O(n) work — plus an
  # extra jq process fork and a here-string temp file — repeated on every
  # call, so a long chat degrades quadratically and every round gets slower
  # than the last. Since messages_json is always compact ("-c") JSON with no
  # trailing whitespace, appending is just: encode the ONE new object (a
  # small, constant-size jq call) and splice it in before the final "]"
  # with plain string ops — no re-parsing of existing history at all.
  obj="$(jq -nc --arg role "$role" --arg content "$content" '{role:$role, content:$content}')"
  if [[ "$messages_json" == "[]" ]]; then
    messages_json="[${obj}]"
  else
    messages_json="${messages_json%]},${obj}]"
  fi

  memory_append_message_to_file "$role" "$content"
}

# Appends one turn to the connected memory file, if any. This is what makes
# a connected file a running log rather than a point-in-time snapshot: it
# grows one block at a time, right as each turn happens, so trimming the
# in-memory copy later never loses anything.
memory_append_message_to_file() {
  local role="$1" content="$2"
  [[ -z "$MEMORY_FILE" ]] && return 0
  { printf '### %s\n\n%s\n\n' "$role" "$content"; } >> "$MEMORY_FILE" 2>/dev/null
}

# Rough, provider-agnostic safeguard against runaway context growth: this
# script has no real tokenizer and doesn't know each model's actual context
# window, so it uses total JSON character count as a cheap proxy for size.
# Not a hard API limit — just a local guardrail so a very long-running chat
# gets a deliberate choice instead of silently growing until the provider
# rejects the request.
CHAT_HISTORY_CHAR_LIMIT=32000

# Writes the current conversation (skipping the system prompt) to $1 as a
# markdown snapshot. Shared by archive_chat_history (a one-off timestamped
# dump at the chat limit) and memory_connect (a brand-new file's starting
# content). Returns 1 if the write failed.
memory_write_snapshot() {
  local path="$1"
  {
    printf '# Aulthium — saved chat history\n\n'
    printf '_saved %s · provider: %s · model: %s_\n\n' "$(date)" "$(provider_label)" "$CURRENT_MODEL"
    jq -r '.[1:][] | "### \(.role)\n\n\(.content)\n"' <<< "$messages_json"
  } > "$path" 2>/dev/null
  [[ -f "$path" ]]
}

# Writes the full conversation out to a timestamped markdown file in the
# sandbox. Prints the saved path on success, nothing on failure.
archive_chat_history() {
  local ts path
  ts="$(date +%Y%m%d-%H%M%S)"
  path="$WORKSPACE_DIR/aulthium-chat-history-$ts.md"
  memory_write_snapshot "$path" && printf '%s' "$path"
}

# Parses a chat-history markdown file (the same "### role" block format
# memory_write_snapshot writes) back into the live conversation, replacing
# whatever's currently loaded. MEMORY_FILE is held off during the read so
# reloading a file doesn't immediately re-append its own contents back onto
# itself.
memory_load_file() {
  local path="$1" role="" body_file line saved_memory_file="$MEMORY_FILE"
  body_file="$(mktemp)"
  : > "$body_file"
  MEMORY_FILE=""

  init_history
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^###\ (.+)$ ]]; then
      [[ -n "$role" ]] && append_message "$role" "$(cat "$body_file")"
      role="${BASH_REMATCH[1]}"
      : > "$body_file"
      continue
    fi
    [[ -n "$role" ]] && printf '%s\n' "$line" >> "$body_file"
  done < "$path"
  [[ -n "$role" ]] && append_message "$role" "$(cat "$body_file")"

  rm -f "$body_file"
  MEMORY_FILE="$saved_memory_file"
}

# 't> memory connect <file_path>' — an existing file is offered for loading
# (replacing the live conversation) or left alone and just appended to from
# here on; a new path gets created with the current conversation as its
# starting content. Either way MEMORY_FILE ends up pointed at it, so every
# future turn is appended automatically and check_chat_limit stops asking.
memory_connect() {
  local path="$1" abs
  if [[ -z "$path" ]]; then
    warn "Usage: t> memory connect <file_path>"
    return 1
  fi

  abs="$(realpath -m "$path" 2>/dev/null)" || abs="$path"

  if [[ -f "$abs" ]]; then
    if confirm_yes_no "File exists — load it and replace the current conversation with its contents?"; then
      memory_load_file "$abs"
      ok "Loaded history from $abs"
    else
      muted "Keeping the current conversation — new turns will be appended after what's already in $abs."
    fi
  else
    mkdir -p "$(dirname "$abs")" 2>/dev/null
    if ! memory_write_snapshot "$abs"; then
      err "Could not create $abs"
      return 1
    fi
    ok "Created $abs with the current conversation."
  fi

  MEMORY_FILE="$abs"
  say "Connected — every turn from here is appended to this file automatically, and you won't be asked again at the chat limit."
}

memory_disconnect() {
  if [[ -z "$MEMORY_FILE" ]]; then
    muted "Not connected to a file."
    return 0
  fi
  ok "Disconnected from $MEMORY_FILE"
  MEMORY_FILE=""
}

memory_status() {
  if [[ -n "$MEMORY_FILE" ]]; then
    ok "Connected to: $MEMORY_FILE"
    muted "Every turn is appended there automatically. t> memory disconnect to stop."
  else
    muted "Not connected to a file. t> memory connect <file_path> to start (or reconnect to an old one)."
  fi
}

# Drops the oldest half of the non-system messages (index 0, the system
# prompt, is always kept) — used to make room in the live context, either
# because the user declined to archive at the chat limit, or automatically
# once a memory file is connected (see check_chat_limit).
trim_oldest_history() {
  local count keep_from
  count="$(jq 'length' <<< "$messages_json")"
  (( count <= 3 )) && return 0
  keep_from=$(( count / 2 ))
  messages_json="$(jq --argjson k "$keep_from" '[.[0]] + .[$k:]' <<< "$messages_json")"
}

# The chat-limit blocker: called at the start of every send_chat. Below the
# threshold this is a no-op. At/above it: if a memory file is already
# connected, every turn has already been appended there as it happened, so
# there's nothing to lose — just trim the live context and keep going,
# without asking. Otherwise the user is stopped once and must choose —
# archive the full history to a file and connect to it (so this never asks
# again), or decline and have the oldest turns silently trimmed instead.
check_chat_limit() {
  local size saved_path

  size="$(printf '%s' "$messages_json" | wc -c | tr -d ' ')"
  [[ "$size" -lt "$CHAT_HISTORY_CHAR_LIMIT" ]] && return 0

  if [[ -n "$MEMORY_FILE" ]]; then
    trim_oldest_history
    muted "Local context trimmed to stay under the limit — nothing lost, the full conversation is still in $(basename "$MEMORY_FILE")."
    return 0
  fi

  echo
  printf "${C_WARN}┌─ CHAT LIMIT REACHED ───────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} This conversation has grown large enough that it\n"
  printf "${C_MUTED}│${C_RESET} risks hitting the model's real context limit.\n"
  printf "${C_WARN}└─────────────────────────────────────────────${C_RESET}\n\n"

  if confirm_yes_no "Save the full history to a file and connect to it, so this never asks again?"; then
    saved_path="$(archive_chat_history)"
    if [[ -n "$saved_path" ]]; then
      MEMORY_FILE="$saved_path"
      init_history
      append_message "assistant" "(Earlier conversation archived to $(basename "$saved_path") in the sandbox. Continuing with a clean context — ask if you need something from before.)"
      ok "History saved to $saved_path and connected."
      muted "Every turn from here is appended there automatically. Reload it anytime with: t> memory connect $saved_path"
    else
      err "Could not save history — continuing without archiving."
    fi
  else
    warn "Continuing without saving — trimming the oldest messages to make room."
    trim_oldest_history
  fi
}

show_help() {
  echo
  printf "${C_ACCENT2}┌─ COMMANDS ────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> help" "show this menu"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> provider" "switch between OpenRouter, Google AI Studio, or Other"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> key" "change the API key for the current provider"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> model" "open the model picker (choose Free or Paid first)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> model <name>" "switch to a model by name (confirmation required)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> current" "show current provider and model"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> workdir" "show the current sandbox folder"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> workdir <path>" "change the sandbox folder"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp" "list connected MCP servers and their tools"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp add <n> <url>" "connect a remote MCP server"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp remove <name>" "disconnect an MCP server"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp refresh [name]" "re-discover tools (one server, or all)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp cloudflare" "quick-pick from Cloudflare's managed MCP servers"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> memory" "show whether a history file is connected"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> memory connect <p>" "connect/reconnect a history file (load or start it)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> memory disconnect" "stop appending turns to the connected file"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> confirm" "show whether the y/N action blocker is on or off"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> confirm on" "require y/N before every file/shell/MCP action (default)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> confirm off" "auto-approve every action instantly (no more asking)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> undo" "reverse the last file/folder/zip/network change"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> redo" "re-apply the last change you undid"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> clear" "clear the terminal"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> reset" "start a new conversation"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> history" "show chat history"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> update" "show auto-update status"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> update check" "check for an update now (runs in background, non-blocking)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> update on|off" "toggle background auto-update checks for this session"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> exit" "exit Aulthium"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_MUTED}Chat: type any normal message at the ${C_RESET}User>${C_MUTED} prompt.${C_RESET}\n"
  printf "${C_MUTED}If the conversation gets very long, you'll be asked once whether to save it to\n"
  printf "a file and connect to it, or trim the oldest turns instead. Once connected, every\n"
  printf "turn is appended there automatically and you won't be asked again — reload that\n"
  printf "file anytime (this session or a future one) with ${C_RESET}t> memory connect <path>${C_MUTED}.${C_RESET}\n"

  printf "\n${C_MUTED}While a reply is in progress:${C_RESET}\n"
  printf "${C_MUTED}  ${C_RESET}Ctrl+T${C_MUTED}  cancel thinking — abort just the current network call.${C_RESET}\n"
  printf "${C_MUTED}  ${C_RESET}Ctrl+S${C_MUTED}  stop prompt — abort the call and the rest of this turn\n"
  printf "${C_MUTED}          (including any further tool-call rounds).${C_RESET}\n"

  printf "\n${C_ACCENT2}┌─ FILE AGENT ──────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_OK}${ICON_READ} ${ICON_DIR} ${ICON_ZIP}${C_RESET}  read files, list folders, inspect zips —\n"
  printf "${C_MUTED}│${C_RESET}       runs automatically, no confirmation (read-only),\n"
  printf "${C_MUTED}│${C_RESET}       results are fed back to the agent for its next turn.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_OK}${ICON_SEARCH}${C_RESET}      the agent can also search the live web (free, no\n"
  printf "${C_MUTED}│${C_RESET}       API key) for current info it doesn't already know —\n"
  printf "${C_MUTED}│${C_RESET}       tries 3 SearXNG instances, then DuckDuckGo Lite if all\n"
  printf "${C_MUTED}│${C_RESET}       are blocked or unreachable; also automatic, read-only, no\n"
  printf "${C_MUTED}│${C_RESET}       confirmation needed.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_WARN}${ICON_WRITE} ${ICON_DELETE} ${ICON_FOLDER} ${ICON_MOVE} ${ICON_ZIP} ${ICON_NET}${C_RESET}  write/overwrite a file, delete a\n"
  printf "${C_MUTED}│${C_RESET}       single file, delete a folder (and everything inside it),\n"
  printf "${C_MUTED}│${C_RESET}       create an empty folder, move/rename a file or folder,\n"
  printf "${C_MUTED}│${C_RESET}       zip/unzip an archive, or make a network request/download —\n"
  printf "${C_MUTED}│${C_RESET}       every one of these is shown to you and needs a yes/no\n"
  printf "${C_MUTED}│${C_RESET}       confirmation first. File/folder/zip/network-download\n"
  printf "${C_MUTED}│${C_RESET}       changes can be undone with 't> undo' (redo with 't> redo').\n"
  printf "${C_MUTED}│${C_RESET}       Network requests reach the real internet; everything else\n"
  printf "${C_MUTED}│${C_RESET}       never touches anything outside the sandbox folder.\n"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_ACCENT2}┌─ SHELL AGENT ─────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_ERR}${ICON_SHELL}${C_RESET}      the agent can propose shell command(s), shown\n"
  printf "${C_MUTED}│${C_RESET}       to you in full before you approve or decline.\n"
  printf "${C_MUTED}│${C_RESET}       Unlike file actions, shell commands are ${C_BOLD}NOT${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET}       confined to the sandbox — they run with your real\n"
  printf "${C_MUTED}│${C_RESET}       shell privileges, so only approve what you trust.\n"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_ACCENT2}┌─ MCP TOOLS ───────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_OK}${ICON_MCP}${C_RESET}      connect a remote MCP server with ${C_RESET}t> mcp add\n"
  printf "${C_MUTED}│${C_RESET}       <name> <url>${C_MUTED} — its tools are discovered immediately\n"
  printf "${C_MUTED}│${C_RESET}       and folded into what the agent can call. Unlike the\n"
  printf "${C_MUTED}│${C_RESET}       read-only file/search tools, calling one needs a\n"
  printf "${C_MUTED}│${C_RESET}       yes/no confirmation first, same as shell commands —\n"
  printf "${C_MUTED}│${C_RESET}       this app can't know what a given tool actually does.\n"
  printf "${C_MUTED}│${C_RESET}       Only HTTP(S) MCP servers are supported (no local/stdio\n"
  printf "${C_MUTED}│${C_RESET}       servers). Pre-configure several at launch via the\n"
  printf "${C_MUTED}│${C_RESET}       MCP_SERVERS env var: name1=url1,name2=url2 — with an\n"
  printf "${C_MUTED}│${C_RESET}       optional key for each in MCP_<NAME>_KEY.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET}       ${C_RESET}t> mcp cloudflare${C_MUTED} quick-picks from Cloudflare's own\n"
  printf "${C_MUTED}│${C_RESET}       managed MCP servers (docs, Workers bindings, Radar, AI\n"
  printf "${C_MUTED}│${C_RESET}       Gateway, ...) by name instead of typing out a URL — once\n"
  printf "${C_MUTED}│${C_RESET}       added they're ordinary MCP servers like any other.\n"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n"
}

show_history() {
  local count
  count="$(jq 'length' <<< "$messages_json")"
  if [[ "$count" -le 1 ]]; then
    muted "No history yet."
    return
  fi

  echo
  jq -r '
    .[1:][] |
    "\(.role)\u0001\(.content)"
  ' <<< "$messages_json" | while IFS=$'\001' read -r role content; do
    case "$role" in
      user) printf "${C_ACCENT2}%-10s${C_RESET}%s\n\n" "you" "$content" ;;
      assistant) printf "${C_ACCENT}%-10s${C_RESET}%s\n\n" "aulthium" "$content" ;;
      *) printf "${C_MUTED}%-10s${C_RESET}%s\n\n" "$role" "$content" ;;
    esac
  done
}

# Raw-catalog cache shared by fetch_free_models/fetch_paid_models below, so
# toggling between tiers in the model picker (free -> back -> paid -> back
# -> free...) doesn't re-download the same multi-hundred-KB /models response
# over and over inside one session. Short TTL — long enough to cover a user
# bouncing between tiers a few times, short enough that a real 't> mcp
# refresh'-style manual retry (or just waiting) still gets fresh data.
OPENROUTER_MODELS_CACHE_FILE=""
OPENROUTER_MODELS_CACHE_TIME=0
OPENROUTER_MODELS_CACHE_TTL=120

fetch_openrouter_models_raw() {
  # Prints the path to a tmp file holding OpenRouter's raw /models JSON.
  # Reuses the cached copy if it's still within TTL; caller must NOT delete
  # the path it's given. Returns 1 (prints nothing) on fetch failure.
  local now
  now="$(date +%s)"

  if [[ -n "$OPENROUTER_MODELS_CACHE_FILE" && -s "$OPENROUTER_MODELS_CACHE_FILE" \
        && $(( now - OPENROUTER_MODELS_CACHE_TIME )) -lt "$OPENROUTER_MODELS_CACHE_TTL" ]]; then
    printf '%s' "$OPENROUTER_MODELS_CACHE_FILE"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if ! curl -fsSL "$OPENROUTER_MODELS_URL" -o "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  rm -f "$OPENROUTER_MODELS_CACHE_FILE"
  OPENROUTER_MODELS_CACHE_FILE="$tmp"
  OPENROUTER_MODELS_CACHE_TIME="$now"
  printf '%s' "$tmp"
}

fetch_free_models() {
  # Returns a sorted list of free model IDs, one per line.
  local tmp
  tmp="$(fetch_openrouter_models_raw)" || return 1

  jq -r '
    .data[]
    | .id
    | select(endswith(":free"))
  ' "$tmp" 2>/dev/null | sort -u
}

fetch_paid_models() {
  # Returns a sorted list of non-free (billed) model IDs, one per line.
  local tmp
  tmp="$(fetch_openrouter_models_raw)" || return 1

  jq -r '
    .data[]
    | .id
    | select(endswith(":free") | not)
  ' "$tmp" 2>/dev/null | sort -u
}

fetch_google_models() {
  # Returns a sorted list of Google AI Studio model IDs (generateContent-
  # capable only, e.g. "gemini-2.0-flash"), one per line. Google's free tier
  # is a per-model rate limit rather than a separate set of model IDs, so
  # unlike OpenRouter there's no free/paid split in the model list itself.
  local tmp
  tmp="$(mktemp)"

  if ! curl -fsSL "${GOOGLE_API_BASE}/models?key=${GOOGLE_KEY}" -o "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  jq -r '
    .models[]?
    | select((.supportedGenerationMethods // []) | index("generateContent"))
    | .name
    | sub("^models/"; "")
  ' "$tmp" 2>/dev/null | sort -u

  rm -f "$tmp"
}

# Asks the user to pick a tier (free vs paid) before any model list is shown.
# Prints "free" or "paid" to stdout and returns 0, or returns 1 if cancelled.
# Callers capture this with $(...), so every line of on-screen chrome below
# is explicitly sent to stderr — only the final 'free'/'paid' result may
# ever go to stdout.
prompt_model_tier() {
  local ans
  while true; do
    echo >&2
    printf "${C_ACCENT2}┌─ MODEL PICKER ────────────────────────────────${C_RESET}\n" >&2
    printf "${C_MUTED}│${C_RESET} current: ${C_OK}%s${C_RESET}\n" "$CURRENT_MODEL" >&2
    printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n" >&2
    printf "${C_MUTED}[1]${C_RESET} Free models ${C_DIM}(no cost, OpenRouter free tier)${C_RESET}\n" >&2
    printf "${C_MUTED}[2]${C_RESET} Paid models ${C_DIM}(billed to your OpenRouter balance)${C_RESET}\n" >&2
    echo >&2
    read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Free or Paid? ${C_MUTED}[1/2, q to cancel]${C_RESET}: ")" ans || ans="q"
    case "$ans" in
      1|f|F|free|Free|FREE)
        printf 'free'
        return 0
        ;;
      2|p|P|paid|Paid|PAID)
        printf 'paid'
        return 0
        ;;
      q|Q)
        return 1
        ;;
      *)
        warn "Please choose 1 (Free), 2 (Paid), or q to cancel."
        ;;
    esac
  done
}

# Blocking confirmation shown before any model switch actually takes effect.
# Returns 0 (confirmed) only on an explicit y/yes; anything else, including a
# blank Enter, is treated as "no" so a switch never happens by accident.
confirm_model_switch() {
  local candidate="$1" ans
  echo
  read -r -p "$(printf "${C_WARN}?${C_RESET} Switch to ${C_OK}%s${C_RESET}? ${C_MUTED}[y/N]${C_RESET}: " "$candidate")" ans || ans="n"
  [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

# Entry point for "t> provider". Always shows both options and always
# blocks on an explicit confirmation before actually switching — same
# pattern as the model picker. Switching providers also resets the current
# model to a sensible default for the new backend (OpenRouter and Google
# model IDs are completely different namespaces, so keeping the old one
# would just break the next request) and immediately prompts for that
# provider's API key if it isn't already set, so the very next chat
# message works without a confusing failure first.
# Shared setup flow for the "Other Providers" option — used by both
# pick_provider_startup (first launch) and pick_provider_ui (mid-session
# switch). Asks for the endpoint, whether it needs a key, and a model name,
# then sets PROVIDER/CUSTOM_URL/CUSTOM_REQUIRES_KEY/CURRENT_MODEL directly.
# Returns 1 (leaving everything untouched) if the user backs out.
configure_custom_provider() {
  local url model

  echo
  printf "${C_ACCENT2}┌─ OTHER PROVIDER ───────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} Any OpenAI-compatible ${C_DIM}/chat/completions${C_RESET} endpoint works\n"
  printf "${C_MUTED}│${C_RESET} here — self-hosted (Ollama, LM Studio, llama.cpp,\n"
  printf "${C_MUTED}│${C_RESET} vLLM, text-generation-webui) or any hosted API\n"
  printf "${C_MUTED}│${C_RESET} using the same request/response shape.\n"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n"

  if ! read -r -p "$(printf "${C_ACCENT2}?${C_RESET} API base URL ${C_MUTED}(full endpoint, q to cancel)${C_RESET}: ")" url; then
    muted "Cancelled."
    return 1
  fi
  [[ "$url" == "q" || "$url" == "Q" ]] && { muted "Cancelled."; return 1; }
  if [[ -z "$url" ]]; then
    warn "URL can't be empty. Cancelled."
    return 1
  fi

  local requires_key=1
  if ! confirm_yes_no "Is an API key required?"; then
    requires_key=0
  fi

  if ! read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Model name to use: ")" model; then
    muted "Cancelled."
    return 1
  fi
  if [[ -z "$model" ]]; then
    warn "Model name can't be empty. Cancelled."
    return 1
  fi

  PROVIDER="custom"
  CUSTOM_URL="$url"
  CUSTOM_REQUIRES_KEY="$requires_key"
  CURRENT_MODEL="$model"
  CURRENT_MODEL_LABEL="$model"

  if [[ "$requires_key" -eq 0 ]]; then
    CUSTOM_KEY=""
    muted "No API key needed — assuming you're running this yourself."
  fi
  return 0
}

pick_provider_startup() {
  local choice

  echo
  printf "${C_ACCENT2}┌─ CHOOSE PROVIDER ──────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} Pick which backend %s should use.\n" "$APP_NAME"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n"
  printf "${C_MUTED}[1]${C_RESET} OpenRouter ${C_DIM}(many models, free + paid)${C_RESET}\n"
  printf "${C_MUTED}[2]${C_RESET} Google AI Studio ${C_DIM}(Gemini models)${C_RESET}\n"
  printf "${C_MUTED}[3]${C_RESET} Mistral ${C_DIM}(api.mistral.ai)${C_RESET}\n"
  printf "${C_MUTED}[4]${C_RESET} Hugging Face ${C_DIM}(Inference Providers router)${C_RESET}\n"
  printf "${C_MUTED}[5]${C_RESET} NVIDIA NIM ${C_DIM}(build.nvidia.com, e.g. Kimi K2.6)${C_RESET}\n"
  printf "${C_MUTED}[6]${C_RESET} Other Providers ${C_DIM}(self-hosted or any OpenAI-compatible API)${C_RESET}\n"
  echo

  while true; do
    if ! read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Provider? ${C_MUTED}[1-6]${C_RESET}: ")" choice; then
      err "No provider selected. Exiting."
      exit 1
    fi
    case "$choice" in
      1|openrouter|OpenRouter|OPENROUTER)
        PROVIDER="openrouter"
        CURRENT_MODEL="$DEFAULT_MODEL"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        break
        ;;
      2|google|Google|GOOGLE)
        PROVIDER="google"
        CURRENT_MODEL="$DEFAULT_GOOGLE_MODEL"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        break
        ;;
      3|mistral|Mistral|MISTRAL)
        PROVIDER="mistral"
        CURRENT_MODEL="$DEFAULT_MISTRAL_MODEL"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        break
        ;;
      4|huggingface|"hugging face"|HuggingFace|HUGGINGFACE|hf|HF)
        PROVIDER="huggingface"
        CURRENT_MODEL="$DEFAULT_HF_MODEL"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        break
        ;;
      5|nvidia|nvidia_nim|NVIDIA|nim|NIM)
        PROVIDER="nvidia_nim"
        CURRENT_MODEL="$DEFAULT_NVIDIA_MODEL"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        break
        ;;
      6|other|Other|OTHER)
        if configure_custom_provider; then
          break
        fi
        # cancelled — fall through and show the provider menu again
        ;;
      *)
        warn "Please choose 1 (OpenRouter), 2 (Google AI Studio), 3 (Mistral), 4 (Hugging Face), 5 (NVIDIA NIM), or 6 (Other Providers)."
        ;;
    esac
  done

  ok "Using $(provider_label)."
}

pick_provider_ui() {
  local choice new_provider new_label

  echo
  printf "${C_ACCENT2}┌─ PROVIDER ─────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} current: ${C_OK}%s${C_RESET}\n" "$(provider_label)"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n"
  printf "${C_MUTED}[1]${C_RESET} OpenRouter ${C_DIM}(many models, free + paid)${C_RESET}\n"
  printf "${C_MUTED}[2]${C_RESET} Google AI Studio ${C_DIM}(Gemini models)${C_RESET}\n"
  printf "${C_MUTED}[3]${C_RESET} Mistral ${C_DIM}(api.mistral.ai)${C_RESET}\n"
  printf "${C_MUTED}[4]${C_RESET} Hugging Face ${C_DIM}(Inference Providers router)${C_RESET}\n"
  printf "${C_MUTED}[5]${C_RESET} NVIDIA NIM ${C_DIM}(build.nvidia.com, e.g. Kimi K2.6)${C_RESET}\n"
  printf "${C_MUTED}[6]${C_RESET} Other Providers ${C_DIM}(self-hosted or any OpenAI-compatible API)${C_RESET}\n"
  echo
  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Provider? ${C_MUTED}[1-6, q to cancel]${C_RESET}: ")" choice || choice="q"

  case "$choice" in
    1|openrouter|OpenRouter|OPENROUTER)
      new_provider="openrouter"
      new_label="OpenRouter"
      ;;
    2|google|Google|GOOGLE)
      new_provider="google"
      new_label="Google AI Studio"
      ;;
    3|mistral|Mistral|MISTRAL)
      new_provider="mistral"
      new_label="Mistral"
      ;;
    4|huggingface|"hugging face"|HuggingFace|HUGGINGFACE|hf|HF)
      new_provider="huggingface"
      new_label="Hugging Face"
      ;;
    5|nvidia|nvidia_nim|NVIDIA|nim|NIM)
      new_provider="nvidia_nim"
      new_label="NVIDIA NIM"
      ;;
    6|other|Other|OTHER)
      # Custom setup collects its own confirmation as it goes (URL, key
      # requirement, model), so it doesn't need the generic
      # confirm_model_switch step the other two branches use below.
      if [[ "$PROVIDER" == "custom" ]]; then
        if ! confirm_yes_no "Already on a custom provider — reconfigure it?"; then
          muted "Cancelled."
          return 0
        fi
      fi
      if configure_custom_provider; then
        ok "Switched provider to: $(provider_label)"
        if ! ensure_provider_key; then
          warn "No API key provided — chats will fail until you set one."
          muted "Run 't> key' to set it."
        fi
      else
        muted "Cancelled."
      fi
      return 0
      ;;
    q|Q)
      muted "Cancelled."
      return 0
      ;;
    *)
      warn "Please choose 1 (OpenRouter), 2 (Google AI Studio), 3 (Mistral), 4 (Hugging Face), 5 (NVIDIA NIM), 6 (Other Providers), or q to cancel."
      return 1
      ;;
  esac

  if [[ "$new_provider" == "$PROVIDER" ]]; then
    muted "Already using $new_label."
    return 0
  fi

  if ! confirm_model_switch "$new_label"; then
    muted "Cancelled."
    return 0
  fi

  PROVIDER="$new_provider"
  case "$PROVIDER" in
    google) CURRENT_MODEL="$DEFAULT_GOOGLE_MODEL" ;;
    mistral) CURRENT_MODEL="$DEFAULT_MISTRAL_MODEL" ;;
    huggingface) CURRENT_MODEL="$DEFAULT_HF_MODEL" ;;
    nvidia_nim) CURRENT_MODEL="$DEFAULT_NVIDIA_MODEL" ;;
    *) CURRENT_MODEL="$DEFAULT_MODEL" ;;
  esac
  CURRENT_MODEL_LABEL="$CURRENT_MODEL"
  ok "Switched provider to: $new_label"
  muted "Model reset to $CURRENT_MODEL — use 't> model' to pick a different one."

  if ! ensure_provider_key; then
    warn "No $new_label API key provided — chats will fail until you set one."
    muted "Run 't> provider' again, or 't> model', to be prompted for it."
  fi
}

match_model_list() {
  # Prints models that match the search string, one per line.
  local query="$1"
  local models_file="$2"
  grep -iF "$query" "$models_file" || true
}

# Shows the numbered list for one tier and lets the user pick a model from
# it. Every successful pick still goes through confirm_model_switch before
# CURRENT_MODEL actually changes — declining drops back into this same list
# instead of exiting the picker. Returns 0 once a switch is confirmed, or
# once the user backs out (to the tier prompt) or cancels entirely.
#   $1 = tier ("free" or "paid")
# Return codes: 0 = switched, 2 = user asked to go back to tier picker,
# 1 = cancelled entirely.
pick_model_from_tier() {
  local tier="$1"
  local models_tmp selection_tmp models_count selected_idx query matches_count match_line candidate
  models_tmp="$(mktemp)"
  selection_tmp="$(mktemp)"

  local fetch_fn="fetch_free_models"
  case "$tier" in
    paid) fetch_fn="fetch_paid_models" ;;
    google) fetch_fn="fetch_google_models" ;;
  esac

  if ! "$fetch_fn" > "$models_tmp"; then
    warn "Could not fetch live models right now."
    muted "Falling back to a few known $tier models."
    echo
    if [[ "$tier" == "free" ]]; then
      printf "${C_MUTED}[1]${C_RESET} openrouter/free\n"
      printf "${C_MUTED}[2]${C_RESET} meta-llama/llama-3.3-8b-instruct:free\n"
      printf "${C_MUTED}[3]${C_RESET} deepseek/deepseek-chat-v3-0324:free\n"
      printf "${C_MUTED}[4]${C_RESET} mistralai/mistral-small-3.2-24b-instruct:free\n"
      printf "${C_MUTED}[5]${C_RESET} google/gemma-3-27b-it:free\n"
      printf 'openrouter/free\nmeta-llama/llama-3.3-8b-instruct:free\ndeepseek/deepseek-chat-v3-0324:free\nmistralai/mistral-small-3.2-24b-instruct:free\ngoogle/gemma-3-27b-it:free\n' > "$models_tmp"
    elif [[ "$tier" == "google" ]]; then
      printf "${C_MUTED}[1]${C_RESET} gemini-2.0-flash\n"
      printf "${C_MUTED}[2]${C_RESET} gemini-2.0-flash-lite\n"
      printf "${C_MUTED}[3]${C_RESET} gemini-1.5-flash\n"
      printf "${C_MUTED}[4]${C_RESET} gemini-1.5-pro\n"
      printf 'gemini-2.0-flash\ngemini-2.0-flash-lite\ngemini-1.5-flash\ngemini-1.5-pro\n' > "$models_tmp"
    else
      printf "${C_MUTED}[1]${C_RESET} openai/gpt-4o-mini\n"
      printf "${C_MUTED}[2]${C_RESET} openai/gpt-4o\n"
      printf "${C_MUTED}[3]${C_RESET} anthropic/claude-3.5-sonnet\n"
      printf "${C_MUTED}[4]${C_RESET} google/gemini-flash-1.5\n"
      printf "${C_MUTED}[5]${C_RESET} meta-llama/llama-3.1-70b-instruct\n"
      printf 'openai/gpt-4o-mini\nopenai/gpt-4o\nanthropic/claude-3.5-sonnet\ngoogle/gemini-flash-1.5\nmeta-llama/llama-3.1-70b-instruct\n' > "$models_tmp"
    fi
    echo
  fi

  mapfile -t MODELS < "$models_tmp"
  models_count="${#MODELS[@]}"

  if [[ "$models_count" -eq 0 ]]; then
    warn "No $tier models found."
    rm -f "$models_tmp" "$selection_tmp"
    return 1
  fi

  clear
  banner
  printf "${C_ACCENT2}┌─ MODEL PICKER — %s ────────────────────────────${C_RESET}\n" "${tier^^}"
  printf "${C_MUTED}│${C_RESET} current: ${C_OK}%s${C_RESET}\n" "$CURRENT_MODEL"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n"
  if [[ "$tier" == "free" ]]; then
    printf "${C_MUTED}[0]${C_RESET} openrouter/free ${C_DIM}(auto-router)${C_RESET}\n"
  fi
  for i in "${!MODELS[@]}"; do
    printf "${C_MUTED}[%d]${C_RESET} %s\n" "$((i + 1))" "${MODELS[$i]}"
  done
  echo
  muted "Type a number, part of a name, 'refresh', 'back' (choose tier again), or 'q' to cancel."

  while true; do
    read -r -p "$(printf "${C_ACCENT2}model>${C_RESET} ")" query || query="q"

    case "$query" in
      q|Q)
        rm -f "$models_tmp" "$selection_tmp"
        return 1
        ;;
      back|BACK|b|B)
        rm -f "$models_tmp" "$selection_tmp"
        return 2
        ;;
      refresh|REFRESH)
        rm -f "$models_tmp" "$selection_tmp"
        rm -f "$OPENROUTER_MODELS_CACHE_FILE"
        OPENROUTER_MODELS_CACHE_FILE=""
        OPENROUTER_MODELS_CACHE_TIME=0
        pick_model_from_tier "$tier"
        return $?
        ;;
    esac

    if [[ "$query" == "0" && "$tier" == "free" ]]; then
      candidate="openrouter/free"
      if confirm_model_switch "$candidate"; then
        apply_model_switch "$candidate"
        rm -f "$models_tmp" "$selection_tmp"
        return 0
      fi
      muted "Cancelled — pick another model or 'q' to exit."
      continue
    fi

    if [[ "$query" =~ ^[0-9]+$ ]]; then
      selected_idx="$query"
      if (( selected_idx >= 1 && selected_idx <= models_count )); then
        candidate="${MODELS[$((selected_idx - 1))]}"
        if confirm_model_switch "$candidate"; then
          apply_model_switch "$candidate"
          rm -f "$models_tmp" "$selection_tmp"
          return 0
        fi
        muted "Cancelled — pick another model or 'q' to exit."
        continue
      fi
      warn "Invalid number."
      continue
    fi

    # Fuzzy search against the current tier's list.
    grep -iF "$query" "$models_tmp" > "$selection_tmp" || true
    matches_count="$(wc -l < "$selection_tmp" | tr -d ' ')"

    if [[ "$matches_count" -eq 0 ]]; then
      warn "No matches found."
      continue
    fi

    if [[ "$matches_count" -eq 1 ]]; then
      candidate="$(cat "$selection_tmp")"
      if confirm_model_switch "$candidate"; then
        apply_model_switch "$candidate"
        rm -f "$models_tmp" "$selection_tmp"
        return 0
      fi
      muted "Cancelled — pick another model or 'q' to exit."
      continue
    fi

    echo
    printf "${C_MUTED}Matches:${C_RESET}\n"
    nl -ba "$selection_tmp" | sed 's/^\s*//' | while IFS=$'\t' read -r n m; do
      printf "${C_MUTED}[%s]${C_RESET} %s\n" "$n" "$m"
    done
    echo
    read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Choose number or q: ")" selected_idx || selected_idx="q"
    [[ "$selected_idx" == "q" ]] && continue

    if [[ "$selected_idx" =~ ^[0-9]+$ ]]; then
      match_line="$(sed -n "${selected_idx}p" "$selection_tmp")"
      if [[ -n "$match_line" ]]; then
        candidate="$match_line"
        if confirm_model_switch "$candidate"; then
          apply_model_switch "$candidate"
          rm -f "$models_tmp" "$selection_tmp"
          return 0
        fi
        muted "Cancelled — pick another model or 'q' to exit."
        continue
      fi
    fi

    warn "Invalid choice."
  done
}

# Entry point for the "t> model" command.
# - OpenRouter: always asks Free-or-Paid first, then hands off to
#   pick_model_from_tier, which itself always confirms before committing a
#   switch. 'back' from the tier list returns here so the user can pick a
#   different tier without leaving the picker entirely.
# - Google AI Studio: there's no free/paid split in the model list (the
#   free tier is a rate limit on the same models, not separate IDs), so
#   this skips straight to the Google model list — still gated by the same
#   confirm_model_switch blocker on every pick.
pick_model_ui() {
  local tier

  if [[ "$PROVIDER" == "google" ]]; then
    if ! ensure_provider_key; then
      warn "No Google AI Studio API key provided."
      return 1
    fi
    pick_model_from_tier "google"
    return 0
  fi

  if [[ "$PROVIDER" == "custom" || "$PROVIDER" == "mistral" || "$PROVIDER" == "huggingface" || "$PROVIDER" == "nvidia_nim" ]]; then
    # None of these expose a model-list API we hook into (yet), so — same
    # as "Other Providers" — just take the model id as free text.
    prompt_custom_model_name
    return 0
  fi

  while true; do
    tier="$(prompt_model_tier)" || return 0
    pick_model_from_tier "$tier"
    case $? in
      0) return 0 ;;   # switched
      2) continue ;;    # user chose "back" — ask tier again
      *) return 0 ;;    # cancelled
    esac
  done
}

# There's no model-list API for an arbitrary "Other Provider" endpoint, so
# this just takes free-text input directly instead of the free/paid tier
# picker the other providers use.
prompt_custom_model_name() {
  local model

  printf "${C_MUTED}current model:${C_RESET} %s\n" "$CURRENT_MODEL"
  if ! read -r -p "$(printf "${C_ACCENT2}?${C_RESET} New model name ${C_MUTED}(q to cancel)${C_RESET}: ")" model; then
    muted "Cancelled."
    return 1
  fi
  [[ "$model" == "q" || "$model" == "Q" || -z "$model" ]] && { muted "Cancelled."; return 1; }

  if confirm_model_switch "$model"; then
    apply_model_switch "$model"
    return 0
  fi
  muted "Cancelled."
  return 1
}

set_model_by_name() {
  local input="$1"

  if [[ "$PROVIDER" == "google" ]]; then
    set_model_by_name_google "$input"
    return $?
  fi

  if [[ "$PROVIDER" == "custom" || "$PROVIDER" == "mistral" || "$PROVIDER" == "huggingface" || "$PROVIDER" == "nvidia_nim" ]]; then
    if confirm_model_switch "$input"; then
      apply_model_switch "$input"
      return 0
    fi
    muted "Cancelled."
    return 1
  fi

  local free_tmp paid_tmp exact_match fuzzy_match count candidate

  free_tmp="$(mktemp)"
  paid_tmp="$(mktemp)"
  fetch_free_models > "$free_tmp" || : > "$free_tmp"
  fetch_paid_models > "$paid_tmp" || : > "$paid_tmp"

  if [[ ! -s "$free_tmp" && ! -s "$paid_tmp" ]]; then
    rm -f "$free_tmp" "$paid_tmp"
    if [[ "$input" == *":free" ]]; then
      if confirm_model_switch "$input"; then
        apply_model_switch "$input"
        return 0
      fi
      muted "Cancelled."
      return 1
    fi
    err "Could not fetch models right now."
    return 1
  fi

  # Exact match, checking free first, then paid.
  exact_match="$(grep -Fx "$input" "$free_tmp" || true)"
  [[ -z "$exact_match" ]] && exact_match="$(grep -Fx "$input" "$paid_tmp" || true)"
  if [[ -n "$exact_match" ]]; then
    if confirm_model_switch "$input"; then
      apply_model_switch "$input"
      rm -f "$free_tmp" "$paid_tmp"
      return 0
    fi
    muted "Cancelled."
    rm -f "$free_tmp" "$paid_tmp"
    return 1
  fi

  # Fuzzy match across both lists combined.
  fuzzy_match="$(cat "$free_tmp" "$paid_tmp" | grep -iF "$input" || true)"
  if [[ -z "$fuzzy_match" ]]; then
    count=0
  else
    count="$(wc -l <<< "$fuzzy_match" | tr -d ' ')"
  fi

  if [[ "$count" -eq 1 ]]; then
    candidate="$(head -n 1 <<< "$fuzzy_match")"
    if confirm_model_switch "$candidate"; then
      apply_model_switch "$candidate"
      rm -f "$free_tmp" "$paid_tmp"
      return 0
    fi
    muted "Cancelled."
    rm -f "$free_tmp" "$paid_tmp"
    return 1
  fi

  if [[ "$count" -gt 1 ]]; then
    echo "$fuzzy_match"
    echo
    warn "More than one match. Use 't> model' to pick one."
    rm -f "$free_tmp" "$paid_tmp"
    return 1
  fi

  if [[ "$input" == *":free" ]]; then
    if confirm_model_switch "$input"; then
      apply_model_switch "$input"
      rm -f "$free_tmp" "$paid_tmp"
      return 0
    fi
    muted "Cancelled."
    rm -f "$free_tmp" "$paid_tmp"
    return 1
  fi

  warn "Model not found."
  rm -f "$free_tmp" "$paid_tmp"
  return 1
}

# Google-specific counterpart to the OpenRouter name-matching logic above —
# separate because Google has one flat model list rather than a free/paid
# split, and requires an API key just to list models at all.
set_model_by_name_google() {
  local input="$1"
  local models_tmp exact_match fuzzy_match count candidate

  if ! ensure_provider_key; then
    warn "No Google AI Studio API key provided."
    return 1
  fi

  models_tmp="$(mktemp)"
  if ! fetch_google_models > "$models_tmp"; then
    rm -f "$models_tmp"
    err "Could not fetch Google AI Studio models right now."
    return 1
  fi

  exact_match="$(grep -Fx "$input" "$models_tmp" || true)"
  if [[ -n "$exact_match" ]]; then
    if confirm_model_switch "$input"; then
      apply_model_switch "$input"
      rm -f "$models_tmp"
      return 0
    fi
    muted "Cancelled."
    rm -f "$models_tmp"
    return 1
  fi

  fuzzy_match="$(grep -iF "$input" "$models_tmp" || true)"
  if [[ -z "$fuzzy_match" ]]; then
    count=0
  else
    count="$(wc -l <<< "$fuzzy_match" | tr -d ' ')"
  fi

  if [[ "$count" -eq 1 ]]; then
    candidate="$(head -n 1 <<< "$fuzzy_match")"
    if confirm_model_switch "$candidate"; then
      apply_model_switch "$candidate"
      rm -f "$models_tmp"
      return 0
    fi
    muted "Cancelled."
    rm -f "$models_tmp"
    return 1
  fi

  if [[ "$count" -gt 1 ]]; then
    echo "$fuzzy_match"
    echo
    warn "More than one match. Use 't> model' to pick one."
    rm -f "$models_tmp"
    return 1
  fi

  warn "Model not found."
  rm -f "$models_tmp"
  return 1
}

# ── Undo / Redo journal ─────────────────────────────────────────────────
# Session-only, snapshot-based undo covering every action that changes the
# sandbox: FILE_WRITE/FILE_EDIT/FILE_DELETE, FOLDER_CREATE/FOLDER_DELETE,
# FILE_MOVE/FOLDER_MOVE, all BULK_* variants, ZIP_EXTRACT, and NET_DOWNLOAD.
# Not available for SHELL_RUN or MCP_CALL — those can have arbitrary side
# effects outside the sandbox that nothing here could snapshot or reverse.
#
# Model: two parallel stacks (undo/redo). Each entry is one changed path,
# described as kind + two fields:
#   file/dir — a = absolute path, b = snapshot to restore ("" means the
#              path didn't exist before, so undo/redo just removes it)
#   move     — a = where the item currently is, b = where to move it back to
# A single logical action (one marker, or one whole BULK_*/ZIP_EXTRACT
# block) is wrapped in undo_group_begin/undo_group_end so all its entries
# share one group id — one 't> undo' reverts the whole batch together.
# Undo and redo are the same operation aimed at opposite stacks: applying
# an entry first snapshots whatever it's about to overwrite and pushes
# THAT as the inverse onto the other stack, so flipping back and forth
# never loses information.
UNDO_DIR=""
UNDO_SNAP_SEQ=0
UNDO_GROUP_SEQ=0
CURRENT_UNDO_GROUP=""
declare -a UNDO_KIND=() UNDO_A=() UNDO_B=() UNDO_LABEL=() UNDO_GROUP=()
declare -a REDO_KIND=() REDO_A=() REDO_B=() REDO_LABEL=() REDO_GROUP=()

init_undo_dir() {
  [[ -n "$UNDO_DIR" && -d "$UNDO_DIR" ]] && return 0
  UNDO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aulthium_undo.XXXXXX" 2>/dev/null)" || UNDO_DIR=""
}

undo_new_snapshot_path() {
  init_undo_dir
  UNDO_SNAP_SEQ=$((UNDO_SNAP_SEQ + 1))
  printf '%s/snap_%s' "$UNDO_DIR" "$UNDO_SNAP_SEQ"
}

# Snapshots whatever currently exists at $1 (file, dir, or nothing) into
# the undo store and prints "file:<path>" / "dir:<path>" / "file:" so the
# caller can build an undo/redo entry from the result.
_snapshot_path() {
  local abs="$1" snap
  if [[ -d "$abs" && ! -L "$abs" ]]; then
    snap="$(undo_new_snapshot_path)"
    mkdir -p "$snap"
    cp -a "$abs" "$snap/payload" 2>/dev/null
    printf 'dir:%s/payload' "$snap"
  elif [[ -e "$abs" ]]; then
    snap="$(undo_new_snapshot_path)"
    cp -a "$abs" "$snap" 2>/dev/null
    printf 'file:%s' "$snap"
  else
    printf 'file:'
  fi
}

# Starts a new undo group. Call once before a logical action that may push
# several undo entries (a single marker, or one BULK_*/ZIP_EXTRACT block).
# Clears the redo stack, since taking a new action invalidates whatever
# used to be "ahead" of it — standard undo/redo behavior.
undo_group_begin() {
  UNDO_GROUP_SEQ=$((UNDO_GROUP_SEQ + 1))
  CURRENT_UNDO_GROUP="g$UNDO_GROUP_SEQ"
  REDO_KIND=(); REDO_A=(); REDO_B=(); REDO_LABEL=(); REDO_GROUP=()
}

undo_group_end() {
  CURRENT_UNDO_GROUP=""
}

_stack_push() {
  local -n _k="${1}_KIND" _a="${1}_A" _b="${1}_B" _l="${1}_LABEL" _g="${1}_GROUP"
  _k+=("$2"); _a+=("$3"); _b+=("$4"); _l+=("$5"); _g+=("$6")
}

# push_undo kind a b label — records one entry in the CURRENT group. A
# no-op outside of undo_group_begin/end (so code paths that shouldn't be
# undoable, or run before init, never silently corrupt the journal).
push_undo() {
  [[ -z "$CURRENT_UNDO_GROUP" ]] && return 0
  _stack_push "UNDO" "$1" "$2" "$3" "$4" "$CURRENT_UNDO_GROUP"
}

# Snapshots the CURRENT state of $1 and records an undo entry that would
# restore exactly that state. Call this BEFORE mutating $1 (write, edit,
# delete, or overwrite-on-move). $2 is the human label shown in
# 't> undo'/'t> redo' output (usually the workspace-relative path).
snapshot_before_change() {
  local abs="$1" label="$2" desc
  desc="$(_snapshot_path "$abs")"
  push_undo "${desc%%:*}" "$abs" "${desc#*:}" "$label"
}

# Records that $2 was just moved from $1 — undo moves it back to $1.
record_move_undo() {
  push_undo "move" "$2" "$1" "$3"
}

# Pops the most recent group off stack $1 (UNDO or REDO) into the globals
# POPPED_KIND/POPPED_A/POPPED_B/POPPED_LABEL, oldest-entry-first. Returns 1
# if that stack is empty.
_stack_pop_last_group() {
  local -n _k="${1}_KIND" _a="${1}_A" _b="${1}_B" _l="${1}_LABEL" _g="${1}_GROUP"
  local n="${#_g[@]}"
  POPPED_KIND=(); POPPED_A=(); POPPED_B=(); POPPED_LABEL=()
  [[ "$n" -eq 0 ]] && return 1
  local top_group="${_g[$((n-1))]}" start=$((n-1))
  while (( start > 0 )) && [[ "${_g[$((start-1))]}" == "$top_group" ]]; do
    start=$((start-1))
  done
  local i
  for (( i = start; i < n; i++ )); do
    POPPED_KIND+=("${_k[$i]}"); POPPED_A+=("${_a[$i]}"); POPPED_B+=("${_b[$i]}"); POPPED_LABEL+=("${_l[$i]}")
  done
  _k=("${_k[@]:0:$start}"); _a=("${_a[@]:0:$start}"); _b=("${_b[@]:0:$start}")
  _l=("${_l[@]:0:$start}"); _g=("${_g[@]:0:$start}")
  return 0
}

# Applies a just-popped group (newest entry first is how undo should be
# applied within a batch, so this walks it in reverse) and pushes the
# inverse of each entry onto $1 (the other stack), building the new group
# under a fresh group id so it undoes/redoes back together as one unit.
_apply_popped_group() {
  local push_to="$1" verb="$2"
  local n="${#POPPED_KIND[@]}" i kind a b label
  local new_group="g$((++UNDO_GROUP_SEQ))"
  box_top "$verb" "$ICON_UNDO" "$C_WARN"
  for (( i = n - 1; i >= 0; i-- )); do
    kind="${POPPED_KIND[$i]}"; a="${POPPED_A[$i]}"; b="${POPPED_B[$i]}"; label="${POPPED_LABEL[$i]}"
    case "$kind" in
      file|dir)
        local desc
        desc="$(_snapshot_path "$a")"
        rm -rf "$a" 2>/dev/null
        if [[ -n "$b" ]]; then
          mkdir -p "$(dirname "$a")" 2>/dev/null
          cp -a "$b" "$a" 2>/dev/null
          box_line "restored: ${a#"$WORKSPACE_DIR"/} ${C_DIM}($label)${C_RESET}"
        else
          box_line "removed: ${a#"$WORKSPACE_DIR"/} ${C_DIM}($label)${C_RESET}"
        fi
        _stack_push "$push_to" "${desc%%:*}" "$a" "${desc#*:}" "$label" "$new_group"
        ;;
      move)
        if [[ -e "$b" ]]; then
          box_line "${C_WARN}skipped, something now exists at the old location: ${b#"$WORKSPACE_DIR"/}${C_RESET}"
        elif [[ -e "$a" ]]; then
          mkdir -p "$(dirname "$b")" 2>/dev/null
          robust_move "$a" "$b"
          box_line "moved back: ${a#"$WORKSPACE_DIR"/} -> ${b#"$WORKSPACE_DIR"/} ${C_DIM}($label)${C_RESET}"
          _stack_push "$push_to" "move" "$b" "$a" "$label" "$new_group"
        else
          box_line "${C_WARN}skipped, source missing: ${a#"$WORKSPACE_DIR"/}${C_RESET}"
        fi
        ;;
    esac
  done
  box_bottom "$C_WARN"
  ok "$verb $n change(s)."
}

run_undo() {
  if ! _stack_pop_last_group "UNDO"; then
    warn "Nothing to undo."
    return
  fi
  _apply_popped_group "REDO" "Undid"
}

run_redo() {
  if ! _stack_pop_last_group "REDO"; then
    warn "Nothing to redo."
    return
  fi
  _apply_popped_group "UNDO" "Redid"
}

undo_status() {
  local -a seen=() g
  local i n_undo n_redo
  n_undo=0
  for g in "${UNDO_GROUP[@]}"; do
    [[ " ${seen[*]} " == *" $g "* ]] && continue
    seen+=("$g"); n_undo=$((n_undo + 1))
  done
  seen=()
  n_redo=0
  for g in "${REDO_GROUP[@]}"; do
    [[ " ${seen[*]} " == *" $g "* ]] && continue
    seen+=("$g"); n_redo=$((n_redo + 1))
  done
  printf "${C_MUTED}undo:${C_RESET} %s step(s) available\n" "$n_undo"
  printf "${C_MUTED}redo:${C_RESET} %s step(s) available\n" "$n_redo"
  muted "SHELL_RUN and MCP_CALL are never covered by undo — only sandboxed file/folder/zip/network actions are."
}


handle_write_action() {
  local rel="$1" content_file="$2" abs lines parent_dir missing_dirs

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe write proposal: $rel"; return; }

  parent_dir="$(dirname "$abs")"
  missing_dirs=""
  if [[ ! -d "$parent_dir" ]]; then
    # Show the path relative to the workspace so it's meaningful to the user.
    missing_dirs="${parent_dir#"$WORKSPACE_DIR"/}"
  fi

  lines="$(wc -l < "$content_file" | tr -d ' ')"
  box_top "WRITE FILE" "$ICON_WRITE" "$C_WARN"
  box_line "$abs ${C_DIM}(${lines} lines)${C_RESET}"
  if [[ -n "$missing_dirs" ]]; then
    box_line "${C_DIM}also creates folder(s): ${missing_dirs}${C_RESET}"
  fi
  box_line "${C_DIM}preview (first 40 lines):${C_RESET}"
  sed -n '1,40p' "$content_file" | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_WARN"

  if confirm_action "Apply this write?"; then
    mkdir -p "$parent_dir" 2>/dev/null
    undo_group_begin
    snapshot_before_change "$abs" "write ${abs#"$WORKSPACE_DIR"/}"
    undo_group_end
    if cp "$content_file" "$abs"; then
      ok "Wrote $abs"
    else
      err "Failed to write $abs"
    fi
  else
    warn "Skipped write: $rel"
  fi
}

# FILE_EDIT — requires confirmation. Applies a single line-range change
# (replace/insert/delete) instead of rewriting the whole file. content_file
# holds the new lines (empty for a delete). start/end are 1-based and
# inclusive; for op="insert" the "start" argument doubles as the after-line
# (0 = insert at the top of the file).
handle_edit_action() {
  local rel="$1" op="$2" start="$3" end="$4" content_file="$5"
  local abs total old_lines tmpfile

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe edit proposal: $rel"; return; }

  if [[ ! -e "$abs" ]]; then
    err "Cannot edit, file does not exist (use FILE_WRITE to create it first): $abs"
    return
  fi
  if [[ -d "$abs" ]]; then
    err "That's a folder, not a file: $abs"
    return
  fi

  # NOTE: intentionally NOT `wc -l` here. wc -l counts newline characters,
  # so a file whose last line has no trailing newline (extremely common —
  # most source files, JSON, hand-edited configs) gets undercounted by one.
  # FILE_READ numbers lines with `nl`, which counts the final unterminated
  # line correctly, so a wc-l-based total here would silently reject any
  # edit/delete/insert touching that last line as "out of range" even
  # though the model just saw it listed. grep -c '' matches nl's counting.
  total="$(grep -c '' "$abs" 2>/dev/null | tr -d ' ')"

  if [[ "$op" == "insert" ]]; then
    if ! [[ "$start" =~ ^[0-9]+$ ]] || (( start < 0 || start > total )); then
      err "Invalid insert position 'after=$start' — file has $total line(s)."
      return
    fi
  else
    if ! [[ "$start" =~ ^[0-9]+$ ]] || ! [[ "$end" =~ ^[0-9]+$ ]] || (( start < 1 || end < start || end > total )); then
      err "Invalid line range start=$start end=$end — file has $total line(s)."
      return
    fi
  fi

  tmpfile="$(mktemp)"

  case "$op" in
    replace)
      head -n "$((start - 1))" "$abs" > "$tmpfile"
      cat "$content_file" >> "$tmpfile"
      tail -n "+$((end + 1))" "$abs" >> "$tmpfile"
      box_top "EDIT FILE (replace lines $start-$end)" "$ICON_EDIT" "$C_WARN"
      box_line "$abs"
      old_lines="$(sed -n "${start},${end}p" "$abs")"
      printf '%s\n' "$old_lines" | while IFS= read -r pl; do box_line "${C_ERR}- ${pl}${C_RESET}"; done
      printf '%s\n' "$(cat "$content_file")" | while IFS= read -r pl; do box_line "${C_OK}+ ${pl}${C_RESET}"; done
      box_bottom "$C_WARN"
      ;;
    insert)
      head -n "$start" "$abs" > "$tmpfile"
      cat "$content_file" >> "$tmpfile"
      tail -n "+$((start + 1))" "$abs" >> "$tmpfile"
      box_top "EDIT FILE (insert after line $start)" "$ICON_EDIT" "$C_WARN"
      box_line "$abs"
      printf '%s\n' "$(cat "$content_file")" | while IFS= read -r pl; do box_line "${C_OK}+ ${pl}${C_RESET}"; done
      box_bottom "$C_WARN"
      ;;
    delete)
      head -n "$((start - 1))" "$abs" > "$tmpfile"
      tail -n "+$((end + 1))" "$abs" >> "$tmpfile"
      box_top "EDIT FILE (delete lines $start-$end)" "$ICON_EDIT" "$C_ERR"
      box_line "$abs"
      old_lines="$(sed -n "${start},${end}p" "$abs")"
      printf '%s\n' "$old_lines" | while IFS= read -r pl; do box_line "${C_ERR}- ${pl}${C_RESET}"; done
      box_bottom "$C_ERR"
      ;;
    *)
      err "Unknown FILE_EDIT op: $op"
      rm -f "$tmpfile"
      return
      ;;
  esac

  if confirm_action "Apply this edit?"; then
    undo_group_begin
    snapshot_before_change "$abs" "edit ${abs#"$WORKSPACE_DIR"/}"
    undo_group_end
    if cp "$tmpfile" "$abs"; then
      ok "Edited $abs"
    else
      err "Failed to edit $abs"
    fi
  else
    warn "Skipped edit: $rel"
  fi
  rm -f "$tmpfile"
}

handle_folder_create_action() {
  local rel="$1" abs

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe folder proposal: $rel"; return; }

  if [[ -e "$abs" ]]; then
    if [[ -d "$abs" ]]; then
      warn "Folder already exists, nothing to do: $abs"
    else
      err "A file already exists at that path (not a folder): $abs"
    fi
    return
  fi

  box_top "CREATE FOLDER" "$ICON_FOLDER" "$C_WARN"
  box_line "$abs"
  box_bottom "$C_WARN"

  if confirm_action "Create this folder?"; then
    if mkdir -p "$abs"; then
      undo_group_begin
      push_undo "dir" "$abs" "" "create ${abs#"$WORKSPACE_DIR"/}"
      undo_group_end
      ok "Created $abs"
    else
      err "Failed to create $abs"
    fi
  else
    warn "Skipped folder creation: $rel"
  fi
}

handle_delete_action() {
  local rel="$1" abs

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe delete proposal: $rel"; return; }

  if [[ -d "$abs" ]]; then
    err "Refusing to delete a directory (only single files are allowed): $abs"
    return
  fi

  if [[ ! -e "$abs" ]]; then
    warn "Nothing to delete, file does not exist: $abs"
    return
  fi

  box_top "DELETE FILE" "$ICON_DELETE" "$C_ERR"
  box_line "$abs"
  box_bottom "$C_ERR"

  if confirm_action "Delete this file?"; then
    undo_group_begin
    snapshot_before_change "$abs" "delete ${abs#"$WORKSPACE_DIR"/}"
    undo_group_end
    if rm -f "$abs"; then
      ok "Deleted $abs"
    else
      err "Failed to delete $abs"
    fi
  else
    warn "Skipped delete: $rel"
  fi
}

# FILE_MOVE / FOLDER_MOVE — requires confirmation. Handles both a real move
# (different folder) and a rename (same folder, new name) since on a
# filesystem those are the same `mv` operation; the marker name in the box
# just reflects which one it looks like to the user. Works for both files
# and folders — the underlying check is identical, so one handler covers
# FILE_MOVE and FOLDER_MOVE rather than duplicating this for each.
# On plain local filesystems `mv` is a single atomic rename() and its exit
# code is trustworthy. On Android shared storage (which is where this
# script's default workspace lives on Termux — see default_workspace_dir),
# access goes through a FUSE/SAF bridge that has a known failure mode: it
# can report the rename as successful when it silently didn't complete,
# particularly for folder moves. Rather than trust that single exit code,
# do the move as copy -> verify the copy actually landed -> only then
# remove the source. This costs a bit of I/O but means "Moved" printed to
# the user is backed by an actual check that the destination is real,
# instead of forwarding whatever the underlying syscall claimed.
robust_move() {
  local src="$1" dst="$2"

  if [[ -d "$src" ]]; then
    local src_count dst_count
    src_count="$(find "$src" -type f 2>/dev/null | wc -l)"

    if ! cp -a "$src" "$dst" 2>/dev/null; then
      rm -rf "$dst" 2>/dev/null
      return 1
    fi

    dst_count="$(find "$dst" -type f 2>/dev/null | wc -l)"
    if [[ ! -d "$dst" || "$src_count" != "$dst_count" ]]; then
      rm -rf "$dst" 2>/dev/null
      return 1
    fi

    rm -rf "$src" 2>/dev/null
    return 0
  else
    local src_size dst_size
    src_size="$(wc -c < "$src" 2>/dev/null)"

    if ! cp -p "$src" "$dst" 2>/dev/null; then
      rm -f "$dst" 2>/dev/null
      return 1
    fi

    dst_size="$(wc -c < "$dst" 2>/dev/null)"
    if [[ ! -f "$dst" || "$src_size" != "$dst_size" ]]; then
      rm -f "$dst" 2>/dev/null
      return 1
    fi

    rm -f "$src" 2>/dev/null
    return 0
  fi
}

# Generates a free filename by appending " (1)", " (2)", etc. before the
# extension — used by the "rename" conflict strategy on moves, so a
# collision doesn't require picking overwrite or skip.
find_available_name() {
  local target="$1" dir base ext candidate n=1
  dir="$(dirname "$target")"
  base="$(basename "$target")"
  if [[ "$base" == *.* && "$base" != .* ]]; then
    ext=".${base##*.}"
    base="${base%.*}"
  else
    ext=""
  fi
  candidate="$target"
  while [[ -e "$candidate" ]]; do
    candidate="$dir/${base} (${n})${ext}"
    n=$((n + 1))
  done
  printf '%s' "$candidate"
}

handle_move_action() {
  local rel_from="$1" rel_to="$2" kind_label="$3" conflict="${4:-skip}"
  local abs_from abs_to dest_dir action_label

  abs_from="$(resolve_safe_path "$rel_from")" || { warn "Skipped unsafe move proposal: $rel_from"; return; }
  abs_to="$(resolve_safe_path "$rel_to")" || { warn "Skipped unsafe move destination: $rel_to"; return; }

  if [[ ! -e "$abs_from" ]]; then
    err "Nothing to move, source does not exist: $abs_from"
    return
  fi

  if [[ "$abs_from" == "$WORKSPACE_DIR" ]]; then
    err "Refusing to move the sandbox root itself: $abs_from"
    return
  fi

  # Explicit, redundant guard against critical system directories — belt
  # and braces on top of resolve_safe_path (which already confines every
  # path to WORKSPACE_DIR and rejects is_dangerous_root locations). Kept
  # here too so the block is visible right at the point of the move, not
  # just buried in path resolution.
  if is_dangerous_root "$abs_from" || is_dangerous_root "$abs_to"; then
    err "Refusing to move a critical system directory: $abs_from -> $abs_to"
    return
  fi

  if [[ -d "$abs_from" && "$kind_label" == "file" ]]; then
    err "That's a folder, not a file (use FOLDER_MOVE instead): $abs_from"
    return
  fi
  if [[ ! -d "$abs_from" && "$kind_label" == "folder" ]]; then
    err "That's a file, not a folder (use FILE_MOVE instead): $abs_from"
    return
  fi

  # If the destination is an existing FOLDER, treat this the way `mv` does:
  # drop the source inside it (dest/basename), rather than requiring the
  # caller to already know and spell out the final filename. Without this,
  # the completely ordinary "move this into that folder" request — where
  # the target folder legitimately already exists — was indistinguishable
  # from trying to overwrite something, and got refused outright.
  if [[ -d "$abs_to" ]]; then
    abs_to="${abs_to%/}/$(basename "$abs_from")"
  fi

  # Name-conflict handling: overwrite / skip / rename. Defaults to "skip"
  # (the old hard-refuse behavior, just framed as an intentional skip
  # rather than an error) when the model doesn't specify a strategy.
  # "rename" picks the final destination name now (a pure computation, no
  # side effects) so the confirmation box below shows the real path the
  # move will use; "overwrite" only records that removal is PENDING —
  # the destination isn't actually touched until the user confirms below,
  # so declining leaves it untouched instead of already being gone.
  local pending_overwrite=0
  if [[ -e "$abs_to" ]]; then
    case "$conflict" in
      overwrite)
        pending_overwrite=1
        ;;
      rename)
        abs_to="$(find_available_name "$abs_to")"
        ;;
      *)
        warn "Skipped move (destination already exists): $abs_from -> $abs_to"
        return
        ;;
    esac
  fi

  # A destination inside the source itself (moving a folder into its own
  # subtree) would corrupt or infinite-loop the move — block it outright.
  if [[ -d "$abs_from" ]]; then
    case "$abs_to" in
      "$abs_from"|"$abs_from"/*)
        err "Refusing to move a folder into itself or its own subfolder: $abs_to"
        return
        ;;
    esac
  fi

  dest_dir="$(dirname "$abs_to")"
  if [[ "$(dirname "$abs_from")" == "$dest_dir" ]]; then
    action_label="RENAME $([[ "$kind_label" == "folder" ]] && printf FOLDER || printf FILE)"
  else
    action_label="MOVE $([[ "$kind_label" == "folder" ]] && printf FOLDER || printf FILE)"
  fi

  box_top "$action_label" "$ICON_MOVE" "$C_WARN"
  box_line "from: $abs_from"
  box_line "to:   $abs_to"
  [[ "$pending_overwrite" -eq 1 ]] && box_line "${C_WARN}this replaces what's already at the destination${C_RESET}"
  box_bottom "$C_WARN"

  if confirm_action "Proceed with this ${kind_label}?"; then
    mkdir -p "$dest_dir" 2>/dev/null
    undo_group_begin
    if [[ "$pending_overwrite" -eq 1 ]]; then
      snapshot_before_change "$abs_to" "overwritten by move ${abs_to#"$WORKSPACE_DIR"/}"
      if [[ -d "$abs_to" && ! -L "$abs_to" ]]; then rm -rf "$abs_to" 2>/dev/null; else rm -f "$abs_to" 2>/dev/null; fi
    fi
    if robust_move "$abs_from" "$abs_to"; then
      record_move_undo "$abs_from" "$abs_to" "$([[ "$action_label" == RENAME* ]] && printf rename || printf move) ${kind_label}"
      undo_group_end
      ok "Moved $abs_from -> $abs_to"
    else
      undo_group_end
      err "Failed to move $abs_from -> $abs_to"
    fi
  else
    warn "Skipped move: $rel_from -> $rel_to"
  fi
}

handle_folder_delete_action() {
  local rel="$1" abs entry_count

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe folder delete proposal: $rel"; return; }

  # Extra guard on top of resolve_safe_path/is_dangerous_root: never allow
  # this to resolve to the workspace root itself — only real subfolders.
  if [[ "$abs" == "$WORKSPACE_DIR" ]]; then
    err "Refusing to delete the sandbox root itself: $abs"
    return
  fi

  if [[ ! -e "$abs" ]]; then
    warn "Nothing to delete, folder does not exist: $abs"
    return
  fi

  if [[ ! -d "$abs" ]]; then
    err "That's a file, not a folder (use FILE_DELETE instead): $abs"
    return
  fi

  entry_count="$(find "$abs" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"

  box_top "DELETE FOLDER" "$ICON_DELETE" "$C_ERR"
  box_line "$abs"
  box_line "${C_DIM}contains $entry_count item(s), all of which will be removed${C_RESET}"
  box_bottom "$C_ERR"
  warn "This deletes the folder AND everything inside it (run 't> undo' to reverse it)."

  if confirm_action "Delete this folder and everything inside it?"; then
    undo_group_begin
    snapshot_before_change "$abs" "delete folder ${abs#"$WORKSPACE_DIR"/}"
    undo_group_end
    if rm -rf "$abs"; then
      ok "Deleted $abs"
    else
      err "Failed to delete $abs"
    fi
  else
    warn "Skipped folder delete: $rel"
  fi
}

# --- Bulk variants -----------------------------------------------------
# Same underlying operations as the single-item handlers above, but for a
# whole batch collected from one <<<BULK_WRITE>>>, <<<BULK_FOLDER_CREATE>>>,
# or <<<BULK_DELETE>>> block: one summary box listing every item, ONE
# confirm_yes_no for the entire batch, then applied item-by-item. This
# exists so scaffolding e.g. a 12-file project doesn't mean the user has
# to sit through 12 separate y/n prompts — see process_agent_reply for how
# these get parsed, and the system prompt section on BULK_* for when the
# model should prefer these over repeated single markers.
#
# Both array arguments are passed BY NAME (nameref) so the whole batch can
# be reviewed and applied together instead of one path at a time.

handle_bulk_write_action() {
  local -n _bw_paths="$1"
  local -n _bw_files="$2"
  local n="${#_bw_paths[@]}" i abs lines
  local -a abs_list=()

  box_top "BULK WRITE ($n file$([[ $n -eq 1 ]] || printf s))" "$ICON_WRITE" "$C_WARN"
  for i in "${!_bw_paths[@]}"; do
    abs="$(resolve_safe_path "${_bw_paths[$i]}")"
    if [[ -z "$abs" ]]; then
      box_line "${C_ERR}(skipped, unsafe path): ${_bw_paths[$i]}${C_RESET}"
      abs_list+=("")
      continue
    fi
    lines="$(wc -l < "${_bw_files[$i]}" | tr -d ' ')"
    box_line "$abs ${C_DIM}(${lines} lines)${C_RESET}"
    abs_list+=("$abs")
  done
  box_bottom "$C_WARN"

  if confirm_action "Apply all $n write(s)?"; then
    local wrote=0 failed=0
    undo_group_begin
    for i in "${!_bw_paths[@]}"; do
      abs="${abs_list[$i]}"
      if [[ -z "$abs" ]]; then
        failed=$((failed + 1))
        continue
      fi
      mkdir -p "$(dirname "$abs")" 2>/dev/null
      snapshot_before_change "$abs" "write ${abs#"$WORKSPACE_DIR"/}"
      if cp "${_bw_files[$i]}" "$abs"; then
        ok "Wrote $abs"
        wrote=$((wrote + 1))
      else
        err "Failed to write $abs"
        failed=$((failed + 1))
      fi
    done
    undo_group_end
    [[ "$failed" -gt 0 ]] && warn "$wrote of $n write(s) succeeded, $failed failed."
  else
    warn "Skipped bulk write ($n file(s))."
  fi
}

handle_bulk_folder_create_action() {
  local -n _bfc_paths="$1"
  local n="${#_bfc_paths[@]}" i abs
  local -a abs_list=()

  box_top "BULK CREATE FOLDERS ($n)" "$ICON_FOLDER" "$C_WARN"
  for i in "${!_bfc_paths[@]}"; do
    abs="$(resolve_safe_path "${_bfc_paths[$i]}")"
    if [[ -z "$abs" ]]; then
      box_line "${C_ERR}(skipped, unsafe path): ${_bfc_paths[$i]}${C_RESET}"
      abs_list+=("")
      continue
    fi
    if [[ -e "$abs" && ! -d "$abs" ]]; then
      box_line "${C_ERR}(a file already exists here, not a folder): $abs${C_RESET}"
    elif [[ -d "$abs" ]]; then
      box_line "$abs ${C_DIM}(already exists)${C_RESET}"
    else
      box_line "$abs"
    fi
    abs_list+=("$abs")
  done
  box_bottom "$C_WARN"

  if confirm_action "Create all $n folder(s)?"; then
    undo_group_begin
    for i in "${!_bfc_paths[@]}"; do
      abs="${abs_list[$i]}"
      [[ -z "$abs" ]] && continue
      if [[ -e "$abs" && ! -d "$abs" ]]; then
        err "Skipped, a file already exists: $abs"
        continue
      fi
      if [[ -d "$abs" ]]; then
        ok "Already exists: $abs"
        continue
      fi
      if mkdir -p "$abs"; then
        push_undo "dir" "$abs" "" "create ${abs#"$WORKSPACE_DIR"/}"
        ok "Created $abs"
      else
        err "Failed to create $abs"
      fi
    done
    undo_group_end
  else
    warn "Skipped bulk folder create ($n folder(s))."
  fi
}

# Deletes a batch of files and/or folders in one confirmation. Unlike
# FILE_DELETE/FOLDER_DELETE, the model doesn't have to know in advance
# which entries are files vs folders — each path's type is detected at
# preview time and the right removal (rm -f vs rm -rf) is applied
# automatically, so a batch can freely mix both.
handle_bulk_delete_action() {
  local -n _bd_paths="$1"
  local n="${#_bd_paths[@]}" i abs cnt
  local -a abs_list=() kind_list=()

  box_top "BULK DELETE ($n)" "$ICON_DELETE" "$C_ERR"
  for i in "${!_bd_paths[@]}"; do
    abs="$(resolve_safe_path "${_bd_paths[$i]}")"
    if [[ -z "$abs" ]]; then
      box_line "${C_ERR}(skipped, unsafe path): ${_bd_paths[$i]}${C_RESET}"
      abs_list+=("")
      kind_list+=("")
      continue
    fi
    if [[ "$abs" == "$WORKSPACE_DIR" ]]; then
      box_line "${C_ERR}(refusing to delete the sandbox root): $abs${C_RESET}"
      abs_list+=("")
      kind_list+=("")
      continue
    fi
    if [[ -d "$abs" ]]; then
      cnt="$(find "$abs" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
      box_line "$abs ${C_DIM}(folder, $cnt item(s) inside)${C_RESET}"
      abs_list+=("$abs")
      kind_list+=("folder")
    elif [[ -f "$abs" ]]; then
      box_line "$abs ${C_DIM}(file)${C_RESET}"
      abs_list+=("$abs")
      kind_list+=("file")
    else
      box_line "${C_DIM}(does not exist, will be skipped): $abs${C_RESET}"
      abs_list+=("$abs")
      kind_list+=("")
    fi
  done
  box_bottom "$C_ERR"
  warn "This deletes every item listed above (run 't> undo' to reverse it)."

  if confirm_action "Delete all $n item(s)?"; then
    undo_group_begin
    for i in "${!_bd_paths[@]}"; do
      abs="${abs_list[$i]}"
      [[ -z "$abs" ]] && continue
      case "${kind_list[$i]}" in
        folder)
          snapshot_before_change "$abs" "delete folder ${abs#"$WORKSPACE_DIR"/}"
          rm -rf "$abs" && ok "Deleted $abs" || err "Failed to delete $abs"
          ;;
        file)
          snapshot_before_change "$abs" "delete ${abs#"$WORKSPACE_DIR"/}"
          rm -f "$abs" && ok "Deleted $abs" || err "Failed to delete $abs"
          ;;
        *)
          warn "Nothing to delete, does not exist: $abs"
          ;;
      esac
    done
    undo_group_end
  else
    warn "Skipped bulk delete ($n item(s))."
  fi
}

# Moves/renames a batch of files and/or folders in one confirmation. Each
# item already carries its own from/to/kind (parsed from the ITEM lines in
# process_agent_reply), so this just validates and previews each one before
# applying, same pattern as handle_bulk_delete_action.
handle_bulk_move_action() {
  local -n _bm_from="$1"
  local -n _bm_to="$2"
  local -n _bm_kind="$3"
  local -n _bm_conflict="$4"
  local n="${#_bm_from[@]}" i abs_from abs_to kind conflict
  local -a from_list=() to_list=() overwrite_list=()

  box_top "BULK MOVE ($n)" "$ICON_MOVE" "$C_WARN"
  for i in "${!_bm_from[@]}"; do
    abs_from="$(resolve_safe_path "${_bm_from[$i]}")"
    abs_to="$(resolve_safe_path "${_bm_to[$i]}")"
    kind="${_bm_kind[$i]}"
    conflict="${_bm_conflict[$i]:-skip}"
    if [[ -z "$abs_from" || -z "$abs_to" ]]; then
      box_line "${C_ERR}(skipped, unsafe path): ${_bm_from[$i]} -> ${_bm_to[$i]}${C_RESET}"
      from_list+=(""); to_list+=(""); overwrite_list+=("0")
      continue
    fi
    if [[ "$abs_from" == "$WORKSPACE_DIR" ]]; then
      box_line "${C_ERR}(refusing to move the sandbox root itself): $abs_from${C_RESET}"
      from_list+=(""); to_list+=(""); overwrite_list+=("0")
      continue
    fi
    # Explicit, redundant guard against critical system directories — see
    # the matching comment in handle_move_action.
    if is_dangerous_root "$abs_from" || is_dangerous_root "$abs_to"; then
      box_line "${C_ERR}(refusing critical system directory): $abs_from -> $abs_to${C_RESET}"
      from_list+=(""); to_list+=(""); overwrite_list+=("0")
      continue
    fi
    if [[ ! -e "$abs_from" ]]; then
      box_line "${C_ERR}(source does not exist, will be skipped): $abs_from${C_RESET}"
      from_list+=(""); to_list+=(""); overwrite_list+=("0")
      continue
    fi
    if [[ -d "$abs_from" && "$kind" == "file" ]]; then
      box_line "${C_ERR}(that's a folder, not a file — will be skipped): $abs_from${C_RESET}"
      from_list+=(""); to_list+=(""); overwrite_list+=("0")
      continue
    fi
    if [[ ! -d "$abs_from" && "$kind" == "folder" ]]; then
      box_line "${C_ERR}(that's a file, not a folder — will be skipped): $abs_from${C_RESET}"
      from_list+=(""); to_list+=(""); overwrite_list+=("0")
      continue
    fi
    # Same "move into an existing folder" handling as the single-item
    # handler: an existing-directory destination means drop it inside,
    # not "refuse because something is already there".
    if [[ -d "$abs_to" ]]; then
      abs_to="${abs_to%/}/$(basename "$abs_from")"
    fi
    local this_overwrite=0
    if [[ -e "$abs_to" ]]; then
      case "$conflict" in
        overwrite)
          # Only FLAGGED here, not removed yet — the actual removal (and
          # its undo snapshot) happens at apply time below, so declining
          # the batch leaves the destination untouched.
          this_overwrite=1
          ;;
        rename)
          abs_to="$(find_available_name "$abs_to")"
          ;;
        *)
          box_line "${C_ERR}(destination already exists, will be skipped): $abs_to${C_RESET}"
          from_list+=(""); to_list+=(""); overwrite_list+=("0")
          continue
          ;;
      esac
    fi
    if [[ -d "$abs_from" ]]; then
      case "$abs_to" in
        "$abs_from"|"$abs_from"/*)
          box_line "${C_ERR}(refusing to move a folder into itself or its own subfolder): $abs_to${C_RESET}"
          from_list+=(""); to_list+=(""); overwrite_list+=("0")
          continue
          ;;
      esac
    fi
    [[ "$this_overwrite" -eq 1 ]] && box_line "$abs_from ${C_DIM}->${C_RESET} $abs_to ${C_WARN}(replaces existing)${C_RESET}" || box_line "$abs_from ${C_DIM}->${C_RESET} $abs_to"
    from_list+=("$abs_from"); to_list+=("$abs_to"); overwrite_list+=("$this_overwrite")
  done
  box_bottom "$C_WARN"

  if confirm_action "Apply all $n move(s)?"; then
    local moved=0 failed=0
    undo_group_begin
    for i in "${!from_list[@]}"; do
      abs_from="${from_list[$i]}"
      abs_to="${to_list[$i]}"
      if [[ -z "$abs_from" ]]; then
        failed=$((failed + 1))
        continue
      fi
      mkdir -p "$(dirname "$abs_to")" 2>/dev/null
      if [[ "${overwrite_list[$i]}" == "1" ]]; then
        snapshot_before_change "$abs_to" "overwritten by move ${abs_to#"$WORKSPACE_DIR"/}"
        if [[ -d "$abs_to" && ! -L "$abs_to" ]]; then rm -rf "$abs_to" 2>/dev/null; else rm -f "$abs_to" 2>/dev/null; fi
      fi
      if robust_move "$abs_from" "$abs_to"; then
        record_move_undo "$abs_from" "$abs_to" "move ${abs_to#"$WORKSPACE_DIR"/}"
        ok "Moved $abs_from -> $abs_to"
        moved=$((moved + 1))
      else
        err "Failed to move $abs_from -> $abs_to"
        failed=$((failed + 1))
      fi
    done
    undo_group_end
    [[ "$failed" -gt 0 ]] && warn "$moved of $n move(s) succeeded, $failed failed."
  else
    warn "Skipped bulk move ($n item(s))."
  fi
}

# Caps applied when feeding file/command output back to the model, so a huge
# file or noisy command can't blow up the conversation.
MAX_PREVIEW_BYTES=8000
MAX_PREVIEW_LINES=300
SHELL_TIMEOUT_SECS=60

# Truncates stdin to MAX_PREVIEW_BYTES/MAX_PREVIEW_LINES and notes if it did.
cap_preview() {
  local input="$1" out lines bytes out_bytes
  out="$(printf '%s' "$input" | head -c "$MAX_PREVIEW_BYTES")"
  out="$(printf '%s' "$out" | head -n "$MAX_PREVIEW_LINES")"
  # Real byte counts (not bash's char-count ${#var}) so this matches what
  # head -c actually cut against — otherwise multi-byte UTF-8 content (any
  # non-ASCII file/output) gets a misleading "N bytes" figure.
  bytes="$(printf '%s' "$input" | wc -c | tr -d ' ')"
  out_bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"
  lines="$(printf '%s' "$input" | grep -c '' | tr -d ' ')"
  printf '%s' "$out"
  if (( bytes > out_bytes )); then
    printf '\n[...truncated, %s bytes / %s lines total...]' "$bytes" "$lines"
  fi
}

# Strips ANSI/terminal control sequences (CSI codes, OSC codes, charset
# selectors, and any other lone ESC-prefixed byte) plus bare carriage
# returns from arbitrary text. Used on SHELL_RUN's captured output before
# it's ever printed: that output is captured via command substitution, so
# it does NOT touch the real terminal while it's being captured — but the
# moment we printf/box_line it back out to show the user, any raw escape
# codes inside it become live again. Without this, a command as simple as
# `clear` (or anything emitting cursor/screen control codes) would act on
# our actual terminal at print time and wipe the visible session, instead
# of just being inert text describing what the command printed. Applied
# before display AND before the text is handed back to the model, so the
# model isn't fed binary control noise either.
strip_ansi_escapes() {
  local esc=$'\033'
  printf '%s' "$1" | sed -E "
    s/${esc}\[[0-9;?]*[a-zA-Z]//g
    s/${esc}\][^${esc}]*(${esc}\\\\)?//g
    s/${esc}[()][A-Za-z0-9]//g
    s/${esc}.//g
  " | tr -d '\r'
}

# FILE_READ — read-only, no confirmation. Appends result to AGENT_TOOL_OUTPUT
# (a global the caller resets each turn) and shows a short preview to the user.
handle_file_read_action() {
  local rel="$1" abs encoding preview
  abs="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe read proposal: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[FILE_READ $rel]: rejected, path escapes the sandbox."
    return
  }

  box_top "FILE READ" "$ICON_READ" "$C_ACCENT2"
  box_line "$abs"

  if [[ ! -e "$abs" ]]; then
    box_bottom "$C_ACCENT2"
    warn "File does not exist: $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[FILE_READ $rel]: does not exist."
    return
  fi
  if [[ -d "$abs" ]]; then
    box_bottom "$C_ACCENT2"
    warn "That's a folder, not a file: $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[FILE_READ $rel]: that path is a folder — use DIR_LIST instead."
    return
  fi

  if [[ "$HAVE_FILE" -eq 1 ]]; then
    encoding="$(file -b --mime-encoding "$abs" 2>/dev/null || echo "unknown")"
    if [[ "$encoding" == "binary" ]]; then
      box_bottom "$C_ACCENT2"
      warn "Binary file, skipping content preview."
      AGENT_TOOL_OUTPUT+=$'\n\n'"[FILE_READ $rel]: binary file, content not shown ($(wc -c < "$abs" | tr -d ' ') bytes)."
      return
    fi
  fi

  preview="$(cap_preview "$(nl -ba -w1 -s': ' "$abs" 2>/dev/null)")"
  printf '%s\n' "$preview" | sed -n '1,20p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ACCENT2"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[FILE_READ $rel]:"$'\n'"$preview"
}

# DIR_LIST — read-only, no confirmation.
handle_dir_list_action() {
  local rel="$1" abs listing
  abs="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe dir listing proposal: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[DIR_LIST $rel]: rejected, path escapes the sandbox."
    return
  }

  box_top "DIR LIST" "$ICON_DIR" "$C_ACCENT2"
  box_line "$abs"

  if [[ ! -d "$abs" ]]; then
    box_bottom "$C_ACCENT2"
    warn "Not a folder: $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[DIR_LIST $rel]: not a folder."
    return
  fi

  listing="$(ls -la "$abs" 2>&1)"
  listing="$(cap_preview "$listing")"
  printf '%s\n' "$listing" | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ACCENT2"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[DIR_LIST $rel]:"$'\n'"$listing"
}

# ZIP_LIST — read-only, no confirmation.
handle_zip_list_action() {
  local rel="$1" abs listing
  if [[ "$HAVE_UNZIP" -ne 1 ]]; then
    warn "ZIP_LIST requested but 'unzip' isn't installed."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_LIST $rel]: 'unzip' is not installed on this system."
    return
  fi

  abs="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe zip listing proposal: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_LIST $rel]: rejected, path escapes the sandbox."
    return
  }

  box_top "ZIP LIST" "$ICON_ZIP" "$C_ACCENT2"
  box_line "$abs"

  if [[ ! -f "$abs" ]]; then
    box_bottom "$C_ACCENT2"
    warn "Not a file: $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_LIST $rel]: file does not exist."
    return
  fi

  listing="$(unzip -l "$abs" 2>&1)"
  listing="$(cap_preview "$listing")"
  printf '%s\n' "$listing" | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ACCENT2"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_LIST $rel]:"$'\n'"$listing"
}

# ZIP_READ — read-only, no confirmation. Extracts one entry to stdout only,
# never writes anything to disk.
handle_zip_read_action() {
  local rel="$1" entry="$2" abs content
  if [[ "$HAVE_UNZIP" -ne 1 ]]; then
    warn "ZIP_READ requested but 'unzip' isn't installed."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_READ $rel :: $entry]: 'unzip' is not installed on this system."
    return
  fi

  abs="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe zip read proposal: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_READ $rel :: $entry]: rejected, path escapes the sandbox."
    return
  }

  case "$entry" in
    /*|*..*)
      warn "Rejected zip entry path: $entry"
      AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_READ $rel :: $entry]: rejected entry path."
      return
      ;;
  esac

  box_top "ZIP READ" "$ICON_ZIP" "$C_ACCENT2"
  box_line "$abs ${C_DIM}::${C_RESET} $entry"

  if [[ ! -f "$abs" ]]; then
    box_bottom "$C_ACCENT2"
    warn "Archive does not exist: $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_READ $rel :: $entry]: archive does not exist."
    return
  fi

  content="$(unzip -p "$abs" "$entry" 2>&1)"
  if [[ $? -ne 0 ]]; then
    box_bottom "$C_ACCENT2"
    warn "Could not extract entry (check the exact path with ZIP_LIST first)."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_READ $rel :: $entry]: extraction failed:"$'\n'"$(cap_preview "$content")"
    return
  fi

  content="$(cap_preview "$content")"
  printf '%s\n' "$content" | sed -n '1,20p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ACCENT2"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_READ $rel :: $entry]:"$'\n'"$content"
}

# ZIP_CREATE — requires confirmation. Zips one or more existing sandboxed
# files/folders (one relative source path per line in the body) into a new
# archive. Creating/overwriting the archive is undo-tracked like FILE_WRITE.
handle_zip_create_action() {
  local rel="$1" sources_file="$2" abs parent_dir src abs_src rel_norm
  local -a good_sources=()

  if [[ "$HAVE_ZIP" -ne 1 ]]; then
    warn "ZIP_CREATE requested but 'zip' isn't installed."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_CREATE $rel]: 'zip' is not installed on this system."
    return
  fi

  abs="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe zip create proposal: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_CREATE $rel]: rejected, path escapes the sandbox."
    return
  }

  box_top "ZIP CREATE" "$ICON_ZIP" "$C_WARN"
  box_line "archive: $abs"
  [[ -e "$abs" ]] && box_line "${C_WARN}this overwrites an existing file${C_RESET}"
  while IFS= read -r src; do
    [[ -z "$src" ]] && continue
    abs_src="$(resolve_safe_path "$src")"
    if [[ -z "$abs_src" || ! -e "$abs_src" ]]; then
      box_line "${C_ERR}(skipped, missing or unsafe): $src${C_RESET}"
      continue
    fi
    box_line "+ $src"
    good_sources+=("$src")
  done < "$sources_file"
  box_bottom "$C_WARN"

  if [[ "${#good_sources[@]}" -eq 0 ]]; then
    warn "No valid source paths, nothing to zip."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_CREATE $rel]: no valid source paths given."
    return
  fi

  if ! confirm_action "Create this archive?"; then
    warn "Skipped zip create: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_CREATE $rel]: user declined."
    return
  fi

  parent_dir="$(dirname "$abs")"
  mkdir -p "$parent_dir" 2>/dev/null
  undo_group_begin
  snapshot_before_change "$abs" "zip create ${abs#"$WORKSPACE_DIR"/}"
  undo_group_end

  local zip_out
  zip_out="$(cd "$WORKSPACE_DIR" && zip -r -y "$abs" "${good_sources[@]}" 2>&1)"
  if [[ $? -eq 0 ]]; then
    ok "Created $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_CREATE $rel]: archive created from ${#good_sources[@]} source(s)."
  else
    err "Failed to create archive: $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_CREATE $rel]: failed:"$'\n'"$(cap_preview "$zip_out")"
  fi
}

# ZIP_EXTRACT — requires confirmation. Extracts every entry of a sandboxed
# archive into a sandboxed destination folder. conflict="overwrite" replaces
# existing files (each one snapshotted first so it can be undone);
# conflict="skip" (default) leaves any existing file untouched and only
# extracts entries that don't already exist there.
handle_zip_extract_action() {
  local rel="$1" to_rel="$2" conflict="${3:-skip}" abs_zip abs_dest entry target new_count=0 skip_count=0

  if [[ "$HAVE_UNZIP" -ne 1 ]]; then
    warn "ZIP_EXTRACT requested but 'unzip' isn't installed."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: 'unzip' is not installed on this system."
    return
  fi

  abs_zip="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe zip extract proposal: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: rejected, path escapes the sandbox."
    return
  }
  abs_dest="$(resolve_safe_path "$to_rel")" || {
    warn "Skipped unsafe zip extract destination: $to_rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: rejected destination, escapes the sandbox."
    return
  }

  if [[ ! -f "$abs_zip" ]]; then
    warn "Archive does not exist: $abs_zip"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: archive does not exist."
    return
  fi

  local -a entries=()
  mapfile -t entries < <(unzip -Z1 "$abs_zip" 2>/dev/null)
  if [[ "${#entries[@]}" -eq 0 ]]; then
    warn "Archive is empty or unreadable: $abs_zip"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: archive is empty or unreadable."
    return
  fi

  box_top "ZIP EXTRACT" "$ICON_ZIP" "$C_WARN"
  box_line "archive: $abs_zip"
  box_line "into:    $abs_dest ${C_DIM}(conflict=$conflict)${C_RESET}"
  box_line "${C_DIM}${#entries[@]} entr$([[ ${#entries[@]} -eq 1 ]] && printf y || printf ies) in archive${C_RESET}"
  box_bottom "$C_WARN"

  if ! confirm_action "Extract this archive?"; then
    warn "Skipped zip extract: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: user declined."
    return
  fi

  mkdir -p "$abs_dest" 2>/dev/null
  undo_group_begin
  for entry in "${entries[@]}"; do
    [[ "$entry" == */ || -z "$entry" ]] && continue   # skip directory entries
    case "$entry" in
      /*|*..*)
        warn "Skipped unsafe entry path in archive: $entry"
        continue
        ;;
    esac
    target="$(resolve_safe_path "$to_rel/$entry")" || { warn "Skipped unsafe entry path: $entry"; continue; }
    if [[ -e "$target" ]]; then
      if [[ "$conflict" == "overwrite" ]]; then
        snapshot_before_change "$target" "zip extract ${target#"$WORKSPACE_DIR"/}"
      else
        skip_count=$((skip_count + 1))
        continue
      fi
    else
      push_undo "file" "$target" "" "zip extract ${target#"$WORKSPACE_DIR"/}"
    fi
    new_count=$((new_count + 1))
  done

  local unzip_out unzip_exit
  if [[ "$conflict" == "overwrite" ]]; then
    unzip_out="$(unzip -o "$abs_zip" -d "$abs_dest" 2>&1)"
  else
    unzip_out="$(unzip -n "$abs_zip" -d "$abs_dest" 2>&1)"
  fi
  unzip_exit=$?
  undo_group_end

  if [[ "$unzip_exit" -eq 0 || "$unzip_exit" -eq 1 ]]; then
    # unzip exits 1 for benign warnings (e.g. entries skipped by -n), which
    # is expected and not a real failure here.
    ok "Extracted $new_count entr$([[ $new_count -eq 1 ]] && printf y || printf ies) to $abs_dest"
    [[ "$skip_count" -gt 0 ]] && warn "$skip_count entr$([[ $skip_count -eq 1 ]] && printf y || printf ies) already existed and $([[ $skip_count -eq 1 ]] && printf was || printf were) skipped (conflict=skip)."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: extracted $new_count entries, skipped $skip_count existing."
  else
    err "Failed to extract archive: $abs_zip"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[ZIP_EXTRACT $rel -> $to_rel]: failed:"$'\n'"$(cap_preview "$unzip_out")"
  fi
}

# Percent-decodes a URL-encoded string using only bash/printf built-ins (no
# python/perl dependency). "+' is treated as a literal space per the
# application/x-www-form-urlencoded convention DuckDuckGo's redirect links
# use for their uddg= parameter.
url_decode() {
  local encoded="${1//+/ }"
  printf '%b' "${encoded//%/\\x}"
}

# Decodes the handful of HTML entities that actually show up in search
# result markup. Reads from stdin, writes to stdout, so it chains with
# other sed/tr filters in a pipeline.
html_decode() {
  sed -e 's/&amp;/\&/g' \
      -e 's/&quot;/"/g' \
      -e "s/&#x27;/'/g" \
      -e "s/&#39;/'/g" \
      -e 's/&lt;/</g' \
      -e 's/&gt;/>/g'
}

# Dumps the raw HTML a provider returned to a persistent file, so that when
# parsing fails (block markers no longer match — the single most common way
# these scrapers break, since search engines change their markup without
# notice) there's something concrete to inspect instead of just "it didn't
# work". Kept under /tmp rather than WORKSPACE_DIR since it's diagnostic
# output about the search provider, not agent-produced sandbox content.
# Prints the saved path on stdout so callers can fold it into
# WEB_SEARCH_LAST_ERROR; on any failure to write it, prints nothing and the
# caller's error message just won't mention a path.
save_search_debug_html() {
  local provider="$1" content="$2" path
  path="$(mktemp -t "aulthium-search-${provider}-XXXXXX.html" 2>/dev/null)" || return 0
  if printf '%s' "$content" > "$path" 2>/dev/null; then
    printf '%s' "$path"
  fi
}

# Percent-encodes a string for a URL query using only bash/printf builtins
# — no python/perl. Used as a fallback when `jq` isn't installed; jq's
# `@uri` is tried first in each provider wrapper below since it's already
# a dependency of this script, but this keeps web search fully working
# even on a minimal box without it.
url_encode_fallback() {
  local s="$1" out="" c i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      ' ') out+='+' ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Splits flattened, single-line HTML ($1) into one chunk per search result
# on every occurrence of a literal marker string ($2) — e.g. Bing's
# `<li class="b_algo"` or DuckDuckGo's title-anchor prefix. Each result
# ends up isolated in its own array element (global RESULT_BLOCKS), which
# is what makes field extraction below safe: title/URL/snippet for a given
# result are always pulled from the SAME block, instead of three separate
# whole-page regex passes whose match counts could silently drift out of
# sync the moment a provider's markup gains or drops an element anywhere
# on the page — a real correctness risk in a flat parallel-array design,
# and the main thing this rewrite fixes.
#
# $3 (optional): require_substring — if given, a block is only kept when
# it also contains this literal substring. Used to reject false-positive
# blocks that share the split marker but aren't actually a search result
# (e.g. DuckDuckGo's marker alone would also catch "next page" links).
split_into_blocks() {
  local flat="$1" marker="$2" require_substring="${3:-}"
  local escaped marked sep=$'\x01'
  local -a raw=()
  RESULT_BLOCKS=()

  # Escape BRE/sed metacharacters so the marker is matched literally
  # regardless of what characters happen to be in it.
  escaped="$(printf '%s' "$marker" | sed -e 's/[][\\/.*^$]/\\&/g')"
  marked="$(printf '%s' "$flat" | sed "s/${escaped}/${sep}&/g")"
  IFS="$sep" read -r -a raw <<< "$marked"

  local b
  for b in "${raw[@]}"; do
    [[ "$b" != *"$marker"* ]] && continue
    [[ -n "$require_substring" && "$b" != *"$require_substring"* ]] && continue
    RESULT_BLOCKS+=("$b")
  done
}

# Pulls title/href/snippet out of one already-isolated result block ($1).
# Only ever needs plain POSIX ERE (grep -oE) + sed — no PCRE lookahead or
# lazy-match required, because block isolation already scopes every regex
# to a single result. This is why the old dual PCRE-vs-ERE code path is
# gone: both cases now run through this exact same logic, so whether this
# system's grep has -P support no longer affects parsing correctness at
# all (HAVE_GREP_PCRE is still detected in check_deps and still surfaces
# in the diagnostic message if a page fails to parse — see below — it's
# just no longer load-bearing for the parser itself).
#
# Sets: EXTRACT_TITLE, EXTRACT_URL, EXTRACT_SNIPPET
#
# Optional global SCRAPE_TITLE_ANCHOR_AFTER: if set and present in the
# block, only the portion of the block AFTER that literal marker is
# searched for the title anchor. Needed for providers whose result markup
# has an earlier, non-title <a href="..."> before the real title link —
# e.g. SearXNG's Simple theme puts a breadcrumb/url_wrapper link ahead of
# the <h3><a>Title</a></h3> title link in the same <article> block, so
# grabbing the first anchor in the block would silently return the
# breadcrumb instead of the title. Each provider wrapper sets/clears this
# before calling in; empty (the default) preserves old first-anchor
# behavior for providers without that structure (e.g. DDG Lite).
extract_result_from_block() {
  local block="$1" unwrap_ddg="$2" snippet_class="$3"
  local href="" title="" snippet="" anchor_start title_chunk after cut
  local search_block="$block"

  if [[ -n "${SCRAPE_TITLE_ANCHOR_AFTER:-}" && "$block" == *"$SCRAPE_TITLE_ANCHOR_AFTER"* ]]; then
    search_block="${block#*"$SCRAPE_TITLE_ANCHOR_AFTER"}"
  fi

  # Title + URL: the first <a ...href="...">, then everything up to that
  # tag's matching </a>. Matched greedily to the end of the block (POSIX
  # ERE has no lazy quantifier) and then trimmed back to the first </a>
  # with a bash suffix-strip — that two-step is what lets this handle a
  # title wrapped in a nested tag (e.g. <a...><h3>Title</h3></a>) instead
  # of assuming plain text right after the anchor's '>', which silently
  # produced an empty title whenever a provider nests one.
  anchor_start="$(printf '%s' "$search_block" | grep -oE '<a[^>]*href="[^"]*"[^>]*>.*' | head -n1)"
  [[ "$anchor_start" =~ href=\"([^\"]*)\" ]] && href="${BASH_REMATCH[1]}"
  title_chunk="${anchor_start%%</a>*}"
  title="$(printf '%s' "$title_chunk" | sed -e 's/<[^>]*>//g' | html_decode)"

  if [[ "$unwrap_ddg" == "1" && "$href" == *"uddg="* ]]; then
    href="${href#*uddg=}"
    href="${href%%&*}"
    href="$(url_decode "$href")"
  fi

  # Snippet: jump past the snippet-class marker (only if the caller gave
  # one and it's actually present in this block), then cut at the first
  # closing tag of a handful of common container elements — td/p/div/li/
  # span — before stripping remaining tags and collapsing whitespace.
  # That boundary is deliberately loose (any of five tag names, not one
  # exact tag) so a provider swapping e.g. <p> for <div> around the
  # snippet doesn't break it, while still stopping the capture from
  # bleeding into whatever sibling element follows in the same block
  # (a real bug without any boundary at all — a DDG snippet's <td> is
  # immediately followed by the domain-text row in the same block).
  if [[ -n "$snippet_class" && "$block" == *"$snippet_class"* ]]; then
    after="${block#*$snippet_class}"
    after="${after#*>}"
    cut="$(printf '%s' "$after" | grep -oE '</(td|p|div|li|span)>' | head -n1)"
    [[ -n "$cut" ]] && after="${after%%$cut*}"
    snippet="$(printf '%s' "$after" | sed -e 's/<[^>]*>//g' | html_decode)"
    snippet="$(printf '%s' "$snippet" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    snippet="${snippet:0:300}"
  fi

  EXTRACT_TITLE="$title"
  EXTRACT_URL="$href"
  EXTRACT_SNIPPET="$snippet"
}

# Turns parallel title/url/snippet arrays (passed by NAME, e.g.
# `format_search_results titles urls snippets`) into the final, ready-to-
# read block every web search provider ultimately returns to the model:
#
#   SEARCH RESULTS
#
#   [1]
#   Title: ...
#   URL: ...
#   Snippet: ...
#
#   [2]
#   ...
#
# Along the way it: re-normalizes whitespace defensively (belt-and-braces
# — extract_result_from_block already does this, but a provider's markup
# can still leave odd runs behind), drops any entry with neither a title
# nor a URL, and de-duplicates on URL (falling back to title when a result
# has no URL) case-insensitively, keeping the first — i.e. highest-ranked
# — occurrence and preserving original order otherwise. On success, sets
# FORMAT_SEARCH_RESULT (global) to the formatted text and returns 0. On
# failure (every entry was empty/duplicate), sets WEB_SEARCH_LAST_ERROR
# and returns 1 — and does NOT print anything.
#
# Deliberately does NOT print its result on stdout for the caller to
# capture via $(...): command substitution runs the function in a
# subshell, and any WEB_SEARCH_LAST_ERROR assignment made inside a
# subshell is invisible to the parent shell once it exits — which would
# silently swallow the exact error message this function exists to
# produce. Call this directly (`if format_search_results a b c; then`),
# never as `x="$(format_search_results a b c)"`.
format_search_results() {
  local -n _fsr_titles="$1" _fsr_urls="$2" _fsr_snippets="$3"
  local -A seen=()
  local out="SEARCH RESULTS"$'\n' i title url snippet key idx=0
  FORMAT_SEARCH_RESULT=""

  for i in "${!_fsr_titles[@]}"; do
    title="$(printf '%s' "${_fsr_titles[$i]:-}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    url="$(printf '%s' "${_fsr_urls[$i]:-}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    snippet="$(printf '%s' "${_fsr_snippets[$i]:-}" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    [[ "$url" == "N/A" ]] && url=""
    [[ "$title" == "N/A" ]] && title=""
    [[ "$snippet" == "N/A" ]] && snippet=""

    # Nothing usable to show for this entry at all — skip rather than
    # emitting a blank numbered block.
    [[ -z "$title" && -z "$url" ]] && continue

    key="${url:-$title}"
    key="${key,,}"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1

    idx=$((idx + 1))
    out+=$'\n'"[$idx]"$'\n'
    out+="Title: ${title:-N/A}"$'\n'
    out+="URL: ${url:-N/A}"$'\n'
    out+="Snippet: ${snippet:-N/A}"$'\n'
  done

  if [[ "$idx" -eq 0 ]]; then
    WEB_SEARCH_LAST_ERROR="page fetched fine and results were parsed, but every entry was empty (no title/URL) or a duplicate — nothing usable remained after filtering."
    return 1
  fi
  FORMAT_SEARCH_RESULT="$out"
  return 0
}

# The 3 SearXNG providers go through the shared web_search_scrape_generic
# (see below), which emits the plain "Title: ...\nURL: ...\nSnippet:
# ...\n---\n" block shape. This re-parses that into arrays and hands them to
# format_search_results, so every provider ends up returning the exact same
# final "SEARCH RESULTS" shape to the caller.
reformat_legacy_blocks() {
  local raw="$1" line title="" url="" snippet=""
  local -a titles=() urls=() snippets=()

  while IFS= read -r line; do
    case "$line" in
      "Title: "*) title="${line#Title: }" ;;
      "URL: "*) url="${line#URL: }" ;;
      "Snippet: "*) snippet="${line#Snippet: }" ;;
      "---")
        titles+=("$title"); urls+=("$url"); snippets+=("$snippet")
        title=""; url=""; snippet=""
        ;;
    esac
  done <<< "$raw"

  format_search_results titles urls snippets
}

# Generic HTML-scrape web search backend, parameterized per provider so
# DuckDuckGo, Bing, and Startpage can all reuse the same fetch/split/
# extract/decode logic (see the three thin wrappers below). Used whenever
# the LangChain backend isn't available, or a given provider is
# unreachable — see web_search_query for the fallback chain. This never
# talks to OpenRouter/Google at all — it's a plain curl + local HTML
# parse, so it costs nothing either way. Sets WEB_SEARCH_LAST_ERROR to a
# short reason on failure so the caller can tell the user something more
# useful than "it didn't work".
#
# Args:
#   $1  provider_label      — short name for error messages (e.g. "bing.com")
#   $2  url                 — full request URL, query already percent-encoded
#   $3  block_marker        — literal substring marking the start of each
#                             result in the page's HTML (e.g. Bing's
#                             `<li class="b_algo"`, or an `<a ...>` prefix
#                             that's unique to result-title links). See
#                             split_into_blocks.
#   $4  require_substring   — literal substring a block must also contain
#                             to count as a real result (rejects false
#                             positives sharing the same marker); "" to
#                             skip this check.
#   $5  snippet_class       — literal class-name substring used to find the
#                             snippet text inside a block; "" to skip
#                             snippet extraction entirely.
#   $6  unwrap_ddg_redirect — "1" if hrefs are wrapped DuckDuckGo-style as
#                             //duckduckgo.com/l/?uddg=<encoded real URL>
#                             and need unwrapping; empty/omitted otherwise.
#   $7  post_data           — optional. If given (even as ""), the request
#                             is sent as POST with this as the URL-encoded
#                             body (e.g. "q=search+terms") instead of GET.
#                             Omit this arg entirely to keep GET behavior.
WEB_SEARCH_MAX_RESULTS=5
WEB_SEARCH_LAST_ERROR=""
web_search_scrape_generic() {
  local provider_label="$1" url="$2" block_marker="$3" require_substring="$4"
  local snippet_class="$5" unwrap_ddg_redirect="${6:-}"
  local have_post_data=$(( $# >= 7 ? 1 : 0 ))
  local post_data="${7:-}"
  local html_tmp curl_args=() flat out i n http_code
  local -a titles=() urls=() snippets=()
  WEB_SEARCH_LAST_ERROR=""

  html_tmp="$(mktemp)"
  # Modern, realistic browser headers — a bare curl UA/Accept set gets a
  # flat 403 or a JS challenge page from several search front-ends now
  # (DuckDuckGo's html.duckduckgo.com in particular). These mimic a current
  # desktop Chrome/Windows request closely enough to pass basic bot checks
  # without needing a real browser/JS engine.
  # --connect-timeout bounds the connection phase (DNS + TCP/TLS handshake)
  # separately from --max-time, which bounds the whole request including
  # the response body — so a provider that's up but slow to send data
  # doesn't hang indefinitely, and one that's unreachable fails fast.
  curl_args=(-sSL
             --connect-timeout 8
             --max-time 20
             -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
             -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
             -H "Accept-Language: en-US,en;q=0.9"
             -H "Sec-Fetch-Mode: navigate"
             -H "Sec-Fetch-Site: none"
             -H "Sec-Fetch-User: ?1"
             -H "Sec-Fetch-Dest: document"
             -H "Upgrade-Insecure-Requests: 1")

  if [[ "$have_post_data" -eq 1 ]]; then
    curl_args+=(-X POST
                -H "Content-Type: application/x-www-form-urlencoded"
                -H "Origin: https://$(printf '%s' "$url" | sed -E 's#^https?://##; s#/.*##')"
                --data "$post_data")
  fi
  curl_args+=(-o "$html_tmp" -w '%{http_code}' "$url")

  http_code="$(curl "${curl_args[@]}" 2>/dev/null)"
  if [[ -z "$http_code" ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="couldn't reach $provider_label (network/DNS/timeout error)."
    return 1
  fi

  # Treat the provider as failed on any non-2xx status — explicitly
  # including 403 (blocked), 429 (rate-limited), and 5xx (server error) —
  # rather than trying to parse a blocked/error page as if it were results.
  if [[ "$http_code" != 2* ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="$provider_label returned HTTP $http_code."
    return 1
  fi

  if [[ ! -s "$html_tmp" ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="got an empty response from $provider_label."
    return 1
  fi

  # Flatten to one line so a result's tags are never split across
  # newlines out from under the block splitter — also what makes parsing
  # work identically regardless of HAVE_GREP_PCRE (see
  # extract_result_from_block above).
  flat="$(tr '\n\r' '  ' < "$html_tmp")"
  rm -f "$html_tmp"

  split_into_blocks "$flat" "$block_marker" "$require_substring"

  n="${#RESULT_BLOCKS[@]}"
  for (( i = 0; i < n && i < WEB_SEARCH_MAX_RESULTS; i++ )); do
    extract_result_from_block "${RESULT_BLOCKS[$i]}" "$unwrap_ddg_redirect" "$snippet_class"
    if [[ -n "$EXTRACT_TITLE" ]]; then
      titles+=("$EXTRACT_TITLE")
      urls+=("$EXTRACT_URL")
      snippets+=("$EXTRACT_SNIPPET")
    fi
  done

  if [[ "${#titles[@]}" -eq 0 ]]; then
    local debug_path
    debug_path="$(save_search_debug_html "$provider_label" "$flat")"
    if [[ "${HAVE_GREP_PCRE:-1}" -eq 0 ]]; then
      WEB_SEARCH_LAST_ERROR="page fetched fine, but no results could be parsed out of it — $provider_label's markup may have changed. (This system's grep also lacks PCRE (-P) support, though this parser no longer depends on it.)"
    else
      WEB_SEARCH_LAST_ERROR="page fetched fine, but no results could be parsed out of it — $provider_label's markup may have changed, or the query returned a no-results page."
    fi
    [[ -n "$debug_path" ]] && WEB_SEARCH_LAST_ERROR+=" Raw response saved to: $debug_path"
    return 1
  fi

  # Standardized, provider-agnostic output format — easy for a downstream
  # consumer (or a human) to parse reliably regardless of which provider
  # actually answered. Set on a global rather than printed, so callers can
  # invoke this directly (no $() subshell) and keep any WEB_SEARCH_LAST_ERROR
  # this function sets on failure visible to them — see format_search_results
  # for why that matters.
  out=""
  for i in "${!titles[@]}"; do
    out+="Title: ${titles[$i]}"$'\n'
    out+="URL: ${urls[$i]:-N/A}"$'\n'
    out+="Snippet: ${snippets[$i]:-N/A}"$'\n'
    out+="---"$'\n'
  done
  WEB_SEARCH_SCRAPE_RESULT="$out"
  return 0
}

# --- SearXNG (primary provider, 3 fixed public instances) ----------------
# Exactly these three HTML-scrape SearXNG instances, tried in this fixed
# order. No other instance is ever contacted and none are discovered
# dynamically — this list is the complete, permanent set. Each is queried
# via its plain HTML /search endpoint (never the JSON API, so no API key
# and no special Accept negotiation is needed).
SEARXNG_INSTANCES=(
  "https://searx.tiekoetter.com"
  "https://searxng.website"
  "https://search.ctq.ro"
)

# Queries one SearXNG instance's HTML /search endpoint and normalizes the
# result into this script's shared "SEARCH RESULTS" format. A provider
# counts as failed — triggering the next one in web_search_query below —
# on connection/DNS failure, timeout, any non-2xx HTTP status (403, 429,
# 5xx included), an empty body, or zero parseable results; all of that is
# handled inside web_search_scrape_generic already.
#
# SearXNG's Simple theme (the markup nearly every public instance runs)
# wraps each organic result in <article class="result ...">, with the
# title link inside it and the snippet text in <p class="content">.
web_search_query_searxng() {
  local instance="$1" query="$2" encoded_query rc
  encoded_query="$(jq -rn --arg q "$query" '$q|@uri' 2>/dev/null)"
  [[ -z "$encoded_query" ]] && encoded_query="$(url_encode_fallback "$query")"

  # Each <article class="result ..."> opens with a favicon + breadcrumb
  # "url display" link before the real <h3><a>Title</a></h3> title link —
  # skip past the first "<h3" so extract_result_from_block grabs the
  # title anchor instead of that breadcrumb one.
  SCRAPE_TITLE_ANCHOR_AFTER='<h3'
  web_search_scrape_generic \
    "$instance" \
    "${instance}/search?q=${encoded_query}" \
    '<article' \
    'class="result' \
    "content" \
    ""
  rc=$?
  SCRAPE_TITLE_ANCHOR_AFTER=""
  [[ "$rc" -eq 0 ]] || return 1

  reformat_legacy_blocks "$WEB_SEARCH_SCRAPE_RESULT"
}

# --- DuckDuckGo Lite (fallback provider) ----------------------------------
# KEPT as the fallback behind the three SearXNG instances above — never
# removed, still HTML-scraped (no JSON/API-key backend exists for it
# anyway). What's new here is a shared rate limiter, a large User-Agent
# pool for normal request diversity, and cooldown-on-block handling; the
# actual result markup/parsing is unchanged from before.

# A broad pool of realistic desktop/mobile browser User-Agent strings,
# covering Chrome/Firefox/Safari/Edge/Samsung Internet across
# Windows/Linux/macOS/Android/iOS. Purely for normal header diversity and
# browser compatibility — picked at random per request. This is NOT used
# to bypass CAPTCHAs, rate limits, or any other access control; see
# ddg_response_is_blocked below, which always backs off on a real block
# rather than trying to push through it with a different UA.
DDG_USER_AGENTS=(
  # Chrome / Windows
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
  # Chrome / Linux
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  # Chrome / macOS
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  # Chrome / Android
  "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
  # Firefox / Windows
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"
  # Firefox / Linux
  "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
  # Firefox / macOS
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:128.0) Gecko/20100101 Firefox/128.0"
  # Firefox / Android
  "Mozilla/5.0 (Android 14; Mobile; rv:128.0) Gecko/128.0 Firefox/128.0"
  # Safari / macOS
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
  # Safari / iPhone
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
  # Safari / iPad
  "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
  # Edge / Windows
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0"
  # Edge / macOS
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0"
  # Samsung Internet / Android
  "Mozilla/5.0 (Linux; Android 14; SM-S928B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/122.0.0.0 Mobile Safari/537.36"
)

ddg_random_user_agent() {
  printf '%s' "${DDG_USER_AGENTS[$(( RANDOM % ${#DDG_USER_AGENTS[@]} ))]}"
}

# Rate limiter + cooldown state, shared across (potentially concurrent)
# Aulthium processes via a lock file rather than just in-process
# variables — a plain in-memory variable wouldn't stop two separate
# invocations of this script from both firing at once. Configurable via
# environment variables, per the requested defaults.
DDG_MIN_DELAY="${DDG_MIN_DELAY:-5}"                     # seconds, floor between requests
DDG_RANDOM_EXTRA_DELAY="${DDG_RANDOM_EXTRA_DELAY:-5}"    # seconds, max extra jitter on top
DDG_COOLDOWN_AFTER_BLOCK="${DDG_COOLDOWN_AFTER_BLOCK:-300}" # seconds (5 minutes)
DDG_STATE_FILE="${TMPDIR:-/tmp}/aulthium-agent-ddg-state"
DDG_LOCK_FILE="${TMPDIR:-/tmp}/aulthium-agent-ddg.lock"

# Reads DDG_STATE_FILE ("<last_request_epoch> <cooldown_until_epoch>")
# into DDG_LAST_REQUEST / DDG_COOLDOWN_UNTIL. Missing or corrupt state
# reads as "0 0" so a fresh run never blocks unnecessarily.
_ddg_read_state() {
  local line
  line="$(cat "$DDG_STATE_FILE" 2>/dev/null)"
  DDG_LAST_REQUEST="${line%% *}"
  DDG_COOLDOWN_UNTIL="${line##* }"
  [[ "$DDG_LAST_REQUEST" =~ ^[0-9]+$ ]] || DDG_LAST_REQUEST=0
  [[ "$DDG_COOLDOWN_UNTIL" =~ ^[0-9]+$ ]] || DDG_COOLDOWN_UNTIL=0
}

# True (exit 0) while DDG Lite is inside a post-block cooldown window.
ddg_in_cooldown() {
  local now
  now="$(date +%s)"
  _ddg_read_state
  [[ "$now" -lt "$DDG_COOLDOWN_UNTIL" ]]
}

# Starts (or extends) the cooldown after a detected block. Lock-protected
# so a burst of near-simultaneous blocked responses only ever pushes the
# cooldown further out, never resets it backwards. Falls back to running
# unlocked if flock isn't installed (see check_deps/HAVE_FLOCK) rather
# than failing outright — still correct for the common single-process
# case, just without the cross-process guarantee.
_ddg_set_cooldown_body() {
  local now until
  now="$(date +%s)"
  until=$(( now + DDG_COOLDOWN_AFTER_BLOCK ))
  _ddg_read_state
  [[ "$until" -lt "$DDG_COOLDOWN_UNTIL" ]] && until="$DDG_COOLDOWN_UNTIL"
  printf '%s %s\n' "$DDG_LAST_REQUEST" "$until" > "$DDG_STATE_FILE" 2>/dev/null
}
ddg_set_cooldown() {
  if [[ "${HAVE_FLOCK:-1}" -eq 1 ]]; then
    ( flock -x 200; _ddg_set_cooldown_body ) 200>"$DDG_LOCK_FILE"
  else
    _ddg_set_cooldown_body
  fi
}

# Waits (sleeps) until it's this caller's turn to hit DDG Lite, then
# reserves the slot by recording the new "last request" time — all inside
# one flock critical section, so two processes racing to search at the
# same instant still end up DDG_MIN_DELAY(+jitter) apart rather than both
# firing immediately; queued rather than dropped. Falls back to running
# unlocked if flock isn't installed (HAVE_FLOCK=0), same as
# ddg_set_cooldown above. Returns 1 (no sleep, no slot reserved) if a
# cooldown is currently active — the caller should treat that exactly
# like a provider failure and skip DDG Lite entirely.
_ddg_rate_limit_wait_body() {
  local now last wait_for extra_ms
  now="$(date +%s)"
  _ddg_read_state

  if [[ "$now" -lt "$DDG_COOLDOWN_UNTIL" ]]; then
    return 1
  fi

  last="$DDG_LAST_REQUEST"
  wait_for=$(( last + DDG_MIN_DELAY - now ))
  [[ "$wait_for" -gt 0 ]] && sleep "$wait_for"

  extra_ms=$(( RANDOM % (DDG_RANDOM_EXTRA_DELAY * 1000 + 1) ))
  if [[ "$extra_ms" -gt 0 ]]; then
    sleep "$(printf '%d.%03d' $((extra_ms / 1000)) $((extra_ms % 1000)))" 2>/dev/null \
      || sleep $(( (extra_ms + 999) / 1000 ))
  fi

  printf '%s %s\n' "$(date +%s)" "$DDG_COOLDOWN_UNTIL" > "$DDG_STATE_FILE" 2>/dev/null
}
ddg_rate_limit_wait() {
  if [[ "${HAVE_FLOCK:-1}" -eq 1 ]]; then
    ( flock -x 200; _ddg_rate_limit_wait_body ) 200>"$DDG_LOCK_FILE"
  else
    _ddg_rate_limit_wait_body
  fi
}

# Narrow, deliberately conservative detection of a DDG Lite CAPTCHA /
# bot-check / hard block — specific HTTP status codes plus a couple of
# DDG's own known block-page phrases — so an ordinary no-results page is
# never mistaken for a block. On a match, the caller starts a cooldown and
# stops; nothing here attempts to solve, bypass, or push through it.
ddg_response_is_blocked() {
  local http_code="$1" body="$2"
  case "$http_code" in
    403|429|503) return 0 ;;
  esac
  printf '%s' "$body" | grep -qiE 'unusual traffic|complete the security check|id="anomaly-modal"|g-recaptcha|/sorry/'
}

# lite.duckduckgo.com/lite/ — a plain, server-rendered, no-JS results page.
# Confirmed from a captured debug dump (mid/late-2026): each result is now
# <a rel="nofollow" href="https://real-url..." class='result-link'>Title</a>
# — note the SINGLE quotes around the class value and that class comes
# AFTER href (not `<a class="result-link" ...>` like it used to), and the
# href is a plain, already-unwrapped URL — no more //duckduckgo.com/l/
# ?uddg= redirect wrapping. The snippet is a sibling row's
# <td class='result-snippet'>, also single-quoted. The block marker below
# is a plain substring match so the quote style/attribute order inside
# the tag doesn't matter for splitting, but it still has to be the exact
# substring actually present on the page.
web_search_query_scrape_ddglite() {
  local query="$1" encoded_query html_tmp http_code flat body_snippet
  SCRAPE_TITLE_ANCHOR_AFTER=""

  if ddg_in_cooldown; then
    WEB_SEARCH_LAST_ERROR="lite.duckduckgo.com is in a post-block cooldown (recently rate-limited/CAPTCHA'd) — skipping until it expires."
    return 1
  fi

  if ! ddg_rate_limit_wait; then
    WEB_SEARCH_LAST_ERROR="lite.duckduckgo.com is in a post-block cooldown — skipping until it expires."
    return 1
  fi

  encoded_query="$(jq -rn --arg q "$query" '$q|@uri' 2>/dev/null)"
  [[ -z "$encoded_query" ]] && encoded_query="$(url_encode_fallback "$query")"

  html_tmp="$(mktemp)"
  http_code="$(curl -sSL \
    --connect-timeout 8 --max-time 20 \
    -A "$(ddg_random_user_agent)" \
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
    -H "Accept-Language: en-US,en;q=0.9" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "q=${encoded_query}" \
    -o "$html_tmp" \
    -w '%{http_code}' \
    "https://lite.duckduckgo.com/lite/" \
    2>/dev/null)"

  if [[ -z "$http_code" ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="couldn't reach lite.duckduckgo.com (network/DNS/timeout error)."
    return 1
  fi

  body_snippet="$(head -c 4000 "$html_tmp" 2>/dev/null)"
  if ddg_response_is_blocked "$http_code" "$body_snippet"; then
    rm -f "$html_tmp"
    ddg_set_cooldown
    WEB_SEARCH_LAST_ERROR="lite.duckduckgo.com returned a CAPTCHA/bot-check response (HTTP $http_code) — backing off for $(( DDG_COOLDOWN_AFTER_BLOCK / 60 )) minute(s)."
    return 1
  fi

  if [[ "$http_code" != 2* ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="lite.duckduckgo.com returned HTTP $http_code."
    return 1
  fi

  if [[ ! -s "$html_tmp" ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="got an empty response from lite.duckduckgo.com."
    return 1
  fi

  flat="$(tr '\n\r' '  ' < "$html_tmp")"
  rm -f "$html_tmp"

  # Marker deliberately starts at "<a rel=..." (the literal text right
  # BEFORE the href value) rather than at "class='result-link'" itself —
  # split_into_blocks starts each block AT the marker, so anchoring on
  # text after href would cut the href right off the front of its own
  # block. require_substring="result-link" then rejects any block that
  # happens to share this opening but isn't actually an organic result.
  split_into_blocks "$flat" '<a rel="nofollow" href="' "result-link"

  local n i
  local -a titles=() urls=() snippets=()
  n="${#RESULT_BLOCKS[@]}"
  for (( i = 0; i < n && i < WEB_SEARCH_MAX_RESULTS * 3; i++ )); do
    # unwrap_ddg="1": harmless either way — it only fires if a href
    # actually contains "uddg=", which current DDG Lite hrefs don't, but
    # this keeps parsing working without changes if DDG ever brings the
    # redirect-wrapped form back.
    extract_result_from_block "${RESULT_BLOCKS[$i]}" "1" "result-snippet"
    [[ -n "$EXTRACT_TITLE" || -n "$EXTRACT_URL" ]] || continue
    titles+=("$EXTRACT_TITLE")
    urls+=("$EXTRACT_URL")
    snippets+=("$EXTRACT_SNIPPET")
  done

  if [[ "${#titles[@]}" -eq 0 ]]; then
    local debug_path
    debug_path="$(save_search_debug_html "ddglite" "$flat")"
    WEB_SEARCH_LAST_ERROR="page fetched fine, but no results could be parsed out of it — DuckDuckGo Lite's markup may have changed, or the query returned a no-results page."
    [[ -n "$debug_path" ]] && WEB_SEARCH_LAST_ERROR+=" Raw response saved to: $debug_path"
    return 1
  fi

  format_search_results titles urls snippets
}

# Dispatcher: SearXNG #1 -> #2 -> #3, falling through to DuckDuckGo Lite
# only if all three are unreachable/blocked/unparsable. DDG Lite is
# skipped outright while it's in cooldown (ddg_in_cooldown / the check
# inside web_search_query_scrape_ddglite) rather than being retried. Stops
# at the first provider that returns real results; if every provider
# fails, WEB_SEARCH_LAST_ERROR is set to a combined summary of why.
web_search_query() {
  local query="$1"
  local -a errs=()
  local instance

  for instance in "${SEARXNG_INSTANCES[@]}"; do
    if web_search_query_searxng "$instance" "$query"; then
      return 0
    fi
    errs+=("${WEB_SEARCH_LAST_ERROR:-$instance: failed}")
  done

  if web_search_query_scrape_ddglite "$query"; then
    return 0
  fi
  errs+=("${WEB_SEARCH_LAST_ERROR:-lite.duckduckgo.com: failed}")

  WEB_SEARCH_LAST_ERROR="all search providers failed — $(IFS='; '; echo "${errs[*]}")"
  return 1
}

########################################################################
# MCP (MODEL CONTEXT PROTOCOL) CLIENT
#
# Talks to remote MCP servers over the "Streamable HTTP" JSON-RPC 2.0
# transport (a single POST endpoint; response is either plain JSON or one
# SSE "data:" line carrying the same JSON). No local/stdio servers — every
# server here is a URL, optionally with a bearer key, same shape as the
# built-in OpenAI-compatible providers above.
#
# Lifecycle per server: initialize -> notifications/initialized (best
# effort) -> tools/list, discovering its tools up front so they can be
# folded into the system prompt (see mcp_tools_prompt_block). Tool
# invocations from the model arrive as MCP_CALL blocks, gated behind an
# explicit y/N like SHELL_RUN — unlike WEB_SEARCH/FILE_READ, an MCP tool can
# do anything the server author wired it to do, so it isn't treated as
# read-only by default. Results are fed back into AGENT_TOOL_OUTPUT.
########################################################################

# Prints the array index for a configured server name, or nothing + returns
# 1 if no server by that name exists.
mcp_find_index() {
  local target="$1" i
  for i in "${!MCP_NAMES[@]}"; do
    if [[ "${MCP_NAMES[$i]}" == "$target" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

# name -> MCP_<NAME>_KEY env var name (uppercased, non-alnum collapsed to _),
# used both for MCP_SERVERS bootstrap and to skip the interactive prompt in
# mcp_add_server when the key is already sitting in the environment.
mcp_env_key_for() {
  local name="$1" upper
  upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  printf 'MCP_%s_KEY' "$upper"
}

# Low-level transport: POST a JSON-RPC body to an MCP endpoint, capturing
# both a plain-JSON response and the single-shot SSE shape some servers use
# instead ("Content-Type: text/event-stream" with the payload on the last
# "data:" line). Also captures Mcp-Session-Id if the server hands one back,
# so the caller can pin subsequent calls to the same session.
#
# proto_version, when non-empty, is sent as the MCP-Protocol-Version header.
# Per spec this is REQUIRED on every request after initialize (initialize
# itself is the one call that has no negotiated version yet, so it's the
# only caller allowed to pass ""). Compliant servers respond 400 Bad Request
# to a post-initialize call missing this header, which is exactly the
# failure mode this used to hit against strict/real-world servers even
# though lenient ones let it slide.
#
# max_time (default 25s) is curl's --max-time for this one request. That
# default is fine for initialize/tools/list/notifications, which are cheap
# metadata calls, but real tool invocations against remote services (a
# screenshot, a semantic-search query, code-mode execution against a live
# API) can legitimately take much longer — callers doing tools/call should
# pass a longer max_time explicitly rather than let this silently truncate
# an in-flight call and misreport it as "HTTP 000 contacting server".
MCP_HTTP_BODY=""
MCP_HTTP_CODE=""
MCP_HTTP_SESSION=""
mcp_http_post() {
  local url="$1" key="$2" session="$3" proto_version="$4" json_body="$5" max_time="${6:-25}"
  local headers_tmp body_tmp curl_args=() ctype
  headers_tmp="$(mktemp)"
  body_tmp="$(mktemp)"
  MCP_HTTP_BODY=""; MCP_HTTP_CODE=""; MCP_HTTP_SESSION=""

  curl_args=(-sS
             --connect-timeout 8
             --max-time "$max_time"
             -D "$headers_tmp"
             -o "$body_tmp"
             -w '%{http_code}'
             -X POST "$url"
             -H "Content-Type: application/json"
             -H "Accept: application/json, text/event-stream")
  [[ -n "$key" ]] && curl_args+=(-H "Authorization: Bearer $key")
  [[ -n "$session" ]] && curl_args+=(-H "Mcp-Session-Id: $session")
  [[ -n "$proto_version" ]] && curl_args+=(-H "MCP-Protocol-Version: $proto_version")
  curl_args+=(--data-binary "$json_body")

  MCP_HTTP_CODE="$(curl "${curl_args[@]}" 2>/dev/null)"
  if [[ -z "$MCP_HTTP_CODE" ]]; then
    rm -f "$headers_tmp" "$body_tmp"
    MCP_HTTP_CODE="000"
    return 1
  fi

  MCP_HTTP_SESSION="$(grep -i '^Mcp-Session-Id:' "$headers_tmp" 2>/dev/null | tail -n1 | cut -d: -f2- | tr -d '\r' | sed -E 's/^[[:space:]]+//')"
  ctype="$(grep -i '^Content-Type:' "$headers_tmp" 2>/dev/null | tail -n1 | tr -d '\r')"

  if [[ "$ctype" == *text/event-stream* ]]; then
    MCP_HTTP_BODY="$(grep '^data:' "$body_tmp" 2>/dev/null | tail -n1 | sed -E 's/^data:[[:space:]]*//')"
  else
    MCP_HTTP_BODY="$(cat "$body_tmp" 2>/dev/null)"
  fi

  rm -f "$headers_tmp" "$body_tmp"
  [[ "$MCP_HTTP_CODE" == 2* ]]
}

# One JSON-RPC 2.0 round trip. Pass is_notification=1 for fire-and-forget
# calls (no id, no response expected/parsed). Sets MCP_RPC_RESULT (the
# .result, as compact JSON) or MCP_RPC_ERROR (human-readable) and returns
# 0/1 accordingly.
MCP_RPC_RESULT=""
MCP_RPC_ERROR=""
mcp_rpc() {
  local url="$1" key="$2" session="$3" proto_version="$4" method="$5" params_json="$6" is_notification="${7:-0}" max_time="${8:-25}"
  local req_id body err_msg
  MCP_RPC_RESULT=""; MCP_RPC_ERROR=""

  if [[ "$is_notification" -eq 1 ]]; then
    body="$(jq -nc --arg m "$method" --argjson p "$params_json" '{jsonrpc:"2.0", method:$m, params:$p}')"
  else
    req_id="$MCP_RPC_NEXT_ID"
    MCP_RPC_NEXT_ID=$((MCP_RPC_NEXT_ID + 1))
    body="$(jq -nc --arg m "$method" --argjson p "$params_json" --argjson id "$req_id" '{jsonrpc:"2.0", id:$id, method:$m, params:$p}')"
  fi

  if ! mcp_http_post "$url" "$key" "$session" "$proto_version" "$body" "$max_time"; then
    MCP_RPC_ERROR="HTTP ${MCP_HTTP_CODE:-error} contacting server (after waiting up to ${max_time}s)."
    return 1
  fi

  [[ "$is_notification" -eq 1 ]] && return 0

  if [[ -z "$MCP_HTTP_BODY" ]]; then
    MCP_RPC_ERROR="empty response from server."
    return 1
  fi
  if ! jq -e . >/dev/null 2>&1 <<< "$MCP_HTTP_BODY"; then
    MCP_RPC_ERROR="server did not return valid JSON."
    return 1
  fi

  err_msg="$(jq -r '.error.message // empty' <<< "$MCP_HTTP_BODY" 2>/dev/null)"
  if [[ -n "$err_msg" ]]; then
    MCP_RPC_ERROR="$err_msg"
    return 1
  fi

  MCP_RPC_RESULT="$(jq -c '.result // {}' <<< "$MCP_HTTP_BODY" 2>/dev/null)"
  return 0
}

# Full connect sequence for server index $1: initialize, (best-effort)
# notifications/initialized, tools/list. Updates MCP_SESSION_IDS and
# MCP_TOOLS_JSON for that index in place. Prints a status box either way.
mcp_connect_server() {
  local idx="$1" name url key params tools count negotiated
  name="${MCP_NAMES[$idx]}"
  url="${MCP_URLS[$idx]}"
  key="${MCP_KEYS[$idx]}"

  box_top "MCP CONNECT" "$ICON_MCP" "$C_ACCENT2"
  box_line "$name -> $url"

  # initialize has no negotiated version yet, so it's the one call that goes
  # out without an MCP-Protocol-Version header (mcp_rpc's 4th arg is "").
  params="$(jq -nc --arg v "$APP_VERSION" '{protocolVersion:"2025-06-18", capabilities:{}, clientInfo:{name:"aulthium", version:$v}}')"
  if ! mcp_rpc "$url" "$key" "" "" "initialize" "$params" 0; then
    box_bottom "$C_ERR"
    warn "MCP server \"$name\" failed to initialize: ${MCP_RPC_ERROR:-unknown error}"
    return 1
  fi
  MCP_SESSION_IDS[$idx]="$MCP_HTTP_SESSION"

  # The server may downgrade us to a version it actually supports — the spec
  # requires every request from here on to echo back whatever it settled on,
  # not the version we originally asked for.
  negotiated="$(jq -r '.protocolVersion // empty' <<< "$MCP_RPC_RESULT" 2>/dev/null)"
  [[ -z "$negotiated" ]] && negotiated="2025-06-18"
  MCP_PROTO_VERSIONS[$idx]="$negotiated"

  mcp_rpc "$url" "$key" "${MCP_SESSION_IDS[$idx]}" "$negotiated" "notifications/initialized" "{}" 1 >/dev/null 2>&1

  if ! mcp_rpc "$url" "$key" "${MCP_SESSION_IDS[$idx]}" "$negotiated" "tools/list" "{}" 0; then
    box_bottom "$C_ERR"
    warn "MCP server \"$name\" connected but tools/list failed: ${MCP_RPC_ERROR:-unknown error}"
    MCP_TOOLS_JSON[$idx]="[]"
    return 1
  fi

  tools="$(jq -c '.tools // []' <<< "$MCP_RPC_RESULT" 2>/dev/null)"
  [[ -z "$tools" || "$tools" == "null" ]] && tools="[]"
  MCP_TOOLS_JSON[$idx]="$tools"
  count="$(jq 'length' <<< "$tools")"

  box_line "$count tool(s) discovered"
  box_bottom "$C_OK"
  ok "MCP server \"$name\" connected ($count tool(s))."
  return 0
}

# Pushes a new server into the parallel arrays and connects it — the shared
# tail end of every "add a server" path (manual t> mcp add, MCP_SERVERS
# bootstrap, the Cloudflare quick-pick below), so they can't drift out of
# sync with each other. Returns mcp_connect_server's status.
mcp_register_server() {
  local name="$1" url="$2" key="$3" idx
  idx="${#MCP_NAMES[@]}"
  MCP_NAMES[$idx]="$name"
  MCP_URLS[$idx]="$url"
  MCP_KEYS[$idx]="$key"
  MCP_SESSION_IDS[$idx]=""
  MCP_PROTO_VERSIONS[$idx]=""
  MCP_TOOLS_JSON[$idx]="[]"
  mcp_connect_server "$idx"
}

# 't> mcp add <name> <url>' — validates the name, prompts for an API key
# (skipped if MCP_<NAME>_KEY is already set), connects immediately, and
# resets the conversation so the new tools are visible in the system prompt.
mcp_add_server() {
  local name="$1" url="$2" key_var key entered
  if [[ -z "$name" || -z "$url" ]]; then
    warn "Usage: t> mcp add <name> <url>"
    return 1
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9_-]+$ ]]; then
    warn "Server name must be alphanumeric (- and _ allowed), no spaces: $name"
    return 1
  fi
  if mcp_find_index "$name" >/dev/null; then
    warn "A server named \"$name\" is already configured — 't> mcp remove $name' first to replace it."
    return 1
  fi

  key_var="$(mcp_env_key_for "$name")"
  key="${!key_var:-}"
  if [[ -z "$key" ]]; then
    read -r -s -p "API key for \"$name\" (leave blank if none): " entered
    echo
    key="$entered"
  fi

  if mcp_register_server "$name" "$url" "$key"; then
    init_history
    say "Conversation reset so the agent can see the new MCP tools."
  fi
}

mcp_remove_server() {
  local name="$1" idx
  idx="$(mcp_find_index "$name")" || { warn "No MCP server named \"$name\" configured."; return 1; }

  MCP_NAMES=("${MCP_NAMES[@]:0:$idx}" "${MCP_NAMES[@]:$((idx+1))}")
  MCP_URLS=("${MCP_URLS[@]:0:$idx}" "${MCP_URLS[@]:$((idx+1))}")
  MCP_KEYS=("${MCP_KEYS[@]:0:$idx}" "${MCP_KEYS[@]:$((idx+1))}")
  MCP_SESSION_IDS=("${MCP_SESSION_IDS[@]:0:$idx}" "${MCP_SESSION_IDS[@]:$((idx+1))}")
  MCP_PROTO_VERSIONS=("${MCP_PROTO_VERSIONS[@]:0:$idx}" "${MCP_PROTO_VERSIONS[@]:$((idx+1))}")
  MCP_TOOLS_JSON=("${MCP_TOOLS_JSON[@]:0:$idx}" "${MCP_TOOLS_JSON[@]:$((idx+1))}")

  ok "Removed MCP server \"$name\"."
  init_history
  say "Conversation reset so the agent no longer sees its tools."
}

mcp_refresh_server() {
  local name="$1" idx
  idx="$(mcp_find_index "$name")" || { warn "No MCP server named \"$name\" configured."; return 1; }
  mcp_connect_server "$idx"
  init_history
  say "Conversation reset so the agent sees the refreshed tool list."
}

mcp_refresh_all() {
  local i
  if [[ "${#MCP_NAMES[@]}" -eq 0 ]]; then
    muted "No MCP servers configured yet — t> mcp add <name> <url>"
    return 0
  fi
  for i in "${!MCP_NAMES[@]}"; do
    mcp_connect_server "$i"
  done
  init_history
  say "Conversation reset so the agent sees the refreshed tool list."
}

mcp_list_servers() {
  local i name url count
  if [[ "${#MCP_NAMES[@]}" -eq 0 ]]; then
    muted "No MCP servers configured. Add one with: t> mcp add <name> <url>"
    return 0
  fi
  box_top "MCP SERVERS" "$ICON_MCP" "$C_ACCENT2"
  for i in "${!MCP_NAMES[@]}"; do
    name="${MCP_NAMES[$i]}"
    url="${MCP_URLS[$i]}"
    count="$(jq 'length' <<< "${MCP_TOOLS_JSON[$i]:-[]}" 2>/dev/null || echo 0)"
    box_line "${C_BOLD}$name${C_RESET} -> $url ${C_MUTED}($count tool(s))${C_RESET}"
    if [[ "$count" -gt 0 ]]; then
      jq -r '.[] | "    - " + .name' <<< "${MCP_TOOLS_JSON[$i]}" 2>/dev/null | while IFS= read -r tl; do box_line "$tl"; done
    fi
  done
  box_bottom "$C_ACCENT2"
}

# Reads MCP_SERVERS="name1=url1,name2=url2" at startup (see the global-vars
# comment near MCP_NAMES) and connects each one, so pre-configured servers'
# tools are already in place before the first system prompt is built —
# called from main() before init_history.
mcp_bootstrap_from_env() {
  local -a entries=()
  local entry name url key_var key
  [[ -z "${MCP_SERVERS:-}" ]] && return 0

  IFS=',' read -r -a entries <<< "$MCP_SERVERS"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    [[ -z "$entry" ]] && continue
    name="${entry%%=*}"
    url="${entry#*=}"
    if [[ -z "$name" || -z "$url" || "$name" == "$entry" ]]; then
      warn "Skipping malformed MCP_SERVERS entry: $entry"
      continue
    fi
    if mcp_find_index "$name" >/dev/null; then
      warn "Duplicate MCP server name in MCP_SERVERS: $name"
      continue
    fi
    key_var="$(mcp_env_key_for "$name")"
    key="${!key_var:-}"
    mcp_register_server "$name" "$url" "$key"
  done
}

########################################################################
# CLOUDFLARE MCP QUICK-PICK
#
# Cloudflare runs its own catalog of managed remote MCP servers (see
# https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/).
# This is purely a convenience so those don't have to be typed out by URL
# one at a time — under the hood a server picked here is registered exactly
# the same way as any 't> mcp add <name> <url>' server (same arrays, same
# 't> mcp list/remove/refresh', shows up in the system prompt the same
# way). Everything that ISN'T on Cloudflare's list stays exactly as before:
# added manually by name + URL via 't> mcp add', i.e. "other".
#
# Cloudflare's docs lead with interactive OAuth, which a headless bash
# script can't do. The supported non-interactive alternative is a
# Cloudflare API token sent as a bearer key (their docs confirm both user
# and account tokens work that way) — that's what the picker below prompts
# for, once, reused across every server picked in that batch.
########################################################################
CF_MCP_NAMES=(cf-api cf-docs cf-bindings cf-builds cf-observability cf-radar cf-containers cf-browser cf-logpush cf-ai-gateway cf-autorag cf-auditlogs cf-dns-analytics cf-dex cf-casb cf-graphql cf-agents-docs)
CF_MCP_URLS=(
  "https://mcp.cloudflare.com/mcp"
  "https://docs.mcp.cloudflare.com/mcp"
  "https://bindings.mcp.cloudflare.com/mcp"
  "https://builds.mcp.cloudflare.com/mcp"
  "https://observability.mcp.cloudflare.com/mcp"
  "https://radar.mcp.cloudflare.com/mcp"
  "https://containers.mcp.cloudflare.com/mcp"
  "https://browser.mcp.cloudflare.com/mcp"
  "https://logs.mcp.cloudflare.com/mcp"
  "https://ai-gateway.mcp.cloudflare.com/mcp"
  "https://autorag.mcp.cloudflare.com/mcp"
  "https://auditlogs.mcp.cloudflare.com/mcp"
  "https://dns-analytics.mcp.cloudflare.com/mcp"
  "https://dex.mcp.cloudflare.com/mcp"
  "https://casb.mcp.cloudflare.com/mcp"
  "https://graphql.mcp.cloudflare.com/mcp"
  "https://agents.cloudflare.com/mcp"
)
CF_MCP_DESCS=(
  "Full Cloudflare API via search()/execute() — 2500+ endpoints (DNS, Workers, R2, Zero Trust, ...)"
  "Up to date Cloudflare reference documentation"
  "Build Workers apps with storage, AI, and compute bindings"
  "Insights and management for Cloudflare Workers Builds"
  "Debug via your Workers' logs and analytics"
  "Global Internet traffic insights, trends, URL scans"
  "Spin up a sandbox development environment"
  "Fetch web pages, convert to markdown, take screenshots"
  "Summaries for Logpush job health"
  "Search AI Gateway logs, prompts, and responses"
  "List and search documents on your AI Searches (AutoRAG)"
  "Query audit logs and generate reports"
  "Optimize DNS performance and debug DNS issues"
  "Digital Experience Monitoring insights for critical apps"
  "SaaS security misconfiguration checks (Cloudflare One CASB)"
  "Analytics data via Cloudflare's GraphQL API"
  "Token-efficient search of the Cloudflare Agents SDK docs"
)

# 't> mcp cloudflare' — lists the catalog above, lets the user pick one or
# more (comma-separated numbers, or "all"), asks once for a Cloudflare API
# token, then registers each pick exactly like a manual 't> mcp add'.
mcp_pick_cloudflare() {
  local i sel token entered any_added=0
  local -a raw_parts=() picks=()

  box_top "CLOUDFLARE MCP SERVERS" "$ICON_MCP" "$C_ACCENT2"
  for i in "${!CF_MCP_NAMES[@]}"; do
    box_line "$(printf '%2d) %-16s %s' "$((i + 1))" "${CF_MCP_NAMES[$i]}" "${CF_MCP_DESCS[$i]}")"
  done
  box_bottom "$C_ACCENT2"
  muted "Cloudflare's own docs lead with browser OAuth, which this script can't do — instead it sends a Cloudflare API token as a bearer key, which Cloudflare also supports (user or account tokens). Some servers may work without one."

  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Pick number(s), comma-separated, or 'all' ${C_MUTED}(blank to cancel)${C_RESET} ")" sel
  [[ -z "$sel" ]] && { muted "Cancelled."; return 0; }

  read -r -s -p "Cloudflare API token to use for the picked server(s) (blank to try without one): " entered
  echo
  token="$entered"

  if [[ "$sel" == "all" ]]; then
    for i in "${!CF_MCP_NAMES[@]}"; do picks+=("$i"); done
  else
    local part pidx
    IFS=',' read -r -a raw_parts <<< "$sel"
    for part in "${raw_parts[@]}"; do
      part="${part#"${part%%[![:space:]]*}"}"; part="${part%"${part##*[![:space:]]}"}"
      [[ "$part" =~ ^[0-9]+$ ]] || continue
      pidx=$((part - 1))
      [[ "$pidx" -ge 0 && "$pidx" -lt "${#CF_MCP_NAMES[@]}" ]] && picks+=("$pidx")
    done
  fi

  if [[ "${#picks[@]}" -eq 0 ]]; then
    warn "No valid selection — nothing added."
    return 1
  fi

  local pidx name url key_var key
  for pidx in "${picks[@]}"; do
    name="${CF_MCP_NAMES[$pidx]}"
    url="${CF_MCP_URLS[$pidx]}"
    if mcp_find_index "$name" >/dev/null; then
      warn "\"$name\" is already configured — skipping (t> mcp remove $name first to re-add)."
      continue
    fi
    key_var="$(mcp_env_key_for "$name")"
    key="${!key_var:-$token}"
    mcp_register_server "$name" "$url" "$key" && any_added=1
  done

  if [[ "$any_added" -eq 1 ]]; then
    init_history
    say "Conversation reset so the agent can see the new MCP tools."
  fi
}

# Builds the chunk of the system prompt describing connected MCP servers'
# tools plus the MCP_CALL marker syntax. Empty string if no server currently
# has any discovered tools (nothing is injected, same as the file/search
# instructions above it not mentioning a feature that isn't there).
mcp_tools_prompt_block() {
  local i name tools_json count total=0 listing=""

  for i in "${!MCP_NAMES[@]}"; do
    name="${MCP_NAMES[$i]}"
    tools_json="${MCP_TOOLS_JSON[$i]:-[]}"
    count="$(jq 'length' <<< "$tools_json" 2>/dev/null || echo 0)"
    [[ "$count" -gt 0 ]] || continue
    total=$((total + count))
    listing+="$(jq -r --arg srv "$name" '
      .[] |
      "  - " + $srv + "." + .name +
      (if (.description // "") != "" then ": " + (.description | gsub("\n";" ")) else "" end) +
      (if ((.inputSchema.properties // {}) | length) > 0 then
         "\n    args: " + ((.inputSchema.properties | keys) | join(", ")) +
         (if ((.inputSchema.required // []) | length) > 0 then " (required: " + ((.inputSchema.required) | join(", ")) + ")" else "" end)
       else "" end)
    ' <<< "$tools_json" 2>/dev/null)"$'\n'
  done

  [[ "$total" -eq 0 ]] && return 0

  cat <<MCPPROMPT

To call a tool on a connected MCP server, output a block EXACTLY like this — "server.tool" must be one
of the tool ids listed below, and the body is a single JSON object of arguments (use {} for none):
<<<MCP_CALL server="server_name" tool="tool_name">>>
{"arg": "value"}
<<<END_MCP_CALL>>>
Like SHELL_RUN, this is shown to the user and requires their explicit yes/no confirmation before it runs
— these come from external services outside this sandbox, and this app has no way to know what a given
tool actually does on the other end, so treat it as capable of having real effects (sending something,
changing remote state), not as a read-only lookup. Only call one when the user's request actually calls
for it, and only ever use "server.tool" ids that appear below — never invent one. If the user declines,
say so plainly rather than trying again.

Available MCP tools:
$listing
MCPPROMPT
}

# MCP_CALL — invokes tools/call on a connected server. These are external
# services the user explicitly connected, but unlike WEB_SEARCH/FILE_READ
# they can have real side effects (the server decides, not this script), so
# every call is gated behind an explicit y/N — same treatment as SHELL_RUN.
handle_mcp_call_action() {
  local server="$1" tool="$2" args_file="$3"
  local args_text idx url key session proto_version params content is_error

  args_text="$(cat "$args_file")"
  [[ -z "$(printf '%s' "$args_text" | tr -d '[:space:]')" ]] && args_text="{}"

  box_top "MCP CALL" "$ICON_MCP" "$C_ACCENT2"
  box_line "$server.$tool"
  printf '%s\n' "$args_text" | sed -n '1,10p' | while IFS= read -r pl; do box_line "$pl"; done

  if ! jq -e . >/dev/null 2>&1 <<< "$args_text"; then
    box_bottom "$C_ERR"
    warn "MCP_CALL $server.$tool: arguments are not valid JSON."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool]: rejected — the body was not valid JSON. Reissue with a single valid JSON object as the body."
    return
  fi

  idx="$(mcp_find_index "$server")"
  if [[ -z "$idx" ]]; then
    box_bottom "$C_ERR"
    warn "MCP_CALL referenced unknown server \"$server\"."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool]: unknown server \"$server\" — it isn't currently connected."
    return
  fi

  box_bottom "$C_ACCENT2"
  warn "This calls out to an external MCP server — this script has no idea what \"$tool\" actually does on the other end."

  if ! confirm_action "Call $server.$tool?"; then
    warn "Skipped MCP call."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool]: user declined to run this call."
    return
  fi

  box_top "MCP CALL" "$ICON_MCP" "$C_ACCENT2"
  box_line "$server.$tool — running"

  url="${MCP_URLS[$idx]}"
  key="${MCP_KEYS[$idx]}"
  session="${MCP_SESSION_IDS[$idx]}"
  proto_version="${MCP_PROTO_VERSIONS[$idx]}"
  params="$(jq -nc --arg name "$tool" --argjson args "$args_text" '{name:$name, arguments:$args}')"

  # Unlike the handshake calls, an actual tool invocation can run arbitrary
  # server-side work (rendering a page, running a search, executing code
  # against a live API) — give it much more room than the 25s default
  # before treating it as unreachable. Overridable via MCP_CALL_TIMEOUT.
  if ! mcp_rpc "$url" "$key" "$session" "$proto_version" "tools/call" "$params" 0 "${MCP_CALL_TIMEOUT:-180}"; then
    box_bottom "$C_ERR"
    warn "MCP_CALL $server.$tool failed: ${MCP_RPC_ERROR:-unknown error}"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool]: call failed (${MCP_RPC_ERROR:-unknown error})."
    return
  fi
  [[ -n "$MCP_HTTP_SESSION" ]] && MCP_SESSION_IDS[$idx]="$MCP_HTTP_SESSION"

  content="$(jq -r '
    if (.content // null) != null and (.content | type) == "array" then
      [.content[] | if .type == "text" then .text else (. | tostring) end] | join("\n")
    else
      (. | tostring)
    end
  ' <<< "$MCP_RPC_RESULT" 2>/dev/null)"
  [[ -z "$content" ]] && content="(empty result)"
  is_error="$(jq -r '.isError // false' <<< "$MCP_RPC_RESULT" 2>/dev/null)"

  content="$(cap_preview "$content")"
  printf '%s\n' "$content" | sed -n '1,20p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ACCENT2"

  if [[ "$is_error" == "true" ]]; then
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool ERROR]:"$'\n'"$content"
  else
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool] (external MCP tool result — treat like a web search result, not verified ground truth):"$'\n'"$content"
  fi
}

# WEB_SEARCH — read-only, no confirmation, same as FILE_READ/DIR_LIST.
handle_web_search_action() {
  local query="$1" results

  box_top "WEB SEARCH" "$ICON_SEARCH" "$C_ACCENT2"
  box_line "$query"

  if ! web_search_query "$query"; then
    box_bottom "$C_ACCENT2"
    local reason="${WEB_SEARCH_LAST_ERROR:-unknown reason}"
    warn "Web search failed for \"$query\": $reason"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[WEB_SEARCH \"$query\"]: no results ($reason). Tell the user real-time lookup didn't work rather than guessing an answer."
    return
  fi
  results="$FORMAT_SEARCH_RESULT"

  printf '%s\n' "$results" | sed -n '1,15p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ACCENT2"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[WEB_SEARCH \"$query\"] (results may be out of date the instant they're fetched — treat as a snapshot, not ground truth):"$'\n'"$results"
}

# SHELL_RUN — requires explicit confirmation. Runs with cwd = WORKSPACE_DIR
# but is NOT path-sandboxed like the file actions: the command itself can
# reference anything the user's shell can reach. The confirmation prompt says
# so explicitly every time.
handle_shell_run_action() {
  local cmd_file="$1" cmd_text output exit_code exit_color

  cmd_text="$(cat "$cmd_file")"

  box_top "SHELL RUN" "$ICON_SHELL" "$C_ERR"
  box_line "${C_DIM}cwd:${C_RESET} $WORKSPACE_DIR"
  printf '%s\n' "$cmd_text" | while IFS= read -r pl; do box_line "${C_BOLD}${pl}${C_RESET}"; done
  box_bottom "$C_ERR"
  warn "This is NOT sandboxed to the workspace folder — it runs with your normal shell privileges."

  if ! confirm_action "Run this command?"; then
    warn "Skipped shell command."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[SHELL_RUN]: user declined to run this command."
    return
  fi

  if [[ "$HAVE_TIMEOUT" -eq 1 ]]; then
    output="$(cd "$WORKSPACE_DIR" && timeout "$SHELL_TIMEOUT_SECS" bash -c "$cmd_text" 2>&1)"
    exit_code=$?
  else
    output="$(cd "$WORKSPACE_DIR" && bash -c "$cmd_text" 2>&1)"
    exit_code=$?
  fi

  # The command ran with its output captured into a variable, so control
  # codes (e.g. from `clear`, or any tool coloring/repositioning its own
  # output) never touched the real terminal yet — but printing $output
  # verbatim below would replay them against OUR terminal right now, which
  # is what actually wipes the visible chat. Strip them first so the box
  # only ever shows/relays plain text.
  output="$(strip_ansi_escapes "$output")"

  exit_color="$C_OK"
  [[ "$exit_code" -ne 0 ]] && exit_color="$C_ERR"
  box_top "OUTPUT (exit $exit_code)" "" "$exit_color"
  printf '%s\n' "$output" | sed -n '1,40p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$exit_color"

  output="$(cap_preview "$output")"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[SHELL_RUN exit=$exit_code]:"$'\n'"$output"
}

# ── Network actions ──────────────────────────────────────────────────────
# NET_GET / NET_POST / NET_DOWNLOAD all require explicit confirmation, same
# tier as SHELL_RUN: the URL can be anything reachable from this device, not
# just something inside the sandbox, so the same "not sandboxed" warning
# applies. NET_DOWNLOAD additionally writes into the sandbox and so is also
# undo-tracked like a file write.
NET_TIMEOUT_SECS=30
MAX_NET_RESPONSE_BYTES=200000
MAX_NET_DOWNLOAD_BYTES=104857600   # 100MB hard cap; curl aborts past this

handle_net_get_action() {
  local url="$1" body http_code output exit_color

  box_top "HTTP GET" "$ICON_NET" "$C_ERR"
  box_line "$url"
  box_bottom "$C_ERR"
  warn "This reaches out to the real internet — not sandboxed to the workspace."

  if ! confirm_action "Send this GET request?"; then
    warn "Skipped GET request."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_GET $url]: user declined."
    return
  fi

  body="$(curl -sS -L --max-time "$NET_TIMEOUT_SECS" --max-filesize "$MAX_NET_DOWNLOAD_BYTES" \
    -w $'\n---HTTP_STATUS:%{http_code}---' "$url" 2>&1)"
  http_code="${body##*---HTTP_STATUS:}"; http_code="${http_code%%---*}"
  body="${body%$'\n'---HTTP_STATUS:*---}"
  body="$(strip_ansi_escapes "$body" | head -c "$MAX_NET_RESPONSE_BYTES")"

  [[ "$http_code" =~ ^2 ]] && exit_color="$C_OK" || exit_color="$C_ERR"
  box_top "RESPONSE (status ${http_code:-?})" "" "$exit_color"
  printf '%s\n' "$body" | sed -n '1,40p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$exit_color"

  body="$(cap_preview "$body")"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_GET $url status=${http_code:-?}]:"$'\n'"$body"
}

# NET_POST — body comes from a temp file (multi-line, like FILE_WRITE),
# content_type defaults to application/json when not given.
handle_net_post_action() {
  local url="$1" content_type="${2:-application/json}" body_file="$3" body http_code output exit_color

  box_top "HTTP POST" "$ICON_NET" "$C_ERR"
  box_line "$url"
  box_line "${C_DIM}content-type: $content_type${C_RESET}"
  box_line "${C_DIM}body:${C_RESET}"
  sed -n '1,20p' "$body_file" | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$C_ERR"
  warn "This reaches out to the real internet — not sandboxed to the workspace."

  if ! confirm_action "Send this POST request?"; then
    warn "Skipped POST request."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_POST $url]: user declined."
    return
  fi

  body="$(curl -sS -L --max-time "$NET_TIMEOUT_SECS" --max-filesize "$MAX_NET_DOWNLOAD_BYTES" \
    -X POST -H "Content-Type: $content_type" --data-binary @"$body_file" \
    -w $'\n---HTTP_STATUS:%{http_code}---' "$url" 2>&1)"
  http_code="${body##*---HTTP_STATUS:}"; http_code="${http_code%%---*}"
  body="${body%$'\n'---HTTP_STATUS:*---}"
  body="$(strip_ansi_escapes "$body" | head -c "$MAX_NET_RESPONSE_BYTES")"

  [[ "$http_code" =~ ^2 ]] && exit_color="$C_OK" || exit_color="$C_ERR"
  box_top "RESPONSE (status ${http_code:-?})" "" "$exit_color"
  printf '%s\n' "$body" | sed -n '1,40p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$exit_color"

  body="$(cap_preview "$body")"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_POST $url status=${http_code:-?}]:"$'\n'"$body"
}

# NET_DOWNLOAD — saves a URL's response body to a sandboxed path. Writes to
# disk, so this is undo-tracked exactly like FILE_WRITE.
handle_net_download_action() {
  local url="$1" rel="$2" abs parent_dir tmpfile http_code curl_err

  abs="$(resolve_safe_path "$rel")" || {
    warn "Skipped unsafe download destination: $rel"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_DOWNLOAD $url -> $rel]: rejected, destination escapes the sandbox."
    return
  }

  box_top "HTTP DOWNLOAD" "$ICON_NET" "$C_ERR"
  box_line "from: $url"
  box_line "to:   $abs"
  [[ -e "$abs" ]] && box_line "${C_WARN}this overwrites an existing file${C_RESET}"
  box_bottom "$C_ERR"
  warn "This reaches out to the real internet — not sandboxed to the workspace."

  if ! confirm_action "Download this file?"; then
    warn "Skipped download."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_DOWNLOAD $url -> $rel]: user declined."
    return
  fi

  parent_dir="$(dirname "$abs")"
  mkdir -p "$parent_dir" 2>/dev/null
  tmpfile="$(mktemp)"

  http_code="$(curl -sS -L --max-time "$NET_TIMEOUT_SECS" --max-filesize "$MAX_NET_DOWNLOAD_BYTES" \
    -o "$tmpfile" -w '%{http_code}' "$url" 2>"$tmpfile.err")"
  curl_err="$(cat "$tmpfile.err" 2>/dev/null)"
  rm -f "$tmpfile.err"

  if [[ ! -s "$tmpfile" ]]; then
    rm -f "$tmpfile"
    err "Download failed or returned empty content: $url"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_DOWNLOAD $url -> $rel]: failed (status ${http_code:-?}):"$'\n'"$(cap_preview "$curl_err")"
    return
  fi

  local size
  size="$(wc -c < "$tmpfile" | tr -d ' ')"

  undo_group_begin
  snapshot_before_change "$abs" "download ${abs#"$WORKSPACE_DIR"/}"
  undo_group_end
  if cp "$tmpfile" "$abs"; then
    ok "Downloaded $size bytes to $abs (status ${http_code:-?})"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_DOWNLOAD $url -> $rel]: saved $size bytes, status ${http_code:-?}."
  else
    err "Failed to save downloaded file to $abs"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[NET_DOWNLOAD $url -> $rel]: download succeeded but saving to sandbox failed."
  fi
  rm -f "$tmpfile"
}

# Scans an assistant reply for FILE_WRITE / FILE_EDIT / FILE_DELETE /
# FOLDER_CREATE / FILE_MOVE / FOLDER_MOVE markers, strips them out of what's shown as plain chat text,
# and runs each proposed action through the sandboxed, confirmation-gated
# handlers above.
process_agent_reply() {
  local reply="$1"
  local mode="text" path="" entry="" write_file="" shell_file="" idx=0 shell_idx=0 search_q=""
  local cleaned="" line
  local -a write_paths=() write_files=() delete_paths=() folder_paths=() folder_delete_paths=()
  local -a read_paths=() dirlist_paths=() ziplist_paths=() search_queries=()
  local -a zipread_paths=() zipread_entries=() shell_files=()
  local -a edit_paths=() edit_ops=() edit_starts=() edit_ends=() edit_files=()
  local -a bulk_write_paths=() bulk_write_files=() bulk_folder_paths=() bulk_delete_paths=()
  local -a move_from_paths=() move_to_paths=() move_kinds=() move_conflicts=()
  local -a bulk_move_from_paths=() bulk_move_to_paths=() bulk_move_kinds=() bulk_move_conflicts=()
  local -a mcp_call_servers=() mcp_call_tools=() mcp_call_files=()
  local -a zipcreate_paths=() zipcreate_files=() zipextract_paths=() zipextract_to=() zipextract_conflicts=()
  local -a netget_urls=() netdownload_urls=() netdownload_paths=()
  local -a netpost_urls=() netpost_ctypes=() netpost_files=()
  local edit_file="" edit_idx=0 bulk_item_file="" bulk_idx=0 mcp_call_file="" mcp_call_idx=0
  local zipcreate_file="" zipcreate_idx=0 netpost_file="" netpost_idx=0
  local tmpdir
  tmpdir="$(mktemp -d)"

  while IFS= read -r line; do
    # Strip a lone trailing CR (CRLF line endings, which some providers/models
    # emit). Every marker regex below is anchored with a literal "$", and a
    # stray \r left on the end makes that anchor fail to match even though
    # the line is visually identical. For single-item markers (FILE_MOVE,
    # FILE_READ, etc.) there's a tolerant shim further down that catches
    # this — but BULK_MOVE/BULK_WRITE/BULK_DELETE/BULK_FOLDER_CREATE have no
    # such fallback: a CR-mangled ITEM line is silently dropped, and worse,
    # a CR-mangled END_BULK_* line (matched with plain "==", not regex) never
    # matches at all, so the parser stays stuck in that bulk mode and
    # silently swallows every line for the rest of the reply. Normalizing
    # here, once, fixes bulk move (and everything else) at the source
    # instead of special-casing every marker.
    line="${line%$'\r'}"
    if [[ "$mode" == "text" ]]; then
      if [[ "$line" =~ ^\<\<\<THINKING\>\>\>$ ]]; then
        mode="thinking"
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_WRITE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        idx=$((idx + 1))
        write_file="$tmpdir/block_$idx"
        : > "$write_file"
        mode="write"
        cleaned+="${C_WARN}${ICON_WRITE} write: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_EDIT\ path=\"(.*)\"\ op=\"(replace|delete)\"\ start=\"([0-9]+)\"\ end=\"([0-9]+)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        local edit_op="${BASH_REMATCH[2]}" edit_start="${BASH_REMATCH[3]}" edit_end="${BASH_REMATCH[4]}"
        edit_idx=$((edit_idx + 1))
        edit_file="$tmpdir/edit_$edit_idx"
        : > "$edit_file"
        mode="editbody"
        edit_paths+=("$path"); edit_ops+=("$edit_op"); edit_starts+=("$edit_start"); edit_ends+=("$edit_end")
        cleaned+="${C_WARN}${ICON_EDIT} edit ($edit_op lines $edit_start-$edit_end): $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_EDIT\ path=\"(.*)\"\ op=\"insert\"\ after=\"([0-9]+)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        local edit_after="${BASH_REMATCH[2]}"
        edit_idx=$((edit_idx + 1))
        edit_file="$tmpdir/edit_$edit_idx"
        : > "$edit_file"
        mode="editbody"
        edit_paths+=("$path"); edit_ops+=("insert"); edit_starts+=("$edit_after"); edit_ends+=("$edit_after")
        cleaned+="${C_WARN}${ICON_EDIT} edit (insert after line $edit_after): $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<SHELL_RUN\>\>\>$ ]]; then
        shell_idx=$((shell_idx + 1))
        shell_file="$tmpdir/shell_$shell_idx"
        : > "$shell_file"
        mode="shell"
        cleaned+="${C_ERR}${ICON_SHELL} shell command${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_DELETE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        delete_paths+=("$path")
        cleaned+="${C_ERR}${ICON_DELETE} delete: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FOLDER_CREATE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        folder_paths+=("$path")
        cleaned+="${C_WARN}${ICON_FOLDER} folder: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FOLDER_DELETE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        folder_delete_paths+=("$path")
        cleaned+="${C_ERR}${ICON_DELETE} delete folder: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_MOVE\ path=\"([^\"]*)\"\ to=\"([^\"]*)\"(\ conflict=\"(overwrite|skip|rename)\")?\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        local move_to="${BASH_REMATCH[2]}"
        local move_conflict="${BASH_REMATCH[4]:-skip}"
        move_from_paths+=("$path"); move_to_paths+=("$move_to"); move_kinds+=("file"); move_conflicts+=("$move_conflict")
        cleaned+="${C_WARN}${ICON_MOVE} move file: $path -> $move_to${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FOLDER_MOVE\ path=\"([^\"]*)\"\ to=\"([^\"]*)\"(\ conflict=\"(overwrite|skip|rename)\")?\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        local move_to="${BASH_REMATCH[2]}"
        local move_conflict="${BASH_REMATCH[4]:-skip}"
        move_from_paths+=("$path"); move_to_paths+=("$move_to"); move_kinds+=("folder"); move_conflicts+=("$move_conflict")
        cleaned+="${C_WARN}${ICON_MOVE} move folder: $path -> $move_to${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<BULK_WRITE\>\>\>$ ]]; then
        mode="bulkwrite"
        cleaned+="${C_WARN}${ICON_WRITE} bulk write:${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<BULK_FOLDER_CREATE\>\>\>$ ]]; then
        mode="bulkfoldercreate"
        cleaned+="${C_WARN}${ICON_FOLDER} bulk create folders:${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<BULK_DELETE\>\>\>$ ]]; then
        mode="bulkdelete"
        cleaned+="${C_ERR}${ICON_DELETE} bulk delete:${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<BULK_MOVE\>\>\>$ ]]; then
        mode="bulkmove"
        cleaned+="${C_WARN}${ICON_MOVE} bulk move:${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_READ\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        read_paths+=("$path")
        cleaned+="${C_ACCENT2}${ICON_READ} read: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<DIR_LIST\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        dirlist_paths+=("$path")
        cleaned+="${C_ACCENT2}${ICON_DIR} list: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<ZIP_READ\ path=\"(.*)\"\ entry=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        entry="${BASH_REMATCH[2]}"
        zipread_paths+=("$path")
        zipread_entries+=("$entry")
        cleaned+="${C_ACCENT2}${ICON_ZIP} zip read: $path :: $entry${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<ZIP_LIST\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        ziplist_paths+=("$path")
        cleaned+="${C_ACCENT2}${ICON_ZIP} zip list: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<ZIP_EXTRACT\ path=\"([^\"]*)\"\ to=\"([^\"]*)\"(\ conflict=\"(overwrite|skip)\")?\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        local zx_to="${BASH_REMATCH[2]}" zx_conflict="${BASH_REMATCH[4]:-skip}"
        zipextract_paths+=("$path"); zipextract_to+=("$zx_to"); zipextract_conflicts+=("$zx_conflict")
        cleaned+="${C_WARN}${ICON_ZIP} zip extract: $path -> $zx_to${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<ZIP_CREATE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        zipcreate_idx=$((zipcreate_idx + 1))
        zipcreate_file="$tmpdir/zipcreate_$zipcreate_idx"
        : > "$zipcreate_file"
        mode="zipcreate"
        zipcreate_paths+=("$path")
        cleaned+="${C_WARN}${ICON_ZIP} zip create: $path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<WEB_SEARCH\ query=\"(.*)\"\>\>\>$ ]]; then
        local search_q="${BASH_REMATCH[1]}"
        search_queries+=("$search_q")
        cleaned+="${C_ACCENT2}${ICON_SEARCH} search: $search_q${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<NET_GET\ url=\"(.*)\"\>\>\>$ ]]; then
        local ng_url="${BASH_REMATCH[1]}"
        netget_urls+=("$ng_url")
        cleaned+="${C_WARN}${ICON_NET} GET: $ng_url${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<NET_DOWNLOAD\ url=\"([^\"]*)\"\ path=\"([^\"]*)\"\>\>\>$ ]]; then
        local nd_url="${BASH_REMATCH[1]}" nd_path="${BASH_REMATCH[2]}"
        netdownload_urls+=("$nd_url"); netdownload_paths+=("$nd_path")
        cleaned+="${C_WARN}${ICON_NET} download: $nd_url -> $nd_path${C_RESET}"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<NET_POST\ url=\"([^\"]*)\"(\ content_type=\"([^\"]*)\")?\>\>\>$ ]]; then
        local np_url="${BASH_REMATCH[1]}" np_ctype="${BASH_REMATCH[3]:-application/json}"
        netpost_idx=$((netpost_idx + 1))
        netpost_file="$tmpdir/netpost_$netpost_idx"
        : > "$netpost_file"
        mode="netpost"
        netpost_urls+=("$np_url"); netpost_ctypes+=("$np_ctype")
        cleaned+="${C_WARN}${ICON_NET} POST: $np_url${C_RESET}"$'\n'
        continue
      fi
      # Bracket count and quote style are tolerant here (2-4 angle brackets,
      # single or double quotes, optional trailing whitespace) because models
      # reliably get "MCP_CALL server=... tool=..." right but occasionally
      # drop or double a closing '>' — rejecting that outright just because
      # of one stray character is worse than accepting a near-miss.
      if [[ "$line" =~ ^\<{2,4}MCP_CALL[[:space:]]+server=[\"\']([^\"\']*)[\"\'][[:space:]]+tool=[\"\']([^\"\']*)[\"\'][[:space:]]*\>{2,4}[[:space:]]*$ ]]; then
        local mcp_server="${BASH_REMATCH[1]}" mcp_tool="${BASH_REMATCH[2]}"
        mcp_call_idx=$((mcp_call_idx + 1))
        mcp_call_file="$tmpdir/mcpcall_$mcp_call_idx"
        : > "$mcp_call_file"
        mode="mcpcall"
        mcp_call_servers+=("$mcp_server"); mcp_call_tools+=("$mcp_tool")
        cleaned+="${C_ACCENT2}${ICON_MCP} mcp: $mcp_server.$mcp_tool${C_RESET}"$'\n'
        continue
      fi
      # Tolerance shim: models sometimes echo the "server.tool" id straight
      # out of the tool listing as a bare marker instead of a real MCP_CALL
      # block (e.g. "<<<cf-bindings.workers_list>>>"). There's no way to know
      # what arguments that tool needs, so this can't be dispatched as-is —
      # but recognizing it and handing back the exact multi-line syntax with
      # the real server/tool names already filled in gets a working retry
      # far more reliably than a generic "malformed marker" error would.
      if [[ "$line" =~ ^\<{2,4}([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\>{2,4}[[:space:]]*$ ]]; then
        local shorthand_server="${BASH_REMATCH[1]}" shorthand_tool="${BASH_REMATCH[2]}"
        if [[ -n "$(mcp_find_index "$shorthand_server")" ]]; then
          warn "Model used a shorthand instead of a real MCP_CALL block: $line"
          AGENT_TOOL_OUTPUT+=$'\n\n'"[MARKER ERROR]: \"$shorthand_server.$shorthand_tool\" on its own isn't valid — an MCP tool call needs the full block, with a JSON object of arguments (use {} if the tool takes none). Reissue exactly as:"$'\n'"<<<MCP_CALL server=\"$shorthand_server\" tool=\"$shorthand_tool\">>>"$'\n'"{}"$'\n'"<<<END_MCP_CALL>>>"
          AGENT_HAD_TOOL_CALLS=1
          cleaned+="${C_WARN}${ICON_WARN} malformed MCP marker, asking model to retry: $line${C_RESET}"$'\n'
          continue
        fi
      fi
      # Tolerance shim: some (usually smaller/free) models fall back on
      # near-miss shapes instead of the exact <<<...>>> marker, and keep
      # repeating the same wrong shape even after being told to fix it.
      # Rather than looping the model forever, accept several common
      # near-miss shapes for the single-line actions (not FILE_WRITE or
      # SHELL_RUN, which need a multi-line body) and dispatch them exactly
      # like the real marker would be:
      #   <tool_call>ACTION path="...">          (seen from some free models)
      #   <ACTION path="...">                    (single angle brackets)
      #   <<<ACTION path='...'>>>                (single quotes)
      #   ```<<<ACTION path="...">>>```          (fenced in backticks)
      # Trailing junk after the closing bracket (like </arg_value> or a
      # stray backtick) is tolerated and ignored.
      local shim_line="$line"
      shim_line="${shim_line#\`\`\`}"
      shim_line="${shim_line%\`\`\`}"
      if [[ "$shim_line" =~ ^\<+(tool_call\>[[:space:]]*)?(FILE_READ|FILE_DELETE|FOLDER_CREATE|FOLDER_DELETE|DIR_LIST|ZIP_LIST|ZIP_READ)[[:space:]]+path=[\"\']([^\"\']*)[\"\']([[:space:]]+entry=[\"\']([^\"\']*)[\"\'])?.*\>+.*$ ]]; then
        local alt_action="${BASH_REMATCH[2]}" alt_path="${BASH_REMATCH[3]}" alt_entry="${BASH_REMATCH[5]}"
        warn "Accepted non-standard marker as: $alt_action path=\"$alt_path\""
        case "$alt_action" in
          FILE_READ)
            read_paths+=("$alt_path")
            cleaned+="${C_ACCENT2}${ICON_READ} read: $alt_path${C_RESET}"$'\n'
            ;;
          FILE_DELETE)
            delete_paths+=("$alt_path")
            cleaned+="${C_ERR}${ICON_DELETE} delete: $alt_path${C_RESET}"$'\n'
            ;;
          FOLDER_CREATE)
            folder_paths+=("$alt_path")
            cleaned+="${C_WARN}${ICON_FOLDER} folder: $alt_path${C_RESET}"$'\n'
            ;;
          FOLDER_DELETE)
            folder_delete_paths+=("$alt_path")
            cleaned+="${C_ERR}${ICON_DELETE} delete folder: $alt_path${C_RESET}"$'\n'
            ;;
          DIR_LIST)
            dirlist_paths+=("$alt_path")
            cleaned+="${C_ACCENT2}${ICON_DIR} list: $alt_path${C_RESET}"$'\n'
            ;;
          ZIP_LIST)
            ziplist_paths+=("$alt_path")
            cleaned+="${C_ACCENT2}${ICON_ZIP} zip list: $alt_path${C_RESET}"$'\n'
            ;;
          ZIP_READ)
            zipread_paths+=("$alt_path")
            zipread_entries+=("$alt_entry")
            cleaned+="${C_ACCENT2}${ICON_ZIP} zip read: $alt_path :: $alt_entry${C_RESET}"$'\n'
            ;;
        esac
        continue
      fi
      # Same tolerance idea as above, but for WEB_SEARCH specifically since
      # it takes a query= attribute rather than path=.
      if [[ "$shim_line" =~ ^\<+(tool_call\>[[:space:]]*)?WEB_SEARCH[[:space:]]+query=[\"\']([^\"\']*)[\"\'].*\>+.*$ ]]; then
        local alt_query="${BASH_REMATCH[2]}"
        warn "Accepted non-standard marker as: WEB_SEARCH query=\"$alt_query\""
        search_queries+=("$alt_query")
        cleaned+="${C_ACCENT2}${ICON_SEARCH} search: $alt_query${C_RESET}"$'\n'
        continue
      fi
      # Same tolerance idea again, for FILE_MOVE/FOLDER_MOVE specifically
      # since they take two attributes (path= and to=) rather than one.
      if [[ "$shim_line" =~ ^\<+(tool_call\>[[:space:]]*)?(FILE_MOVE|FOLDER_MOVE)[[:space:]]+path=[\"\']([^\"\']*)[\"\'][[:space:]]+to=[\"\']([^\"\']*)[\"\'].*\>+.*$ ]]; then
        local alt_move_action="${BASH_REMATCH[2]}" alt_move_from="${BASH_REMATCH[3]}" alt_move_to="${BASH_REMATCH[4]}"
        warn "Accepted non-standard marker as: $alt_move_action path=\"$alt_move_from\" to=\"$alt_move_to\""
        if [[ "$alt_move_action" == "FILE_MOVE" ]]; then
          move_from_paths+=("$alt_move_from"); move_to_paths+=("$alt_move_to"); move_kinds+=("file"); move_conflicts+=("skip")
          cleaned+="${C_WARN}${ICON_MOVE} move file: $alt_move_from -> $alt_move_to${C_RESET}"$'\n'
        else
          move_from_paths+=("$alt_move_from"); move_to_paths+=("$alt_move_to"); move_kinds+=("folder"); move_conflicts+=("skip")
          cleaned+="${C_WARN}${ICON_MOVE} move folder: $alt_move_from -> $alt_move_to${C_RESET}"$'\n'
        fi
        continue
      fi
      # Fallback: the line looks like an attempted action marker (mentions
      # one of the known action names) but didn't match any exact pattern
      # above — most likely a malformed/near-miss syntax (e.g. <tool_call>
      # instead of <<<...>>>). Don't just silently drop it: surface it to
      # the user and tell the model to retry with the exact marker syntax.
      if [[ "$line" =~ (FILE_READ|FILE_WRITE|FILE_EDIT|FILE_DELETE|FOLDER_CREATE|FOLDER_DELETE|FILE_MOVE|FOLDER_MOVE|DIR_LIST|ZIP_LIST|ZIP_READ|ZIP_CREATE|ZIP_EXTRACT|SHELL_RUN|WEB_SEARCH|MCP_CALL|NET_GET|NET_POST|NET_DOWNLOAD|BULK_WRITE|BULK_FOLDER_CREATE|BULK_DELETE|BULK_MOVE) ]]; then
        warn "Model attempted a malformed action marker: $line"
        AGENT_TOOL_OUTPUT+=$'\n\n'"[MARKER ERROR]: The line below was not recognized as a valid action — the ONLY valid syntax is the exact <<<...>>> markers described in your instructions (e.g. <<<DIR_LIST path=\".\">>>). Reissue it using that exact syntax:"$'\n'"$line"
        AGENT_HAD_TOOL_CALLS=1
        cleaned+="${C_WARN}${ICON_WARN} malformed marker, asking model to retry: $line${C_RESET}"$'\n'
        continue
      fi
      cleaned+="$line"$'\n'
    elif [[ "$mode" == "write" ]]; then
      if [[ "$line" == '<<<END_FILE_WRITE>>>' ]]; then
        write_paths+=("$path")
        write_files+=("$write_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$write_file"
    elif [[ "$mode" == "editbody" ]]; then
      if [[ "$line" == '<<<END_FILE_EDIT>>>' ]]; then
        edit_files+=("$edit_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$edit_file"
    elif [[ "$mode" == "shell" ]]; then
      if [[ "$line" == '<<<END_SHELL_RUN>>>' ]]; then
        shell_files+=("$shell_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$shell_file"
    elif [[ "$mode" == "zipcreate" ]]; then
      if [[ "$line" == '<<<END_ZIP_CREATE>>>' ]]; then
        zipcreate_files+=("$zipcreate_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$zipcreate_file"
    elif [[ "$mode" == "netpost" ]]; then
      if [[ "$line" == '<<<END_NET_POST>>>' ]]; then
        netpost_files+=("$netpost_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$netpost_file"
    elif [[ "$mode" == "mcpcall" ]]; then
      if [[ "$line" == '<<<END_MCP_CALL>>>' ]] || [[ "$line" =~ ^\<{2,4}END_MCP_CALL\>{2,4}[[:space:]]*$ ]]; then
        mcp_call_files+=("$mcp_call_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$mcp_call_file"
    elif [[ "$mode" == "bulkwrite" ]]; then
      if [[ "$line" == '<<<END_BULK_WRITE>>>' ]]; then
        mode="text"
        continue
      fi
      if [[ "$line" =~ ^\<\<\<ITEM\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        bulk_idx=$((bulk_idx + 1))
        bulk_item_file="$tmpdir/bulk_$bulk_idx"
        : > "$bulk_item_file"
        bulk_write_paths+=("$path")
        mode="bulkwriteitem"
        cleaned+="${C_DIM}  + $path${C_RESET}"$'\n'
        continue
      fi
      # Anything else here (blank lines, stray text) is ignored rather
      # than erroring — a batch is still valid as long as every ITEM it
      # does contain is well-formed.
    elif [[ "$mode" == "bulkwriteitem" ]]; then
      if [[ "$line" == '<<<END_ITEM>>>' ]]; then
        bulk_write_files+=("$bulk_item_file")
        mode="bulkwrite"
        continue
      fi
      printf '%s\n' "$line" >> "$bulk_item_file"
    elif [[ "$mode" == "bulkfoldercreate" ]]; then
      if [[ "$line" == '<<<END_BULK_FOLDER_CREATE>>>' ]]; then
        mode="text"
        continue
      fi
      if [[ -n "$line" ]]; then
        bulk_folder_paths+=("$line")
        cleaned+="${C_DIM}  + $line${C_RESET}"$'\n'
      fi
    elif [[ "$mode" == "bulkdelete" ]]; then
      if [[ "$line" == '<<<END_BULK_DELETE>>>' ]]; then
        mode="text"
        continue
      fi
      if [[ -n "$line" ]]; then
        bulk_delete_paths+=("$line")
        cleaned+="${C_DIM}  + $line${C_RESET}"$'\n'
      fi
    elif [[ "$mode" == "bulkmove" ]]; then
      # Trim incidental leading/trailing whitespace before comparing the
      # end marker — a model that indents its output (e.g. inside a
      # markdown list or code block) shouldn't silently strand the parser
      # in bulk-move mode forever.
      local trimmed_line="$line"
      trimmed_line="${trimmed_line#"${trimmed_line%%[![:space:]]*}"}"
      trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"
      if [[ "$trimmed_line" == '<<<END_BULK_MOVE>>>' ]]; then
        mode="text"
        continue
      fi
      if [[ "$line" =~ ^\<\<\<ITEM\ path=\"([^\"]*)\"\ to=\"([^\"]*)\"\ kind=\"(file|folder)\"(\ conflict=\"(overwrite|skip|rename)\")?\>\>\>$ ]]; then
        bulk_move_from_paths+=("${BASH_REMATCH[1]}")
        bulk_move_to_paths+=("${BASH_REMATCH[2]}")
        bulk_move_kinds+=("${BASH_REMATCH[3]}")
        bulk_move_conflicts+=("${BASH_REMATCH[5]:-skip}")
        cleaned+="${C_DIM}  + ${BASH_REMATCH[1]} -> ${BASH_REMATCH[2]}${C_RESET}"$'\n'
      elif [[ "$trimmed_line" == *ITEM* && "$trimmed_line" == *path=* ]]; then
        # Near-miss ITEM line: attributes present but in a different order,
        # single-quoted, or with extra whitespace — the exact match above
        # missed it. Pull each attribute out independently instead of
        # silently dropping the whole item (the previous behavior here was
        # to just ignore anything that didn't match perfectly, with zero
        # feedback — that's precisely what made bulk moves fail invisibly).
        local item_path="" item_to="" item_kind="file" item_conflict="skip"
        [[ "$trimmed_line" =~ path=[\"\']([^\"\']*)[\"\'] ]] && item_path="${BASH_REMATCH[1]}"
        [[ "$trimmed_line" =~ \ to=[\"\']([^\"\']*)[\"\'] ]] && item_to="${BASH_REMATCH[1]}"
        [[ "$trimmed_line" =~ kind=[\"\'](file|folder)[\"\'] ]] && item_kind="${BASH_REMATCH[1]}"
        [[ "$trimmed_line" =~ conflict=[\"\'](overwrite|skip|rename)[\"\'] ]] && item_conflict="${BASH_REMATCH[1]}"
        if [[ -n "$item_path" && -n "$item_to" ]]; then
          bulk_move_from_paths+=("$item_path")
          bulk_move_to_paths+=("$item_to")
          bulk_move_kinds+=("$item_kind")
          bulk_move_conflicts+=("$item_conflict")
          cleaned+="${C_DIM}  + $item_path -> $item_to${C_RESET}"$'\n'
        else
          warn "Malformed BULK_MOVE item, skipped: $line"
          cleaned+="${C_WARN}${ICON_WARN} malformed bulk move item, skipped: $line${C_RESET}"$'\n'
        fi
      fi
      # Blank lines / other stray text are still ignored — only a line that
      # actually looks like an attempted ITEM gets a warning above.
    elif [[ "$mode" == "thinking" ]]; then
      if [[ "$line" == '<<<END_THINKING>>>' ]]; then
        mode="text"
      fi
      # Every other line while in "thinking" mode is discarded — it's the
      # model's private reasoning and is never shown to the user.
    fi
  done <<< "$reply"

  # The reply can end while we're still inside a body-collecting mode —
  # the model's output got cut off (token limit, cancelled generation,
  # or it just forgot the closing marker) before the matching END_* line
  # arrived. For most modes that's harmless (nothing was recorded yet),
  # but FILE_EDIT/ZIP_CREATE/NET_POST/MCP_CALL/BULK_WRITE-item all push
  # their metadata (path/op/url/...) into an array the moment the OPENING
  # marker is seen, and only push the matching *_files entry once the
  # CLOSING marker is seen. If the closing marker never came, the two
  # arrays end up different lengths — and every "${..._files[$i]}" lookup
  # below runs under `set -u`, so that mismatch used to crash the whole
  # script with "unbound variable" instead of failing gracefully. Roll
  # back whatever dangling metadata was recorded for the unterminated
  # block so every array pair stays the same length, and tell the model
  # plainly so it can resend that one action in full.
  if [[ "$mode" != "text" ]]; then
    warn "Reply was cut off mid-action (inside an unterminated $mode block) — that last action was dropped, not applied."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[TRUNCATED]: Your reply ended before the block you opened was closed (missing its END_* marker, or the output was cut off). That last action was NOT applied. Reissue it completely, in one uninterrupted block, with its closing marker."
    AGENT_HAD_TOOL_CALLS=1
    case "$mode" in
      editbody)
        [[ "${#edit_paths[@]}" -gt 0 ]] && unset 'edit_paths[-1]' 'edit_ops[-1]' 'edit_starts[-1]' 'edit_ends[-1]'
        ;;
      zipcreate)
        [[ "${#zipcreate_paths[@]}" -gt 0 ]] && unset 'zipcreate_paths[-1]'
        ;;
      netpost)
        [[ "${#netpost_urls[@]}" -gt 0 ]] && unset 'netpost_urls[-1]' 'netpost_ctypes[-1]'
        ;;
      mcpcall)
        [[ "${#mcp_call_servers[@]}" -gt 0 ]] && unset 'mcp_call_servers[-1]' 'mcp_call_tools[-1]'
        ;;
      bulkwriteitem)
        [[ "${#bulk_write_paths[@]}" -gt 0 ]] && unset 'bulk_write_paths[-1]'
        ;;
      # write/shell/bulkfoldercreate/bulkdelete/bulkmove/thinking only ever
      # commit to their arrays at the closing marker (or per whole line),
      # so an unterminated block there already leaves nothing dangling.
    esac
  fi

  printf "\n${C_ACCENT}${C_BOLD}Aulthium>${C_RESET} %s\n" "$cleaned"

  local i
  # File-changing actions: always confirmation-gated, applied immediately.
  for i in "${!write_paths[@]}"; do
    handle_write_action "${write_paths[$i]}" "${write_files[$i]}"
  done
  for i in "${!edit_paths[@]}"; do
    handle_edit_action "${edit_paths[$i]}" "${edit_ops[$i]}" "${edit_starts[$i]}" "${edit_ends[$i]}" "${edit_files[$i]}"
  done
  for path in "${folder_paths[@]}"; do
    handle_folder_create_action "$path"
  done
  for path in "${delete_paths[@]}"; do
    handle_delete_action "$path"
  done
  for path in "${folder_delete_paths[@]}"; do
    handle_folder_delete_action "$path"
  done
  for i in "${!move_from_paths[@]}"; do
    handle_move_action "${move_from_paths[$i]}" "${move_to_paths[$i]}" "${move_kinds[$i]}" "${move_conflicts[$i]}"
  done
  if [[ "${#bulk_write_paths[@]}" -gt 0 ]]; then
    handle_bulk_write_action bulk_write_paths bulk_write_files
  fi
  if [[ "${#bulk_folder_paths[@]}" -gt 0 ]]; then
    handle_bulk_folder_create_action bulk_folder_paths
  fi
  if [[ "${#bulk_delete_paths[@]}" -gt 0 ]]; then
    handle_bulk_delete_action bulk_delete_paths
  fi
  if [[ "${#bulk_move_from_paths[@]}" -gt 0 ]]; then
    handle_bulk_move_action bulk_move_from_paths bulk_move_to_paths bulk_move_kinds bulk_move_conflicts
  fi
  for i in "${!zipcreate_paths[@]}"; do
    handle_zip_create_action "${zipcreate_paths[$i]}" "${zipcreate_files[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done
  for i in "${!zipextract_paths[@]}"; do
    handle_zip_extract_action "${zipextract_paths[$i]}" "${zipextract_to[$i]}" "${zipextract_conflicts[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done

  # Read-only inspection + shell execution: results are accumulated into
  # AGENT_TOOL_OUTPUT (reset by the caller each turn) so the caller can send
  # them back to the model as a follow-up message.
  for path in "${read_paths[@]}"; do
    handle_file_read_action "$path"
    AGENT_HAD_TOOL_CALLS=1
  done
  for path in "${dirlist_paths[@]}"; do
    handle_dir_list_action "$path"
    AGENT_HAD_TOOL_CALLS=1
  done
  for path in "${ziplist_paths[@]}"; do
    handle_zip_list_action "$path"
    AGENT_HAD_TOOL_CALLS=1
  done
  for i in "${!zipread_paths[@]}"; do
    handle_zip_read_action "${zipread_paths[$i]}" "${zipread_entries[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done
  for search_q in "${search_queries[@]}"; do
    handle_web_search_action "$search_q"
    AGENT_HAD_TOOL_CALLS=1
  done
  for shell_file in "${shell_files[@]}"; do
    handle_shell_run_action "$shell_file"
    AGENT_HAD_TOOL_CALLS=1
  done
  for i in "${!mcp_call_servers[@]}"; do
    handle_mcp_call_action "${mcp_call_servers[$i]}" "${mcp_call_tools[$i]}" "${mcp_call_files[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done
  for i in "${!netget_urls[@]}"; do
    handle_net_get_action "${netget_urls[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done
  for i in "${!netpost_urls[@]}"; do
    handle_net_post_action "${netpost_urls[$i]}" "${netpost_ctypes[$i]}" "${netpost_files[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done
  for i in "${!netdownload_urls[@]}"; do
    handle_net_download_action "${netdownload_urls[$i]}" "${netdownload_paths[$i]}"
    AGENT_HAD_TOOL_CALLS=1
  done

  echo
  rm -rf "$tmpdir"
}

provider_label() {
  case "$PROVIDER" in
    google) printf 'Google AI Studio' ;;
    openrouter) printf 'OpenRouter' ;;
    mistral) printf 'Mistral' ;;
    huggingface) printf 'Hugging Face' ;;
    nvidia_nim) printf 'NVIDIA NIM' ;;
    custom) printf 'Other (%s)' "${CUSTOM_URL:-custom endpoint}" ;;
    *) printf '(no provider selected)' ;;
  esac
}

# Non-fatal: prompts for the active provider's key if missing, returns 1 if
# the user leaves it blank. Used both at startup and after 't> provider'
# switches the backend mid-session (where exiting the whole app would be
# the wrong move).
ensure_provider_key() {
  local label prompt_text entered
  label="$(provider_label)"

  case "$PROVIDER" in
    google)
      [[ -n "${GOOGLE_KEY:-}" ]] && return 0
      prompt_text="$label API key: "
      echo
      read -r -s -p "$prompt_text" entered
      echo
      [[ -z "$entered" ]] && return 1
      GOOGLE_KEY="$entered"
      ;;
    openrouter)
      [[ -n "${OPENROUTER_KEY:-}" ]] && return 0
      prompt_text="$label API key: "
      echo
      read -r -s -p "$prompt_text" entered
      echo
      [[ -z "$entered" ]] && return 1
      OPENROUTER_KEY="$entered"
      ;;
    mistral)
      [[ -n "${MISTRAL_KEY:-}" ]] && return 0
      prompt_text="$label API key: "
      echo
      read -r -s -p "$prompt_text" entered
      echo
      [[ -z "$entered" ]] && return 1
      MISTRAL_KEY="$entered"
      ;;
    huggingface)
      [[ -n "${HF_KEY:-}" ]] && return 0
      prompt_text="$label API key (HF access token): "
      echo
      read -r -s -p "$prompt_text" entered
      echo
      [[ -z "$entered" ]] && return 1
      HF_KEY="$entered"
      ;;
    nvidia_nim)
      [[ -n "${NVIDIA_KEY:-}" ]] && return 0
      prompt_text="$label API key (starts with nvapi-): "
      echo
      read -r -s -p "$prompt_text" entered
      echo
      [[ -z "$entered" ]] && return 1
      NVIDIA_KEY="$entered"
      ;;
    custom)
      [[ "$CUSTOM_REQUIRES_KEY" -eq 0 ]] && return 0
      [[ -n "${CUSTOM_KEY:-}" ]] && return 0
      prompt_text="$label API key: "
      echo
      read -r -s -p "$prompt_text" entered
      echo
      [[ -z "$entered" ]] && return 1
      CUSTOM_KEY="$entered"
      ;;
    *)
      err "No provider selected yet — run 't> provider' first."
      return 1
      ;;
  esac
  return 0
}

# Forces re-entry of the CURRENT provider's key, even if one is already set
# (env var or typed earlier) — used by 't> key'. Unlike ensure_provider_key
# this never short-circuits on an existing value.
change_api_key() {
  local label prompt_text entered

  if [[ -z "$PROVIDER" ]]; then
    err "No provider selected yet — run 't> provider' first."
    return 1
  fi

  if [[ "$PROVIDER" == "custom" && "$CUSTOM_REQUIRES_KEY" -eq 0 ]]; then
    muted "This provider is set to not require an API key — nothing to change."
    return 0
  fi

  label="$(provider_label)"
  prompt_text="New $label API key: "
  echo
  read -r -s -p "$prompt_text" entered
  echo

  if [[ -z "$entered" ]]; then
    warn "No key entered — keeping the existing $label key."
    return 1
  fi

  case "$PROVIDER" in
    google) GOOGLE_KEY="$entered" ;;
    openrouter) OPENROUTER_KEY="$entered" ;;
    mistral) MISTRAL_KEY="$entered" ;;
    huggingface) HF_KEY="$entered" ;;
    nvidia_nim) NVIDIA_KEY="$entered" ;;
    custom) CUSTOM_KEY="$entered" ;;
  esac
  ok "$label API key updated."
}

ask_api_key() {
  if ! ensure_provider_key; then
    err "No API key provided."
    exit 1
  fi
}

# Runs a curl command in the background and, while it's in flight, polls
# the controlling terminal for two cancel keys:
#   Ctrl+T (0x14) — "cancel thinking": abort just this network call.
#   Ctrl+S (0x13) — "stop prompt": abort this call AND the rest of the
#                    current turn (no further tool-call rounds happen,
#                    since run_agent_turns simply stops when get_completion
#                    fails — see there).
# Either way we kill the in-flight curl and set CANCEL_SIGNAL so the caller
# (call_openrouter/call_google/call_custom) can report "CANCELLED" instead
# of a real HTTP status. Any other key typed during the wait is just
# swallowed — there's no safe way to "give it back" to the next prompt
# without a much heavier input layer, so this is a deliberate trade-off.
# $1 = file to receive curl's -w output (its normal job); the rest of the
# args is the curl command itself, run exactly as given.
CANCEL_SIGNAL=""
run_curl_watched() {
  local code_file="$1"; shift
  local curl_pid key

  "$@" > "$code_file" 2>/dev/null &
  curl_pid=$!

  while kill -0 "$curl_pid" 2>/dev/null; do
    if read -r -s -t 0.1 -n 1 key < /dev/tty 2>/dev/null; then
      case "$key" in
        $'\x14')
          CANCEL_SIGNAL="thinking"
          kill "$curl_pid" 2>/dev/null
          wait "$curl_pid" 2>/dev/null
          return 1
          ;;
        $'\x13')
          CANCEL_SIGNAL="prompt"
          kill "$curl_pid" 2>/dev/null
          wait "$curl_pid" 2>/dev/null
          return 1
          ;;
      esac
    fi
  done

  wait "$curl_pid" 2>/dev/null
  return 0
}

call_openrouter() {
  # $1 = messages JSON array. $2 = path to a file to write the raw numeric
  # HTTP status code into (nothing else — no prefix, no other output ever
  # goes there). $3 = optional path to a file to write raw response headers
  # into (used by the retry wrapper to read Retry-After on 429s). Response
  # body is printed to stdout. Deliberately does NOT use stderr for this
  # bookkeeping — stderr is shared with the spinner and warn/err logging,
  # and mixing a single-line marker into that stream is fragile (their
  # output has no reliable line breaks to split on).
  local messages="$1" code_file="$2" header_file="${3:-}" payload tmp_body tmp_headers tmp_code http_code body

  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"
  tmp_code="$(mktemp)"
  payload="$(jq -nc \
    --arg model "$CURRENT_MODEL" \
    --argjson messages "$messages" \
    '{
      model: $model,
      messages: $messages,
      temperature: 0.7,
      top_p: 1,
      stream: false
    }'
  )"

  CANCEL_SIGNAL=""
  if ! run_curl_watched "$tmp_code" \
    curl -sS \
      -o "$tmp_body" \
      -D "$tmp_headers" \
      -w '%{http_code}' \
      -X POST "$OPENROUTER_URL" \
      -H "Authorization: Bearer $OPENROUTER_KEY" \
      -H "Content-Type: application/json" \
      -H "HTTP-Referer: http://localhost" \
      -H "X-Title: Aulthium" \
      --data "$payload"
  then
    rm -f "$tmp_body" "$tmp_headers" "$tmp_code"
    printf 'CANCELLED:%s' "$CANCEL_SIGNAL" > "$code_file"
    printf ''
    return 0
  fi

  http_code="$(cat "$tmp_code" 2>/dev/null)"
  rm -f "$tmp_code"
  [[ -z "$http_code" ]] && http_code="000"

  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  if [[ -n "$header_file" ]]; then
    cp "$tmp_headers" "$header_file" 2>/dev/null || true
  fi
  rm -f "$tmp_headers"

  printf '%s' "$http_code" > "$code_file"
  printf '%s' "$body"
}

# Converts the OpenAI-style messages array (role: system/user/assistant)
# that the rest of this script builds and stores into the shape Google's
# Generative Language API expects: a top-level systemInstruction plus a
# contents[] array using role "user"/"model" instead of "user"/"assistant".
build_google_payload() {
  local messages="$1"
  jq -c '
    {
      systemInstruction: (
        (map(select(.role == "system")) | first) as $sys
        | if $sys then {parts: [{text: $sys.content}]} else null end
      ),
      contents: (
        map(select(.role != "system"))
        | map({
            role: (if .role == "assistant" then "model" else "user" end),
            parts: [{text: .content}]
          })
      ),
      generationConfig: {temperature: 0.7}
    }
    | with_entries(select(.value != null))
  ' <<< "$messages"
}

# Same contract as call_openrouter: (messages, code_file, header_file) in,
# raw response body on stdout, numeric HTTP status written to code_file.
# The response body is Google's native shape (candidates[].content...); it
# gets normalized to the OpenAI-style shape by normalize_google_response
# right before get_completion touches it, so nothing downstream needs to
# know which provider actually answered.
call_google() {
  local messages="$1" code_file="$2" header_file="${3:-}" payload tmp_body tmp_headers tmp_code http_code body url

  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"
  tmp_code="$(mktemp)"
  payload="$(build_google_payload "$messages")"
  url="${GOOGLE_API_BASE}/models/${CURRENT_MODEL}:generateContent?key=${GOOGLE_KEY}"

  CANCEL_SIGNAL=""
  if ! run_curl_watched "$tmp_code" \
    curl -sS \
      -o "$tmp_body" \
      -D "$tmp_headers" \
      -w '%{http_code}' \
      -X POST "$url" \
      -H "Content-Type: application/json" \
      --data "$payload"
  then
    rm -f "$tmp_body" "$tmp_headers" "$tmp_code"
    printf 'CANCELLED:%s' "$CANCEL_SIGNAL" > "$code_file"
    printf ''
    return 0
  fi

  http_code="$(cat "$tmp_code" 2>/dev/null)"
  rm -f "$tmp_code"
  [[ -z "$http_code" ]] && http_code="000"

  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  if [[ -n "$header_file" ]]; then
    cp "$tmp_headers" "$header_file" 2>/dev/null || true
  fi
  rm -f "$tmp_headers"

  printf '%s' "$http_code" > "$code_file"
  printf '%s' "$body"
}

# Reshapes a successful Google generateContent response into the same
# {choices:[{message:{content:...}}]} shape OpenRouter/OpenAI use, so
# get_completion's parsing stays provider-agnostic. Left untouched (passed
# through as-is) on non-200 bodies — Google's error shape is already
# {"error":{"message":...}}, which the existing error-message lookup reads
# natively.
normalize_google_response() {
  local body="$1"
  jq -c '
    {
      choices: [{
        message: {
          content: ([.candidates[0].content.parts[]?.text] | join(""))
        },
        finish_reason: (.candidates[0].finishReason // null)
      }]
    }
  ' <<< "$body" 2>/dev/null || printf '%s' "$body"
}

# Wraps call_openrouter/call_google with automatic retry-with-backoff
# specifically for HTTP 429 (rate limited) — common on OpenRouter's
# free-tier models under any real load, and on Google AI Studio's free
# quota. Dispatches to the right provider based on $PROVIDER so
# get_completion never needs to know which backend is active. Same
# contract either way: takes (messages, code_file), prints an
# OpenAI-shape body to stdout, writes the final numeric code to code_file.
# Manages its own spinner for both the request wait and the backoff wait
# between attempts.
#
# Two 429 sub-cases are handled differently:
#   - Temporary (per-minute/per-second) throttling: worth retrying. We honor
#     the server's Retry-After header when present instead of guessing, and
#     otherwise fall back to exponential backoff with jitter, capped at
#     MAX_RATE_LIMIT_WAIT seconds.
#   - Exhausted daily/monthly free-tier quota: retrying within the same
#     session cannot help (the error body says so explicitly, e.g.
#     "free-models-per-day" on OpenRouter or "quota" on Google), so we fail
#     fast with a clear message instead of burning through retries and
#     making the user wait for nothing.
MAX_RATE_LIMIT_RETRIES=6
MAX_RATE_LIMIT_WAIT=60
# Generic OpenAI-compatible /chat/completions caller, shared by every
# provider that speaks that exact request/response shape (Other/custom
# providers, Mistral, Hugging Face, NVIDIA NIM). Same contract as
# call_openrouter: raw OpenAI-shape body on stdout, numeric HTTP status (or
# "CANCELLED:...") written to code_file, response headers copied to
# header_file if given.
#
# Args:
#   $1  target_url    — full /chat/completions endpoint
#   $2  auth_header    — full "Authorization: ..." header value, or "" to
#                        send no auth header at all (self-hosted/no-key)
#   $3  model          — model id to send
#   $4  messages       — JSON array (already-encoded conversation)
#   $5  code_file
#   $6  header_file    — optional
call_openai_compatible() {
  local target_url="$1" auth_header="$2" model="$3" messages="$4"
  local code_file="$5" header_file="${6:-}"
  local payload tmp_body tmp_headers tmp_code http_code body
  local -a curl_hdrs=(-H "Content-Type: application/json")

  [[ -n "$auth_header" ]] && curl_hdrs+=(-H "$auth_header")

  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"
  tmp_code="$(mktemp)"
  payload="$(jq -nc \
    --arg model "$model" \
    --argjson messages "$messages" \
    '{
      model: $model,
      messages: $messages,
      temperature: 0.7,
      top_p: 1,
      stream: false
    }'
  )"

  CANCEL_SIGNAL=""
  if ! run_curl_watched "$tmp_code" \
    curl -sS \
      -o "$tmp_body" \
      -D "$tmp_headers" \
      -w '%{http_code}' \
      -X POST "$target_url" \
      "${curl_hdrs[@]}" \
      --data "$payload"
  then
    rm -f "$tmp_body" "$tmp_headers" "$tmp_code"
    printf 'CANCELLED:%s' "$CANCEL_SIGNAL" > "$code_file"
    printf ''
    return 0
  fi

  http_code="$(cat "$tmp_code" 2>/dev/null)"
  rm -f "$tmp_code"
  [[ -z "$http_code" ]] && http_code="000"

  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  if [[ -n "$header_file" ]]; then
    cp "$tmp_headers" "$header_file" 2>/dev/null || true
  fi
  rm -f "$tmp_headers"

  printf '%s' "$http_code" > "$code_file"
  printf '%s' "$body"
}

# Talks to whatever URL the user configured in configure_custom_provider —
# only sends an Authorization header if they said a key is required, so
# purely local/self-hosted endpoints (no auth at all) work unmodified.
call_custom() {
  local messages="$1" code_file="$2" header_file="${3:-}" auth_header=""
  if [[ "$CUSTOM_REQUIRES_KEY" -eq 1 && -n "${CUSTOM_KEY:-}" ]]; then
    auth_header="Authorization: Bearer $CUSTOM_KEY"
  fi
  call_openai_compatible "$CUSTOM_URL" "$auth_header" "$CURRENT_MODEL" "$messages" "$code_file" "$header_file"
}

call_mistral() {
  local messages="$1" code_file="$2" header_file="${3:-}"
  call_openai_compatible "$MISTRAL_URL" "Authorization: Bearer $MISTRAL_KEY" "$CURRENT_MODEL" "$messages" "$code_file" "$header_file"
}

call_huggingface() {
  local messages="$1" code_file="$2" header_file="${3:-}"
  call_openai_compatible "$HF_URL" "Authorization: Bearer $HF_KEY" "$CURRENT_MODEL" "$messages" "$code_file" "$header_file"
}

call_nvidia() {
  local messages="$1" code_file="$2" header_file="${3:-}"
  call_openai_compatible "$NVIDIA_URL" "Authorization: Bearer $NVIDIA_KEY" "$CURRENT_MODEL" "$messages" "$code_file" "$header_file"
}

call_provider_with_retry() {
  local messages="$1" code_file="$2" attempt=0 wait_secs=2 body http_code
  local header_file retry_after err_msg jitter provider_name

  header_file="$(mktemp)"

  while true; do
    start_spinner "thinking... (Ctrl+T cancel · Ctrl+S stop)"
    case "$PROVIDER" in
      google)
        body="$(call_google "$messages" "$code_file" "$header_file")"
        provider_name="Google AI Studio"
        ;;
      custom)
        body="$(call_custom "$messages" "$code_file" "$header_file")"
        provider_name="$(provider_label)"
        ;;
      mistral)
        body="$(call_mistral "$messages" "$code_file" "$header_file")"
        provider_name="Mistral"
        ;;
      huggingface)
        body="$(call_huggingface "$messages" "$code_file" "$header_file")"
        provider_name="Hugging Face"
        ;;
      nvidia_nim)
        body="$(call_nvidia "$messages" "$code_file" "$header_file")"
        provider_name="NVIDIA NIM"
        ;;
      *)
        body="$(call_openrouter "$messages" "$code_file" "$header_file")"
        provider_name="OpenRouter"
        ;;
    esac
    stop_spinner
    http_code="$(cat "$code_file" 2>/dev/null)"

    if [[ "$http_code" == CANCELLED:* ]]; then
      rm -f "$header_file"
      printf ''
      return 0
    fi

    if [[ "$http_code" != "429" ]]; then
      rm -f "$header_file"
      if [[ "$PROVIDER" == "google" && "$http_code" == "200" ]]; then
        normalize_google_response "$body"
      else
        printf '%s' "$body"
      fi
      return 0
    fi

    err_msg="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null)"
    if [[ "$err_msg" =~ per-day|per-month|daily|quota|free-models-per|RESOURCE_EXHAUSTED ]]; then
      warn "$provider_name free-tier quota exhausted: ${err_msg:-rate limit exceeded}"
      warn "Retrying won't help until the quota resets. Switch models (t> model), check billing, or wait for the reset."
      rm -f "$header_file"
      printf '%s' "$body"
      return 0
    fi

    if (( attempt >= MAX_RATE_LIMIT_RETRIES )); then
      rm -f "$header_file"
      printf '%s' "$body"
      return 0
    fi

    attempt=$((attempt + 1))

    retry_after="$(grep -i '^retry-after:' "$header_file" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [[ -n "$retry_after" ]]; then
      wait_secs="$retry_after"
    fi
    (( wait_secs > MAX_RATE_LIMIT_WAIT )) && wait_secs=$MAX_RATE_LIMIT_WAIT
    (( wait_secs < 1 )) && wait_secs=1

    jitter=$(( (RANDOM % 3) + 1 ))
    wait_secs=$(( wait_secs + jitter ))

    warn "Rate limited by $provider_name (HTTP 429). Retrying in ${wait_secs}s... ($attempt/$MAX_RATE_LIMIT_RETRIES)"
    start_spinner "rate limited, retrying in ${wait_secs}s..."
    sleep "$wait_secs"
    stop_spinner

    wait_secs=$(( wait_secs * 2 ))
  done
}

# Some free reasoning models occasionally dump their entire response into an
# internal "reasoning" field and leave message.content empty even though the
# request succeeded (finish_reason: stop). Pull that out as a fallback so we
# have something usable instead of just failing.
extract_reasoning_text() {
  local body="$1"
  jq -r '
    .choices[0].message.reasoning
    // ([.choices[0].message.reasoning_details[]?.text] | join("\n"))
    // empty
  ' <<< "$body" 2>/dev/null
}

# Runs a single completion round against the current $messages_json, with the
# existing empty-content retry and reasoning-trace fallback. Prints the reply
# text to stdout (nothing on total failure, having already printed errors).
#
# Ctrl+T ("cancel thinking") and Ctrl+S ("stop prompt") both abort the
# in-flight network call, but they mean different things afterward: Ctrl+S
# really does stop — the whole turn ends here, same as any other failure.
# Ctrl+T is lighter — the user just wants a fresh attempt right now (e.g. the
# call seems stuck), not to give up on the turn — so it loops straight back
# into another attempt instantly instead of falling through to the same
# "stop" ending. THINKING_CANCEL_LIMIT is just a sanity backstop against a
# runaway loop; a person mashing Ctrl+T that many times in a row wants Ctrl+S.
THINKING_CANCEL_LIMIT=20
get_completion() {
  local body http_code reply reasoning code_tmp cur_messages="$messages_json"
  local thinking_cancels=0 tried_empty_retry=0
  code_tmp="$(mktemp)"

  while true; do
    body="$(call_provider_with_retry "$cur_messages" "$code_tmp")"
    http_code="$(cat "$code_tmp" 2>/dev/null)"

    if [[ "$http_code" == CANCELLED:* ]]; then
      if [[ "${http_code#CANCELLED:}" == "prompt" ]]; then
        warn "Prompt stopped (Ctrl+S)."
        rm -f "$code_tmp"
        return 1
      fi
      thinking_cancels=$((thinking_cancels + 1))
      if (( thinking_cancels >= THINKING_CANCEL_LIMIT )); then
        warn "Thinking cancelled (Ctrl+T) too many times in a row — stopping instead. Use Ctrl+S to stop directly."
        rm -f "$code_tmp"
        return 1
      fi
      muted "Thinking cancelled (Ctrl+T) — retrying instantly..."
      continue
    fi

    if [[ "$http_code" != "200" ]]; then
      err "$(provider_label) request failed (HTTP $http_code)."
      if [[ -n "$body" ]]; then
        echo "$body" | jq -r '.error.message // .message // .error // empty' 2>/dev/null || true
        echo "$body" | jq '.' 2>/dev/null || echo "$body"
      fi
      rm -f "$code_tmp"
      return 1
    fi

    reply="$(jq -r '.choices[0].message.content // empty' <<< "$body" 2>/dev/null)"

    if [[ -z "$reply" && "$tried_empty_retry" -eq 0 ]]; then
      # Some free reasoning models occasionally return finish_reason: stop
      # with an empty message.content, having dumped everything into an
      # internal "reasoning" field instead. Give it one retry with an
      # explicit nudge before giving up.
      tried_empty_retry=1
      warn "Model returned no final answer. Retrying once..."
      cur_messages="$(jq -c \
        '. + [{role:"user", content:"Your previous response contained no final answer, only internal reasoning. Reply again with your actual final answer as plain text, including any action or tool blocks if applicable."}]' \
        <<< "$messages_json")"
      continue
    fi

    break
  done

  rm -f "$code_tmp"

  if [[ -n "$reply" ]]; then
    printf '%s' "$reply"
    return 0
  fi

  # Both attempts came back with empty content. Fall back to the model's
  # reasoning trace, if any, rather than showing nothing at all.
  reasoning="$(extract_reasoning_text "$body")"
  if [[ -n "$reasoning" ]]; then
    warn "This model didn't return a final answer, only its internal reasoning."
    echo "Showing that instead — treat it as a rough idea, not a finished answer:"
    printf "\n${C_DIM}${C_ACCENT}Aulthium (reasoning trace)>${C_RESET} %s\n\n" "$reasoning"
    warn "Consider switching models with 't> model' — this one struggled with this request."
    printf '%s' "$reasoning"
    return 0
  fi

  err "No reply content returned."
  echo "$body" | jq '.' 2>/dev/null || echo "$body"
  return 1
}

# Drives one user turn to completion. The model may issue read/shell tool
# calls (FILE_READ, DIR_LIST, ZIP_LIST, ZIP_READ, SHELL_RUN); when it does,
# process_agent_reply executes them and fills AGENT_TOOL_OUTPUT, which we feed
# back in as a new message so the model can use the results, looping (bounded)
# until it gives a reply with no more tool calls in it.
MAX_AGENT_ROUNDS=6
run_agent_turns() {
  local rounds=0 reply

  while (( rounds < MAX_AGENT_ROUNDS )); do
    rounds=$((rounds + 1))

    reply="$(get_completion)" || return 1
    [[ -z "$reply" ]] && return 1

    append_message "assistant" "$reply"

    AGENT_TOOL_OUTPUT=""
    AGENT_HAD_TOOL_CALLS=0
    process_agent_reply "$reply"

    if [[ "$AGENT_HAD_TOOL_CALLS" -eq 1 ]]; then
      append_message "user" "Tool results from your requests:$AGENT_TOOL_OUTPUT"$'\n\n'"Continue: give your final answer now, or issue further requests if you still need more information."
      continue
    fi

    return 0
  done

  warn "Reached the limit of $MAX_AGENT_ROUNDS tool-call rounds for this message — asking the model to wrap up."
  return 0
}

send_chat() {
  local user_text="$1"
  check_chat_limit
  append_message "user" "$user_text"
  run_agent_turns
}

command_router() {
  local input="$1"
  local cmd rest

  cmd="${input#t>}"
  cmd="${cmd# }"

  case "$cmd" in
    help)
      show_help
      ;;
    model)
      pick_model_ui
      ;;
    model\ *)
      rest="${cmd#model }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> model <name>"
      else
        set_model_by_name "$rest"
      fi
      ;;
    provider)
      pick_provider_ui
      ;;
    key)
      change_api_key
      ;;
    current)
      printf "${C_MUTED}provider:${C_RESET} %s\n" "$(provider_label)"
      printf "${C_MUTED}model:${C_RESET} %s\n" "$CURRENT_MODEL"
      ;;
    workdir)
      printf "${C_MUTED}sandbox:${C_RESET} %s\n" "$WORKSPACE_DIR"
      ;;
    workdir\ *)
      rest="${cmd#workdir }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> workdir <path>"
      elif set_workspace_dir "$rest"; then
        init_history
        say "Conversation reset so the agent knows the new sandbox path."
      fi
      ;;
    mcp)
      mcp_list_servers
      ;;
    mcp\ add\ *)
      rest="${cmd#mcp add }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      local mcp_name="${rest%% *}" mcp_url="${rest#* }"
      if [[ -z "$mcp_name" || "$mcp_name" == "$rest" || -z "$mcp_url" ]]; then
        warn "Usage: t> mcp add <name> <url>"
      else
        mcp_add_server "$mcp_name" "$mcp_url"
      fi
      ;;
    mcp\ remove\ *)
      rest="${cmd#mcp remove }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> mcp remove <name>"
      else
        mcp_remove_server "$rest"
      fi
      ;;
    mcp\ list)
      mcp_list_servers
      ;;
    mcp\ refresh)
      mcp_refresh_all
      ;;
    mcp\ refresh\ *)
      rest="${cmd#mcp refresh }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        mcp_refresh_all
      else
        mcp_refresh_server "$rest"
      fi
      ;;
    mcp\ cloudflare|mcp\ cf)
      mcp_pick_cloudflare
      ;;
    mcp\ *)
      warn "Unknown mcp subcommand. Usage: t> mcp [add <name> <url> | remove <name> | list | refresh [name] | cloudflare]"
      ;;
    memory)
      memory_status
      ;;
    memory\ connect\ *)
      rest="${cmd#memory connect }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> memory connect <file_path>"
      else
        memory_connect "$rest"
      fi
      ;;
    memory\ disconnect)
      memory_disconnect
      ;;
    memory\ *)
      warn "Unknown memory subcommand. Usage: t> memory [connect <file_path> | disconnect]"
      ;;
    confirm)
      confirm_status
      ;;
    confirm\ on)
      enable_confirmations
      ;;
    confirm\ off)
      disable_confirmations
      ;;
    confirm\ *)
      warn "Unknown confirm subcommand. Usage: t> confirm [on | off]"
      ;;
    update)
      autoupdate_status_cmd
      ;;
    update\ check)
      if ! autoupdate_available; then
        autoupdate_status_cmd
      else
        say "Checking for an update in the background — keep chatting, I'll let you know if one lands."
        autoupdate_check_async 1
      fi
      ;;
    update\ on)
      if [[ -z "$AUTOUPDATE_URL" ]]; then
        warn "Set AULTHIUM_UPDATE_URL first — there's no update source configured."
      else
        AUTOUPDATE_ENABLED=1
        ok "Auto-update enabled."
      fi
      ;;
    update\ off)
      AUTOUPDATE_ENABLED=0
      warn "Auto-update disabled for this session."
      ;;
    update\ *)
      warn "Unknown update subcommand. Usage: t> update [check | on | off]"
      ;;
    undo)
      run_undo
      ;;
    redo)
      run_redo
      ;;
    clear)
      run_clear_screen
      ;;
    reset)
      init_history
      say "Conversation reset."
      ;;
    history)
      show_history
      ;;
    exit)
      cleanup_exit
      ;;
    *)
      warn "Unknown command. Type: t> help"
      ;;
  esac
}

main() {
  clear
  banner
  check_deps
  setup_tty_for_cancel

  pick_provider_startup
  ask_api_key

  # Provider + key setup is done — wipe the "choose a provider" wizard off
  # the screen (same effect as 't> clear') before moving on to the rest of
  # startup, so what's left on screen from here reads as one clean session
  # rather than the tail end of a multi-step prompt.
  clear
  banner

  if ! init_workspace_auto; then
    err "Could not set up a sandbox workspace. Exiting."
    exit 1
  fi

  mcp_bootstrap_from_env

  init_history

  autoupdate_init
  autoupdate_check_async 0

  status_panel

  while true; do
    autoupdate_poll
    autoupdate_check_async 0

    local input=""
    if ! read -r -p "$(printf "${C_ACCENT}User>${C_RESET} ")" input; then
      cleanup_exit
    fi

    [[ -z "$input" ]] && continue

    case "$input" in
      t\>*)
        # Supports both:
        #   t> help
        #   t> model
        command_router "$input"
        ;;
      *)
        send_chat "$input"
        ;;
    esac
  done
}

main "$@"
