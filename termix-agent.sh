#!/usr/bin/env bash
set -u

# TERMIX AGENT
# Single-file Bash terminal AI client for Termux / Linux
# Talks to either OpenRouter or Google AI Studio, chosen via 't> provider'.
# Conversation stays in memory only while the process is running.

APP_NAME="TERMIX AGENT"
APP_VERSION="v1.2"
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

CURRENT_MODEL="$DEFAULT_MODEL"
CURRENT_MODEL_LABEL="$DEFAULT_MODEL"

# Sandbox directory the agent is allowed to create/edit/delete files in.
# Every file action is confined to this folder — nothing outside it is ever touched.
WORKSPACE_DIR=""

# In-memory conversation history only.
# We keep the system prompt in the history from the start.
build_system_prompt() {
  cat <<EOF
You are Termix Agent, a helpful terminal-based AI assistant. Answer clearly and concisely. Be practical, friendly, and accurate.

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

=== TOOL USE POLICY (avoid wasting actions) ===

You get a limited number of action rounds per user message ($MAX_AGENT_ROUNDS) before you're cut off and
asked to wrap up, so spend them deliberately:
- Never call a read/inspect marker (FILE_READ, DIR_LIST, ZIP_LIST, ZIP_READ, WEB_SEARCH) for something already
  shown earlier in this same conversation — check what you already know before asking again.
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
ICON_SHELL="❯"    # running a shell command
ICON_SEARCH="⌕"   # web search
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

banner() {
  printf "${C_ACCENT}"
  cat <<'EOF'
████████╗███████╗██████╗ ███╗   ███╗██╗██╗  ██╗
╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║╚██╗██╔╝
   ██║   █████╗  ██████╔╝██╔████╔██║██║ ╚███╔╝
   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║ ██╔██╗
   ██║   ███████╗██║  ██║██║ ╚═╝ ██║██║██╔╝ ██╗
   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═╝
EOF
  printf "${C_RESET}${C_DIM}             T E R M I X   A G E N T${C_RESET}\n"
  printf "${C_MUTED}               AI Terminal Assistant · %s${C_RESET}\n\n" "$APP_VERSION"
}

# Renders the "connected / model / sandbox" status panel shown at startup
# and after 't> clear'. Centralized so both call sites always match.
status_panel() {
  printf "${C_ACCENT2}┌─ SESSION ─────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} %-10s ${C_OK}%s${C_RESET}\n" "provider" "$(provider_label) — connected"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "model" "$CURRENT_MODEL"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "sandbox" "$WORKSPACE_DIR"
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

# Finalizes a confirmed model switch: sets CURRENT_MODEL/LABEL, announces
# it, then runs the same clear-screen-and-reprint-status flow as 't> clear'.
# Called from every model-picking path (tier picker, fuzzy search, direct
# name, Google model picker, custom-provider free-text entry) so the
# post-switch behavior is identical no matter how the model was chosen.
apply_model_switch() {
  CURRENT_MODEL="$1"
  CURRENT_MODEL_LABEL="$CURRENT_MODEL"
  ok "Switched to: $CURRENT_MODEL"
  run_clear_screen
}

cleanup_exit() {
  stop_spinner
  restore_tty
  printf '\n'
  printf "${C_OK}%s${C_RESET}\n" "Termix Agent has been closed." >&2
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
  HAVE_FILE=1
  want_cmd file || HAVE_FILE=0
  HAVE_TIMEOUT=1
  want_cmd timeout || HAVE_TIMEOUT=0

  # Web search parses HTML results (DuckDuckGo, then Bing, then Startpage —
  # see web_search_query) with PCRE (grep -P, needed for \K and non-greedy
  # matching) when available; otherwise it falls back to a plain POSIX-ERE
  # parser that's a bit less precise but still functional.
  HAVE_GREP_PCRE=1
  printf 'x' | grep -Pzo 'x' >/dev/null 2>&1 || HAVE_GREP_PCRE=0
  if [[ "$HAVE_GREP_PCRE" -eq 0 ]]; then
    warn "This system's grep lacks PCRE (-P) support — web search will use a simpler fallback parser."
  fi

  # Preferred web search backend: LangChain's DuckDuckGoSearchAPIWrapper
  # (from langchain-community, itself backed by the duckduckgo-search PyPI
  # package). It does its own request handling and result parsing, which is
  # sturdier than hand-rolled HTML scraping — the scrapers above stay in the
  # script as a dependency-free fallback chain (DuckDuckGo, then Bing, then
  # Startpage) for systems without python3 or those packages installed, or
  # for whenever a given provider is blocked or unreachable on the network.
  HAVE_PYTHON3=1
  want_cmd python3 || HAVE_PYTHON3=0
  HAVE_LANGCHAIN_SEARCH=0
  if [[ "$HAVE_PYTHON3" -eq 1 ]]; then
    python3 -c "from langchain_community.utilities import DuckDuckGoSearchAPIWrapper" >/dev/null 2>&1 \
      && HAVE_LANGCHAIN_SEARCH=1
  fi
  if [[ "$HAVE_LANGCHAIN_SEARCH" -eq 0 ]]; then
    if [[ "$HAVE_PYTHON3" -eq 1 ]]; then
      muted "Tip: 'pip install langchain-community duckduckgo-search' gives web search a sturdier backend (currently falling back to scraping DuckDuckGo/Bing/Startpage directly)."
    fi
  fi
}

confirm_yes_no() {
  local prompt="$1" ans
  read -r -p "$(printf "${C_ACCENT2}?${C_RESET} %s ${C_MUTED}[y/N]${C_RESET} " "$prompt")" ans || ans="n"
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
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

# Picks the default workspace location: a "termixai-workspace" folder inside
# the device's real Downloads folder, so files are immediately visible in
# the normal file manager / Gallery-adjacent apps with no extra copy step.
# Falls back to the current directory only if no Downloads folder is found.
default_workspace_dir() {
  local name="termixai-workspace"

  if [[ -n "${TERMIX_WORKDIR:-}" ]]; then
    printf '%s' "$TERMIX_WORKDIR"
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

append_message() {
  local role="$1"
  local content="$2"
  messages_json="$(jq -c --arg role "$role" --arg content "$content" '. + [{role:$role, content:$content}]' <<< "$messages_json")"
}

# Rough, provider-agnostic safeguard against runaway context growth: this
# script has no real tokenizer and doesn't know each model's actual context
# window, so it uses total JSON character count as a cheap proxy for size.
# Not a hard API limit — just a local guardrail so a very long-running chat
# gets a deliberate choice instead of silently growing until the provider
# rejects the request.
CHAT_HISTORY_CHAR_LIMIT=32000

# Writes the full conversation (skipping the system prompt) out to a
# timestamped markdown file in the sandbox. Prints the saved path on
# success, nothing on failure.
archive_chat_history() {
  local ts path
  ts="$(date +%Y%m%d-%H%M%S)"
  path="$WORKSPACE_DIR/termix-chat-history-$ts.md"

  {
    printf '# Termix Agent — saved chat history\n\n'
    printf '_saved %s · provider: %s · model: %s_\n\n' "$(date)" "$(provider_label)" "$CURRENT_MODEL"
    jq -r '.[1:][] | "### \(.role)\n\n\(.content)\n"' <<< "$messages_json"
  } > "$path" 2>/dev/null

  if [[ -f "$path" ]]; then
    printf '%s' "$path"
  fi
}

# Drops the oldest half of the non-system messages (index 0, the system
# prompt, is always kept) — used when the user declines to archive at the
# chat limit, so they can keep going without saving anything.
trim_oldest_history() {
  local count keep_from
  count="$(jq 'length' <<< "$messages_json")"
  (( count <= 3 )) && return 0
  keep_from=$(( count / 2 ))
  messages_json="$(jq --argjson k "$keep_from" '[.[0]] + .[$k:]' <<< "$messages_json")"
}

# The chat-limit blocker: called at the start of every send_chat. Below the
# threshold this is a no-op. At/above it, the user is stopped and must
# choose — archive the full history to a sandbox file and continue with a
# clean, effectively-unlimited context, or decline and have the oldest
# turns silently trimmed to make room instead.
check_chat_limit() {
  local size saved_path

  size="$(printf '%s' "$messages_json" | wc -c | tr -d ' ')"
  [[ "$size" -lt "$CHAT_HISTORY_CHAR_LIMIT" ]] && return 0

  echo
  printf "${C_WARN}┌─ CHAT LIMIT REACHED ───────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} This conversation has grown large enough that it\n"
  printf "${C_MUTED}│${C_RESET} risks hitting the model's real context limit.\n"
  printf "${C_WARN}└─────────────────────────────────────────────${C_RESET}\n\n"

  if confirm_yes_no "Save the full history to a file in your sandbox and continue unlimited?"; then
    saved_path="$(archive_chat_history)"
    if [[ -n "$saved_path" ]]; then
      init_history
      append_message "assistant" "(Earlier conversation archived to $(basename "$saved_path") in the sandbox. Continuing with a clean context — ask if you need something from before.)"
      ok "History saved to $saved_path"
      muted "Conversation reset — you're good for a lot more now."
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
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> clear" "clear the terminal"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> reset" "start a new conversation"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> history" "show chat history"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> exit" "exit Termix Agent"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_MUTED}Chat: type any normal message at the ${C_RESET}User>${C_MUTED} prompt.${C_RESET}\n"
  printf "${C_MUTED}If the conversation gets very long, you'll be asked whether to save it to\n"
  printf "a file in the sandbox and continue fresh, or trim the oldest turns instead.${C_RESET}\n"

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
  printf "${C_MUTED}│${C_RESET}       tries DuckDuckGo, then Bing, then Startpage if one is\n"
  printf "${C_MUTED}│${C_RESET}       blocked or unreachable; also automatic, read-only, no\n"
  printf "${C_MUTED}│${C_RESET}       confirmation needed.\n"
  printf "${C_MUTED}│${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_WARN}${ICON_WRITE} ${ICON_DELETE} ${ICON_FOLDER}${C_RESET}  write/overwrite a file, delete a single file,\n"
  printf "${C_MUTED}│${C_RESET}       delete a folder (and everything inside it), or create\n"
  printf "${C_MUTED}│${C_RESET}       an empty folder — every one of these is shown to you\n"
  printf "${C_MUTED}│${C_RESET}       and needs a yes/no confirmation first. Nothing ever\n"
  printf "${C_MUTED}│${C_RESET}       reaches outside the sandbox folder.\n"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_ACCENT2}┌─ SHELL AGENT ─────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_ERR}${ICON_SHELL}${C_RESET}      the agent can propose shell command(s), shown\n"
  printf "${C_MUTED}│${C_RESET}       to you in full before you approve or decline.\n"
  printf "${C_MUTED}│${C_RESET}       Unlike file actions, shell commands are ${C_BOLD}NOT${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET}       confined to the sandbox — they run with your real\n"
  printf "${C_MUTED}│${C_RESET}       shell privileges, so only approve what you trust.\n"
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
      assistant) printf "${C_ACCENT}%-10s${C_RESET}%s\n\n" "termix" "$content" ;;
      *) printf "${C_MUTED}%-10s${C_RESET}%s\n\n" "$role" "$content" ;;
    esac
  done
}

fetch_free_models() {
  # Returns a sorted list of free model IDs, one per line.
  local tmp
  tmp="$(mktemp)"

  if ! curl -fsSL "$OPENROUTER_MODELS_URL" -o "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  jq -r '
    .data[]
    | .id
    | select(endswith(":free"))
  ' "$tmp" 2>/dev/null | sort -u

  rm -f "$tmp"
}

fetch_paid_models() {
  # Returns a sorted list of non-free (billed) model IDs, one per line.
  local tmp
  tmp="$(mktemp)"

  if ! curl -fsSL "$OPENROUTER_MODELS_URL" -o "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi

  jq -r '
    .data[]
    | .id
    | select(endswith(":free") | not)
  ' "$tmp" 2>/dev/null | sort -u

  rm -f "$tmp"
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

  if confirm_yes_no "Apply this write?"; then
    mkdir -p "$parent_dir" 2>/dev/null
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
  local abs total new_lines old_lines tmpfile

  abs="$(resolve_safe_path "$rel")" || { warn "Skipped unsafe edit proposal: $rel"; return; }

  if [[ ! -e "$abs" ]]; then
    err "Cannot edit, file does not exist (use FILE_WRITE to create it first): $abs"
    return
  fi
  if [[ -d "$abs" ]]; then
    err "That's a folder, not a file: $abs"
    return
  fi

  total="$(wc -l < "$abs" | tr -d ' ')"

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

  new_lines="$(wc -l < "$content_file" | tr -d ' ')"
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

  if confirm_yes_no "Apply this edit?"; then
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

  if confirm_yes_no "Create this folder?"; then
    if mkdir -p "$abs"; then
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

  if confirm_yes_no "Delete this file?"; then
    if rm -f "$abs"; then
      ok "Deleted $abs"
    else
      err "Failed to delete $abs"
    fi
  else
    warn "Skipped delete: $rel"
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
  warn "This deletes the folder AND everything inside it — this cannot be undone."

  if confirm_yes_no "Delete this folder and everything inside it?"; then
    if rm -rf "$abs"; then
      ok "Deleted $abs"
    else
      err "Failed to delete $abs"
    fi
  else
    warn "Skipped folder delete: $rel"
  fi
}

# Caps applied when feeding file/command output back to the model, so a huge
# file or noisy command can't blow up the conversation.
MAX_PREVIEW_BYTES=8000
MAX_PREVIEW_LINES=300
SHELL_TIMEOUT_SECS=60

# Truncates stdin to MAX_PREVIEW_BYTES/MAX_PREVIEW_LINES and notes if it did.
cap_preview() {
  local input="$1" out lines bytes
  out="$(printf '%s' "$input" | head -c "$MAX_PREVIEW_BYTES")"
  out="$(printf '%s' "$out" | head -n "$MAX_PREVIEW_LINES")"
  bytes="${#input}"
  lines="$(printf '%s' "$input" | wc -l | tr -d ' ')"
  printf '%s' "$out"
  if (( bytes > ${#out} )); then
    printf '\n[...truncated, %s bytes / %s lines total...]' "$bytes" "$lines"
  fi
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

# Percent-decodes a URL-encoded string using only bash/printf built-ins (no
# python/perl dependency). "+' is treated as a literal space per the
# application/x-www-form-urlencoded convention DuckDuckGo's redirect links
# use for their uddg= parameter.
url_decode() {
  local encoded="${1//+/ }"
  printf '%b' "${encoded//%/\\x}"
}

# Generic HTML-scrape web search backend, parameterized per provider so
# DuckDuckGo, Bing, and Startpage can all reuse the same fetch/parse/decode
# logic (see the three thin wrappers below this function). Used whenever the
# LangChain backend isn't available, or a given provider is unreachable —
# see web_search_query for the fallback chain. This never talks to
# OpenRouter/Google at all — it's a plain curl + local HTML parse, so it
# costs nothing either way. Sets WEB_SEARCH_LAST_ERROR to a short reason on
# failure so the caller can tell the user something more useful than "it
# didn't work".
#
# Args:
#   $1  provider_label   — short name for error messages (e.g. "bing.com")
#   $2  url               — full request URL, query already percent-encoded
#   $3  pcre_tag_re        — PCRE: the whole opening <a ...> tag of a result
#                            title (used to pull href out of via bash regex)
#   $4  pcre_title_re      — PCRE: the title link's inner text (\K...(?=</a>))
#   $5  pcre_snippet_re    — PCRE: the snippet text (\K...(?=</...>))
#   $6  ere_title_tag_re   — POSIX ERE fallback: whole "<a ...>text</a>" tag
#                            (no PCRE -P support on this system's grep)
#   $7  ere_snippet_tag_re — POSIX ERE fallback: snippet's opening tag plus
#                            its text up to the next "<" (opening tag itself
#                            is stripped off after the match, up to the
#                            first ">")
#   $8  unwrap_ddg_redirect — "1" if hrefs are wrapped DuckDuckGo-style as
#                            //duckduckgo.com/l/?uddg=<encoded real URL> and
#                            need unwrapping; empty/omitted otherwise
#   $9  post_data           — optional. If set (even to ""), the request is
#                            sent as POST with this as the URL-encoded body
#                            (e.g. "q=search+terms") instead of a GET. Omit
#                            this arg entirely to keep the old GET behavior.
WEB_SEARCH_MAX_RESULTS=5
WEB_SEARCH_LAST_ERROR=""
web_search_scrape_generic() {
  local provider_label="$1" url="$2"
  local pcre_tag_re="$3" pcre_title_re="$4" pcre_snippet_re="$5"
  local ere_title_tag_re="$6" ere_snippet_tag_re="$7"
  local unwrap_ddg_redirect="${8:-}"
  local have_post_data=$(( $# >= 9 ? 1 : 0 ))
  local post_data="${9:-}"
  local html_tmp curl_args=() titles_raw urls_raw snippets_raw
  local -a titles=() urls=() snippets=()
  local i out n
  WEB_SEARCH_LAST_ERROR=""

  html_tmp="$(mktemp)"
  # Modern, realistic browser headers — a bare curl UA/Accept set gets a
  # flat 403 or a JS challenge page from several search front-ends now
  # (DuckDuckGo's html.duckduckgo.com in particular). These mimic a current
  # desktop Chrome/Windows request closely enough to pass basic bot checks
  # without needing a real browser/JS engine.
  curl_args=(-sSL
             -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
             -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
             -H "Accept-Language: en-US,en;q=0.9"
             -H "Sec-Fetch-Mode: navigate"
             -H "Sec-Fetch-Site: none"
             -H "Sec-Fetch-User: ?1"
             -H "Sec-Fetch-Dest: document"
             -H "Upgrade-Insecure-Requests: 1"
             --max-time 20)

  if [[ "$have_post_data" -eq 1 ]]; then
    curl_args+=(-X POST
                -H "Content-Type: application/x-www-form-urlencoded"
                -H "Origin: https://$(printf '%s' "$url" | sed -E 's#^https?://##; s#/.*##')"
                --data "$post_data")
  fi
  curl_args+=("$url")

  if ! curl "${curl_args[@]}" -o "$html_tmp" 2>/dev/null; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="couldn't reach $provider_label (network/curl error)."
    return 1
  fi

  if [[ ! -s "$html_tmp" ]]; then
    rm -f "$html_tmp"
    WEB_SEARCH_LAST_ERROR="got an empty response from $provider_label."
    return 1
  fi

  if [[ "$HAVE_GREP_PCRE" -eq 1 ]]; then
    # -z treats the whole file as one match space so \K + non-greedy .*? can
    # span the (irrelevant) newlines in the markup. href and class can
    # appear in either order inside the tag, so grab the whole opening tag
    # first and pull href out of that with a plain bash regex rather than
    # assuming an order.
    local -a title_tags=()
    mapfile -d '' -t title_tags < <(grep -Pzo "$pcre_tag_re" "$html_tmp" 2>/dev/null)
    mapfile -d '' -t titles_raw < <(grep -Pzo "$pcre_title_re" "$html_tmp" 2>/dev/null)
    mapfile -d '' -t snippets_raw < <(grep -Pzo "$pcre_snippet_re" "$html_tmp" 2>/dev/null)

    n="${#titles_raw[@]}"
    for ((i = 0; i < n && i < WEB_SEARCH_MAX_RESULTS; i++)); do
      local t u s real_url tag_text
      t="$(printf '%s' "${titles_raw[$i]}" | sed -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&#x27;/'"'"'/g' -e 's/&quot;/"/g')"
      tag_text="${title_tags[$i]:-}"
      u=""
      [[ "$tag_text" =~ href=\"([^\"]*)\" ]] && u="${BASH_REMATCH[1]}"
      if [[ "$unwrap_ddg_redirect" == "1" && "$u" == *"uddg="* ]]; then
        real_url="${u#*uddg=}"
        real_url="${real_url%%&*}"
        real_url="$(url_decode "$real_url")"
      else
        real_url="$u"
      fi
      s="$(printf '%s' "${snippets_raw[$i]:-}" | sed -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&#x27;/'"'"'/g' -e 's/&quot;/"/g')"
      [[ -n "$t" ]] && titles+=("$t") && urls+=("$real_url") && snippets+=("$s")
    done
  else
    # No PCRE (-P) support in this system's grep (common on BSD/macOS grep,
    # busybox/toybox grep on some Termux setups). Fall back to plain POSIX
    # ERE: flatten the file to one line so -o can still return multiple
    # matches, and match "up to the next <" instead of a lazy quantifier
    # (result titles are plain text with no nested tags, so this holds in
    # practice; snippets occasionally have a <b> highlight, which this
    # simpler pass just stops at — good enough for a fallback).
    local flat
    flat="$(tr '\n\r' '  ' < "$html_tmp")"
    local -a title_tags=() snippet_tags=()
    mapfile -t title_tags < <(printf '%s' "$flat" | grep -oE "$ere_title_tag_re" 2>/dev/null)
    mapfile -t snippet_tags < <(printf '%s' "$flat" | grep -oE "$ere_snippet_tag_re" 2>/dev/null)

    n="${#title_tags[@]}"
    for ((i = 0; i < n && i < WEB_SEARCH_MAX_RESULTS; i++)); do
      local tag="${title_tags[$i]}" t u s real_url snip
      u=""
      [[ "$tag" =~ href=\"([^\"]*)\" ]] && u="${BASH_REMATCH[1]}"
      t="$(printf '%s' "$tag" | sed -e 's/^<a[^>]*>//' -e 's/<\/a>$//' -e 's/<[^>]*>//g' -e 's/&amp;/\&/g' -e 's/&#x27;/'"'"'/g' -e 's/&quot;/"/g')"
      if [[ "$unwrap_ddg_redirect" == "1" && "$u" == *"uddg="* ]]; then
        real_url="${u#*uddg=}"
        real_url="${real_url%%&*}"
        real_url="$(url_decode "$real_url")"
      else
        real_url="$u"
      fi
      snip="${snippet_tags[$i]:-}"
      snip="${snip#*>}"
      s="$(printf '%s' "$snip" | sed -e 's/&amp;/\&/g' -e 's/&#x27;/'"'"'/g' -e 's/&quot;/"/g')"
      [[ -n "$t" ]] && titles+=("$t") && urls+=("$real_url") && snippets+=("$s")
    done
  fi

  rm -f "$html_tmp"

  if [[ "${#titles[@]}" -eq 0 ]]; then
    if [[ "$HAVE_GREP_PCRE" -eq 0 ]]; then
      WEB_SEARCH_LAST_ERROR="page fetched fine, but this system's grep lacks PCRE (-P) support and the plain-ERE fallback parser also found nothing — $provider_label's markup may have changed. Consider installing GNU grep."
    else
      WEB_SEARCH_LAST_ERROR="page fetched fine, but no results could be parsed out of it — $provider_label's markup may have changed, or the query returned a no-results page."
    fi
    return 1
  fi

  out=""
  for i in "${!titles[@]}"; do
    out+="$((i + 1)). ${titles[$i]}"$'\n'
    [[ -n "${urls[$i]:-}" ]] && out+="   ${urls[$i]}"$'\n'
    [[ -n "${snippets[$i]:-}" ]] && out+="   ${snippets[$i]}"$'\n'
  done
  printf '%s' "$out"
  return 0
}

# The three scrape providers, in the order web_search_query tries them.
# Each is a thin wrapper around web_search_scrape_generic supplying just the
# URL and that site's current markup patterns. All are free and require no
# API key. If one provider is blocked, rate-limited, or unreachable on a
# given network, the others still have a shot — see web_search_query.
web_search_query_scrape_ddg() {
  local query="$1" encoded_query
  encoded_query="$(jq -rn --arg q "$query" '$q|@uri' 2>/dev/null)"
  [[ -z "$encoded_query" ]] && encoded_query="$query"
  # html.duckduckgo.com now sits behind stepped-up bot detection (403s / JS
  # challenges), so we use the officially supported lite endpoint instead.
  # It only accepts POST with the query as URL-encoded form data, and its
  # markup uses "result-link" / "result-snippet" classes (a plain table
  # layout) rather than the old "result__a" / "result__snippet" divs. The
  # snippet class lives directly on a <td>, so its closing tag is </td>,
  # not </a> as with the old endpoint.
  web_search_scrape_generic \
    "duckduckgo.com" \
    "https://lite.duckduckgo.com/lite/" \
    '<a[^>]*class="result-link"[^>]*>' \
    'class="result-link"[^>]*>\K.*?(?=</a>)' \
    'class="result-snippet"[^>]*>\K.*?(?=</td>)' \
    '<a[^>]*class="result-link"[^>]*>[^<]*</a>' \
    'class="result-snippet"[^>]*>[^<]*' \
    "1" \
    "q=${encoded_query}"
}

web_search_query_scrape_bing() {
  local query="$1" encoded_query
  encoded_query="$(jq -rn --arg q "$query" '$q|@uri' 2>/dev/null)"
  [[ -z "$encoded_query" ]] && encoded_query="$query"
  web_search_scrape_generic \
    "bing.com" \
    "https://www.bing.com/search?q=${encoded_query}&count=${WEB_SEARCH_MAX_RESULTS}" \
    '<h2><a[^>]*>' \
    '<h2><a[^>]*>\K.*?(?=</a>)' \
    '<div class="b_caption"[^>]*><p[^>]*>\K.*?(?=</p>)' \
    '<h2><a[^>]*>[^<]*</a>' \
    'class="b_caption"[^>]*><p[^>]*>[^<]*' \
    ""
}

web_search_query_scrape_startpage() {
  local query="$1" encoded_query
  encoded_query="$(jq -rn --arg q "$query" '$q|@uri' 2>/dev/null)"
  [[ -z "$encoded_query" ]] && encoded_query="$query"
  web_search_scrape_generic \
    "startpage.com" \
    "https://www.startpage.com/sp/search?query=${encoded_query}" \
    '<a[^>]*class="w-gl__result-title"[^>]*>' \
    'class="w-gl__result-title"[^>]*>\K.*?(?=</a>)' \
    'class="w-gl__description"[^>]*>\K.*?(?=</p>)' \
    '<a[^>]*class="w-gl__result-title"[^>]*>[^<]*</a>' \
    'class="w-gl__description"[^>]*>[^<]*' \
    ""
}

# Preferred web search backend: LangChain's DuckDuckGoSearchAPIWrapper
# (langchain_community.utilities), which wraps the duckduckgo-search PyPI
# package and does its own request handling and result parsing — no
# hand-rolled HTML scraping here. Still completely free (DuckDuckGo has no
# paid "search plugin" involved anywhere in this path, same as the scraper).
# Only called when check_deps found the package importable (HAVE_LANGCHAIN_
# SEARCH=1). Same output contract as the scrape backends below: formatted
# numbered results on stdout, or empty + WEB_SEARCH_LAST_ERROR set on
# failure.
web_search_query_langchain() {
  local query="$1" py_tmp out rc n

  py_tmp="$(mktemp --suffix=.py)"
  cat > "$py_tmp" << 'PYEOF'
import sys, json

try:
    from langchain_community.utilities import DuckDuckGoSearchAPIWrapper
except Exception as e:
    print(json.dumps({"error": "import_error", "detail": str(e)}))
    sys.exit(2)

query = sys.argv[1]
max_results = int(sys.argv[2]) if len(sys.argv) > 2 else 5

try:
    wrapper = DuckDuckGoSearchAPIWrapper(max_results=max_results)
    results = wrapper.results(query, max_results=max_results)
except Exception as e:
    print(json.dumps({"error": "search_error", "detail": str(e)}))
    sys.exit(3)

out = []
for r in results[:max_results]:
    out.append({
        "title": r.get("title") or "",
        "link": r.get("link") or r.get("href") or "",
        "snippet": r.get("snippet") or r.get("body") or "",
    })
print(json.dumps({"results": out}))
PYEOF

  out="$(python3 "$py_tmp" "$query" "$WEB_SEARCH_MAX_RESULTS" 2>/dev/null)"
  rc=$?
  rm -f "$py_tmp"

  if [[ $rc -ne 0 || -z "$out" ]]; then
    WEB_SEARCH_LAST_ERROR="LangChain search backend failed (exit $rc) — falling back to the built-in scraper."
    return 1
  fi

  if ! printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
    WEB_SEARCH_LAST_ERROR="LangChain search returned unparseable output — falling back to the built-in scraper."
    return 1
  fi

  if printf '%s' "$out" | jq -e 'has("error")' >/dev/null 2>&1; then
    local detail
    detail="$(printf '%s' "$out" | jq -r '.detail // .error')"
    WEB_SEARCH_LAST_ERROR="LangChain search error: $detail — falling back to the built-in scraper."
    return 1
  fi

  n="$(printf '%s' "$out" | jq '.results | length')"
  if [[ "$n" -eq 0 ]]; then
    WEB_SEARCH_LAST_ERROR="LangChain search returned zero results."
    return 1
  fi

  printf '%s' "$out" | jq -r '
    .results
    | to_entries
    | map(
        "\(.key + 1). \(.value.title)\n"
        + (if .value.link != "" then "   \(.value.link)\n" else "" end)
        + (if .value.snippet != "" then "   \(.value.snippet)\n" else "" end)
      )
    | join("")
  '
  return 0
}

# Dispatcher: tries the LangChain backend first when it's available (see
# check_deps), then falls through the scrape backends in order —
# DuckDuckGo, then Bing, then Startpage — stopping at the first one that
# returns real results. This means a provider that's blocked, rate-limited,
# or just unreachable on a given network doesn't take web search down
# entirely; the caller never needs to know which provider actually
# answered. If every provider fails, WEB_SEARCH_LAST_ERROR is set to a
# combined summary of why each one failed.
web_search_query() {
  local query="$1"
  local -a errs=()

  if [[ "${HAVE_LANGCHAIN_SEARCH:-0}" -eq 1 ]]; then
    if web_search_query_langchain "$query"; then
      return 0
    fi
    errs+=("langchain/duckduckgo-search: ${WEB_SEARCH_LAST_ERROR:-failed}")
  fi

  if web_search_query_scrape_ddg "$query"; then
    return 0
  fi
  errs+=("${WEB_SEARCH_LAST_ERROR:-duckduckgo.com: failed}")

  if web_search_query_scrape_bing "$query"; then
    return 0
  fi
  errs+=("${WEB_SEARCH_LAST_ERROR:-bing.com: failed}")

  if web_search_query_scrape_startpage "$query"; then
    return 0
  fi
  errs+=("${WEB_SEARCH_LAST_ERROR:-startpage.com: failed}")

  WEB_SEARCH_LAST_ERROR="all search providers failed — $(IFS='; '; echo "${errs[*]}")"
  return 1
}

# WEB_SEARCH — read-only, no confirmation, same as FILE_READ/DIR_LIST.
handle_web_search_action() {
  local query="$1" results

  box_top "WEB SEARCH" "$ICON_SEARCH" "$C_ACCENT2"
  box_line "$query"

  results="$(web_search_query "$query")"
  if [[ -z "$results" ]]; then
    box_bottom "$C_ACCENT2"
    local reason="${WEB_SEARCH_LAST_ERROR:-unknown reason}"
    warn "Web search failed for \"$query\": $reason"
    AGENT_TOOL_OUTPUT+=$'\n\n'"[WEB_SEARCH \"$query\"]: no results ($reason). Tell the user real-time lookup didn't work rather than guessing an answer."
    return
  fi

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

  if ! confirm_yes_no "Run this command?"; then
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

  exit_color="$C_OK"
  [[ "$exit_code" -ne 0 ]] && exit_color="$C_ERR"
  box_top "OUTPUT (exit $exit_code)" "" "$exit_color"
  printf '%s\n' "$output" | sed -n '1,40p' | while IFS= read -r pl; do box_line "$pl"; done
  box_bottom "$exit_color"

  output="$(cap_preview "$output")"
  AGENT_TOOL_OUTPUT+=$'\n\n'"[SHELL_RUN exit=$exit_code]:"$'\n'"$output"
}

# Scans an assistant reply for FILE_WRITE / FILE_EDIT / FILE_DELETE /
# FOLDER_CREATE markers, strips them out of what's shown as plain chat text,
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
  local edit_file="" edit_idx=0
  local tmpdir
  tmpdir="$(mktemp -d)"

  while IFS= read -r line; do
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
      if [[ "$line" =~ ^\<\<\<WEB_SEARCH\ query=\"(.*)\"\>\>\>$ ]]; then
        local search_q="${BASH_REMATCH[1]}"
        search_queries+=("$search_q")
        cleaned+="${C_ACCENT2}${ICON_SEARCH} search: $search_q${C_RESET}"$'\n'
        continue
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
      # Fallback: the line looks like an attempted action marker (mentions
      # one of the known action names) but didn't match any exact pattern
      # above — most likely a malformed/near-miss syntax (e.g. <tool_call>
      # instead of <<<...>>>). Don't just silently drop it: surface it to
      # the user and tell the model to retry with the exact marker syntax.
      if [[ "$line" =~ (FILE_READ|FILE_WRITE|FILE_EDIT|FILE_DELETE|FOLDER_CREATE|FOLDER_DELETE|DIR_LIST|ZIP_LIST|ZIP_READ|SHELL_RUN|WEB_SEARCH) ]] \
        && [[ ! "$line" =~ ^\<\<\< ]]; then
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
    elif [[ "$mode" == "thinking" ]]; then
      if [[ "$line" == '<<<END_THINKING>>>' ]]; then
        mode="text"
      fi
      # Every other line while in "thinking" mode is discarded — it's the
      # model's private reasoning and is never shown to the user.
    fi
  done <<< "$reply"

  printf "\n${C_ACCENT}${C_BOLD}Termix>${C_RESET} %s\n" "$cleaned"

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
      -H "X-Title: Termix Agent" \
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
get_completion() {
  local body http_code reply retry_messages reasoning code_tmp
  code_tmp="$(mktemp)"

  body="$(call_provider_with_retry "$messages_json" "$code_tmp")"
  http_code="$(cat "$code_tmp" 2>/dev/null)"

  if [[ "$http_code" == CANCELLED:* ]]; then
    rm -f "$code_tmp"
    if [[ "${http_code#CANCELLED:}" == "prompt" ]]; then
      warn "Prompt stopped (Ctrl+S)."
    else
      warn "Thinking cancelled (Ctrl+T)."
    fi
    return 1
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

  if [[ -z "$reply" ]]; then
    # Some free reasoning models occasionally return finish_reason: stop with
    # an empty message.content, having dumped everything into an internal
    # "reasoning" field instead. Give it one retry with an explicit nudge
    # before giving up.
    warn "Model returned no final answer. Retrying once..."
    retry_messages="$(jq -c \
      '. + [{role:"user", content:"Your previous response contained no final answer, only internal reasoning. Reply again with your actual final answer as plain text, including any action or tool blocks if applicable."}]' \
      <<< "$messages_json")"
    body="$(call_provider_with_retry "$retry_messages" "$code_tmp")"
    http_code="$(cat "$code_tmp" 2>/dev/null)"

    if [[ "$http_code" == CANCELLED:* ]]; then
      rm -f "$code_tmp"
      if [[ "${http_code#CANCELLED:}" == "prompt" ]]; then
        warn "Prompt stopped (Ctrl+S)."
      else
        warn "Thinking cancelled (Ctrl+T)."
      fi
      return 1
    fi

    if [[ "$http_code" == "200" ]]; then
      reply="$(jq -r '.choices[0].message.content // empty' <<< "$body" 2>/dev/null)"
    fi
  fi

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
    printf "\n${C_DIM}${C_ACCENT}Termix (reasoning trace)>${C_RESET} %s\n\n" "$reasoning"
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
  check_deps
  setup_tty_for_cancel
  banner
  pick_provider_startup
  ask_api_key

  if ! init_workspace_auto; then
    err "Could not set up a sandbox workspace. Exiting."
    exit 1
  fi

  init_history

  status_panel

  while true; do
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
