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
APP_VERSION="v1.0.4"
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

# Auth method per configured server, index-aligned with MCP_NAMES: "none",
# "apikey" (bearer key sitting in MCP_KEYS, same as before), or "oauth"
# (bearer key for each request is pulled live from the credential store via
# oauth_get_valid_token — see the OAUTH 2.1 CLIENT section below). Existing
# servers registered before this existed default to "apikey"/"none" so old
# behavior is untouched — see mcp_register_server.
MCP_AUTH_TYPES=()
# Credential-store id for this server's OAuth tokens ("" unless auth type is
# "oauth"). Deliberately NOT the server name itself, so a server can be
# removed and re-added under the same name without colliding with leftover
# credentials from a previous, differently-scoped connection.
MCP_OAUTH_CRED_IDS=()

# Servers can be pre-configured at launch via the MCP_SERVERS env var:
#   MCP_SERVERS="name1=https://host1/mcp,name2=https://host2/mcp"
# with an optional per-server bearer key picked up from
# MCP_<NAME>_KEY (name uppercased, non-alphanumeric chars turned into "_").
# Anything beyond that is managed at runtime with 't> mcp add/remove/list/refresh'.

# ── Credential storage (OAuth tokens, etc.) ─────────────────────────────
# See CREDENTIAL STORE section below for the implementation and its
# documented security model. Directory is created lazily (0700) on first
# use, not at startup, so a pure API-key session never touches disk.
CRED_STORE_DIR="${AULTHIUM_CRED_DIR:-$HOME/.aulthium/credentials}"
# "plain" (default: 0600-permissioned JSON files) or "encrypted" (AES-256
# via openssl, passphrase held in memory only) — see cred_store_init.
# 't> mcp cred encrypt on' switches this on for the rest of the session.
CRED_STORE_MODE="plain"
CRED_STORE_PASSPHRASE="" # session-only; never written to disk. Encrypted mode only.
CRED_STORE_INITIALIZED=0

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

# Plugins are separate, self-contained programs (not sandboxed like the
# file agent) that Aulthium can launch on request, pre-fed with the active
# provider/model/key as env vars so they can talk to the AI backend on
# their own. Installed under $PLUGINS_DIR, one subfolder per plugin, each
# with a plugin.json manifest — see BUILD_PLUGIN.md for the format writers
# of new plugins need. Overridable so a non-default HOME (or none at all)
# doesn't break plugin discovery.
PLUGINS_DIR="${AULTHIUM_PLUGINS_DIR:-$HOME/.aulthium/plugins}"

# Where hook-plugin on/off/stopped state survives across restarts (see
# plugin_hook_state_load/save and plugins_autostart below). Lives next to
# the plugins themselves so it moves with PLUGINS_DIR if that's overridden.
PLUGIN_HOOK_STATE_FILE="$PLUGINS_DIR/.hook_state.json"

# Where per-plugin permission grants survive across restarts (see
# plugin_perms_grant_load/save and plugin_confirm_permissions below). A
# grant is keyed to a fingerprint of the exact permission set approved, so
# a plugin whose declared permissions change (a bad-faith update, or just
# an honest new feature) is re-prompted instead of silently inheriting an
# old approval.
PLUGIN_PERMS_FILE="$PLUGINS_DIR/.permissions.json"

# "Built-in" plugins are no longer bundled as source inside this script,
# and their names are no longer hardcoded here either — they're discovered
# live by scanning a folder in a GitHub repo Aulthium knows the coordinates
# of (one subfolder per plugin, each installable via plugin_install_github).
# AULTHIUM_BUILTIN_PLUGINS_REPO / AULTHIUM_BUILTIN_PLUGINS_PATH let you
# point discovery at your own fork/folder instead of the upstream default;
# see BUILD_PLUGIN.md for the layout expected under that path.
BUILTIN_PLUGINS_REPO="${AULTHIUM_BUILTIN_PLUGINS_REPO:-d3stiny-io/aulthium}"
BUILTIN_PLUGINS_PATH="${AULTHIUM_BUILTIN_PLUGINS_PATH:-plugins/built-in}"

# Session-scoped cache for the discovered "name repo/path" pairs (same
# shape BUILTIN_PLUGIN_SOURCES used to be hardcoded as) so a listing or
# lookup mid-session never hits the GitHub API more than once. Populated
# lazily by builtin_plugin_sources() on first use.
# FETCHED distinguishes "not checked yet" from "checked, found nothing /
# offline" (an empty cache is a valid result of the latter).
BUILTIN_PLUGIN_SOURCES_CACHE=""
BUILTIN_PLUGIN_SOURCES_FETCHED=0

# Set by plugin_install_github right before it calls plugin_install_from_url,
# so the latter knows which repo to stamp into the installed plugin.json's
# "_source" field (for later `t> plugin update`). Empty means "not a
# GitHub-tracked install" — plugin_install_from_url clears it back to empty
# the moment it reads it, so a stale value never leaks into an unrelated call.
PLUGIN_INSTALL_SOURCE_REPO=""

# Registry for "hook" plugins — plugins whose plugin.json sets
# "mode": "hook" (e.g. better-websearch) instead of the default foreground
# one (e.g. webchat). A hook plugin doesn't take over the terminal when
# run: `t> plugin run <name>` just registers it here and hands control
# straight back to the normal "User>" prompt. It's invoked on-demand,
# per call, at whatever hook point its manifest names — see
# KNOWN_HOOK_POINTS below for the full list — instead of running
# continuously as a background process.
#
# All six arrays are keyed by plugin name and stay in lockstep — a name
# is "running" iff it has an entry in RUNNING_PLUGIN_ENABLED. Session-only,
# same as everything else here: nothing here survives a restart, so a
# hook plugin needs `t> plugin run <name>` again after one.
declare -A RUNNING_PLUGIN_ENABLED=()      # name -> "on" | "off"
declare -A RUNNING_PLUGIN_HOOK=()         # name -> hook point, e.g. "web_search"
declare -A RUNNING_PLUGIN_ENTRY=()        # name -> manifest "entry" command
declare -A RUNNING_PLUGIN_DIR=()          # name -> plugin's install dir
declare -A RUNNING_PLUGIN_TOGGLE_PREFIX=()  # name -> its "<prefix>>" shorthand, if any
declare -A RUNNING_PLUGIN_PRIORITY=()     # name -> manifest "priority" int (default 0)

# Reverse lookup for the REPL: "<prefix>>" input text -> plugin name, so
# typing e.g. "bws> on" at the main prompt is recognized without scanning
# all of RUNNING_PLUGIN_TOGGLE_PREFIX on every keystroke loop.
declare -A TOGGLE_PREFIX_TO_PLUGIN=()

# Hook points this version of Aulthium knows about. A plugin's manifest
# "hook" field must be one of these (checked by hook_point_is_known) to
# actually register, though plugin_manifest_validate only warns (not
# blocks) on install for an unrecognized one, same as it does for unknown
# permission strings — a future Aulthium version may add more points.
#   web_search  — see web_search_query_plugin_hook (built in from the start)
#   shell_exec  — see shell_exec_plugin_hook, called from handle_shell_run_action
#   file_action — see file_action_plugin_hook, called from the core single-item
#                 file mutation handlers (write/edit/create-folder/delete-file/
#                 delete-folder). NOTE: bulk write/create/delete/move, FILE_MOVE/
#                 FOLDER_MOVE, and the ZIP_CREATE/ZIP_EXTRACT actions are NOT
#                 currently routed through this hook.
#   mcp_call    — see mcp_call_plugin_hook, called from handle_mcp_call_action
#   chat_pre    — see chat_pre_plugin_hook, called from send_chat
KNOWN_HOOK_POINTS="web_search shell_exec file_action mcp_call chat_pre"

# hook_name -> name of the plugin that currently owns it. Only one plugin
# can own a given hook point at a time — see hook_claim_ownership for the
# priority-based rule used when a second plugin wants the same point.
declare -A HOOK_OWNER=()

# True (exit 0) iff $1 is one of KNOWN_HOOK_POINTS.
hook_point_is_known() {
  local h=" $KNOWN_HOOK_POINTS "
  [[ "$h" == *" $1 "* ]]
}

# Attempts to give plugin $1 ownership of hook point $2 at priority $3
# (integer; higher = stronger claim, default/undeclared is 0). If the
# point is unclaimed, or already owned by $1 itself (re-registration),
# takes it immediately. If owned by a different plugin:
#   - equal or lower incumbent priority: the incumbent is stopped
#     (plugin_stoprun) and $1 takes over, with a warning naming what
#     was replaced — this is the original "last one in wins" behavior,
#     now scoped to same-or-lower priority so a plugin that cares can
#     opt out of being casually bumped by declaring a higher "priority"
#     in its plugin.json.
#   - strictly higher incumbent priority: refuses and warns; $1 does
#     NOT take the point. Returns 1.
# Callers (plugin_run, plugins_autostart) still need to set
# RUNNING_PLUGIN_PRIORITY[$1] themselves after a successful claim.
hook_claim_ownership() {
  local name="$1" hook="$2" priority="${3:-0}" incumbent incumbent_priority
  incumbent="${HOOK_OWNER[$hook]:-}"
  if [[ -z "$incumbent" || "$incumbent" == "$name" ]]; then
    HOOK_OWNER[$hook]="$name"
    return 0
  fi
  incumbent_priority="${RUNNING_PLUGIN_PRIORITY[$incumbent]:-0}"
  if (( priority < incumbent_priority )); then
    warn "'$name' wants the $hook hook but '$incumbent' already holds it at a higher priority (${incumbent_priority} > ${priority}) — skipped."
    return 1
  fi
  warn "Replacing '$incumbent' as the active $hook hook with '$name'."
  plugin_stoprun "$incumbent"
  HOOK_OWNER[$hook]="$name"
  return 0
}

# Releases whatever hook point $1 currently owns, if any. Called from
# plugin_stoprun so a stopped plugin never leaves a dangling HOOK_OWNER
# entry pointing at a name that's no longer running.
hook_release_ownership() {
  local name="$1" hook="${RUNNING_PLUGIN_HOOK[$name]:-}"
  [[ -n "$hook" && "${HOOK_OWNER[$hook]:-}" == "$name" ]] && unset "HOOK_OWNER[$hook]"
}

# Shells out to hook plugin $1's entry command with "$2..." appended as
# individually shell-quoted arguments — the shared invocation core behind
# every specific *_plugin_hook wrapper below (web_search_query_plugin_hook
# has its own inline copy of this for historical reasons and is untouched).
# Exports the same env a foreground `t> plugin run` gets (provider/model/
# key, config overrides, secrets only if the plugin's permissions include
# "secrets") around the single call and cleans it up after, exactly like
# plugin_toggle_prefix_forward does for its "<prefix>> ..." shorthand calls.
# Prints nothing itself; leaves the plugin's stdout in PLUGIN_HOOK_OUTPUT
# and returns its exit status. Callers decide what a non-zero status means
# for their hook point — see the wrapper functions for each one's contract.
plugin_hook_call() {
  local name="$1" dir entry status _perm_list
  shift
  dir="${RUNNING_PLUGIN_DIR[$name]}"
  entry="${RUNNING_PLUGIN_ENTRY[$name]}"
  local -a quoted_args=()
  local a
  for a in "$@"; do quoted_args+=("$(printf '%q' "$a")"); done

  _perm_list="$(jq -r '.permissions // [] | join(" ")' "$dir/plugin.json" 2>/dev/null)"
  [[ " $_perm_list " == *" secrets "* ]] && PLUGIN_EXPORT_SECRETS=1 || PLUGIN_EXPORT_SECRETS=0
  plugin_export_env
  plugin_export_config_env "$name" "$dir"
  PLUGIN_HOOK_OUTPUT="$(cd "$dir" && eval "$entry" "${quoted_args[@]}" 2>/dev/null)"
  status=$?
  unset AULTHIUM_API_KEY AULTHIUM_API_URL AULTHIUM_API_KIND AULTHIUM_PROVIDER \
        AULTHIUM_PROVIDER_LABEL AULTHIUM_MODEL AULTHIUM_WORKSPACE_DIR \
        AULTHIUM_APP_NAME AULTHIUM_APP_VERSION AULTHIUM_SKIP_CONFIRMATIONS \
        AULTHIUM_MAX_RATE_LIMIT_RETRIES AULTHIUM_MAX_RATE_LIMIT_WAIT \
        AULTHIUM_SHELL_TIMEOUT_SECS
  plugin_unset_config_env
  PLUGIN_EXPORT_SECRETS=0
  return $status
}

# True (0) iff hook point $1 currently has an owner that's also toggled on
# — the common "is there actually anyone to call" guard shared by every
# *_plugin_hook wrapper below, so a hook point with no plugin, or one
# that's registered but toggled off, is indistinguishable to a call site
# from "hook not active" without each of them re-deriving it.
hook_point_is_active() {
  local name="${HOOK_OWNER[$1]:-}"
  [[ -n "$name" ]] || return 1
  [[ "${RUNNING_PLUGIN_ENABLED[$name]:-off}" == "on" ]]
}

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

To create several empty folders at once, output a block EXACTLY like this — one ITEM line per entry, and
nothing else in the block besides ITEM lines:
<<<BULK_FOLDER_CREATE>>>
<<<ITEM path="relative/folder/one">>>
<<<ITEM path="relative/folder/two">>>
<<<ITEM path="relative/folder/three">>>
<<<END_BULK_FOLDER_CREATE>>>

To delete several files and/or folders at once, output a block EXACTLY like this — one ITEM line per entry,
and nothing else in the block besides ITEM lines. You do NOT need to know or say whether each path is a
file or a folder; that's detected automatically and the right kind of removal is applied to each:
<<<BULK_DELETE>>>
<<<ITEM path="relative/path/to/old-file.txt">>>
<<<ITEM path="relative/path/to/old-folder">>>
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
ICON_PLUGIN="▶"   # plugin activity
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

  # base64 (coreutils) is required for OAuth PKCE (RFC 7636) and for
  # encoding token-store contents — without it, "t> mcp add" can still add
  # apikey/none-auth servers, but OAuth-based connections are disabled.
  HAVE_BASE64=1
  want_cmd base64 || HAVE_BASE64=0
  [[ "$HAVE_BASE64" -eq 0 ]] && warn "base64 not found — OAuth-based MCP connections will be unavailable (API-key and unauthenticated servers are unaffected)."

  # nc (netcat) is what the OAuth loopback callback listener uses to
  # receive the browser redirect. Not required — if it's missing,
  # oauth_run_flow (see oauth_callback_method) falls back to a python3
  # one-shot HTTP server instead, offering to install python first if
  # neither is present, and only drops to a manual paste-the-redirect-URL
  # prompt if that's declined or fails.
  HAVE_NC=1
  want_cmd nc || HAVE_NC=0
  [[ "$HAVE_NC" -eq 0 ]] && warn "nc (netcat) not found — OAuth logins will use a python3 fallback listener instead (installing python if needed), or ask you to paste the redirect URL manually if that's unavailable."

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

# Rejects strings that read like a sentence rather than a plausible relative
# path. Exists specifically because BULK_FOLDER_CREATE and BULK_DELETE parse
# as "one path per line, nothing else" with no <<<ITEM>>> wrapper and no
# regex on the line at all (see process_agent_reply) — every other marker
# at least requires matching a path="..." attribute inside <<<...>>> before
# a string is treated as a path. If a model ever slips ordinary prose inside
# one of those two blocks instead of sticking to bare paths (seen mostly
# from smaller/free models improvising near the edges of the format), that
# sentence — or, worse, each individual word if it gets line-wrapped one
# token per line — would otherwise sail straight through as a literal
# folder to create or a target to delete. This is deliberately loose about
# what a path can contain (spaces, dots, hyphens are all fine); it only
# filters the combination of "several words" and/or punctuation that real
# relative paths essentially never have.
looks_like_plausible_path() {
  local p="$1" wc

  case "$p" in
    *[\!\?\"\'\`\;]*) return 1 ;;
  esac

  wc=$(wc -w <<< "$p")
  (( wc > 6 )) && return 1

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

  if ! looks_like_plausible_path "$rel"; then
    err "Rejected — looks like free text, not a real path: $rel"
    return 1
  fi

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
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp add <n> <url>" "connect a remote MCP server (API key or none)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp oauth <n> <url>" "connect via OAuth 2.1 + PKCE (opens your browser)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp remove <name>" "disconnect an MCP server"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp refresh [name]" "re-discover tools (one server, or all)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp cloudflare" "quick-pick from Cloudflare's managed MCP servers"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp github" "quick-connect to GitHub's official remote MCP server"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> mcp cred ..." "encrypt on/off | clear — manage stored OAuth tokens"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin" "list installed plugins"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin run <name>" "launch a plugin (needs a y/N permissions grant)"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin run --stoprun <n>" "fully stop/de-register a running hook plugin"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin toggle <n> <s>" "turn a running hook plugin on/off without stopping it"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin info <name>" "show a plugin's manifest, effective config, and integrity"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin config <name>" "view/set/unset a plugin's local config overrides"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin verify <name>" "check installed files against the hash recorded at install"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin install <p>" "install from a folder, github:owner/repo, or a zip URL"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin update [name]" "check (and confirm) GitHub-sourced plugins for updates"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> plugin remove <name>" "delete an installed plugin (needs y/N confirmation)"
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
  printf "${C_MUTED}│${C_RESET}       ${C_RESET}t> mcp github${C_MUTED} quick-connects to GitHub's official\n"
  printf "${C_MUTED}│${C_RESET}       remote MCP server (repos, issues, PRs, Actions, ...) via\n"
  printf "${C_MUTED}│${C_RESET}       a personal access token or browser OAuth.\n"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_ACCENT2}┌─ PLUGINS ─────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_OK}${ICON_PLUGIN}${C_RESET}      plugins are separate external programs, one\n"
  printf "${C_MUTED}│${C_RESET}       per folder under %s, each\n" "$PLUGINS_DIR"
  printf "${C_MUTED}│${C_RESET}       with a plugin.json manifest. Unlike the file/search\n"
  printf "${C_MUTED}│${C_RESET}       agent, they are NOT sandboxed — launching one is a\n"
  printf "${C_MUTED}│${C_RESET}       trust decision, same tier as a shell command, and\n"
  printf "${C_MUTED}│${C_RESET}       needs a y/N confirmation.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET}       Built-in plugins aren't bundled in this script — they're\n"
  printf "${C_MUTED}│${C_RESET}       discovered live from github.com/%s\n" "$BUILTIN_PLUGINS_REPO"
  printf "${C_MUTED}│${C_RESET}       (path: %s), so what's available can\n" "$BUILTIN_PLUGINS_PATH"
  printf "${C_MUTED}│${C_RESET}       change without a script update. See ${C_RESET}t> plugin list${C_MUTED}\n"
  printf "${C_MUTED}│${C_RESET}       for the current set — ${C_RESET}t> plugin run <name>${C_MUTED} fetches\n"
  printf "${C_MUTED}│${C_RESET}       one from GitHub the first time, and\n"
  printf "${C_MUTED}│${C_RESET}       ${C_RESET}t> plugin update <name>${C_MUTED} checks for a newer release.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET}       Write your own by reading BUILD_PLUGIN.md, then\n"
  printf "${C_MUTED}│${C_RESET}       ${C_RESET}t> plugin install <folder|github:owner/repo|url>${C_MUTED}.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET}       A \"hook\" plugin (${C_RESET}\"mode\": \"hook\"${C_MUTED} in its manifest)\n"
  printf "${C_MUTED}│${C_RESET}       registers for one hook point and is invoked on-demand\n"
  printf "${C_MUTED}│${C_RESET}       instead of taking over the terminal. Known hook points:\n"
  printf "${C_MUTED}│${C_RESET}       %s\n" "$KNOWN_HOOK_POINTS"
  printf "${C_MUTED}│${C_RESET}       Only one plugin can own a given point at a time — an\n"
  printf "${C_MUTED}│${C_RESET}       optional integer ${C_RESET}\"priority\"${C_MUTED} in plugin.json (default 0)\n"
  printf "${C_MUTED}│${C_RESET}       decides who wins if two plugins want the same one.\n"
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


# If a "file_action" hook plugin is registered and toggled on, gives it a
# look at a pending file mutation before the user is even asked to confirm
# it. Entry is invoked as: <entry> file_action <action> <path>, where
# action is one of write/edit/create-folder/delete-file/delete-folder (see
# KNOWN_HOOK_POINTS comment for which call sites this does and doesn't
# cover). UNLIKE web_search's hook, a non-zero exit here is a deliberate
# VETO, not "the hook failed" — there's no built-in file-review behavior
# to fall back to, so silence/success (exit 0) is the only way to mean
# "allow". Sets FILE_ACTION_HOOK_VETO_REASON to the plugin's stdout (or a
# generic fallback if it printed nothing) when it vetoes. No hook
# registered, or one that's toggled off, always allows (returns 0) — a
# missing hook plugin should never block ordinary file actions.
file_action_plugin_hook() {
  local action="$1" path="$2" name
  hook_point_is_active "file_action" || return 0
  name="${HOOK_OWNER[file_action]}"

  if plugin_hook_call "$name" "file_action" "$action" "$path"; then
    return 0
  fi
  FILE_ACTION_HOOK_VETO_REASON="${PLUGIN_HOOK_OUTPUT:-'$name' declined this action without a reason}"
  return 1
}

handle_write_action() {
  local rel="$1" content_file="$2" abs lines parent_dir missing_dirs

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe write proposal: $rel"; return; }

  if ! file_action_plugin_hook "write" "$abs"; then
    warn "Skipped write: $rel (blocked by hook plugin — $FILE_ACTION_HOOK_VETO_REASON)"
    return
  fi

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

  if ! file_action_plugin_hook "edit" "$abs"; then
    warn "Skipped edit: $rel (blocked by hook plugin — $FILE_ACTION_HOOK_VETO_REASON)"
    return
  fi

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

  if ! file_action_plugin_hook "create-folder" "$abs"; then
    warn "Skipped folder creation: $rel (blocked by hook plugin — $FILE_ACTION_HOOK_VETO_REASON)"
    return
  fi

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

  if ! file_action_plugin_hook "delete-file" "$abs"; then
    warn "Skipped delete: $rel (blocked by hook plugin — $FILE_ACTION_HOOK_VETO_REASON)"
    return
  fi

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

  if ! file_action_plugin_hook "delete-folder" "$abs"; then
    warn "Skipped folder delete: $rel (blocked by hook plugin — $FILE_ACTION_HOOK_VETO_REASON)"
    return
  fi

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

# If a "web_search" hook plugin (e.g. better-websearch) is currently
# registered AND toggled on, shells out to its entry command with the
# query as its argument and uses whatever it prints as the result body
# instead of the built-in SearXNG/DDG chain. Returns 1 (with
# WEB_SEARCH_LAST_ERROR set) if no such plugin is active, it's toggled
# off, or it ran but failed/returned nothing — either way the caller
# (web_search_query) falls through to the normal providers, so a flaky or
# disabled hook plugin never blocks search outright.
web_search_query_plugin_hook() {
  local query="$1" name dir entry output status
  name="${HOOK_OWNER[web_search]:-}"
  [[ -n "$name" ]] || return 1
  [[ "${RUNNING_PLUGIN_ENABLED[$name]:-off}" == "on" ]] || {
    WEB_SEARCH_LAST_ERROR="hook plugin '$name' is installed but toggled off (t> plugin toggle $name on to re-enable)."
    return 1
  }

  dir="${RUNNING_PLUGIN_DIR[$name]}"
  entry="${RUNNING_PLUGIN_ENTRY[$name]}"
  # Same env a foreground plugin_run gets (provider/model/key etc) — a
  # hook plugin is invoked fresh on every call, not left running, so this
  # has to happen (and be cleaned up) around each individual call rather
  # than once at 't> plugin run' time. Secrets gating mirrors plugin_run:
  # the live API key only goes out if this plugin declared "secrets" in
  # its permissions (approved back when it was registered via t> plugin run).
  local _perm_list
  _perm_list="$(jq -r '.permissions // [] | join(" ")' "$dir/plugin.json" 2>/dev/null)"
  [[ " $_perm_list " == *" secrets "* ]] && PLUGIN_EXPORT_SECRETS=1 || PLUGIN_EXPORT_SECRETS=0
  plugin_export_env
  plugin_export_config_env "$name" "$dir"
  output="$(cd "$dir" && eval "$entry" "$(printf '%q' "$query")" 2>/dev/null)"
  status=$?
  unset AULTHIUM_API_KEY AULTHIUM_API_URL AULTHIUM_API_KIND AULTHIUM_PROVIDER \
        AULTHIUM_PROVIDER_LABEL AULTHIUM_MODEL AULTHIUM_WORKSPACE_DIR \
        AULTHIUM_APP_NAME AULTHIUM_APP_VERSION AULTHIUM_SKIP_CONFIRMATIONS \
        AULTHIUM_MAX_RATE_LIMIT_RETRIES AULTHIUM_MAX_RATE_LIMIT_WAIT \
        AULTHIUM_SHELL_TIMEOUT_SECS
  plugin_unset_config_env
  PLUGIN_EXPORT_SECRETS=0

  if [[ $status -ne 0 || -z "$output" ]]; then
    WEB_SEARCH_LAST_ERROR="hook plugin '$name' failed or returned nothing (exit $status)."
    return 1
  fi

  # Drop the plugin's own "Searching for: ..." preamble line (and the
  # blank line after it) if present — handle_web_search_action already
  # shows the query above the results box, so it'd just be repeated.
  output="$(printf '%s\n' "$output" | sed '/^Searching for: /d' | sed '/./,$!d')"

  FORMAT_SEARCH_RESULT="SEARCH RESULTS (via plugin '$name')"$'\n\n'"$output"
  return 0
}

# Dispatcher: the active "web_search" hook plugin (if any) gets first
# shot, then SearXNG #1 -> #2 -> #3, falling through to DuckDuckGo Lite
# only if all of those are unreachable/blocked/unparsable/inactive. DDG
# Lite is skipped outright while it's in cooldown (ddg_in_cooldown / the
# check inside web_search_query_scrape_ddglite) rather than being
# retried. Stops at the first source that returns real results; if every
# source fails, WEB_SEARCH_LAST_ERROR is set to a combined summary of why.
web_search_query() {
  local query="$1"
  local -a errs=()
  local instance

  if web_search_query_plugin_hook "$query"; then
    return 0
  fi
  [[ -n "${WEB_SEARCH_LAST_ERROR:-}" ]] && errs+=("$WEB_SEARCH_LAST_ERROR")

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
# Resolves the bearer token to actually send for server index $1, whatever
# its auth type: a static key for "apikey"/"none" (unchanged from before
# OAuth existed), or a live, auto-refreshed access token pulled from the
# credential store for "oauth". Returns 2 (distinct from 1/"no token") when
# an oauth server's token is unrecoverably expired, so callers can tell the
# user to reconnect rather than just report a generic auth failure.
mcp_resolve_key() {
  local idx="$1" auth_type="${MCP_AUTH_TYPES[$idx]:-apikey}" tok rc
  if [[ "$auth_type" == "oauth" ]]; then
    tok="$(oauth_get_valid_token "${MCP_OAUTH_CRED_IDS[$idx]}")"; rc=$?
    if [[ $rc -eq 2 ]]; then
      warn "OAuth session for \"${MCP_NAMES[$idx]}\" has expired and can't be refreshed — run: t> mcp oauth ${MCP_NAMES[$idx]} ${MCP_URLS[$idx]}"
      return 1
    fi
    [[ $rc -ne 0 ]] && return 1
    printf '%s' "$tok"
    return 0
  fi
  printf '%s' "${MCP_KEYS[$idx]}"
  return 0
}

mcp_connect_server() {
  local idx="$1" name url key params tools count negotiated
  name="${MCP_NAMES[$idx]}"
  url="${MCP_URLS[$idx]}"
  key="$(mcp_resolve_key "$idx")" || key=""

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
# bootstrap, the Cloudflare quick-pick below, and now t> mcp oauth), so
# they can't drift out of sync with each other. auth_type/oauth_cred_id
# default to the pre-OAuth "apikey"/"" shape so every existing call site
# above keeps working unchanged. Returns mcp_connect_server's status.
mcp_register_server() {
  local name="$1" url="$2" key="$3" auth_type="${4:-apikey}" oauth_cred_id="${5:-}" idx
  [[ -z "$key" && "$auth_type" == "apikey" ]] && auth_type="none"
  idx="${#MCP_NAMES[@]}"
  MCP_NAMES[$idx]="$name"
  MCP_URLS[$idx]="$url"
  MCP_KEYS[$idx]="$key"
  MCP_SESSION_IDS[$idx]=""
  MCP_PROTO_VERSIONS[$idx]=""
  MCP_TOOLS_JSON[$idx]="[]"
  MCP_AUTH_TYPES[$idx]="$auth_type"
  MCP_OAUTH_CRED_IDS[$idx]="$oauth_cred_id"
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

# 't> mcp oauth <name> <url>' — same shape as 't> mcp add' but authenticates
# via the generic OAuth 2.1 + PKCE flow (oauth_run_flow) instead of a
# static bearer key. The resulting tokens are stored under a fresh
# credential id (not the server name — see MCP_OAUTH_CRED_IDS comment)
# so removing and re-adding the server never collides with a stale token.
mcp_add_server_oauth() {
  local name="$1" url="$2" cred_id token_json
  if [[ -z "$name" || -z "$url" ]]; then
    warn "Usage: t> mcp oauth <name> <url>"
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
  if [[ "${HAVE_BASE64:-1}" -eq 0 ]]; then
    err "OAuth requires base64 (coreutils), which isn't installed."
    return 1
  fi

  token_json="$(oauth_run_flow "$url" "$name")"
  if [[ -z "$token_json" ]]; then
    err "OAuth connection to \"$name\" failed: ${OAUTH_FLOW_ERROR:-unknown error}"
    return 1
  fi

  cred_id="oauth-${name}-$(date +%s)-$$"
  if ! cred_save "$cred_id" "$token_json"; then
    err "Got a token for \"$name\" but couldn't save it to the credential store — aborting rather than run session-only."
    return 1
  fi

  if mcp_register_server "$name" "$url" "" "oauth" "$cred_id"; then
    init_history
    say "Conversation reset so the agent can see the new MCP tools."
  else
    cred_delete "$cred_id"
  fi
}

mcp_remove_server() {
  local name="$1" idx cred_id
  idx="$(mcp_find_index "$name")" || { warn "No MCP server named \"$name\" configured."; return 1; }

  cred_id="${MCP_OAUTH_CRED_IDS[$idx]:-}"
  [[ -n "$cred_id" ]] && cred_delete "$cred_id"

  MCP_NAMES=("${MCP_NAMES[@]:0:$idx}" "${MCP_NAMES[@]:$((idx+1))}")
  MCP_URLS=("${MCP_URLS[@]:0:$idx}" "${MCP_URLS[@]:$((idx+1))}")
  MCP_KEYS=("${MCP_KEYS[@]:0:$idx}" "${MCP_KEYS[@]:$((idx+1))}")
  MCP_SESSION_IDS=("${MCP_SESSION_IDS[@]:0:$idx}" "${MCP_SESSION_IDS[@]:$((idx+1))}")
  MCP_PROTO_VERSIONS=("${MCP_PROTO_VERSIONS[@]:0:$idx}" "${MCP_PROTO_VERSIONS[@]:$((idx+1))}")
  MCP_TOOLS_JSON=("${MCP_TOOLS_JSON[@]:0:$idx}" "${MCP_TOOLS_JSON[@]:$((idx+1))}")
  MCP_AUTH_TYPES=("${MCP_AUTH_TYPES[@]:0:$idx}" "${MCP_AUTH_TYPES[@]:$((idx+1))}")
  MCP_OAUTH_CRED_IDS=("${MCP_OAUTH_CRED_IDS[@]:0:$idx}" "${MCP_OAUTH_CRED_IDS[@]:$((idx+1))}")

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
    auth="${MCP_AUTH_TYPES[$i]:-apikey}"
    count="$(jq 'length' <<< "${MCP_TOOLS_JSON[$i]:-[]}" 2>/dev/null || echo 0)"
    box_line "${C_BOLD}$name${C_RESET} -> $url ${C_MUTED}($count tool(s), auth: $auth)${C_RESET}"
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
# CREDENTIAL STORE
#
# A small save/get/delete/exists/clear abstraction over disk storage for
# OAuth tokens (and anything else worth persisting between runs — this app
# was memory-only before now; OAuth is the first thing that actually needs
# to survive a restart, since re-doing a full browser authorization every
# launch would make OAuth-based MCP servers unusable in practice).
#
# SECURITY MODEL — read this before assuming more than it provides:
#
#   There is no portable, dependency-free OS keychain this script can rely
#   on across both plain Linux and Termux. Termux apps do NOT have access
#   to the Android Keystore from a shell context (that requires a signed
#   Android app with JNI/AndroidKeyStore API calls — not reachable from
#   bash/curl/jq), and there's no equivalent of macOS Keychain or the
#   Secret Service (org.freedesktop.secrets, used by gnome-keyring/KWallet)
#   guaranteed to be present. So:
#
#   - "plain" mode (default): each credential is one JSON file under
#     CRED_STORE_DIR, chmod 600, in a chmod 700 directory. On Termux this
#     directory lives inside the app's private storage
#     (/data/data/com.termux/files/home/...), which other Android apps
#     cannot read without root — the OS sandbox is doing the real work
#     there, not this script. On a shared multi-user Linux box, 600/700
#     permissions stop other unprivileged users from reading it. What this
#     does NOT protect against: another process running as the same user,
#     root, a full disk/backup image, or a device-unlock bypass. This is
#     the same tier of protection tools like `gh` and `gcloud` fall back to
#     when no OS keychain is available.
#
#   - "encrypted" mode (opt-in, 't> mcp cred encrypt on', requires
#     openssl): the same JSON is instead stored AES-256-CBC-encrypted
#     (PBKDF2, 200k iterations, random salt) under a passphrase that is
#     ONLY ever held in memory for the running session — never written to
#     disk, never logged. You will be re-prompted for it every new session
#     before any OAuth-authenticated MCP server can be used. This raises
#     the bar to "attacker needs the passphrase too", at the cost of typing
#     it in each time you restart Aulthium.
#
#   Whichever mode is active, secrets are never written to: application
#   logs, terminal output, error messages, debug output, git repositories,
#   the generated system prompt, or anywhere else the model or a
#   subsequent `git add .` could pick them up. Grep this file for
#   `cred_save` call sites if you want to audit that claim yourself.
########################################################################

# Lazily creates CRED_STORE_DIR (0700) the first time it's actually needed,
# and — if AULTHIUM_CRED_ENCRYPT=1 was set before launch, or the user
# already flipped CRED_STORE_MODE this session — makes sure openssl is
# actually available before promising encrypted storage. Falls back to
# "plain" with a warning rather than silently pretending to encrypt.
cred_store_init() {
  [[ "$CRED_STORE_INITIALIZED" -eq 1 ]] && return 0
  mkdir -p -m 700 "$CRED_STORE_DIR" 2>/dev/null || {
    err "Could not create credential store directory: $CRED_STORE_DIR"
    return 1
  }
  chmod 700 "$CRED_STORE_DIR" 2>/dev/null

  if [[ "${AULTHIUM_CRED_ENCRYPT:-0}" == "1" && "$CRED_STORE_MODE" == "plain" ]]; then
    CRED_STORE_MODE="encrypted"
  fi
  if [[ "$CRED_STORE_MODE" == "encrypted" ]] && ! command -v openssl >/dev/null 2>&1; then
    warn "Encrypted credential storage requested but openssl isn't installed — falling back to permission-restricted plaintext storage."
    CRED_STORE_MODE="plain"
  fi
  CRED_STORE_INITIALIZED=1
  return 0
}

# Prompts once per session (cached in memory only) for the passphrase used
# by encrypted mode. Confirms on first-ever use (no existing files yet) so
# a typo doesn't lock the user out of their own tokens moments later.
cred_ensure_passphrase() {
  [[ "$CRED_STORE_MODE" != "encrypted" ]] && return 0
  [[ -n "$CRED_STORE_PASSPHRASE" ]] && return 0
  local p1 p2 has_existing=0
  compgen -G "$CRED_STORE_DIR/*.cred" >/dev/null 2>&1 && has_existing=1

  read -r -s -p "Credential store passphrase: " p1; echo
  if [[ "$has_existing" -eq 0 ]]; then
    read -r -s -p "Confirm passphrase: " p2; echo
    if [[ "$p1" != "$p2" ]]; then
      err "Passphrases did not match."
      return 1
    fi
  fi
  if [[ -z "$p1" ]]; then
    err "Passphrase cannot be empty in encrypted mode."
    return 1
  fi
  CRED_STORE_PASSPHRASE="$p1"
  return 0
}

# Turns a credential id into a safe filename — ids come from this script
# (server names, oauth-<random>), never raw user text, but this keeps
# path traversal structurally impossible regardless.
cred_store_path() {
  local id="$1" safe
  safe="$(printf '%s' "$id" | tr -c 'A-Za-z0-9_.-' '_')"
  printf '%s/%s.cred' "$CRED_STORE_DIR" "$safe"
}

# cred_save <id> <json>  — writes (overwriting) the credential for <id>.
cred_save() {
  local id="$1" json="$2" path
  cred_store_init || return 1
  path="$(cred_store_path "$id")"
  if [[ "$CRED_STORE_MODE" == "encrypted" ]]; then
    cred_ensure_passphrase || return 1
    if ! printf '%s' "$json" | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
         -pass "pass:$CRED_STORE_PASSPHRASE" -out "$path" 2>/dev/null; then
      err "Failed to write encrypted credential for \"$id\"."
      return 1
    fi
  else
    printf '%s' "$json" > "$path" 2>/dev/null || {
      err "Failed to write credential for \"$id\"."
      return 1
    }
  fi
  chmod 600 "$path" 2>/dev/null
  return 0
}

# cred_get <id>  — prints the stored JSON on stdout, returns 1 if missing
# or (encrypted mode) the passphrase was wrong.
cred_get() {
  local id="$1" path
  cred_store_init || return 1
  path="$(cred_store_path "$id")"
  [[ -f "$path" ]] || return 1
  if [[ "$CRED_STORE_MODE" == "encrypted" ]]; then
    cred_ensure_passphrase || return 1
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
      -pass "pass:$CRED_STORE_PASSPHRASE" -in "$path" 2>/dev/null || {
      err "Could not decrypt credential for \"$id\" — wrong passphrase?"
      return 1
    }
  else
    cat "$path" 2>/dev/null
  fi
  return 0
}

cred_exists() {
  local path
  path="$(cred_store_path "$1")"
  [[ -f "$path" ]]
}

cred_delete() {
  local path
  path="$(cred_store_path "$1")"
  [[ -f "$path" ]] || return 0
  rm -f "$path" 2>/dev/null
}

# Wipes every stored credential — 't> mcp cred clear', confirmed by the
# caller before this runs.
cred_clear() {
  [[ -d "$CRED_STORE_DIR" ]] || return 0
  find "$CRED_STORE_DIR" -maxdepth 1 -name '*.cred' -type f -exec rm -f {} + 2>/dev/null
}

########################################################################
# OAUTH 2.1 CLIENT (generic — not GitHub/Cloudflare/Notion-specific)
#
# Implements the MCP authorization spec's flow for any compliant remote
# MCP server: Protected Resource Metadata discovery (RFC 9728) ->
# Authorization Server Metadata discovery (RFC 8414, with an OIDC
# discovery fallback) -> Dynamic Client Registration (RFC 7591, when the
# server offers a registration_endpoint and we don't have a client_id for
# it yet) -> PKCE authorization-code flow (RFC 7636) -> token exchange ->
# refresh. No provider ever needs special-cased auth code here — a
# "preset" is just a name + URL that gets fed into this same pipeline (see
# the small preset registry further below).
#
# Every function below is provider-agnostic. GitHub/Cloudflare-specific
# knowledge, where it exists at all, lives only in the preset table, never
# in this section.
########################################################################

# ── PKCE / random primitives (RFC 7636) ─────────────────────────────────
# Uses only coreutils already required elsewhere in this script
# (sha256sum, base64, tr) — no python/openssl dependency for the crypto
# primitives themselves, matching the rest of Aulthium's minimal-deps
# philosophy. openssl is only pulled in, optionally, for encrypted
# credential storage above.

# Base64url-encodes raw stdin (strips padding, swaps +/ for -_).
oauth_b64url_encode() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}

# n random bytes, base64url-encoded. Used for code_verifier and state.
oauth_random_b64url() {
  local nbytes="$1"
  head -c "$nbytes" /dev/urandom | oauth_b64url_encode
}

# RFC 7636 code_verifier: 43-128 chars from [A-Za-z0-9-._~]. 32 random
# bytes -> 43 base64url chars, right at the low end of the allowed range
# but comfortably high-entropy (256 bits).
oauth_gen_code_verifier() {
  oauth_random_b64url 32
}

# CSRF state token / PKCE-adjacent nonce.
oauth_gen_state() {
  oauth_random_b64url 24
}

# S256 code_challenge = base64url(sha256(code_verifier)). sha256sum only
# gives a hex digest, so this hand-converts hex -> raw bytes via printf's
# %b (backslash-escape interpretation) rather than pulling in xxd/openssl,
# then base64url-encodes those raw bytes.
oauth_code_challenge_s256() {
  local verifier="$1" hex esc i
  hex="$(printf '%s' "$verifier" | sha256sum | awk '{print $1}')"
  esc=""
  for (( i = 0; i < ${#hex}; i += 2 )); do
    esc+="\\x${hex:i:2}"
  done
  printf '%b' "$esc" | oauth_b64url_encode
}

# ── HTTP helpers ─────────────────────────────────────────────────────────
# Plain GET/POST with response body + HTTP status captured separately, and
# HTTPS enforced (see oauth_require_https) — used for every discovery,
# registration, and token-endpoint call below. Deliberately does NOT
# reuse mcp_http_post, which is shaped around JSON-RPC framing and
# MCP-specific headers (Mcp-Session-Id, MCP-Protocol-Version) that don't
# apply to plain OAuth/OIDC metadata and token endpoints.
OAUTH_HTTP_BODY=""
OAUTH_HTTP_CODE=""

oauth_require_https() {
  # http://localhost / http://127.0.0.1 is the one well-known exception
  # (RFC 8252 loopback interactive clients) — needed for the callback URI
  # we hand servers, and for testing against a local dev MCP server.
  case "$1" in
    https://*) return 0 ;;
    http://localhost*|http://127.0.0.1*) return 0 ;;
    *) return 1 ;;
  esac
}

oauth_http_get() {
  local url="$1" headers_tmp body_tmp code
  oauth_require_https "$url" || { OAUTH_HTTP_BODY=""; OAUTH_HTTP_CODE="000"; return 1; }
  headers_tmp="$(mktemp)"; body_tmp="$(mktemp)"
  code="$(curl -sS --connect-timeout 8 --max-time 20 \
            -D "$headers_tmp" -o "$body_tmp" -w '%{http_code}' \
            -H "Accept: application/json" "$url" 2>/dev/null)"
  OAUTH_HTTP_CODE="${code:-000}"
  OAUTH_HTTP_BODY="$(cat "$body_tmp" 2>/dev/null)"
  rm -f "$headers_tmp" "$body_tmp"
  [[ "$OAUTH_HTTP_CODE" == 2* ]]
}

# form-encoded POST (every OAuth token/registration endpoint expects this,
# per RFC 6749, except DCR which is JSON per RFC 7591 — see
# oauth_http_post_json below for that one).
oauth_http_post_form() {
  local url="$1"; shift
  local headers_tmp body_tmp code data=()
  oauth_require_https "$url" || { OAUTH_HTTP_BODY=""; OAUTH_HTTP_CODE="000"; return 1; }
  headers_tmp="$(mktemp)"; body_tmp="$(mktemp)"
  while [[ $# -gt 0 ]]; do data+=(--data-urlencode "$1"); shift; done
  code="$(curl -sS --connect-timeout 8 --max-time 20 \
            -D "$headers_tmp" -o "$body_tmp" -w '%{http_code}' \
            -H "Accept: application/json" \
            -X POST "$url" "${data[@]}" 2>/dev/null)"
  OAUTH_HTTP_CODE="${code:-000}"
  OAUTH_HTTP_BODY="$(cat "$body_tmp" 2>/dev/null)"
  rm -f "$headers_tmp" "$body_tmp"
  [[ "$OAUTH_HTTP_CODE" == 2* ]]
}

oauth_http_post_json() {
  local url="$1" json="$2" headers_tmp body_tmp code
  oauth_require_https "$url" || { OAUTH_HTTP_BODY=""; OAUTH_HTTP_CODE="000"; return 1; }
  headers_tmp="$(mktemp)"; body_tmp="$(mktemp)"
  code="$(curl -sS --connect-timeout 8 --max-time 20 \
            -D "$headers_tmp" -o "$body_tmp" -w '%{http_code}' \
            -H "Content-Type: application/json" -H "Accept: application/json" \
            -X POST "$url" --data-binary "$json" 2>/dev/null)"
  OAUTH_HTTP_CODE="${code:-000}"
  OAUTH_HTTP_BODY="$(cat "$body_tmp" 2>/dev/null)"
  rm -f "$headers_tmp" "$body_tmp"
  [[ "$OAUTH_HTTP_CODE" == 2* ]]
}

# ── Discovery (RFC 9728 + RFC 8414, with a same-origin well-known fallback) ──
# Sets: OAUTH_AUTHZ_ENDPOINT, OAUTH_TOKEN_ENDPOINT,
#       OAUTH_REGISTRATION_ENDPOINT (may be empty — not every server
#       supports DCR), OAUTH_SCOPES (space-separated, may be empty).
OAUTH_AUTHZ_ENDPOINT=""
OAUTH_TOKEN_ENDPOINT=""
OAUTH_REGISTRATION_ENDPOINT=""
OAUTH_SCOPES=""

# origin (scheme://host[:port]) of a URL, no path.
oauth_origin_of() {
  printf '%s' "$1" | sed -E 's#^(https?://[^/]+).*#\1#'
}

# Step 1 (RFC 9728): find the Protected Resource Metadata document for the
# MCP server itself. Compliant servers advertise it via a WWW-Authenticate
# header on an unauthenticated 401; this hits the MCP endpoint directly
# first (cheapest, most spec-correct) and falls back to the same-origin
# well-known path if that doesn't turn one up.
# Prints the authorization_server base URL on stdout, or nothing.
oauth_discover_resource_metadata() {
  local mcp_url="$1" origin resource_meta_url www_auth headers_tmp probe_body
  origin="$(oauth_origin_of "$mcp_url")"

  headers_tmp="$(mktemp)"
  curl -sS --connect-timeout 8 --max-time 15 -D "$headers_tmp" -o /dev/null \
       -X POST "$mcp_url" -H "Content-Type: application/json" \
       -H "Accept: application/json, text/event-stream" \
       --data-binary '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
       2>/dev/null >/dev/null
  www_auth="$(grep -i '^WWW-Authenticate:' "$headers_tmp" 2>/dev/null | tail -n1)"
  rm -f "$headers_tmp"

  resource_meta_url="$(printf '%s' "$www_auth" | grep -oE 'resource_metadata="[^"]+"' | sed -E 's/resource_metadata="([^"]+)"/\1/')"
  [[ -z "$resource_meta_url" ]] && resource_meta_url="$origin/.well-known/oauth-protected-resource"

  if oauth_http_get "$resource_meta_url" && jq -e . >/dev/null 2>&1 <<< "$OAUTH_HTTP_BODY"; then
    jq -r '.authorization_servers[0] // empty' <<< "$OAUTH_HTTP_BODY" 2>/dev/null
    return 0
  fi
  return 1
}

# Step 2 (RFC 8414, OIDC-discovery fallback): fetch authorization server
# metadata for $1 (an authorization-server base URL). Populates the
# OAUTH_*_ENDPOINT / OAUTH_SCOPES globals above.
oauth_discover_as_metadata() {
  local as_base="$1" meta_url
  for meta_url in \
      "$as_base/.well-known/oauth-authorization-server" \
      "$as_base/.well-known/openid-configuration"; do
    if oauth_http_get "$meta_url" && jq -e . >/dev/null 2>&1 <<< "$OAUTH_HTTP_BODY"; then
      OAUTH_AUTHZ_ENDPOINT="$(jq -r '.authorization_endpoint // empty' <<< "$OAUTH_HTTP_BODY")"
      OAUTH_TOKEN_ENDPOINT="$(jq -r '.token_endpoint // empty' <<< "$OAUTH_HTTP_BODY")"
      OAUTH_REGISTRATION_ENDPOINT="$(jq -r '.registration_endpoint // empty' <<< "$OAUTH_HTTP_BODY")"
      OAUTH_SCOPES="$(jq -r '(.scopes_supported // []) | join(" ")' <<< "$OAUTH_HTTP_BODY")"
      if [[ -n "$OAUTH_AUTHZ_ENDPOINT" && -n "$OAUTH_TOKEN_ENDPOINT" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# Full discovery for MCP server URL $1. Returns 0 and populates the
# OAUTH_* globals on success.
oauth_discover() {
  local mcp_url="$1" as_base
  OAUTH_AUTHZ_ENDPOINT=""; OAUTH_TOKEN_ENDPOINT=""; OAUTH_REGISTRATION_ENDPOINT=""; OAUTH_SCOPES=""
  as_base="$(oauth_discover_resource_metadata "$mcp_url")"
  [[ -z "$as_base" ]] && as_base="$(oauth_origin_of "$mcp_url")"
  oauth_discover_as_metadata "$as_base"
}

# ── Dynamic Client Registration (RFC 7591) ──────────────────────────────
# Registers Aulthium as a public OAuth client with the authorization
# server if it offers a registration_endpoint and we don't already have a
# client_id cached for it. Sets OAUTH_CLIENT_ID (and OAUTH_CLIENT_SECRET,
# usually empty for a public/native client using PKCE).
OAUTH_CLIENT_ID=""
OAUTH_CLIENT_SECRET=""

oauth_dynamic_register() {
  local registration_endpoint="$1" redirect_uri="$2" req
  [[ -z "$registration_endpoint" ]] && return 1
  req="$(jq -nc --arg name "Aulthium" --arg uri "$redirect_uri" \
    '{client_name:$name, redirect_uris:[$uri], grant_types:["authorization_code","refresh_token"], response_types:["code"], token_endpoint_auth_method:"none"}')"
  if oauth_http_post_json "$registration_endpoint" "$req" && jq -e . >/dev/null 2>&1 <<< "$OAUTH_HTTP_BODY"; then
    OAUTH_CLIENT_ID="$(jq -r '.client_id // empty' <<< "$OAUTH_HTTP_BODY")"
    OAUTH_CLIENT_SECRET="$(jq -r '.client_secret // empty' <<< "$OAUTH_HTTP_BODY")"
    [[ -n "$OAUTH_CLIENT_ID" ]]
    return $?
  fi
  return 1
}

# ── Browser launch (cross-platform, Termux included) ────────────────────
# Tries every opener this script might plausibly be running under, in
# order, and falls through to printing the URL for manual copy/paste if
# none work headlessly — that fallback is what keeps this from ever
# hard-failing the flow just because no opener was found.
oauth_open_browser() {
  local url="$1"
  if command -v termux-open-url >/dev/null 2>&1; then
    termux-open-url "$url" >/dev/null 2>&1 && return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 & disown 2>/dev/null; return 0
  fi
  if command -v open >/dev/null 2>&1; then
    open "$url" >/dev/null 2>&1 & disown 2>/dev/null; return 0
  fi
  if command -v am >/dev/null 2>&1; then
    # Bare Termux without termux-api installed still usually has Android's
    # `am` (activity manager) on PATH.
    am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1 && return 0
  fi
  return 1
}

# ── Loopback OAuth callback (RFC 8252 §7.3) ──────────────────────────────
# Android/Termux note: this is NOT desktop-only despite appearances. The
# system browser and Termux both run on the same device/network
# namespace, and mobile browsers (Chrome included) treat http://127.0.0.1
# as a secure-context exception the same way desktop browsers do — so a
# loopback redirect genuinely round-trips through the Termux app back to
# this listener on real Android devices, not just on a desktop OS. This is
# the same technique termux-api-free tools like `gh auth login` rely on.
#
# It still needs a raw TCP listener, which this script gets from `nc`
# (netcat) rather than bash's /dev/tcp (which can only make outbound
# connections, not listen) — `nc` is common but not universal, especially
# on a minimal Termux install, so oauth_run_flow falls back to a manual
# paste-the-redirect-URL prompt (oauth_manual_callback) whenever `nc`
# isn't available or the listener doesn't receive a hit in time.
#
# Sets OAUTH_CALLBACK_CODE / OAUTH_CALLBACK_STATE / OAUTH_CALLBACK_ERROR.
OAUTH_CALLBACK_CODE=""
OAUTH_CALLBACK_STATE=""
OAUTH_CALLBACK_ERROR=""

# Picks a local port to listen on. No fixed port is reserved system-wide,
# so this just tries a small fixed pool and takes the first one `nc` can
# actually bind — good enough for a short-lived, one-shot listener.
oauth_pick_callback_port() {
  local p
  for p in 8765 8766 8964 9876 43219; do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
      printf '%s' "$p"
      return 0
    fi
    exec 3<&- 2>/dev/null; exec 3>&- 2>/dev/null
  done
  printf '%s' 8765 # give up gracefully; caller will just see it fail to bind
}

oauth_have_callback_listener() {
  command -v nc >/dev/null 2>&1
}

# Python fallback for the loopback listener, used when `nc` isn't
# installed. Requires python3 specifically — the listener script below
# uses the py3-only http.server/socketserver modules, so a bare `python`
# that turns out to be python2 is deliberately not accepted here rather
# than risking a cryptic traceback mid-OAuth-flow. Checked live (not
# cached) so a python install triggered moments ago by
# oauth_offer_install_python is picked up immediately without
# restarting Aulthium.
oauth_python_bin() {
  if command -v python3 >/dev/null 2>&1; then
    printf 'python3'
  elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
    printf 'python'
  fi
}

oauth_have_python() {
  [[ -n "$(oauth_python_bin)" ]]
}

# Which mechanism (if any) can receive the browser's loopback redirect
# right now: "nc" (preferred — lightest weight), "python" (fallback), or
# "" if neither is available and oauth_run_flow should fall back to the
# manual paste-the-redirect-URL prompt instead.
oauth_callback_method() {
  if oauth_have_callback_listener; then
    printf 'nc'
  elif oauth_have_python; then
    printf 'python'
  else
    printf ''
  fi
}

# Neither `nc` nor python found — before giving up on the automatic
# callback path and falling back to manual paste, offer to install
# python (it's far more commonly packaged than an OAuth-capable nc, and
# a one-shot HTTP server is easy to write portably in it). Always asks
# first via confirm_yes_no; never installs anything silently. Detects
# whichever package manager is actually on this box; if none is
# recognized, or the user declines, or the install fails, this just
# returns 1 and oauth_run_flow proceeds to the manual fallback exactly
# as it did before this existed — the automatic path is a bonus, never
# a requirement.
oauth_offer_install_python() {
  local mgr=""
  if command -v pkg >/dev/null 2>&1 && [[ -n "${PREFIX:-}" || -d "/data/data/com.termux" ]]; then
    mgr="pkg"
  elif command -v apt-get >/dev/null 2>&1; then
    mgr="apt-get"
  elif command -v dnf >/dev/null 2>&1; then
    mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then
    mgr="yum"
  elif command -v apk >/dev/null 2>&1; then
    mgr="apk"
  elif command -v pacman >/dev/null 2>&1; then
    mgr="pacman"
  elif command -v brew >/dev/null 2>&1; then
    mgr="brew"
  fi

  if [[ -z "$mgr" ]]; then
    warn "Python isn't installed and no supported package manager was found to install it automatically — falling back to manual redirect entry."
    return 1
  fi

  if ! confirm_yes_no "Python isn't installed. Installing it lets this OAuth login complete automatically instead of pasting a redirect URL by hand — install it now?"; then
    return 1
  fi

  local sudo_cmd=""
  if [[ "$mgr" != "pkg" && "$mgr" != "brew" && "$(id -u 2>/dev/null)" != "0" ]] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi

  say "Installing python..."
  case "$mgr" in
    pkg)      pkg install -y python >/dev/null 2>&1 ;;
    apt-get)  $sudo_cmd apt-get update -y >/dev/null 2>&1; $sudo_cmd apt-get install -y python3 >/dev/null 2>&1 ;;
    dnf)      $sudo_cmd dnf install -y python3 >/dev/null 2>&1 ;;
    yum)      $sudo_cmd yum install -y python3 >/dev/null 2>&1 ;;
    apk)      $sudo_cmd apk add --no-cache python3 >/dev/null 2>&1 ;;
    pacman)   $sudo_cmd pacman -Sy --noconfirm python >/dev/null 2>&1 ;;
    brew)     brew install python3 >/dev/null 2>&1 ;;
  esac

  if oauth_have_python; then
    ok "Python installed."
    return 0
  fi
  warn "Python install failed — falling back to manual redirect entry."
  return 1
}

# Blocks (up to $2 seconds) for exactly one HTTP GET on 127.0.0.1:$1,
# parses ?code=&state= (or an error=) off the request line, and writes a
# minimal human-readable HTML response before closing the connection.
oauth_run_callback_listener() {
  local port="$1" timeout="${2:-180}" req request_line query
  OAUTH_CALLBACK_CODE=""; OAUTH_CALLBACK_STATE=""; OAUTH_CALLBACK_ERROR=""

  local resp_ok='HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body><h2>Aulthium: authorization received.</h2><p>You can close this tab and return to the terminal.</p></body></html>'
  local resp_err='HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html><body><h2>Aulthium: authorization was not completed.</h2><p>You can close this tab and return to the terminal.</p></body></html>'

  request_line="$( { printf '%b' "$resp_ok" | timeout "${timeout}"s nc -l -q1 127.0.0.1 "$port" 2>/dev/null || true; } | head -n1 | tr -d '\r' )"
  [[ -z "$request_line" ]] && { OAUTH_CALLBACK_ERROR="Timed out waiting for the browser redirect."; return 1; }

  query="$(printf '%s' "$request_line" | awk '{print $2}')"
  query="${query#*\?}"
  [[ "$query" == "$request_line"* ]] && query=""

  OAUTH_CALLBACK_CODE="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="code"{print $2; exit}')"
  OAUTH_CALLBACK_STATE="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="state"{print $2; exit}')"
  local err_param
  err_param="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="error"{print $2; exit}')"
  if [[ -n "$err_param" ]]; then
    OAUTH_CALLBACK_ERROR="$(printf '%s' "$err_param" | sed 's/+/ /g')"
    return 1
  fi
  [[ -z "$OAUTH_CALLBACK_CODE" ]] && { OAUTH_CALLBACK_ERROR="No authorization code in the callback."; return 1; }
  return 0
}

# Fallback when no loopback listener is usable: ask the user to paste
# either the full redirect URL their browser landed on, or just the
# `code` value out of it.
oauth_manual_callback() {
  local pasted query
  OAUTH_CALLBACK_CODE=""; OAUTH_CALLBACK_STATE=""; OAUTH_CALLBACK_ERROR=""
  echo
  muted "No local callback listener available (nc not found)."
  muted "After you authorize in the browser, it will redirect to a URL that may fail to load — that's expected."
  read -r -p "Paste that full URL (or just the code= value) here: " pasted
  if [[ "$pasted" == *"code="* ]]; then
    query="${pasted#*\?}"
    OAUTH_CALLBACK_CODE="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="code"{print $2; exit}')"
    OAUTH_CALLBACK_STATE="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="state"{print $2; exit}')"
  else
    OAUTH_CALLBACK_CODE="$pasted"
  fi
  [[ -z "$OAUTH_CALLBACK_CODE" ]] && { OAUTH_CALLBACK_ERROR="No code provided."; return 1; }
  return 0
}

# Python equivalent of oauth_run_callback_listener above, used when `nc`
# isn't installed (see oauth_callback_method / oauth_offer_install_python).
# Same contract: blocks up to $2 seconds for one HTTP GET on
# 127.0.0.1:$1, sets OAUTH_CALLBACK_CODE / _STATE / _ERROR the same way,
# so oauth_run_flow doesn't need to know or care which listener actually
# served the request.
#
# The whole one-shot server is a single inline python script fed via
# heredoc rather than a scratch file on disk — nothing to clean up, and
# it runs identically whether the interpreter is python3 or (rare, old
# systems) python2's http.server-less "SimpleHTTPServer" naming, which is
# why this pins to the python3-only http.server/socketserver names and
# just requires python3 specifically (oauth_python_bin prefers python3;
# see there).
oauth_run_callback_listener_python() {
  local port="$1" timeout="${2:-180}" pybin query
  OAUTH_CALLBACK_CODE=""; OAUTH_CALLBACK_STATE=""; OAUTH_CALLBACK_ERROR=""

  pybin="$(oauth_python_bin)"
  if [[ -z "$pybin" ]]; then
    OAUTH_CALLBACK_ERROR="No working Python 3 interpreter found."
    return 1
  fi

  query="$("$pybin" - "$port" "$timeout" <<'PYEOF'
import sys
import http.server
import socketserver
import urllib.parse

port = int(sys.argv[1])
timeout = float(sys.argv[2])

RESP_OK = ("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
           "<html><body><h2>Aulthium: authorization received.</h2>"
           "<p>You can close this tab and return to the terminal.</p></body></html>")
RESP_ERR = ("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n"
            "<html><body><h2>Aulthium: authorization was not completed.</h2>"
            "<p>You can close this tab and return to the terminal.</p></body></html>")

captured = {"query": ""}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        captured["query"] = parsed.query
        params = urllib.parse.parse_qs(parsed.query)
        body = RESP_ERR if "error" in params else RESP_OK
        try:
            self.wfile.write(body.encode("utf-8"))
        except Exception:
            pass

    # Silence the default per-request access log to stderr — Aulthium's
    # own status lines are the only output this should produce.
    def log_message(self, format, *args):
        pass

class OneShotServer(socketserver.TCPServer):
    allow_reuse_address = True

try:
    srv = OneShotServer(("127.0.0.1", port), Handler)
    srv.timeout = timeout
    srv.handle_request()
    srv.server_close()
except Exception:
    pass

print(captured["query"])
PYEOF
)"

  [[ -z "$query" ]] && { OAUTH_CALLBACK_ERROR="Timed out waiting for the browser redirect."; return 1; }

  OAUTH_CALLBACK_CODE="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="code"{print $2; exit}')"
  OAUTH_CALLBACK_STATE="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="state"{print $2; exit}')"
  local err_param
  err_param="$(printf '%s' "$query" | tr '&' '\n' | awk -F= '$1=="error"{print $2; exit}')"
  if [[ -n "$err_param" ]]; then
    OAUTH_CALLBACK_ERROR="$(printf '%s' "$err_param" | sed 's/+/ /g')"
    return 1
  fi
  [[ -z "$OAUTH_CALLBACK_CODE" ]] && { OAUTH_CALLBACK_ERROR="No authorization code in the callback."; return 1; }
  return 0
}

# ── Token exchange / refresh ─────────────────────────────────────────────
# Sets OAUTH_TOKEN_JSON to the full token response (access_token,
# refresh_token if given, expires_in, etc.) as compact JSON.
OAUTH_TOKEN_JSON=""

oauth_exchange_code() {
  local token_endpoint="$1" code="$2" redirect_uri="$3" verifier="$4" client_id="$5" client_secret="$6"
  local -a args=(grant_type=authorization_code code="$code" redirect_uri="$redirect_uri" \
                  code_verifier="$verifier" client_id="$client_id")
  local access_token_check
  [[ -n "$client_secret" ]] && args+=(client_secret="$client_secret")

  if ! oauth_http_post_form "$token_endpoint" "${args[@]}"; then
    OAUTH_RPC_ERROR="No response from token endpoint (HTTP ${OAUTH_HTTP_CODE:-000})."
    return 1
  fi

  # Validate the body is a single well-formed JSON document BEFORE trusting
  # any field out of it. This used to be a bare truthiness check
  # (`jq -e '.access_token'`) with stderr thrown away, which meant a
  # malformed/non-JSON body (HTML error page, form-urlencoded response,
  # trailing garbage, etc.) could silently slip through here and only blow
  # up later when individual fields were re-extracted — by which point the
  # caller had already moved on as if the exchange had succeeded, and ended
  # up saving/using a blank access_token. Fail loudly and immediately here
  # instead, with a snippet of the actual body so it's debuggable.
  if ! jq -e . >/dev/null 2>/tmp/aulthium_jq_err.$$ <<< "$OAUTH_HTTP_BODY"; then
    OAUTH_RPC_ERROR="Token endpoint returned a non-JSON or malformed response (HTTP ${OAUTH_HTTP_CODE:-000}): $(printf '%s' "$OAUTH_HTTP_BODY" | head -c 200)"
    rm -f "/tmp/aulthium_jq_err.$$" 2>/dev/null
    return 1
  fi
  rm -f "/tmp/aulthium_jq_err.$$" 2>/dev/null

  # Body parses fine as JSON — now make sure access_token is actually a
  # non-empty string rather than just "truthy" (jq treats any non-null,
  # non-false value as truthy, which previously let an empty string ""
  # through as a "success").
  access_token_check="$(jq -r '.access_token // empty' <<< "$OAUTH_HTTP_BODY" 2>/dev/null)"
  if [[ -z "$access_token_check" ]]; then
    OAUTH_RPC_ERROR="$(jq -r '.error_description // .error // "Token endpoint response had no access_token."' <<< "$OAUTH_HTTP_BODY" 2>/dev/null)"
    return 1
  fi

  OAUTH_TOKEN_JSON="$OAUTH_HTTP_BODY"
  return 0
}

oauth_refresh_token() {
  local token_endpoint="$1" refresh_token="$2" client_id="$3" client_secret="$4"
  local -a args=(grant_type=refresh_token refresh_token="$refresh_token" client_id="$client_id")
  [[ -n "$client_secret" ]] && args+=(client_secret="$client_secret")
  if oauth_http_post_form "$token_endpoint" "${args[@]}" && jq -e '.access_token' >/dev/null 2>&1 <<< "$OAUTH_HTTP_BODY"; then
    OAUTH_TOKEN_JSON="$OAUTH_HTTP_BODY"
    return 0
  fi
  return 1
}

# ── Manual OAuth client (servers without RFC 7591 registration) ─────────
# Some authorization servers — GitHub's github.com/login/oauth is the
# common one an MCP client will actually hit — don't support Dynamic
# Client Registration at all, so there's no way to get a client_id
# automatically. The user has to register their own OAuth App with the
# provider and hand Aulthium its client_id (GitHub also requires a
# client_secret at the token endpoint even for a PKCE-using public
# client — see github.com/github/github-mcp-server/blob/main/docs/oauth-login.md,
# which confirms this and notes the secret can't be kept truly
# confidential in a distributed client like this one; PKCE, not secrecy
# of that value, is what actually secures the exchange).
#
# Cached in the credential store keyed by the authorization server's
# host (oauth_manual_client_cred_id) rather than per-MCP-server, since
# every server sharing one authorization server (e.g. every GitHub MCP
# endpoint uses the same github.com/login/oauth) can reuse the same
# OAuth App credentials — one registration covers all of them.
oauth_manual_client_cred_id() {
  local host
  host="$(printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##; s#[/:].*##')"
  printf 'oauth-client-%s' "${host:-unknown}"
}

OAUTH_MANUAL_CLIENT_ID=""
OAUTH_MANUAL_CLIENT_SECRET=""

oauth_get_manual_client() {
  local label="$1" cred_id cred cached_id cached_secret entered_id entered_secret
  OAUTH_MANUAL_CLIENT_ID=""; OAUTH_MANUAL_CLIENT_SECRET=""
  cred_id="$(oauth_manual_client_cred_id "$OAUTH_AUTHZ_ENDPOINT")"

  if cred="$(cred_get "$cred_id" 2>/dev/null)" && jq -e '.client_id' >/dev/null 2>&1 <<< "$cred"; then
    cached_id="$(jq -r '.client_id // empty' <<< "$cred")"
    if [[ -n "$cached_id" ]]; then
      cached_secret="$(jq -r '.client_secret // empty' <<< "$cred")"
      OAUTH_MANUAL_CLIENT_ID="$cached_id"
      OAUTH_MANUAL_CLIENT_SECRET="$cached_secret"
      return 0
    fi
  fi

  box_top "MANUAL OAUTH CLIENT NEEDED" "$ICON_MCP" "$C_WARN"
  box_line "$label's authorization server doesn't support automatic client"
  box_line "registration — register Aulthium as an OAuth App yourself and"
  box_line "paste in its credentials (only needed once per provider)."
  if [[ "$OAUTH_AUTHZ_ENDPOINT" == *"github.com"* ]]; then
    box_line ""
    box_line "For GitHub: github.com/settings/developers -> OAuth Apps ->"
    box_line "New OAuth App. Homepage URL can be anything you like. Set"
    box_line "the Authorization callback URL to: http://127.0.0.1/callback"
    box_line "(GitHub doesn't require the port in the callback to match"
    box_line "the one actually used at login time, so this works no"
    box_line "matter which local port Aulthium happens to pick). Then"
    box_line "generate a client secret — GitHub requires one at the token"
    box_line "endpoint even though this flow already uses PKCE."
  fi
  box_bottom "$C_WARN"

  read -r -p "Client ID (blank to cancel): " entered_id
  if [[ -z "$entered_id" ]]; then
    OAUTH_FLOW_ERROR="No client ID entered."
    return 1
  fi
  read -r -s -p "Client secret (leave blank if this provider doesn't need one): " entered_secret
  echo

  OAUTH_MANUAL_CLIENT_ID="$entered_id"
  OAUTH_MANUAL_CLIENT_SECRET="$entered_secret"

  if confirm_yes_no "Save these for next time? (reused for every server on this same provider)"; then
    if cred_save "$cred_id" "$(jq -nc --arg cid "$entered_id" --arg cs "$entered_secret" \
        '{client_id:$cid, client_secret:($cs|select(length>0))}')"; then
      ok "Saved."
    else
      warn "Couldn't save — you'll be asked again next session."
    fi
  fi
  return 0
}

# ── Full authorization-code + PKCE flow orchestrator ─────────────────────
# oauth_run_flow <mcp_url> <server_label> -> on success, prints a
# credential-store JSON blob to stdout (caller decides the cred id and
# calls cred_save). On failure, prints nothing and returns 1 — caller
# reads OAUTH_FLOW_ERROR for why.
OAUTH_FLOW_ERROR=""

oauth_run_flow() {
  local mcp_url="$1" label="$2"
  local verifier challenge state port redirect_uri client_id client_secret
  local used_listener=0
  OAUTH_FLOW_ERROR=""

  say "Discovering OAuth configuration for $label..."
  if ! oauth_discover "$mcp_url"; then
    OAUTH_FLOW_ERROR="Could not discover OAuth authorization/token endpoints for this server (checked RFC 9728 protected-resource metadata and RFC 8414/OIDC authorization-server metadata)."
    return 1
  fi

  port="$(oauth_pick_callback_port)"
  redirect_uri="http://127.0.0.1:${port}/callback"

  client_id="${OAUTH_PRESET_CLIENT_ID:-}"
  client_secret="${OAUTH_PRESET_CLIENT_SECRET:-}"
  if [[ -z "$client_id" ]]; then
    if [[ -n "$OAUTH_REGISTRATION_ENDPOINT" ]]; then
      say "Registering Aulthium as a client with this server (RFC 7591)..."
      if ! oauth_dynamic_register "$OAUTH_REGISTRATION_ENDPOINT" "$redirect_uri"; then
        OAUTH_FLOW_ERROR="Dynamic client registration failed and no client_id was pre-configured for this server."
        return 1
      fi
      client_id="$OAUTH_CLIENT_ID"
      client_secret="$OAUTH_CLIENT_SECRET"
    else
      # No RFC 7591 registration endpoint — GitHub's own MCP server is the
      # common case here (github.com/login/oauth advertises no
      # registration_endpoint at all; see
      # github.com/github/github-mcp-server/blob/main/docs/oauth-login.md).
      # Rather than hard-failing, fall back to asking the user for their
      # own OAuth App's client_id/secret — see oauth_get_manual_client,
      # which also caches the answer so this is only needed once per
      # authorization server, not once per MCP server on it.
      if ! oauth_get_manual_client "$label"; then
        OAUTH_FLOW_ERROR="${OAUTH_FLOW_ERROR:-This server has no dynamic client registration endpoint and no client_id is pre-configured for it.}"
        return 1
      fi
      client_id="$OAUTH_MANUAL_CLIENT_ID"
      client_secret="$OAUTH_MANUAL_CLIENT_SECRET"
    fi
  fi

  verifier="$(oauth_gen_code_verifier)"
  challenge="$(oauth_code_challenge_s256 "$verifier")"
  state="$(oauth_gen_state)"

  local authz_url scope_param=""
  [[ -n "$OAUTH_SCOPES" ]] && scope_param="&scope=$(url_encode_fallback "$OAUTH_SCOPES")"
  authz_url="${OAUTH_AUTHZ_ENDPOINT}?response_type=code&client_id=$(url_encode_fallback "$client_id")&redirect_uri=$(url_encode_fallback "$redirect_uri")&state=$(url_encode_fallback "$state")&code_challenge=$(url_encode_fallback "$challenge")&code_challenge_method=S256${scope_param}"

  box_top "OAUTH" "$ICON_MCP" "$C_ACCENT2"
  box_line "Opening your browser to authorize $label..."
  box_line "If it doesn't open, visit this URL manually:"
  box_line "$authz_url"
  box_bottom "$C_ACCENT2"
  oauth_open_browser "$authz_url" >/dev/null 2>&1

  local callback_method
  callback_method="$(oauth_callback_method)"
  if [[ -z "$callback_method" ]]; then
    # Neither nc nor python is on this box — offer to install python
    # once before falling back to manual paste, so a minimal install
    # (common on fresh Termux) doesn't silently lose the automatic path.
    oauth_offer_install_python && callback_method="$(oauth_callback_method)"
  fi

  case "$callback_method" in
    nc)
      used_listener=1
      oauth_run_callback_listener "$port" 180
      ;;
    python)
      used_listener=1
      oauth_run_callback_listener_python "$port" 180
      ;;
    *)
      oauth_manual_callback
      ;;
  esac

  if [[ -n "$OAUTH_CALLBACK_ERROR" || -z "$OAUTH_CALLBACK_CODE" ]]; then
    OAUTH_FLOW_ERROR="${OAUTH_CALLBACK_ERROR:-Authorization was not completed.}"
    return 1
  fi
  # State validation (CSRF protection) — skipped only for the manual-paste
  # fallback path when the user pasted a bare code with no state to check;
  # any listener-based callback MUST match.
  if [[ "$used_listener" -eq 1 && "$OAUTH_CALLBACK_STATE" != "$state" ]]; then
    OAUTH_FLOW_ERROR="State mismatch on OAuth callback — possible CSRF, aborting."
    return 1
  fi

  say "Exchanging authorization code for a token..."
  if ! oauth_exchange_code "$OAUTH_TOKEN_ENDPOINT" "$OAUTH_CALLBACK_CODE" "$redirect_uri" "$verifier" "$client_id" "$client_secret"; then
    OAUTH_FLOW_ERROR="${OAUTH_RPC_ERROR:-Token exchange failed.}"
    return 1
  fi

  local access_token refresh_token expires_in obtained_at
  access_token="$(jq -r '.access_token // empty' <<< "$OAUTH_TOKEN_JSON" 2>/dev/null)"
  refresh_token="$(jq -r '.refresh_token // empty' <<< "$OAUTH_TOKEN_JSON" 2>/dev/null)"
  expires_in="$(jq -r '.expires_in // empty' <<< "$OAUTH_TOKEN_JSON" 2>/dev/null)"
  obtained_at="$(date +%s)"

  # Belt and suspenders: oauth_exchange_code already refuses to report
  # success without a non-empty access_token, but this is the point where
  # a credential blob actually gets constructed and handed back to the
  # caller (who saves it and immediately tries to use it as a bearer
  # token) — so refuse here too rather than ever emitting
  # {"access_token":"", ...} as if it were a good credential. That's what
  # was previously happening: a blank token got saved and used, and every
  # server connection then failed with an opaque HTTP 401 instead of a
  # clear "the OAuth flow didn't actually get you a token" message.
  if [[ -z "$access_token" ]]; then
    OAUTH_FLOW_ERROR="Token exchange reported success but no access_token was present in the response — not saving a broken credential."
    return 1
  fi

  jq -nc --arg at "$access_token" --arg rt "$refresh_token" --arg exp "$expires_in" \
         --arg obtained "$obtained_at" --arg te "$OAUTH_TOKEN_ENDPOINT" \
         --arg cid "$client_id" --arg cs "$client_secret" \
    '{access_token:$at, refresh_token:($rt|select(length>0)),
      expires_in:($exp|select(length>0)|tonumber?),
      obtained_at:($obtained|tonumber), token_endpoint:$te,
      client_id:$cid, client_secret:($cs|select(length>0))}'
  return 0
}

# ── Live token retrieval, with transparent refresh ───────────────────────
# oauth_get_valid_token <cred_id> -> prints a valid access_token on
# stdout, refreshing first if it's expired (or within 60s of expiring)
# and a refresh_token is available. This is the one function the MCP
# request path (mcp_http_post) will call for "oauth"-type servers.
oauth_get_valid_token() {
  local cred_id="$1" cred access_token expires_in obtained_at now age refresh_token token_endpoint client_id client_secret
  cred="$(cred_get "$cred_id")" || return 1
  access_token="$(jq -r '.access_token // empty' <<< "$cred")"
  expires_in="$(jq -r '.expires_in // empty' <<< "$cred")"
  obtained_at="$(jq -r '.obtained_at // empty' <<< "$cred")"

  if [[ -n "$expires_in" && -n "$obtained_at" ]]; then
    now="$(date +%s)"
    age=$(( now - obtained_at ))
    if [[ $(( age + 60 )) -ge $expires_in ]]; then
      refresh_token="$(jq -r '.refresh_token // empty' <<< "$cred")"
      token_endpoint="$(jq -r '.token_endpoint // empty' <<< "$cred")"
      client_id="$(jq -r '.client_id // empty' <<< "$cred")"
      client_secret="$(jq -r '.client_secret // empty' <<< "$cred")"
      if [[ -n "$refresh_token" && -n "$token_endpoint" ]]; then
        if oauth_refresh_token "$token_endpoint" "$refresh_token" "$client_id" "$client_secret"; then
          local new_access new_refresh new_expires
          new_access="$(jq -r '.access_token' <<< "$OAUTH_TOKEN_JSON")"
          new_refresh="$(jq -r '.refresh_token // empty' <<< "$OAUTH_TOKEN_JSON")"
          [[ -z "$new_refresh" ]] && new_refresh="$refresh_token" # some servers omit it on refresh; keep the old one
          new_expires="$(jq -r '.expires_in // empty' <<< "$OAUTH_TOKEN_JSON")"
          local updated
          updated="$(jq -nc --arg at "$new_access" --arg rt "$new_refresh" --arg exp "$new_expires" \
                            --arg obtained "$(date +%s)" --arg te "$token_endpoint" \
                            --arg cid "$client_id" --arg cs "$client_secret" \
            '{access_token:$at, refresh_token:($rt|select(length>0)),
              expires_in:($exp|select(length>0)|tonumber?),
              obtained_at:($obtained|tonumber), token_endpoint:$te,
              client_id:$cid, client_secret:($cs|select(length>0))}')"
          cred_save "$cred_id" "$updated" || true
          printf '%s' "$new_access"
          return 0
        else
          # Refresh failed — token is stale/expired and unrecoverable
          # without a fresh interactive authorization. Surface that
          # distinctly from "not connected at all" so the caller can tell
          # the user to reconnect rather than just "add" again.
          return 2
        fi
      fi
      # Expired with no refresh_token to use — same "needs reauth" signal.
      return 2
    fi
  fi

  [[ -z "$access_token" ]] && return 1
  printf '%s' "$access_token"
  return 0
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
# more (comma-separated numbers, or "all"), then registers each pick either
# via browser OAuth (each Cloudflare service authorizes separately, so this
# opens the browser once per pick) or a single Cloudflare API token reused
# across the whole batch — mirrors the same choice 't> mcp github' offers.
mcp_pick_cloudflare() {
  local i sel choice token entered any_added=0
  local -a raw_parts=() picks=()

  box_top "CLOUDFLARE MCP SERVERS" "$ICON_MCP" "$C_ACCENT2"
  for i in "${!CF_MCP_NAMES[@]}"; do
    box_line "$(printf '%2d) %-16s %s' "$((i + 1))" "${CF_MCP_NAMES[$i]}" "${CF_MCP_DESCS[$i]}")"
  done
  box_bottom "$C_ACCENT2"

  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Pick number(s), comma-separated, or 'all' ${C_MUTED}(blank to cancel)${C_RESET} ")" sel
  [[ -z "$sel" ]] && { muted "Cancelled."; return 0; }

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

  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Auth via (o)Auth in browser or (t)oken? ${C_MUTED}(o/t, blank to cancel)${C_RESET} ")" choice
  case "${choice,,}" in
    o|oauth)
      local pidx name url
      for pidx in "${picks[@]}"; do
        name="${CF_MCP_NAMES[$pidx]}"
        url="${CF_MCP_URLS[$pidx]}"
        if mcp_find_index "$name" >/dev/null; then
          warn "\"$name\" is already configured — skipping (t> mcp remove $name first to re-add)."
          continue
        fi
        mcp_add_server_oauth "$name" "$url" && any_added=1
      done
      # mcp_add_server_oauth already resets history/says so per server.
      return 0
      ;;
    t|token)
      read -r -s -p "Cloudflare API token to use for the picked server(s) (blank to try without one): " entered
      echo
      token="$entered"
      ;;
    *)
      muted "Cancelled."
      return 0
      ;;
  esac

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

########################################################################
# GITHUB MCP QUICK-CONNECT
#
# GitHub runs one official remote MCP server (see
# https://github.com/github/github-mcp-server and
# https://docs.github.com/en/copilot/how-tos/provide-context/model-context-protocol/using-the-github-mcp-server)
# at GH_MCP_URL below, exposing repos/issues/PRs/actions/etc as tools. Unlike
# the Cloudflare picker above there's no catalog to choose from — this is
# just a named shortcut so the URL doesn't have to be typed out, registered
# exactly like any 't> mcp add <name> <url>' server (same arrays, same
# 't> mcp list/remove/refresh').
#
# GitHub's server supports two auth styles: a fine-grained Personal Access
# Token sent as a bearer key (simplest, works headless), or full OAuth 2.1 +
# PKCE via this script's generic OAuth client (mcp_add_server_oauth) if the
# user would rather authorize through the browser than paste a token.
########################################################################
GH_MCP_NAME="github"
GH_MCP_URL="https://api.githubcopilot.com/mcp/"

# 't> mcp github' — offers PAT-or-OAuth, then registers GH_MCP_NAME/GH_MCP_URL
# exactly like a manual 't> mcp add' / 't> mcp oauth' would.
mcp_pick_github() {
  local choice token entered key_var

  if mcp_find_index "$GH_MCP_NAME" >/dev/null; then
    warn "\"$GH_MCP_NAME\" is already configured — 't> mcp remove $GH_MCP_NAME' first to reconnect."
    return 1
  fi

  box_top "GITHUB MCP SERVER" "$ICON_MCP" "$C_ACCENT2"
  box_line "$GH_MCP_URL"
  box_line "Repos, issues, PRs, Actions, code search, and more"
  box_bottom "$C_ACCENT2"

  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Auth via (p)ersonal access token or (o)Auth in browser? ${C_MUTED}(p/o, blank to cancel)${C_RESET} ")" choice
  case "${choice,,}" in
    p|pat)
      key_var="$(mcp_env_key_for "$GH_MCP_NAME")"
      token="${!key_var:-}"
      if [[ -z "$token" ]]; then
        read -r -s -p "GitHub personal access token (fine-grained recommended): " entered
        echo
        token="$entered"
      fi
      if [[ -z "$token" ]]; then
        warn "No token entered — cancelled."
        return 1
      fi
      if mcp_register_server "$GH_MCP_NAME" "$GH_MCP_URL" "$token"; then
        init_history
        say "Conversation reset so the agent can see the new MCP tools."
      fi
      ;;
    o|oauth)
      mcp_add_server_oauth "$GH_MCP_NAME" "$GH_MCP_URL"
      ;;
    *)
      muted "Cancelled."
      return 0
      ;;
  esac
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

# If an "mcp_call" hook plugin is registered and toggled on, gives it a
# look at the pending server/tool/arguments before the user is asked to
# confirm the call. Entry is invoked as: <entry> mcp_call <server> <tool>
# <args-json>. Same VETO:/transform/pass-through contract as
# shell_exec_plugin_hook: exit 0 + "VETO:<reason>" blocks the call, exit 0
# + other non-empty (and valid-JSON) stdout replaces the argument object,
# exit 0 + empty stdout or a non-zero exit leaves the arguments unchanged.
# If the replacement stdout isn't valid JSON it's discarded with a warning
# rather than sent on to the server. Always sets MCP_CALL_HOOK_ARGS to
# whatever arguments should actually be sent.
mcp_call_plugin_hook() {
  local server="$1" tool="$2" args="$3" name
  MCP_CALL_HOOK_ARGS="$args"
  hook_point_is_active "mcp_call" || return 0
  name="${HOOK_OWNER[mcp_call]}"

  if ! plugin_hook_call "$name" "mcp_call" "$server" "$tool" "$args"; then
    return 0
  fi
  if [[ "$PLUGIN_HOOK_OUTPUT" == VETO:* ]]; then
    MCP_CALL_HOOK_VETO_REASON="${PLUGIN_HOOK_OUTPUT#VETO:}"
    MCP_CALL_HOOK_VETO_REASON="${MCP_CALL_HOOK_VETO_REASON# }"
    return 1
  fi
  if [[ -n "$PLUGIN_HOOK_OUTPUT" ]]; then
    if jq -e . >/dev/null 2>&1 <<< "$PLUGIN_HOOK_OUTPUT"; then
      MCP_CALL_HOOK_ARGS="$PLUGIN_HOOK_OUTPUT"
    else
      warn "Hook plugin '$name' returned non-JSON for mcp_call — ignoring its output, using the original arguments."
    fi
  fi
  return 0
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

  if ! mcp_call_plugin_hook "$server" "$tool" "$args_text"; then
    warn "MCP_CALL $server.$tool blocked by hook plugin — ${MCP_CALL_HOOK_VETO_REASON:-no reason given}."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool]: blocked by hook plugin (${MCP_CALL_HOOK_VETO_REASON:-no reason given})."
    return
  fi
  args_text="$MCP_CALL_HOOK_ARGS"

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
  key="$(mcp_resolve_key "$idx")" || {
    box_bottom "$C_ERR"
    warn "MCP_CALL $server.$tool failed: OAuth session expired and needs reconnecting (t> mcp oauth $server ${MCP_URLS[$idx]})."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[MCP_CALL $server.$tool]: call failed (OAuth session expired — reconnect with t> mcp oauth $server)."
    return
  }
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

# If a "shell_exec" hook plugin is registered and toggled on, gives it a
# look at the pending command before the user is asked to confirm it.
# Entry is invoked as: <entry> shell_exec <command>. On exit 0:
#   - stdout starting with "VETO:" blocks the command entirely — the rest
#     of that line is the reason, surfaced to the user.
#   - any other non-empty stdout REPLACES the command that will actually
#     run (and gets shown in the confirmation box, not the original).
#   - empty stdout leaves the command unchanged.
# A non-zero exit (hook errored, crashed, etc) is treated as "no opinion"
# — same fallback-to-unmodified behavior as web_search's hook when it
# fails, so a flaky hook plugin never silently blocks shell access.
# Always sets SHELL_EXEC_HOOK_CMD to whatever should actually run.
shell_exec_plugin_hook() {
  local cmd="$1" name
  SHELL_EXEC_HOOK_CMD="$cmd"
  hook_point_is_active "shell_exec" || return 0
  name="${HOOK_OWNER[shell_exec]}"

  if ! plugin_hook_call "$name" "shell_exec" "$cmd"; then
    return 0
  fi
  if [[ "$PLUGIN_HOOK_OUTPUT" == VETO:* ]]; then
    SHELL_EXEC_HOOK_VETO_REASON="${PLUGIN_HOOK_OUTPUT#VETO:}"
    SHELL_EXEC_HOOK_VETO_REASON="${SHELL_EXEC_HOOK_VETO_REASON# }"
    return 1
  fi
  [[ -n "$PLUGIN_HOOK_OUTPUT" ]] && SHELL_EXEC_HOOK_CMD="$PLUGIN_HOOK_OUTPUT"
  return 0
}

# SHELL_RUN — requires explicit confirmation. Runs with cwd = WORKSPACE_DIR
# but is NOT path-sandboxed like the file actions: the command itself can
# reference anything the user's shell can reach. The confirmation prompt says
# so explicitly every time.
handle_shell_run_action() {
  local cmd_file="$1" cmd_text output exit_code exit_color

  cmd_text="$(cat "$cmd_file")"

  if ! shell_exec_plugin_hook "$cmd_text"; then
    warn "Shell command blocked by hook plugin — ${SHELL_EXEC_HOOK_VETO_REASON:-no reason given}."
    AGENT_TOOL_OUTPUT+=$'\n\n'"[SHELL_RUN]: blocked by hook plugin (${SHELL_EXEC_HOOK_VETO_REASON:-no reason given})."
    return
  fi
  cmd_text="$SHELL_EXEC_HOOK_CMD"

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
      # Requires an explicit <<<ITEM path="...">>> line, same as BULK_WRITE
      # and BULK_MOVE — a bare line used to be accepted as a path outright
      # (see git history / CHANGELOG), which meant a model that ever slipped
      # ordinary commentary inside this block — or worse, line-wrapped a
      # sentence one word per line — had every one of those words silently
      # queued up as a folder to create. Requiring the marker means free
      # text can never syntactically match, no matter how path-like a
      # single stray word happens to look.
      if [[ "$line" =~ ^\<\<\<ITEM\ path=\"([^\"]*)\"\>\>\>$ ]]; then
        bulk_folder_paths+=("${BASH_REMATCH[1]}")
        cleaned+="${C_DIM}  + ${BASH_REMATCH[1]}${C_RESET}"$'\n'
      elif [[ "$line" =~ path=[\"\']([^\"\']*)[\"\'] ]]; then
        # Near-miss (single-quoted, extra whitespace, etc.) — same
        # tolerance shim pattern used elsewhere in this parser.
        bulk_folder_paths+=("${BASH_REMATCH[1]}")
        cleaned+="${C_DIM}  + ${BASH_REMATCH[1]}${C_RESET}"$'\n'
      elif [[ -n "$line" ]]; then
        warn "Non-ITEM line inside BULK_FOLDER_CREATE, skipped: $line"
        cleaned+="${C_WARN}${ICON_WARN} not a valid ITEM line, skipped: $line${C_RESET}"$'\n'
      fi
    elif [[ "$mode" == "bulkdelete" ]]; then
      if [[ "$line" == '<<<END_BULK_DELETE>>>' ]]; then
        mode="text"
        continue
      fi
      # See BULK_FOLDER_CREATE above — same fix, same reasoning.
      if [[ "$line" =~ ^\<\<\<ITEM\ path=\"([^\"]*)\"\>\>\>$ ]]; then
        bulk_delete_paths+=("${BASH_REMATCH[1]}")
        cleaned+="${C_DIM}  + ${BASH_REMATCH[1]}${C_RESET}"$'\n'
      elif [[ "$line" =~ path=[\"\']([^\"\']*)[\"\'] ]]; then
        bulk_delete_paths+=("${BASH_REMATCH[1]}")
        cleaned+="${C_DIM}  + ${BASH_REMATCH[1]}${C_RESET}"$'\n'
      elif [[ -n "$line" ]]; then
        warn "Non-ITEM line inside BULK_DELETE, skipped: $line"
        cleaned+="${C_WARN}${ICON_WARN} not a valid ITEM line, skipped: $line${C_RESET}"$'\n'
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


# ── Plugins ──────────────────────────────────────────────────────────────
# A plugin is an ordinary external program living under $PLUGINS_DIR/<name>/,
# described by a plugin.json manifest ({name, description, entry, runtime}).
# Aulthium does NOT sandbox plugin execution the way it sandboxes the file
# agent — running one is a trust decision, same tier as a shell command, and
# is gated by the same confirm_action prompt. What Aulthium DOES do is hand
# the plugin the currently-selected provider/model/key as env vars (see
# plugin_export_env) so the plugin can talk to the AI backend on its own,
# without needing this bash process in the loop. Full format documented in
# BUILD_PLUGIN.md for anyone writing a new one.

plugins_ensure_dir() {
  mkdir -p "$PLUGINS_DIR" 2>/dev/null
}

# Persisted on/off/stopped state for hook plugins, so an explicit
# `t> plugin toggle <n> off` or `t> plugin run --stoprun <n>` sticks across
# a full restart of Aulthium (not just a Ctrl+C-free session) — see
# plugins_autostart, which is what actually reads this back on the way up.
#
# Echoes "on" / "off" / "stopped" for a known name, or nothing if the
# state file doesn't exist yet or has never recorded that name (autostart
# treats "nothing recorded" as "on" — a plugin's first-ever install starts
# out active by default, same as if the state file didn't exist at all).
plugin_hook_state_load() {
  local name="$1"
  [[ -f "$PLUGIN_HOOK_STATE_FILE" ]] || return 0
  jq -r --arg n "$name" '.[$n] // empty' "$PLUGIN_HOOK_STATE_FILE" 2>/dev/null
}

# Records one plugin's on/off/stopped state into PLUGIN_HOOK_STATE_FILE,
# merging with whatever's already there (read-modify-write via a temp file
# + mv so a crash mid-write can't truncate it to garbage). Best-effort: a
# write failure here doesn't fail the caller's toggle/run/stoprun, it just
# means that particular state change won't survive a restart.
plugin_hook_state_save() {
  local name="$1" state="$2" tmp existing
  plugins_ensure_dir
  existing="{}"
  [[ -f "$PLUGIN_HOOK_STATE_FILE" ]] && existing="$(cat "$PLUGIN_HOOK_STATE_FILE" 2>/dev/null)"
  [[ -z "$existing" ]] && existing="{}"
  tmp="$(mktemp)" || return 1
  if printf '%s' "$existing" | jq --arg n "$name" --arg s "$state" '.[$n] = $s' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$PLUGIN_HOOK_STATE_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Called once at startup (from main, after the provider/key are already
# set up) to bring back every installed hook plugin that opts into
# "autostart": true in its plugin.json — e.g. better-websearch. Default
# behavior is "on" every launch, Ctrl+C or not; an explicit prior
# `t> plugin toggle <n> off` or `t> plugin run --stoprun <n>` is what
# overrides that (read back via plugin_hook_state_load), not the other
# way around. Silent on success (status_panel/plugin list show the
# result); failures (missing runtime, hook collision, bad manifest) print
# a warning but never block the rest of startup.
plugins_autostart() {
  local dir name manifest mode hook toggle_prefix runtime entry autostart state priority

  for dir in "$PLUGINS_DIR"/*/; do
    manifest="${dir}plugin.json"
    [[ -f "$manifest" ]] || continue
    name="$(basename "$dir")"

    mode="$(jq -r '.mode // "foreground"' "$manifest" 2>/dev/null)"
    [[ "$mode" == "hook" ]] || continue
    autostart="$(jq -r '.autostart // false' "$manifest" 2>/dev/null)"
    [[ "$autostart" == "true" ]] || continue

    state="$(plugin_hook_state_load "$name")"
    [[ "$state" == "stopped" ]] && continue
    [[ -z "$state" ]] && state="on"

    hook="$(jq -r '.hook // empty' "$manifest" 2>/dev/null)"
    entry="$(jq -r '.entry // empty' "$manifest" 2>/dev/null)"
    runtime="$(jq -r '.runtime // empty' "$manifest" 2>/dev/null)"
    toggle_prefix="$(jq -r '.toggle_prefix // empty' "$manifest" 2>/dev/null)"
    priority="$(jq -r '.priority // 0' "$manifest" 2>/dev/null)"
    [[ "$priority" =~ ^-?[0-9]+$ ]] || priority=0

    if [[ -z "$hook" || -z "$entry" ]]; then
      warn "Autostart: '$name' has an incomplete hook manifest (missing entry/hook) — skipped."
      continue
    fi
    if [[ -n "$runtime" ]] && ! want_cmd "$runtime"; then
      warn "Autostart: '$name' needs '$runtime', which isn't available — skipped. Run 't> plugin run $name' once that's fixed."
      continue
    fi

    if ! hook_point_is_known "$hook"; then
      warn "Autostart: '$name' declares an unknown hook point '$hook' — skipped. Known hook points: $KNOWN_HOOK_POINTS"
      continue
    fi
    if ! hook_claim_ownership "$name" "$hook" "$priority"; then
      continue
    fi

    if [[ -n "$toggle_prefix" ]]; then
      if [[ -n "${TOGGLE_PREFIX_TO_PLUGIN[$toggle_prefix]:-}" ]]; then
        warn "Autostart: toggle prefix '${toggle_prefix}>' already claimed — '$name' will only be toggleable via t> plugin toggle."
        toggle_prefix=""
      else
        TOGGLE_PREFIX_TO_PLUGIN[$toggle_prefix]="$name"
      fi
    fi

    RUNNING_PLUGIN_ENABLED[$name]="$state"
    RUNNING_PLUGIN_HOOK[$name]="$hook"
    RUNNING_PLUGIN_ENTRY[$name]="$entry"
    RUNNING_PLUGIN_DIR[$name]="$dir"
    RUNNING_PLUGIN_TOGGLE_PREFIX[$name]="$toggle_prefix"
    RUNNING_PLUGIN_PRIORITY[$name]="$priority"
  done
}

# Scans $BUILTIN_PLUGINS_PATH inside $BUILTIN_PLUGINS_REPO via GitHub's
# "contents" API and prints one "name owner/repo/path/to/name" pair per
# line — the same shape BUILTIN_PLUGIN_SOURCES used to be hardcoded as,
# just discovered live instead of typed in. Only entries the API reports
# as type=="dir" count as plugins (a stray README.md, LICENSE, etc sitting
# alongside them in that folder is silently skipped). Returns non-zero on
# any failure (offline, repo/path doesn't exist, rate-limited) with
# nothing printed — deliberately undifferentiated, same as
# plugin_github_latest_release, since every caller treats "couldn't
# determine built-ins" the same way regardless of why.
builtin_plugin_sources_fetch() {
  local api_url json
  api_url="https://api.github.com/repos/$BUILTIN_PLUGINS_REPO/contents/$BUILTIN_PLUGINS_PATH"
  json="$(curl -fsSL --max-time 15 -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | jq -r --arg repo "$BUILTIN_PLUGINS_REPO" --arg path "$BUILTIN_PLUGINS_PATH" \
    'if type == "array" then
       (.[]? | select(.type == "dir") | "\(.name) \($repo)/\($path)/\(.name)")
     else empty end' 2>/dev/null
}

# Cache-aware wrapper around builtin_plugin_sources_fetch — the thing
# every other call site should actually use. Fetches once per session
# (see BUILTIN_PLUGIN_SOURCES_FETCHED above) and hands back the cached
# result on every call after that. Use builtin_plugin_sources_refresh
# instead when the caller specifically wants a fresh live check
# (e.g. 't> plugin list --refresh' or similar).
builtin_plugin_sources() {
  if [[ "$BUILTIN_PLUGIN_SOURCES_FETCHED" -eq 1 ]]; then
    printf '%s' "$BUILTIN_PLUGIN_SOURCES_CACHE"
    return 0
  fi
  builtin_plugin_sources_refresh
}

# Forces a live re-fetch of the built-in plugin listing, replacing
# whatever was cached. Echoes the fresh result and returns non-zero if
# the fetch itself failed (network down, bad repo/path, GitHub rate
# limit) — callers that only care about the listing can ignore the
# return code, since BUILTIN_PLUGIN_SOURCES_CACHE is left empty (not
# stale) on failure either way.
builtin_plugin_sources_refresh() {
  local out
  BUILTIN_PLUGIN_SOURCES_FETCHED=1
  if out="$(builtin_plugin_sources_fetch)"; then
    BUILTIN_PLUGIN_SOURCES_CACHE="$out"
    printf '%s' "$out"
    return 0
  fi
  BUILTIN_PLUGIN_SOURCES_CACHE=""
  return 1
}

# Looks up a name among the discovered built-ins, echoing its
# "owner/repo/path" coordinate on a match. Used by plugin_run to offer an
# install when a known built-in name is referenced but nothing is on disk
# for it yet.
builtin_plugin_repo_for() {
  local target="$1" line pname prepo
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    read -r pname prepo <<< "$line"
    if [[ "$pname" == "$target" ]]; then
      printf '%s' "$prepo"
      return 0
    fi
  done <<< "$(builtin_plugin_sources)"
  return 1
}

# ── Plugin manifest validation, permissions, integrity & config ─────────
# Everything in this section is shared across every way a plugin reaches
# disk (t> plugin install <folder|url|github:...>),
# so a plugin is held to the same bar regardless of where it came from.

# Known permission scopes a plugin.json may declare in its "permissions"
# array. Purely declarative — Aulthium still does not sandbox a plugin the
# way it sandboxes the file agent to WORKSPACE_DIR — but declaring them
# lets plugin_confirm_permissions show a specific, honest picture of what
# a plugin says it needs, instead of the old one-size-fits-all warning.
KNOWN_PLUGIN_PERMISSIONS="network filesystem shell mcp secrets"

plugin_permission_label() {
  case "$1" in
    network)    printf 'Network access — can make its own HTTP requests (beyond the AI API call itself).' ;;
    filesystem) printf 'Filesystem access — can read/write files outside the sandboxed workspace.' ;;
    shell)      printf 'Shell access — can run arbitrary commands on this machine.' ;;
    mcp)        printf 'MCP access — can call your connected MCP servers/tools.' ;;
    secrets)    printf 'Secrets access — receives your live API key for the active provider.' ;;
    *)          printf 'Unrecognized permission scope (not known to this version of Aulthium).' ;;
  esac
}

# Structural validation shared by every install path — catches the stuff
# that would otherwise fail confusingly deep inside plugin_run/plugin_export_env:
# invalid JSON, a missing/unsafe name, a mode/hook combo that doesn't make
# sense, and permission strings outside the known set (warned, not
# blocked — a future Aulthium version may know scopes this one doesn't).
# Prints its own err/warn messages; returns non-zero on anything serious
# enough to block an install.
plugin_manifest_validate() {
  local manifest="$1" name entry mode hook perms p unknown=""
  if [[ ! -f "$manifest" ]]; then
    err "No plugin.json at $manifest"
    return 1
  fi
  if ! jq empty "$manifest" 2>/dev/null; then
    err "plugin.json isn't valid JSON."
    return 1
  fi
  name="$(jq -r '.name // empty' "$manifest" 2>/dev/null)"
  if [[ -z "$name" ]]; then
    err "plugin.json is missing a \"name\" field."
    return 1
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    err "Plugin name must contain only letters, numbers, - or _: got '$name'."
    return 1
  fi
  mode="$(jq -r '.mode // "foreground"' "$manifest" 2>/dev/null)"
  if [[ "$mode" != "foreground" && "$mode" != "hook" ]]; then
    err "plugin.json \"mode\" must be \"foreground\" or \"hook\" (got '$mode')."
    return 1
  fi
  entry="$(jq -r '.entry // empty' "$manifest" 2>/dev/null)"
  if [[ -z "$entry" ]]; then
    warn "plugin.json has no \"entry\" command — it won't be runnable until one is added."
  fi
  if [[ "$mode" == "hook" ]]; then
    hook="$(jq -r '.hook // empty' "$manifest" 2>/dev/null)"
    if [[ -z "$hook" ]]; then
      err "\"mode\": \"hook\" needs a \"hook\" field naming the hook point (e.g. \"web_search\")."
      return 1
    fi
    if ! hook_point_is_known "$hook"; then
      warn "plugin.json declares hook point '$hook', which this version of Aulthium doesn't know (known: $KNOWN_HOOK_POINTS) — it'll fail to register until that's fixed or a future version adds it."
    fi
  fi
  perms="$(jq -r '.permissions[]? // empty' "$manifest" 2>/dev/null)"
  if [[ -n "$perms" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ " $KNOWN_PLUGIN_PERMISSIONS " == *" $p "* ]] || unknown="$unknown $p"
    done <<< "$perms"
    if [[ -n "$unknown" ]]; then
      warn "plugin.json declares unrecognized permission(s):$unknown — shown to the user as-is, but this version of Aulthium has no built-in description for them."
    fi
  fi
  return 0
}

# A stable fingerprint of exactly what a manifest's "permissions" array
# currently says (order-independent), used to decide whether a prior grant
# still covers what's being installed/run now.
# Informational-only permissions display shown right after a fresh
# install — NOT a grant, doesn't touch PLUGIN_PERMS_FILE, and asks
# nothing. The actual grant gate is plugin_confirm_permissions, which
# always runs at 't> plugin run' time regardless of what happened here;
# this just means nobody is surprised by that prompt later.
plugin_install_show_permissions() {
  local manifest="$1" perms p
  perms="$(jq -r '.permissions[]? // empty' "$manifest" 2>/dev/null)"
  [[ -n "$perms" ]] || return 0
  muted "This plugin declares permissions (confirmed again on first run):"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    muted "  - $p — $(plugin_permission_label "$p")"
  done <<< "$perms"
}

plugin_perms_fingerprint() {
  jq -r '.permissions // [] | sort | join(",")' "$1" 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
}

plugin_perms_grant_load() {
  local name="$1"
  [[ -f "$PLUGIN_PERMS_FILE" ]] || return 0
  jq -r --arg n "$name" '.[$n] // empty' "$PLUGIN_PERMS_FILE" 2>/dev/null
}

# Read-modify-write via temp file + mv, same crash-safe shape as
# plugin_hook_state_save above.
plugin_perms_grant_save() {
  local name="$1" fp="$2" tmp existing
  plugins_ensure_dir
  existing="{}"
  [[ -f "$PLUGIN_PERMS_FILE" ]] && existing="$(cat "$PLUGIN_PERMS_FILE" 2>/dev/null)"
  [[ -z "$existing" ]] && existing="{}"
  tmp="$(mktemp)" || return 1
  if printf '%s' "$existing" | jq --arg n "$name" --arg f "$fp" '.[$n] = $f' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$PLUGIN_PERMS_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Shows exactly what a plugin's manifest declares it needs and gets an
# explicit y/N via confirm_yes_no — deliberately NEVER confirm_action, so
# 't> confirm off' (scoped to agent-proposed file/shell/MCP actions — see
# confirm_action above) can never silently wave a plugin's permission
# grant through. Skips re-asking only when the exact same permission set
# (by fingerprint) was already approved for this plugin name before;
# anything that changes the set — a reinstall with a different
# "permissions" array, an update, a plugin.json hand-edit — asks again.
plugin_confirm_permissions() {
  local name="$1" manifest="$2" perms fp prior p
  perms="$(jq -r '.permissions[]? // empty' "$manifest" 2>/dev/null)"
  fp="$(plugin_perms_fingerprint "$manifest")"
  prior="$(plugin_perms_grant_load "$name")"

  box_top "PLUGIN PERMISSIONS: $name" "$ICON_WARN" "$C_WARN"
  if [[ -z "$perms" ]]; then
    box_line "${C_MUTED}This plugin declares no permissions in its plugin.json.${C_RESET}"
    box_line "${C_MUTED}It is still an ordinary external program — Aulthium does not sandbox it.${C_RESET}"
  else
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      box_line "${C_BOLD}${p}${C_RESET}${C_MUTED} — $(plugin_permission_label "$p")${C_RESET}"
    done <<< "$perms"
  fi
  box_bottom "$C_WARN"

  if [[ -n "$prior" && "$prior" == "$fp" ]]; then
    muted "Permissions unchanged since you last approved '$name' — not asking again."
    return 0
  fi
  if [[ -n "$prior" ]]; then
    warn "'$name' requested permissions changed since you last approved it — re-confirming."
  fi

  if confirm_yes_no "Grant '$name' the permissions above and run it?"; then
    plugin_perms_grant_save "$name" "$fp"
    return 0
  fi
  return 1
}

# Deterministic content hash of everything in a plugin's install directory
# except plugin.json itself (where the hash gets stored — hashing it would
# be circular) and config.json (a user's local overrides, not part of
# what was actually "installed"). Stamped at install/create time via
# plugin_stamp_integrity, and re-checked by plugin_verify / plugin_run to
# detect drift — files changing on disk after install, whether from a
# manual edit, a bug, or tampering.
plugin_tree_checksum() {
  local dir="$1"
  find "$dir" -type f ! -name 'plugin.json' ! -name 'config.json' -print0 2>/dev/null \
    | sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sha256sum 2>/dev/null \
    | awk '{print $1}'
}

# Stamps a freshly (re)computed _integrity.sha256 + _integrity.at (UTC
# timestamp) into a plugin's manifest. Called right after every install
# (local folder, zip URL, GitHub), so every plugin on disk carries a hash
# of what was actually delivered.
plugin_stamp_integrity() {
  local dest="$1" manifest="$dest/plugin.json" hash stamped
  [[ -f "$manifest" ]] || return 1
  hash="$(plugin_tree_checksum "$dest")"
  stamped="$(jq --arg h "$hash" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    '._integrity = {"sha256": $h, "at": $t}' "$manifest" 2>/dev/null)"
  if [[ -n "$stamped" ]]; then
    printf '%s\n' "$stamped" > "$manifest"
  fi
}

# `t> plugin verify <name>` — recomputes the hash and compares it to what
# was recorded at install/create time. Strictly read-only: never
# reinstalls, repairs, or re-stamps anything on a mismatch — that only
# happens via a fresh t> plugin install/update, so the hash always means
# "matches what was deliberately installed", never "matches whatever's
# there now".
plugin_verify() {
  local name="$1" dir manifest stored current
  if [[ -z "$name" ]]; then
    warn "Usage: t> plugin verify <name>"
    return 1
  fi
  dir="$PLUGINS_DIR/$name"
  manifest="$dir/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    err "No plugin named '$name' — run 't> plugin list' to see what's installed."
    return 1
  fi
  stored="$(jq -r '._integrity.sha256 // empty' "$manifest" 2>/dev/null)"
  if [[ -z "$stored" ]]; then
    warn "'$name' has no recorded integrity hash (installed before this feature existed) — nothing to verify against."
    muted "Reinstall it to get one: t> plugin install <same source>"
    return 1
  fi
  current="$(plugin_tree_checksum "$dir")"
  if [[ "$current" == "$stored" ]]; then
    ok "'$name' matches its recorded hash — files are unchanged since $(jq -r '._integrity.at // "install"' "$manifest" 2>/dev/null)."
  else
    err "'$name' does NOT match its recorded hash — files changed since $(jq -r '._integrity.at // "install"' "$manifest" 2>/dev/null)."
    muted "recorded: $stored"
    muted "current:  $current"
  fi
}

# `t> plugin config <name>` family — per-plugin customization. A plugin
# author declares defaults in plugin.json's "config" object; a user's own
# overrides live separately in <plugin-dir>/config.json so they survive
# `t> plugin update`/reinstall untouched. plugin_config_effective is the
# single source of truth both the CLI and plugin_export_config_env (what a
# running plugin actually receives) read from — defaults overlaid with
# overrides, overrides always winning.
plugin_config_effective() {
  local dir="$1" defaults overrides
  defaults="$(jq -c '.config // {}' "$dir/plugin.json" 2>/dev/null)"
  [[ -n "$defaults" ]] || defaults="{}"
  overrides="{}"
  [[ -f "$dir/config.json" ]] && overrides="$(cat "$dir/config.json" 2>/dev/null)"
  [[ -n "$overrides" ]] || overrides="{}"
  jq -c -n --argjson d "$defaults" --argjson o "$overrides" '$d * $o' 2>/dev/null
}

plugin_config() {
  local name="$1"; shift || true
  local dir manifest sub
  if [[ -z "$name" ]]; then
    warn "Usage: t> plugin config <name> [list | get <key> | set <key> <value> | unset <key>]"
    return 1
  fi
  dir="$PLUGINS_DIR/$name"
  manifest="$dir/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    err "No plugin named '$name' — run 't> plugin list' to see what's installed."
    return 1
  fi

  sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      box_top "PLUGIN CONFIG: $name" "$ICON_PLUGIN" "$C_ACCENT2"
      local eff line
      eff="$(plugin_config_effective "$dir")"
      if [[ -z "$eff" || "$eff" == "{}" ]]; then
        box_line "${C_MUTED}(no config keys declared or set)${C_RESET}"
      else
        while IFS= read -r line; do
          box_line "$line"
        done < <(printf '%s' "$eff" | jq -r 'to_entries[] | "\(.key) = \(.value)"' 2>/dev/null)
      fi
      box_bottom "$C_ACCENT2"
      muted "Set with: t> plugin config $name set <key> <value>   —   clear an override with: t> plugin config $name unset <key>"
      ;;
    get)
      local key="$1"
      if [[ -z "$key" ]]; then
        warn "Usage: t> plugin config $name get <key>"
        return 1
      fi
      printf '%s' "$(plugin_config_effective "$dir")" | jq -r --arg k "$key" '.[$k] // "(unset)"' 2>/dev/null
      ;;
    set)
      local key="$1" val="$2" tmp existing
      if [[ -z "$key" || -z "$val" ]]; then
        warn "Usage: t> plugin config $name set <key> <value>"
        return 1
      fi
      existing="{}"
      [[ -f "$dir/config.json" ]] && existing="$(cat "$dir/config.json" 2>/dev/null)"
      [[ -z "$existing" ]] && existing="{}"
      tmp="$(mktemp)" || return 1
      if printf '%s' "$existing" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$dir/config.json"
        ok "Set '$key' = '$val' for '$name' (local override — untouched by t> plugin update/reinstall)."
      else
        rm -f "$tmp"
        err "Couldn't write config.json for '$name'."
        return 1
      fi
      ;;
    unset)
      local key="$1" tmp existing
      if [[ -z "$key" ]]; then
        warn "Usage: t> plugin config $name unset <key>"
        return 1
      fi
      if [[ ! -f "$dir/config.json" ]]; then
        warn "'$name' has no local config overrides to unset."
        return 0
      fi
      existing="$(cat "$dir/config.json" 2>/dev/null)"
      [[ -z "$existing" ]] && existing="{}"
      tmp="$(mktemp)" || return 1
      if printf '%s' "$existing" | jq --arg k "$key" 'del(.[$k])' > "$tmp" 2>/dev/null; then
        mv "$tmp" "$dir/config.json"
        ok "Unset local override for '$key' — '$name' falls back to its plugin.json default (if any)."
      else
        rm -f "$tmp"
        err "Couldn't update config.json for '$name'."
        return 1
      fi
      ;;
    *)
      warn "Usage: t> plugin config <name> [list | get <key> | set <key> <value> | unset <key>]"
      return 1
      ;;
  esac
}


# Queries GitHub's REST API for a repo's latest release. On success, prints
# two lines: the tag name, then the download URL of its best zip asset (a
# release asset literally named *.zip if one was attached, else empty —
# callers fall back to GitHub's own auto-generated source-archive URL for
# that tag). Failure (no releases, repo doesn't exist, offline, rate
# limited) is a plain non-zero return with nothing printed, deliberately
# undifferentiated — callers already have a same-shape fallback for "no
# releases" (the default branch's zip), so there's no reason to make every
# call site parse out *why* GitHub didn't give us a tag.
plugin_github_latest_release() {
  local repo="$1" api_url json tag asset_url
  api_url="https://api.github.com/repos/$repo/releases/latest"
  json="$(curl -fsSL --max-time 20 -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  tag="$(printf '%s' "$json" | jq -r '.tag_name // empty' 2>/dev/null)"
  [[ -n "$tag" ]] || return 1
  asset_url="$(printf '%s' "$json" | jq -r '[.assets[]? | select(.name | test("\\.zip$"))][0].browser_download_url // empty' 2>/dev/null)"
  printf '%s\n%s\n' "$tag" "$asset_url"
}

# Downloads a zip from $1, extracts it, and installs whatever plugin it
# contains into $PLUGINS_DIR/<name> — the same validation plugin_install
# applies to a local folder (plugin.json present, name is safe, same
# overwrite confirmation), just with a download-and-unzip step first. The
# zip may extract flat (plugin.json at the top level) or wrapped in one
# containing folder, which is what GitHub's auto-generated source-archive
# zips always do (e.g. "somerepo-1.2.0/plugin.json") — searched up to one
# level deep either way.
#
# Optional $2: a subpath inside the repo (set by plugin_install_github when
# the coordinate has more than two "/"-segments, i.e. a monorepo plugin
# living below the repo root, like "plugins/built-in/webchat"). When given,
# the manifest search is pointed straight at "<wrapper>/<subpath>/plugin.json"
# (or "<subpath>/plugin.json" with no wrapper folder) instead of the generic
# maxdepth-2 sweep, since a monorepo can easily have other plugin.json files
# elsewhere that a blind sweep might match first.
plugin_install_from_url() {
  local url="$1" subpath="${2:-}" tmp_zip tmp_dir manifest_path src_dir name dest stamped source_repo
  source_repo="$PLUGIN_INSTALL_SOURCE_REPO"
  PLUGIN_INSTALL_SOURCE_REPO=""
  if [[ "$HAVE_UNZIP" -ne 1 ]]; then
    err "Installing a plugin from a zip needs 'unzip', which isn't available on this system."
    return 1
  fi

  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/aulthium_plugin.XXXXXX.zip" 2>/dev/null)" || {
    err "Couldn't create a temp file to download into."
    return 1
  }
  if ! curl -fsSL -L --max-time 60 --max-filesize "$MAX_NET_DOWNLOAD_BYTES" "$url" -o "$tmp_zip" 2>/dev/null; then
    err "Couldn't download $url"
    rm -f "$tmp_zip"
    return 1
  fi

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/aulthium_plugin_extract.XXXXXX" 2>/dev/null)" || {
    err "Couldn't create a temp folder to extract into."
    rm -f "$tmp_zip"
    return 1
  }
  if ! unzip -q -o "$tmp_zip" -d "$tmp_dir" 2>/dev/null; then
    err "Couldn't extract that download — it doesn't look like a valid zip file."
    rm -rf -- "$tmp_zip" "$tmp_dir"
    return 1
  fi
  rm -f "$tmp_zip"

  if [[ -n "$subpath" ]]; then
    # Look for the manifest directly under the subpath, with or without
    # GitHub's single auto-generated wrapper folder (e.g.
    # "aulthium-main/plugins/built-in/webchat/plugin.json"). Try no-wrapper
    # first, then exactly one wrapper level — never a blind repo-wide sweep,
    # since a monorepo can hold more than one plugin.json.
    manifest_path="$tmp_dir/$subpath/plugin.json"
    [[ -f "$manifest_path" ]] || manifest_path="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)/$subpath/plugin.json"
    [[ -f "$manifest_path" ]] || manifest_path=""
    if [[ -z "$manifest_path" ]]; then
      err "No plugin.json found at '$subpath' inside that zip."
      rm -rf -- "$tmp_dir"
      return 1
    fi
  else
    manifest_path="$(find "$tmp_dir" -maxdepth 2 -name plugin.json -print -quit 2>/dev/null)"
    if [[ -z "$manifest_path" ]]; then
      err "No plugin.json found inside that zip — see BUILD_PLUGIN.md for the expected layout."
      rm -rf -- "$tmp_dir"
      return 1
    fi
  fi
  src_dir="$(dirname -- "$manifest_path")"

  if ! plugin_manifest_validate "$manifest_path"; then
    err "Refusing to install — plugin.json failed validation (see above)."
    rm -rf -- "$tmp_dir"
    return 1
  fi
  name="$(jq -r '.name // empty' "$manifest_path" 2>/dev/null)"

  plugins_ensure_dir
  dest="$PLUGINS_DIR/$name"
  if [[ -d "$dest" ]]; then
    if ! confirm_yes_no "Plugin '$name' already exists — overwrite it?"; then
      warn "Cancelled."
      rm -rf -- "$tmp_dir"
      return 1
    fi
    rm -rf -- "$dest"
  fi

  if ! cp -R "$src_dir" "$dest" 2>/dev/null; then
    err "Failed to copy plugin into $dest"
    rm -rf -- "$tmp_dir"
    return 1
  fi

  # Stamp how this landed here, so `t> plugin update` can find its way
  # back to the same repo later without the user having to re-specify it.
  # jq merge — anything the manifest itself already declares wins over
  # this (a plugin author is free to ship their own richer "_source").
  # Only stamped for a GitHub-sourced install; a plain `t> plugin install
  # <url>` (no repo coordinate) leaves the manifest untouched.
  if [[ -n "$source_repo" ]]; then
    stamped="$(jq --arg repo "$source_repo" --arg path "$subpath" \
      '. + (if has("_source") then {} else
        ({"_source": {"type":"github","repo":$repo}} *
         (if $path == "" then {} else {"_source": {"path":$path}} end))
      end)' "$dest/plugin.json" 2>/dev/null)"
    if [[ -n "$stamped" ]]; then
      printf '%s\n' "$stamped" > "$dest/plugin.json"
    fi
  fi

  plugin_stamp_integrity "$dest"
  ok "Installed plugin '$name' (v$(jq -r '.version // "?"' "$dest/plugin.json" 2>/dev/null)) → $dest"
  plugin_install_show_permissions "$dest/plugin.json"
  muted "Run it with: t> plugin run $name"
  rm -rf -- "$tmp_dir"
  return 0
}

# Resolves "$1" — an "owner/repo" GitHub coordinate, optionally followed by
# a subpath for a plugin that lives below the repo root in a monorepo
# ("owner/repo/plugins/built-in/webchat") — and installs it. Falls back to
# the repo's default-branch source zip if it has no releases at all — good
# enough for a plugin with no build step, though a real tagged release is
# what makes `t> plugin update` meaningful (untagged installs have nothing
# to compare against next time).
#
# A subpath coordinate ALWAYS goes straight to the default-branch source
# zip, skipping release/tag lookup entirely — a GitHub release is repo-wide,
# so its tag reflects whatever the repo's main deliverable is (e.g. this
# script's own APP_VERSION), not the version of an individual plugin buried
# somewhere inside it. A release asset built for that main deliverable also
# has no reason to contain the rest of the repo tree, so relying on it here
# would just as easily 404 on the subpath even when a release exists. Since
# there's no per-plugin version signal to compare against ahead of time,
# `t> plugin update` treats a subpath plugin as "sync to whatever's on the
# branch now" rather than "is there a newer tag" — see plugin_update below.
plugin_install_github() {
  local full="$1" repo subpath release_info tag asset_url
  if [[ -z "$full" ]]; then
    warn "Usage: t> plugin install github:<owner>/<repo>[/subpath]"
    return 1
  fi
  repo="$(printf '%s' "$full" | cut -d/ -f1,2)"
  subpath="$(printf '%s' "$full" | cut -s -d/ -f3-)"
  PLUGIN_INSTALL_SOURCE_REPO="$repo"

  if [[ -n "$subpath" ]]; then
    say "Fetching $repo (default branch) for the plugin at '$subpath'..."
    plugin_install_from_url "https://github.com/$repo/archive/refs/heads/main.zip" "$subpath"
    return $?
  fi

  say "Checking github.com/$repo for a release..."
  if ! release_info="$(plugin_github_latest_release "$repo")"; then
    warn "No releases found for $repo (or GitHub is unreachable right now) — trying its default branch instead."
    plugin_install_from_url "https://github.com/$repo/archive/refs/heads/main.zip" "$subpath"
    return $?
  fi
  tag="$(printf '%s' "$release_info" | sed -n '1p')"
  asset_url="$(printf '%s' "$release_info" | sed -n '2p')"
  if [[ -z "$asset_url" ]]; then
    asset_url="https://github.com/$repo/archive/refs/tags/$tag.zip"
  fi
  say "Installing $repo @ $tag ..."
  plugin_install_from_url "$asset_url" "$subpath"
}

# `t> plugin update` with no name: read-only sweep over every installed
# plugin that has a "_source.repo" (i.e. came from plugin_install_github),
# reporting which have a newer release out — nothing is installed here.
plugin_update_check_all() {
  plugins_ensure_dir
  local dir manifest name repo subpath cur_version release_info tag any=0
  box_top "PLUGIN UPDATES" "$ICON_PLUGIN" "$C_ACCENT2"
  for dir in "$PLUGINS_DIR"/*/; do
    manifest="${dir}plugin.json"
    [[ -f "$manifest" ]] || continue
    repo="$(jq -r '._source.repo // empty' "$manifest" 2>/dev/null)"
    [[ -n "$repo" ]] || continue
    any=1
    name="$(basename "$dir")"
    subpath="$(jq -r '._source.path // empty' "$manifest" 2>/dev/null)"
    cur_version="$(jq -r '.version // "0"' "$manifest" 2>/dev/null)"
    if [[ -n "$subpath" ]]; then
      # No repo-wide tag applies to a single plugin buried in a monorepo —
      # see plugin_install_github — so there's nothing to diff against
      # without downloading the branch, which this sweep intentionally
      # doesn't do (it's read-only). Point at the per-plugin update instead.
      box_line "${C_BOLD}${name}${C_RESET} — v${cur_version} ${C_MUTED}(monorepo plugin — run 't> plugin update ${name}' to sync)${C_RESET}"
      continue
    fi
    if release_info="$(plugin_github_latest_release "$repo")"; then
      tag="$(printf '%s' "$release_info" | sed -n '1p')"
      if autoupdate_version_gt "$tag" "$cur_version"; then
        box_line "${C_BOLD}${name}${C_RESET} — v${cur_version} → ${C_OK}${tag}${C_RESET} available"
      else
        box_line "${C_BOLD}${name}${C_RESET} — v${cur_version} ${C_MUTED}(up to date)${C_RESET}"
      fi
    else
      box_line "${C_BOLD}${name}${C_RESET} — v${cur_version} ${C_MUTED}(couldn't reach $repo)${C_RESET}"
    fi
  done
  if [[ "$any" -eq 0 ]]; then
    box_line "${C_MUTED}(no GitHub-sourced plugins installed — nothing to check)${C_RESET}"
  fi
  box_bottom "$C_ACCENT2"
  [[ "$any" -eq 1 ]] && muted "Update one with: t> plugin update <name>"
}

# `t> plugin update <name>`: checks that one plugin's repo, and — only
# after an explicit yes/no, same trust model as installing or running a
# plugin at all — reinstalls it if a newer release exists.
plugin_update() {
  local name="$1" manifest repo subpath full cur_version release_info tag
  if [[ -z "$name" ]]; then
    plugin_update_check_all
    return 0
  fi
  manifest="$PLUGINS_DIR/$name/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    err "No plugin named '$name' — run 't> plugin list' to see what's installed."
    return 1
  fi
  repo="$(jq -r '._source.repo // empty' "$manifest" 2>/dev/null)"
  if [[ -z "$repo" ]]; then
    warn "'$name' wasn't installed from GitHub (or predates update-tracking) — nothing to check it against."
    muted "Reinstall it from a repo with: t> plugin install github:<owner>/<repo>"
    return 1
  fi
  subpath="$(jq -r '._source.path // empty' "$manifest" 2>/dev/null)"
  cur_version="$(jq -r '.version // "0"' "$manifest" 2>/dev/null)"
  full="$repo"
  [[ -n "$subpath" ]] && full="$repo/$subpath"

  # A subpath plugin has no repo-wide tag to compare against (see the note
  # on plugin_install_github) — there's no cheap way to know ahead of time
  # whether the branch has moved since this was installed, so just confirm
  # and re-fetch; plugin_install_from_url's own overwrite prompt is the
  # only gate, and the new version (if any) shows up in its "Installed"
  # line afterward.
  if [[ -n "$subpath" ]]; then
    say "'$name' is a monorepo plugin (no per-plugin release tag to check) — currently v$cur_version."
    if ! confirm_yes_no "Re-fetch '$name' from the current $repo default branch?"; then
      warn "Cancelled."
      return 1
    fi
    plugin_install_github "$full"
    return $?
  fi

  say "Checking $repo for a release newer than v$cur_version..."
  if ! release_info="$(plugin_github_latest_release "$repo")"; then
    err "Couldn't reach GitHub, or $repo has no releases."
    return 1
  fi
  tag="$(printf '%s' "$release_info" | sed -n '1p')"
  if ! autoupdate_version_gt "$tag" "$cur_version"; then
    ok "'$name' is already up to date (v$cur_version)."
    return 0
  fi
  if ! confirm_yes_no "Update '$name': v$cur_version → $tag?"; then
    warn "Cancelled."
    return 1
  fi
  plugin_install_github "$full"
}

# `t> plugin remove/delete <name>`: deletes an installed plugin's folder
# from disk after an explicit y/N, same trust model as everything else
# under `t> plugin`. This only removes what plugin_install/plugin_install_*
# put in $PLUGINS_DIR/<name> — it doesn't touch anything the plugin itself
# may have written elsewhere (its own data/config dirs, if any), since
# Aulthium has no record of that beyond the plugin's own manifest.
plugin_remove() {
  local name="$1" dest
  if [[ -z "$name" ]]; then
    warn "Usage: t> plugin remove <name>"
    return 1
  fi
  dest="$PLUGINS_DIR/$name"
  if [[ ! -d "$dest" ]]; then
    err "No plugin named '$name' — run 't> plugin list' to see what's installed."
    return 1
  fi
  if ! confirm_yes_no "Remove plugin '$name' ($dest)? This can't be undone."; then
    warn "Cancelled."
    return 1
  fi
  if rm -rf -- "$dest"; then
    ok "Removed plugin '$name'."
  else
    err "Failed to remove $dest"
    return 1
  fi
}

plugin_list() {
  plugins_ensure_dir
  local found=0 dir name desc entry repo
  box_top "PLUGINS" "$ICON_PLUGIN" "$C_ACCENT2"
  for dir in "$PLUGINS_DIR"/*/; do
    [[ -f "${dir}plugin.json" ]] || continue
    found=1
    name="$(basename "$dir")"
    desc="$(jq -r '.description // "(no description)"' "${dir}plugin.json" 2>/dev/null)"
    entry="$(jq -r '.entry // "?"' "${dir}plugin.json" 2>/dev/null)"
    repo="$(jq -r '._source.repo // empty' "${dir}plugin.json" 2>/dev/null)"
    local perms
    perms="$(jq -r '.permissions // [] | join(", ")' "${dir}plugin.json" 2>/dev/null)"
    box_line "${C_BOLD}${name}${C_RESET}${C_MUTED} — ${desc}${C_RESET}"
    box_line "  ${C_MUTED}entry: ${entry}${C_RESET}"
    [[ -n "$perms" ]] && box_line "  ${C_MUTED}permissions: ${perms}${C_RESET}"
    [[ -n "$repo" ]] && box_line "  ${C_MUTED}source: github.com/${repo}${C_RESET}"
  done
  if [[ "$found" -eq 0 ]]; then
    box_line "${C_MUTED}(none installed yet)${C_RESET}"
  fi

  # Hook plugins currently registered (mode:"hook", e.g. better-websearch)
  # — these run silently alongside normal chat rather than blocking the
  # terminal, so t> plugin/plugin list is the only place their live
  # on/off state is otherwise visible.
  if [[ "${#RUNNING_PLUGIN_ENABLED[@]}" -gt 0 ]]; then
    local rname rstate rhook rprefix rpriority
    box_line ""
    box_line "${C_MUTED}Running:${C_RESET}"
    for rname in "${!RUNNING_PLUGIN_ENABLED[@]}"; do
      rstate="${RUNNING_PLUGIN_ENABLED[$rname]}"
      rhook="${RUNNING_PLUGIN_HOOK[$rname]}"
      rprefix="${RUNNING_PLUGIN_TOGGLE_PREFIX[$rname]:-}"
      rpriority="${RUNNING_PLUGIN_PRIORITY[$rname]:-0}"
      box_line "  ${C_BOLD}${rname}${C_RESET}${C_MUTED} — hook: ${rhook} (priority ${rpriority}), state: ${rstate}${C_RESET}"
      if [[ -n "$rprefix" ]]; then
        box_line "    ${C_MUTED}toggle: ${rprefix}> on|off   or   t> plugin toggle ${rname} on|off${C_RESET}"
      else
        box_line "    ${C_MUTED}toggle: t> plugin toggle ${rname} on|off${C_RESET}"
      fi
    done
  fi

  # Built-ins the user hasn't installed yet — a new user has no other way
  # to discover these exist short of already knowing the exact
  # "github:owner/repo/path" coordinate, so surface them here every time,
  # not just on the plugin_run "did you mean" nudge. The list itself comes
  # from a live GitHub scan (see builtin_plugin_sources), not anything
  # hardcoded in this script.
  local builtin_sources line pname prepo any_avail=0
  if ! builtin_sources="$(builtin_plugin_sources)"; then
    box_line ""
    box_line "${C_MUTED}(couldn't check github.com/${BUILTIN_PLUGINS_REPO} for built-ins — offline or rate-limited)${C_RESET}"
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      read -r pname prepo <<< "$line"
      [[ -d "$PLUGINS_DIR/$pname" ]] && continue
      if [[ "$any_avail" -eq 0 ]]; then
        box_line ""
        box_line "${C_MUTED}Available (not installed):${C_RESET}"
        any_avail=1
      fi
      box_line "  ${C_BOLD}${pname}${C_RESET}${C_MUTED} — t> plugin install github:${prepo}${C_RESET}"
    done <<< "$builtin_sources"
  fi

  box_bottom "$C_ACCENT2"
  muted "Run one with: t> plugin run <name>   —   install one with: t> plugin install <path|github:owner/repo>   —   remove one with: t> plugin remove <name>"
  muted "Scaffold a new one with the standalone aulthium-plugin-create.sh   —   tune one with: t> plugin config <name>   —   check it with: t> plugin verify <name>"
  muted "Plugins live in: $PLUGINS_DIR"
}

plugin_info() {
  local name="$1" manifest
  if [[ -z "$name" ]]; then
    warn "Usage: t> plugin info <name>"
    return 1
  fi
  manifest="$PLUGINS_DIR/$name/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    err "No plugin named '$name' — run 't> plugin list' to see what's installed."
    return 1
  fi
  box_top "PLUGIN: $name" "$ICON_PLUGIN" "$C_ACCENT2"
  while IFS= read -r line; do
    box_line "$line"
  done < <(jq -r 'to_entries[] | select(.key != "_integrity") | "\(.key): \(.value)"' "$manifest" 2>/dev/null)

  local eff stored current dir
  dir="$PLUGINS_DIR/$name"
  eff="$(plugin_config_effective "$dir")"
  if [[ -n "$eff" && "$eff" != "{}" ]]; then
    box_line "effective config: $eff"
  fi

  stored="$(jq -r '._integrity.sha256 // empty' "$manifest" 2>/dev/null)"
  if [[ -n "$stored" ]]; then
    current="$(plugin_tree_checksum "$dir")"
    if [[ "$current" == "$stored" ]]; then
      box_line "${C_OK}integrity: OK${C_RESET} ${C_MUTED}(matches hash recorded $(jq -r '._integrity.at // "?"' "$manifest" 2>/dev/null))${C_RESET}"
    else
      box_line "${C_ERR}integrity: MISMATCH${C_RESET} ${C_MUTED}(files changed since $(jq -r '._integrity.at // "?"' "$manifest" 2>/dev/null) — run t> plugin verify $name)${C_RESET}"
    fi
  else
    box_line "${C_MUTED}integrity: no hash recorded${C_RESET}"
  fi
  box_bottom "$C_ACCENT2"
}

# Exports the connection details a plugin needs to reach the AI provider on
# its own, mirroring the shape of call_openai_compatible / call_google
# above so plugin authors can speak the same two request shapes:
#   AULTHIUM_API_KIND   "openai" (Bearer-auth /chat/completions) or "google"
#   AULTHIUM_API_URL    endpoint (openai) / API base (google — model+key
#                        still need appending, same as call_google does)
#   AULTHIUM_API_KEY    active provider's key (may be empty for a no-key
#                        custom endpoint)
#   AULTHIUM_MODEL      current model id
# Unset again by plugin_run once the plugin exits, so the key doesn't
# linger in this shell's exported environment for anything launched after.
plugin_export_env() {
  export AULTHIUM_APP_NAME="$APP_NAME"
  export AULTHIUM_APP_VERSION="$APP_VERSION"
  export AULTHIUM_WORKSPACE_DIR="$WORKSPACE_DIR"
  export AULTHIUM_PROVIDER="$PROVIDER"
  export AULTHIUM_PROVIDER_LABEL="$(provider_label)"
  export AULTHIUM_MODEL="$CURRENT_MODEL"
  # Lets a plugin start out matching this terminal session's current
  # confirm-gate state and 429-retry tuning, instead of guessing/hardcoding
  # its own. Plugins are free to offer their own toggle for this on top
  # (webchat does), but it always *starts* synced to what's set here.
  export AULTHIUM_SKIP_CONFIRMATIONS="$SKIP_CONFIRMATIONS"
  export AULTHIUM_MAX_RATE_LIMIT_RETRIES="$MAX_RATE_LIMIT_RETRIES"
  export AULTHIUM_MAX_RATE_LIMIT_WAIT="$MAX_RATE_LIMIT_WAIT"
  # So a plugin's own SHELL_RUN (webchat has one) times out on the same
  # schedule as the terminal's does, instead of guessing/hardcoding it.
  export AULTHIUM_SHELL_TIMEOUT_SECS="$SHELL_TIMEOUT_SECS"

  # Sensitive: AULTHIUM_API_KEY is only worth exporting to a plugin that
  # actually declared "secrets" in its permissions (and was granted it via
  # plugin_confirm_permissions) — see the switch below, which now checks
  # PLUGIN_EXPORT_SECRETS before ever setting AULTHIUM_API_KEY.
  local _key=""
  case "$PROVIDER" in
    google)
      export AULTHIUM_API_KIND="google"
      export AULTHIUM_API_URL="$GOOGLE_API_BASE"
      _key="$GOOGLE_KEY"
      ;;
    openrouter)
      export AULTHIUM_API_KIND="openai"
      export AULTHIUM_API_URL="$OPENROUTER_URL"
      _key="$OPENROUTER_KEY"
      ;;
    mistral)
      export AULTHIUM_API_KIND="openai"
      export AULTHIUM_API_URL="$MISTRAL_URL"
      _key="$MISTRAL_KEY"
      ;;
    huggingface)
      export AULTHIUM_API_KIND="openai"
      export AULTHIUM_API_URL="$HF_URL"
      _key="$HF_KEY"
      ;;
    nvidia_nim)
      export AULTHIUM_API_KIND="openai"
      export AULTHIUM_API_URL="$NVIDIA_URL"
      _key="$NVIDIA_KEY"
      ;;
    custom)
      export AULTHIUM_API_KIND="openai"
      export AULTHIUM_API_URL="$CUSTOM_URL"
      _key="$CUSTOM_KEY"
      ;;
    *)
      export AULTHIUM_API_KIND=""
      export AULTHIUM_API_URL=""
      ;;
  esac
  # Only ever hand the live API key to a plugin that declared "secrets" in
  # its plugin.json permissions AND was granted it via
  # plugin_confirm_permissions (see PLUGIN_EXPORT_SECRETS, set by
  # plugin_run right before this is called). A plugin that didn't ask for
  # "secrets" gets AULTHIUM_API_KEY="" — it can still see which provider/
  # model is active (AULTHIUM_PROVIDER/AULTHIUM_MODEL), it just can't talk
  # to the API on your behalf unless it said up front that it would.
  if [[ "${PLUGIN_EXPORT_SECRETS:-0}" -eq 1 ]]; then
    export AULTHIUM_API_KEY="$_key"
  else
    export AULTHIUM_API_KEY=""
  fi
}

# Exports a running plugin's effective config (plugin.json defaults
# overlaid with any local config.json overrides — see
# plugin_config_effective above) so a plugin can read its own settings
# without reinventing config-file parsing itself:
#   AULTHIUM_PLUGIN_NAME          the plugin's own name
#   AULTHIUM_PLUGIN_CONFIG_JSON   the whole effective config, as compact JSON
#   AULTHIUM_PLUGIN_CFG_<KEY>     one var per top-level scalar config key,
#                                  upper-cased with non-alnum chars -> "_"
# PLUGIN_LAST_CFG_VARS remembers exactly which var names were exported so
# plugin_unset_config_env can clean up precisely, however many/few config
# keys a given plugin happens to declare.
PLUGIN_LAST_CFG_VARS=()
plugin_export_config_env() {
  local name="$1" dir="$2" eff key val varname
  eff="$(plugin_config_effective "$dir")"
  [[ -n "$eff" ]] || eff="{}"
  export AULTHIUM_PLUGIN_CONFIG_JSON="$eff"
  export AULTHIUM_PLUGIN_NAME="$name"
  PLUGIN_LAST_CFG_VARS=(AULTHIUM_PLUGIN_CONFIG_JSON AULTHIUM_PLUGIN_NAME)
  while IFS=$'\t' read -r key val; do
    [[ -z "$key" ]] && continue
    varname="AULTHIUM_PLUGIN_CFG_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    export "$varname=$val"
    PLUGIN_LAST_CFG_VARS+=("$varname")
  done < <(printf '%s' "$eff" | jq -r 'to_entries[] | select(.value | (type == "string") or (type == "number") or (type == "boolean")) | "\(.key)\t\(.value)"' 2>/dev/null)
}

plugin_unset_config_env() {
  local v
  for v in "${PLUGIN_LAST_CFG_VARS[@]:-}"; do
    [[ -n "$v" ]] && unset "$v"
  done
  PLUGIN_LAST_CFG_VARS=()
}

# `t> plugin run --stoprun <name>` — the counterpart to registering a hook
# plugin. Unlike `t> plugin toggle <name> off` (which just flips it
# inactive but keeps it registered, so turning it back on is instant),
# this fully de-registers it: clears its RUNNING_PLUGIN_* entries, frees
# its toggle prefix, and releases whichever hook point it owned. A plugin
# stopped this way needs a fresh `t> plugin run <name>` (and re-confirmation)
# to become active again — same as a foreground plugin needing to be
# started over after Ctrl+C.
plugin_stoprun() {
  local name="$1"
  if [[ -z "$name" ]]; then
    warn "Usage: t> plugin run --stoprun <name>"
    return 1
  fi
  if [[ -z "${RUNNING_PLUGIN_ENABLED[$name]:-}" ]]; then
    warn "'$name' isn't currently running as a hook plugin — nothing to stop."
    return 1
  fi

  local prefix="${RUNNING_PLUGIN_TOGGLE_PREFIX[$name]:-}"
  [[ -n "$prefix" ]] && unset "TOGGLE_PREFIX_TO_PLUGIN[$prefix]"
  hook_release_ownership "$name"
  unset "RUNNING_PLUGIN_ENABLED[$name]" "RUNNING_PLUGIN_HOOK[$name]" \
        "RUNNING_PLUGIN_ENTRY[$name]" "RUNNING_PLUGIN_DIR[$name]" \
        "RUNNING_PLUGIN_TOGGLE_PREFIX[$name]" "RUNNING_PLUGIN_PRIORITY[$name]"
  plugin_hook_state_save "$name" "stopped"

  ok "Stopped '$name' — it's fully de-registered now (run it again with t> plugin run $name)."
}

# `t> plugin toggle <name> <on|off>` — flips an already-*running* hook
# plugin's active/inactive state without de-registering it. This is the
# generic version of a plugin's own "<prefix>> on/off" shorthand (see
# RUNNING_PLUGIN_TOGGLE_PREFIX / the main loop's prefix dispatch below) —
# every hook plugin supports this, whether or not it also defines its own
# short prefix.
plugin_toggle() {
  local name="$1" state="$2"
  if [[ -z "$name" || -z "$state" ]]; then
    warn "Usage: t> plugin toggle <name> <on|off>"
    return 1
  fi
  state="${state,,}"
  if [[ "$state" != "on" && "$state" != "off" ]]; then
    warn "Usage: t> plugin toggle <name> <on|off>"
    return 1
  fi
  if [[ -z "${RUNNING_PLUGIN_ENABLED[$name]:-}" ]]; then
    warn "'$name' isn't running yet — start it with 't> plugin run $name' first."
    return 1
  fi

  RUNNING_PLUGIN_ENABLED[$name]="$state"
  plugin_hook_state_save "$name" "$state"
  if [[ "$state" == "on" ]]; then
    ok "'$name' is now active."
  else
    warn "'$name' is now toggled off (still running — its hook just falls through to the built-in behavior)."
  fi
}

plugin_run() {
  if [[ "$1" == "--stoprun" ]]; then
    plugin_stoprun "$2"
    return $?
  fi

  local name="$1"; shift || true
  local dir manifest entry runtime desc mode hook toggle_prefix status priority

  if [[ -z "$name" ]]; then
    warn "Usage: t> plugin run <name>"
    return 1
  fi

  dir="$PLUGINS_DIR/$name"
  manifest="$dir/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    local builtin_repo
    if builtin_repo="$(builtin_plugin_repo_for "$name")" && [[ -n "$builtin_repo" ]]; then
      warn "Plugin '$name' isn't installed yet — it ships as a separate GitHub repo instead of being bundled in this script."
      if confirm_yes_no "Install '$name' now from github.com/$builtin_repo?"; then
        plugin_install_github "$builtin_repo" || return 1
      else
        warn "Cancelled."
        return 1
      fi
    else
      err "No plugin named '$name'. Run 't> plugin list' to see what's installed, or 't> plugin install github:<owner>/<repo>' to fetch one."
      return 1
    fi
  fi

  entry="$(jq -r '.entry // empty' "$manifest" 2>/dev/null)"
  runtime="$(jq -r '.runtime // empty' "$manifest" 2>/dev/null)"
  desc="$(jq -r '.description // ""' "$manifest" 2>/dev/null)"
  mode="$(jq -r '.mode // "foreground"' "$manifest" 2>/dev/null)"
  hook="$(jq -r '.hook // empty' "$manifest" 2>/dev/null)"
  toggle_prefix="$(jq -r '.toggle_prefix // empty' "$manifest" 2>/dev/null)"
  priority="$(jq -r '.priority // 0' "$manifest" 2>/dev/null)"
  [[ "$priority" =~ ^-?[0-9]+$ ]] || priority=0

  if [[ -z "$entry" ]]; then
    err "Plugin '$name' has no \"entry\" command in its plugin.json — can't run it."
    return 1
  fi
  if [[ -n "$runtime" ]] && ! want_cmd "$runtime"; then
    err "Plugin '$name' needs '$runtime', which isn't installed/available on this system."
    return 1
  fi
  if [[ -z "$PROVIDER" ]]; then
    err "No provider selected yet — run 't> provider' first, then try again."
    return 1
  fi

  box_top "PLUGIN RUN" "$ICON_PLUGIN" "$C_ACCENT2"
  box_line "${C_BOLD}${name}${C_RESET}${C_MUTED} — ${desc}${C_RESET}"
  box_line "${C_MUTED}entry:${C_RESET} $entry"
  box_line "${C_MUTED}dir:${C_RESET}   $dir"
  [[ "$mode" == "hook" ]] && box_line "${C_MUTED}mode:${C_RESET}  hook (${hook:-?}) — stays in chat, no separate prompt"
  box_bottom "$C_ACCENT2"

  # Integrity drift check — non-blocking (a plugin author edits their own
  # files all the time), but surfaced loudly right before the trust
  # decision below rather than left to be discovered later.
  local _stored_hash _current_hash
  _stored_hash="$(jq -r '._integrity.sha256 // empty' "$manifest" 2>/dev/null)"
  if [[ -n "$_stored_hash" ]]; then
    _current_hash="$(plugin_tree_checksum "$dir")"
    if [[ "$_current_hash" != "$_stored_hash" ]]; then
      warn "'$name' files have changed since they were installed/verified (on-disk hash no longer matches plugin.json's _integrity.sha256)."
      warn "Run 't> plugin verify $name' for details before trusting this run."
    fi
  fi

  warn "Plugins are ordinary external programs — Aulthium does not sandbox them like the file agent."
  if ! plugin_confirm_permissions "$name" "$manifest"; then
    warn "Cancelled."
    return 1
  fi
  local _perm_list
  _perm_list="$(jq -r '.permissions // [] | join(" ")' "$manifest" 2>/dev/null)"
  if [[ " $_perm_list " == *" secrets "* ]]; then
    PLUGIN_EXPORT_SECRETS=1
  else
    PLUGIN_EXPORT_SECRETS=0
  fi

  # Hook plugins (mode:"hook" in their manifest, e.g. better-websearch)
  # don't take over the terminal — they just register here and get
  # invoked on-demand at whatever hook point they declared. Chat keeps
  # going at "User>" immediately; no Ctrl+C dance, no foreground eval.
  if [[ "$mode" == "hook" ]]; then
    if [[ -z "$hook" ]]; then
      err "Plugin '$name' has \"mode\": \"hook\" but no \"hook\" field naming what it hooks — can't register it."
      return 1
    fi

    if ! hook_point_is_known "$hook"; then
      err "Plugin '$name' declares an unknown hook point '$hook' — this version of Aulthium only knows: $KNOWN_HOOK_POINTS."
      return 1
    fi
    if ! hook_claim_ownership "$name" "$hook" "$priority"; then
      return 1
    fi
    RUNNING_PLUGIN_PRIORITY[$name]="$priority"

    if [[ -n "$toggle_prefix" ]]; then
      if [[ -n "${TOGGLE_PREFIX_TO_PLUGIN[$toggle_prefix]:-}" && "${TOGGLE_PREFIX_TO_PLUGIN[$toggle_prefix]}" != "$name" ]]; then
        warn "Toggle prefix '${toggle_prefix}>' is already claimed by '${TOGGLE_PREFIX_TO_PLUGIN[$toggle_prefix]}' — '$name' will only be toggleable via t> plugin toggle."
        toggle_prefix=""
      else
        TOGGLE_PREFIX_TO_PLUGIN[$toggle_prefix]="$name"
      fi
    fi

    RUNNING_PLUGIN_ENABLED[$name]="on"
    RUNNING_PLUGIN_HOOK[$name]="$hook"
    RUNNING_PLUGIN_ENTRY[$name]="$entry"
    RUNNING_PLUGIN_DIR[$name]="$dir"
    RUNNING_PLUGIN_TOGGLE_PREFIX[$name]="$toggle_prefix"
    plugin_hook_state_save "$name" "on"

    ok "'$name' is active — it'll now handle $hook automatically. Keep chatting at User>."
    if [[ -n "$toggle_prefix" ]]; then
      muted "Toggle it with: ${toggle_prefix}> on|off   —   or: t> plugin toggle $name on|off   —   stop it fully with: t> plugin run --stoprun $name"
    else
      muted "Toggle it with: t> plugin toggle $name on|off   —   stop it fully with: t> plugin run --stoprun $name"
    fi
    return 0
  fi

  plugin_export_env
  plugin_export_config_env "$name" "$dir"
  say "Starting '$name' — press Ctrl+C to stop it and return to chat."
  # Ctrl+C while the plugin is in the foreground delivers SIGINT to this
  # whole process group — including US, not just the plugin's child
  # process. Without this, our own `trap cleanup_exit INT` (set way up at
  # the top of the script) fires right alongside the plugin's own Ctrl+C
  # handling, so we'd print "Aulthium has been closed." and exit(0) the
  # instant the plugin merely stopped. Swap in a no-op handler for the
  # duration of the plugin run instead: it's a *caught* signal (not
  # SIG_IGN), so it does NOT propagate as "ignored" to the plugin's child
  # process across fork/exec — that child still gets normal default
  # SIGINT behavior (e.g. Python raising KeyboardInterrupt as usual) and
  # can react to Ctrl+C on its own, same as it always could. We just stop
  # *our* trap from also treating that same keypress as "quit the whole
  # app". Restored to the real trap right after, whether the plugin
  # exited cleanly, was Ctrl+C'd, or errored.
  trap ':' INT
  ( cd "$dir" && eval "$entry" "$@" )
  status=$?
  trap cleanup_exit INT

  unset AULTHIUM_API_KEY AULTHIUM_API_URL AULTHIUM_API_KIND AULTHIUM_PROVIDER \
        AULTHIUM_PROVIDER_LABEL AULTHIUM_MODEL AULTHIUM_WORKSPACE_DIR \
        AULTHIUM_APP_NAME AULTHIUM_APP_VERSION AULTHIUM_SKIP_CONFIRMATIONS \
        AULTHIUM_MAX_RATE_LIMIT_RETRIES AULTHIUM_MAX_RATE_LIMIT_WAIT \
        AULTHIUM_SHELL_TIMEOUT_SECS
  plugin_unset_config_env
  PLUGIN_EXPORT_SECRETS=0

  if [[ $status -ne 0 ]]; then
    warn "Plugin '$name' exited with status $status."
  else
    ok "Plugin '$name' finished."
  fi
}

plugin_install() {
  local src="$1" name dest
  if [[ -z "$src" ]]; then
    warn "Usage: t> plugin install <path-to-plugin-folder | github:<owner>/<repo> | https://.../file.zip>"
    return 1
  fi
  if [[ "$src" == github:* ]]; then
    plugin_install_github "${src#github:}"
    return $?
  fi
  if [[ "$src" == http://* || "$src" == https://* ]]; then
    plugin_install_from_url "$src"
    return $?
  fi
  src="${src/#\~/$HOME}"
  if [[ ! -d "$src" ]]; then
    err "Not a folder: $src"
    return 1
  fi
  if [[ ! -f "$src/plugin.json" ]]; then
    err "No plugin.json found in $src — see BUILD_PLUGIN.md for the manifest format."
    return 1
  fi
  if ! plugin_manifest_validate "$src/plugin.json"; then
    err "Refusing to install — plugin.json failed validation (see above)."
    return 1
  fi
  name="$(jq -r '.name // empty' "$src/plugin.json" 2>/dev/null)"
  plugins_ensure_dir
  dest="$PLUGINS_DIR/$name"
  if [[ -d "$dest" ]]; then
    if ! confirm_yes_no "Plugin '$name' already exists — overwrite it?"; then
      warn "Cancelled."
      return 1
    fi
    rm -rf -- "$dest"
  fi
  if cp -R "$src" "$dest" 2>/dev/null; then
    plugin_stamp_integrity "$dest"
    ok "Installed plugin '$name' → $dest"
    plugin_install_show_permissions "$dest/plugin.json"
    muted "Run it with: t> plugin run $name"
  else
    err "Failed to copy plugin into $dest"
  fi
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

# If a "chat_pre" hook plugin is registered and toggled on, lets it
# rewrite the user's message before it's added to conversation history and
# sent to the model. Entry is invoked as: <entry> chat_pre <message>. Exit
# 0 + non-empty stdout REPLACES the outgoing message (what the model sees
# — and what gets stored in history — is the plugin's output, not what the
# user typed). Exit 0 + empty stdout, or a non-zero exit, leaves the
# message unchanged. There's no VETO here — a plugin that wants to block a
# message entirely can just not be a great fit for this hook point; send
# it back as empty-ish text instead. Always sets CHAT_PRE_HOOK_TEXT to
# whatever should actually be sent.
chat_pre_plugin_hook() {
  local text="$1" name
  CHAT_PRE_HOOK_TEXT="$text"
  hook_point_is_active "chat_pre" || return 0
  name="${HOOK_OWNER[chat_pre]}"

  if plugin_hook_call "$name" "chat_pre" "$text" && [[ -n "$PLUGIN_HOOK_OUTPUT" ]]; then
    CHAT_PRE_HOOK_TEXT="$PLUGIN_HOOK_OUTPUT"
  fi
  return 0
}

send_chat() {
  local user_text="$1"
  check_chat_limit
  chat_pre_plugin_hook "$user_text"
  user_text="$CHAT_PRE_HOOK_TEXT"
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
    mcp\ github|mcp\ gh)
      mcp_pick_github
      ;;
    mcp\ oauth\ *)
      rest="${cmd#mcp oauth }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      local mcp_oauth_name="${rest%% *}" mcp_oauth_url="${rest#* }"
      if [[ -z "$mcp_oauth_name" || "$mcp_oauth_name" == "$rest" || -z "$mcp_oauth_url" ]]; then
        warn "Usage: t> mcp oauth <name> <url>"
      else
        mcp_add_server_oauth "$mcp_oauth_name" "$mcp_oauth_url"
      fi
      ;;
    mcp\ cred\ encrypt\ on)
      if ! command -v openssl >/dev/null 2>&1; then
        err "openssl isn't installed — can't enable encrypted credential storage."
      else
        CRED_STORE_MODE="encrypted"
        CRED_STORE_PASSPHRASE=""
        ok "Encrypted credential storage enabled — you'll be prompted for a passphrase on first use this session."
      fi
      ;;
    mcp\ cred\ encrypt\ off)
      CRED_STORE_MODE="plain"
      CRED_STORE_PASSPHRASE=""
      warn "Credential storage set back to plain (permission-restricted) mode. Existing encrypted credentials won't be readable until you turn encryption back on."
      ;;
    mcp\ cred\ clear)
      if confirm_action "Delete ALL stored MCP credentials (OAuth tokens) from disk?"; then
        cred_clear
        ok "Cleared the credential store."
      fi
      ;;
    mcp\ cred*)
      warn "Usage: t> mcp cred [encrypt on|off | clear]"
      ;;
    mcp\ *)
      warn "Unknown mcp subcommand. Usage: t> mcp [add <name> <url> | oauth <name> <url> | remove <name> | list | refresh [name] | cloudflare | github | cred ...]"
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
    plugin|plugin\ list)
      plugin_list
      ;;
    plugin\ run\ *)
      rest="${cmd#plugin run }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin run <name>  (or: t> plugin run --stoprun <name>)"
      else
        plugin_run $rest
      fi
      ;;
    plugin\ info\ *)
      rest="${cmd#plugin info }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin info <name>"
      else
        plugin_info "$rest"
      fi
      ;;
    plugin\ install\ *)
      rest="${cmd#plugin install }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin install <path | github:<owner>/<repo> | url>"
      else
        plugin_install "$rest"
      fi
      ;;
    plugin\ verify\ *)
      rest="${cmd#plugin verify }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin verify <name>"
      else
        plugin_verify "$rest"
      fi
      ;;
    plugin\ config\ *)
      rest="${cmd#plugin config }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin config <name> [list | get <key> | set <key> <value> | unset <key>]"
      else
        plugin_config $rest
      fi
      ;;
    plugin\ update)
      plugin_update
      ;;
    plugin\ update\ *)
      rest="${cmd#plugin update }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        plugin_update
      else
        plugin_update "$rest"
      fi
      ;;
    plugin\ remove\ *|plugin\ delete\ *)
      rest="${cmd#plugin remove }"
      rest="${rest#plugin delete }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin remove <name>"
      else
        plugin_remove "$rest"
      fi
      ;;
    plugin\ toggle\ *)
      rest="${cmd#plugin toggle }"
      rest="${rest#"${rest%%[![:space:]]*}"}"
      if [[ -z "$rest" ]]; then
        warn "Usage: t> plugin toggle <name> <on|off>"
      else
        plugin_toggle $rest
      fi
      ;;
    plugin\ *)
      warn "Unknown plugin subcommand. Usage: t> plugin [list | run <name> | info <name> | install <path|github:owner/repo|url> | update [name] | remove <name> | toggle <name> <on|off> | config <name> ... | verify <name> | run --stoprun <name>]"
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

# Forwards anything after "<prefix>> " that ISN'T the literal on/off
# toggle straight to a hook plugin's entry command, using the exact same
# call convention web_search_query_plugin_hook already uses for it: the
# text goes in as one shell-quoted argv argument, and whatever the entry
# prints to stdout is shown back in chat as-is. Aulthium doesn't parse or
# know anything about the subcommand itself (e.g. "use my-skill") — that
# meaning is entirely up to the plugin's own entry script. A plugin that
# only ever wants on/off never has to care this exists; it's purely
# opt-in by the plugin choosing to handle extra argv beyond a bare query.
#
# Deliberately gated on RUNNING_PLUGIN_ENABLED like the hook call is —
# toggling a plugin off with "<prefix>> off" also stops this shorthand
# from reaching it, rather than leaving a side door open while "off".
plugin_toggle_prefix_forward() {
  local name="$1" rest="$2" dir entry output status _perm_list

  if [[ "${RUNNING_PLUGIN_ENABLED[$name]:-off}" != "on" ]]; then
    warn "'$name' is toggled off — turn it on first with: t> plugin toggle $name on"
    return 1
  fi

  dir="${RUNNING_PLUGIN_DIR[$name]}"
  entry="${RUNNING_PLUGIN_ENTRY[$name]}"

  _perm_list="$(jq -r '.permissions // [] | join(" ")' "$dir/plugin.json" 2>/dev/null)"
  [[ " $_perm_list " == *" secrets "* ]] && PLUGIN_EXPORT_SECRETS=1 || PLUGIN_EXPORT_SECRETS=0
  plugin_export_env
  plugin_export_config_env "$name" "$dir"
  output="$(cd "$dir" && eval "$entry" "$(printf '%q' "$rest")" 2>&1)"
  status=$?
  unset AULTHIUM_API_KEY AULTHIUM_API_URL AULTHIUM_API_KIND AULTHIUM_PROVIDER \
        AULTHIUM_PROVIDER_LABEL AULTHIUM_MODEL AULTHIUM_WORKSPACE_DIR \
        AULTHIUM_APP_NAME AULTHIUM_APP_VERSION AULTHIUM_SKIP_CONFIRMATIONS \
        AULTHIUM_MAX_RATE_LIMIT_RETRIES AULTHIUM_MAX_RATE_LIMIT_WAIT \
        AULTHIUM_SHELL_TIMEOUT_SECS
  plugin_unset_config_env
  PLUGIN_EXPORT_SECRETS=0

  [[ -n "$output" ]] && printf '%s\n' "$output"
  if [[ $status -ne 0 ]]; then
    warn "'$name' exited $status handling: $rest"
  fi
  return $status
}

# Anything that isn't a "t> ..." command lands here. Ordinarily that's
# just a chat message, but a running hook plugin with a "toggle_prefix"
# (e.g. better-websearch's "bws") gets first look — typing "bws> on" or
# "bws> off" at the normal chat prompt is recognized as that plugin's
# shorthand toggle instead of being sent to the AI as a message, so
# switching it on/off never requires leaving the chat flow at User> at
# all. Anything else after the prefix (e.g. "skills> use my-skill") is
# forwarded verbatim to the plugin itself via plugin_toggle_prefix_forward
# rather than rejected — see that function for the call convention. Only
# a completely unrecognized prefix falls straight through to send_chat,
# same as before this existed.
handle_repl_input() {
  local input="$1" prefix rest rest_lc
  for prefix in "${!TOGGLE_PREFIX_TO_PLUGIN[@]}"; do
    case "$input" in
      "${prefix}>"*)
        rest="${input#"${prefix}>"}"
        rest="${rest# }"
        rest_lc="${rest,,}"
        case "$rest_lc" in
          on|off)
            plugin_toggle "${TOGGLE_PREFIX_TO_PLUGIN[$prefix]}" "$rest_lc"
            ;;
          "")
            warn "Usage: ${prefix}> <on|off|...>"
            ;;
          *)
            plugin_toggle_prefix_forward "${TOGGLE_PREFIX_TO_PLUGIN[$prefix]}" "$rest"
            ;;
        esac
        return 0
        ;;
    esac
  done
  send_chat "$input"
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
  plugins_ensure_dir
  plugins_autostart

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
        handle_repl_input "$input"
        ;;
    esac
  done
}

main "$@"
