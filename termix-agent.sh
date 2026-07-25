#!/usr/bin/env bash
set -u

# TERMIX AGENT
# Single-file Bash terminal AI client for Termux / Linux
# Uses OpenRouter for free-model chat.
# Conversation stays in memory only while the process is running.

APP_NAME="TERMIX AGENT"
APP_VERSION="v1.1"
OPENROUTER_URL="https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_MODELS_URL="https://openrouter.ai/api/v1/models"
DEFAULT_MODEL="openrouter/free"

API_KEY="${OPENROUTER_API_KEY:-}"
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

To list the contents of a folder, output a line EXACTLY like this:
<<<DIR_LIST path="relative/folder">>>
(use path="." to list the workspace root)

To list the entries inside a zip archive without extracting it, output a line EXACTLY like this:
<<<ZIP_LIST path="relative/archive.zip">>>

To read one specific entry's contents from inside a zip archive, output a line EXACTLY like this:
<<<ZIP_READ path="relative/archive.zip" entry="path/inside/zip.txt">>>

You can issue several of the above in one reply. Their results are appended to the conversation as a
follow-up message and you will automatically be prompted again with that information, so you can request
something, wait for the result, and then give your real answer or take further action in a later turn.
Large or binary files are truncated/rejected — you'll be told when that happens.

=== CHANGING FILES (shown to the user, requires explicit yes/no confirmation) ===

To create or overwrite a file, output a block EXACTLY like this (nothing else on those marker lines):
<<<FILE_WRITE path="relative/path.txt">>>
the full file content goes here
<<<END_FILE_WRITE>>>

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
- Never call a read/inspect marker (FILE_READ, DIR_LIST, ZIP_LIST, ZIP_READ) for something already shown
  earlier in this same conversation — check what you already know before asking again.
- Only inspect something when the answer or action genuinely depends on it. Don't DIR_LIST or FILE_READ
  "just to be safe" when the user's request doesn't hinge on the current state of that path.
- If you already know you'll need several independent reads, issue them together in one reply instead of
  one per round.
- Never repeat the exact same marker with the exact same arguments — if it already ran once this
  conversation, reuse that result instead of asking again.
- For a file-changing or shell action, only precede it with a read/list check when there's real uncertainty
  about the current state (e.g. you don't know whether a target already exists). The user still confirms the
  exact path before anything happens, so a reflexive check-first-every-time habit is usually wasted.
- If the user's request is simple enough to answer or act on directly, skip tools altogether and just answer.

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
ICON_DELETE="✕"   # deleting a file
ICON_FOLDER="+"   # creating a folder
ICON_SHELL="❯"    # running a shell command
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
  printf "${C_MUTED}│${C_RESET} %-10s ${C_OK}%s${C_RESET}\n" "provider" "OpenRouter — connected"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "model" "$CURRENT_MODEL"
  printf "${C_MUTED}│${C_RESET} %-10s %s\n" "sandbox" "$WORKSPACE_DIR"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}Type ${C_RESET}t> help${C_MUTED} for commands · ${C_RESET}Ctrl+C${C_MUTED} to exit${C_RESET}\n\n"
}

cleanup_exit() {
  stop_spinner
  printf '\n'
  printf "${C_OK}%s${C_RESET}\n" "Termix Agent has been closed." >&2
  exit 0
}

trap cleanup_exit INT

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

show_help() {
  echo
  printf "${C_ACCENT2}┌─ COMMANDS ────────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> help" "show this menu"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> model" "open the free-model picker"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> model <name>" "switch to a model by name"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> current" "show current model"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> workdir" "show the current sandbox folder"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> workdir <path>" "change the sandbox folder"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> clear" "clear the terminal"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> reset" "start a new conversation"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> history" "show chat history"
  printf "${C_MUTED}│${C_RESET} %-22s %s\n" "t> exit" "exit Termix Agent"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n"

  printf "\n${C_MUTED}Chat: type any normal message at the ${C_RESET}User>${C_MUTED} prompt.${C_RESET}\n"

  printf "\n${C_ACCENT2}┌─ FILE AGENT ──────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} ${C_OK}${ICON_READ} ${ICON_DIR} ${ICON_ZIP}${C_RESET}  read files, list folders, inspect zips —\n"
  printf "${C_MUTED}│${C_RESET}       runs automatically, no confirmation (read-only),\n"
  printf "${C_MUTED}│${C_RESET}       results are fed back to the agent for its next turn.\n"
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

match_model_list() {
  # Prints models that match the search string, one per line.
  local query="$1"
  local models_file="$2"
  grep -iF "$query" "$models_file" || true
}

pick_model_ui() {
  local models_tmp selection_tmp models_count selected_idx selected_model query matches_count match_line
  models_tmp="$(mktemp)"
  selection_tmp="$(mktemp)"

  if ! fetch_free_models > "$models_tmp"; then
    rm -f "$models_tmp" "$selection_tmp"
    warn "Could not fetch live models right now."
    muted "Falling back to a few known free models."
    echo
    printf "${C_MUTED}[1]${C_RESET} openrouter/free\n"
    printf "${C_MUTED}[2]${C_RESET} meta-llama/llama-3.3-8b-instruct:free\n"
    printf "${C_MUTED}[3]${C_RESET} deepseek/deepseek-chat-v3-0324:free\n"
    printf "${C_MUTED}[4]${C_RESET} mistralai/mistral-small-3.2-24b-instruct:free\n"
    printf "${C_MUTED}[5]${C_RESET} google/gemma-3-27b-it:free\n"
    echo
    read -r -p "$(printf "${C_ACCENT2}?${C_RESET} Model number or name ${C_MUTED}(q to cancel)${C_RESET}: ")" query
    [[ "$query" == "q" ]] && return 0

    case "$query" in
      1) CURRENT_MODEL="openrouter/free" ;;
      2) CURRENT_MODEL="meta-llama/llama-3.3-8b-instruct:free" ;;
      3) CURRENT_MODEL="deepseek/deepseek-chat-v3-0324:free" ;;
      4) CURRENT_MODEL="mistralai/mistral-small-3.2-24b-instruct:free" ;;
      5) CURRENT_MODEL="google/gemma-3-27b-it:free" ;;
      *)
        if [[ "$query" == *":free" ]]; then
          CURRENT_MODEL="$query"
        else
          warn "Invalid choice."
          rm -f "$models_tmp" "$selection_tmp"
          return 1
        fi
        ;;
    esac

    CURRENT_MODEL_LABEL="$CURRENT_MODEL"
    ok "Switched to: $CURRENT_MODEL"
    rm -f "$models_tmp" "$selection_tmp"
    return 0
  fi

  mapfile -t MODELS < "$models_tmp"
  models_count="${#MODELS[@]}"

  if [[ "$models_count" -eq 0 ]]; then
    warn "No free models found."
    rm -f "$models_tmp" "$selection_tmp"
    return 1
  fi

  clear
  banner
  printf "${C_ACCENT2}┌─ MODEL PICKER ────────────────────────────────${C_RESET}\n"
  printf "${C_MUTED}│${C_RESET} current: ${C_OK}%s${C_RESET}\n" "$CURRENT_MODEL"
  printf "${C_ACCENT2}└─────────────────────────────────────────────${C_RESET}\n\n"
  printf "${C_MUTED}[0]${C_RESET} openrouter/free ${C_DIM}(auto-router)${C_RESET}\n"
  for i in "${!MODELS[@]}"; do
    printf "${C_MUTED}[%d]${C_RESET} %s\n" "$((i + 1))" "${MODELS[$i]}"
  done
  echo
  muted "Type a number, part of a name, 'refresh', or 'q' to cancel."

  while true; do
    read -r -p "$(printf "${C_ACCENT2}model>${C_RESET} ")" query || query="q"

    case "$query" in
      q|Q)
        rm -f "$models_tmp" "$selection_tmp"
        return 0
        ;;
      refresh|REFRESH)
        rm -f "$models_tmp"
        pick_model_ui
        return $?
        ;;
      0)
        CURRENT_MODEL="openrouter/free"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        ok "Switched to: $CURRENT_MODEL"
        rm -f "$models_tmp" "$selection_tmp"
        return 0
        ;;
    esac

    if [[ "$query" =~ ^[0-9]+$ ]]; then
      selected_idx="$query"
      if (( selected_idx >= 1 && selected_idx <= models_count )); then
        CURRENT_MODEL="${MODELS[$((selected_idx - 1))]}"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        ok "Switched to: $CURRENT_MODEL"
        rm -f "$models_tmp" "$selection_tmp"
        return 0
      fi
      warn "Invalid number."
      continue
    fi

    # Fuzzy search against the current list.
    grep -iF "$query" "$models_tmp" > "$selection_tmp" || true
    matches_count="$(wc -l < "$selection_tmp" | tr -d ' ')"

    if [[ "$matches_count" -eq 0 ]]; then
      warn "No matches found."
      continue
    fi

    if [[ "$matches_count" -eq 1 ]]; then
      CURRENT_MODEL="$(cat "$selection_tmp")"
      CURRENT_MODEL_LABEL="$CURRENT_MODEL"
      ok "Switched to: $CURRENT_MODEL"
      rm -f "$models_tmp" "$selection_tmp"
      return 0
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
        CURRENT_MODEL="$match_line"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        ok "Switched to: $CURRENT_MODEL"
        rm -f "$models_tmp" "$selection_tmp"
        return 0
      fi
    fi

    warn "Invalid choice."
  done
}

set_model_by_name() {
  local input="$1"
  local models_tmp exact_match fuzzy_match count
  models_tmp="$(mktemp)"

  if ! fetch_free_models > "$models_tmp"; then
    rm -f "$models_tmp"
    if [[ "$input" == *":free" ]]; then
      CURRENT_MODEL="$input"
      CURRENT_MODEL_LABEL="$CURRENT_MODEL"
      ok "Switched to: $CURRENT_MODEL"
      return 0
    fi
    err "Could not fetch free models right now."
    return 1
  fi

  exact_match="$(grep -Fx "$input" "$models_tmp" || true)"
  if [[ -n "$exact_match" ]]; then
    CURRENT_MODEL="$input"
    CURRENT_MODEL_LABEL="$CURRENT_MODEL"
    ok "Switched to: $CURRENT_MODEL"
    rm -f "$models_tmp"
    return 0
  fi

  fuzzy_match="$(grep -iF "$input" "$models_tmp" || true)"
  if [[ -z "$fuzzy_match" ]]; then
    count=0
  else
    count="$(wc -l <<< "$fuzzy_match" | tr -d ' ')"
  fi

  if [[ "$count" -eq 1 ]]; then
    CURRENT_MODEL="$(head -n 1 <<< "$fuzzy_match")"
    CURRENT_MODEL_LABEL="$CURRENT_MODEL"
    ok "Switched to: $CURRENT_MODEL"
    rm -f "$models_tmp"
    return 0
  fi

  if [[ "$count" -gt 1 ]]; then
    echo "$fuzzy_match"
    echo
    warn "More than one match. Use 't> model' to pick one."
    rm -f "$models_tmp"
    return 1
  fi

  if [[ "$input" == *":free" ]]; then
    CURRENT_MODEL="$input"
    CURRENT_MODEL_LABEL="$CURRENT_MODEL"
    ok "Switched to: $CURRENT_MODEL"
    rm -f "$models_tmp"
    return 0
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

  preview="$(cap_preview "$(cat "$abs" 2>/dev/null)")"
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

# Scans an assistant reply for FILE_WRITE / FILE_DELETE / FOLDER_CREATE
# markers, strips them out of what's shown as plain chat text, and runs each
# proposed action through the sandboxed, confirmation-gated handlers above.
process_agent_reply() {
  local reply="$1"
  local mode="text" path="" entry="" write_file="" shell_file="" idx=0 shell_idx=0
  local cleaned="" line
  local -a write_paths=() write_files=() delete_paths=() folder_paths=() folder_delete_paths=()
  local -a read_paths=() dirlist_paths=() ziplist_paths=()
  local -a zipread_paths=() zipread_entries=() shell_files=()
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
      # Tolerance shim: some (usually smaller/free) models fall back on a
      # <tool_call>ACTION path="..."> habit from their own training instead
      # of the exact <<<...>>> marker, and keep repeating it even after being
      # told to fix it. Rather than looping the model forever, accept this
      # one alternate shape for the single-line actions (not FILE_WRITE or
      # SHELL_RUN, which need a multi-line body) and dispatch it exactly like
      # the real marker would be. Trailing junk after the closing >> (like
      # </arg_value>) is tolerated and ignored.
      if [[ "$line" =~ ^\<tool_call\>[[:space:]]*(FILE_READ|FILE_DELETE|FOLDER_CREATE|FOLDER_DELETE|DIR_LIST|ZIP_LIST|ZIP_READ)[[:space:]]+path=\"([^\"]*)\"([[:space:]]+entry=\"([^\"]*)\")?.*\>\>?$ ]]; then
        local alt_action="${BASH_REMATCH[1]}" alt_path="${BASH_REMATCH[2]}" alt_entry="${BASH_REMATCH[4]}"
        warn "Accepted non-standard <tool_call> marker as: $alt_action path=\"$alt_path\""
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
      # Fallback: the line looks like an attempted action marker (mentions
      # one of the known action names) but didn't match any exact pattern
      # above — most likely a malformed/near-miss syntax (e.g. <tool_call>
      # instead of <<<...>>>). Don't just silently drop it: surface it to
      # the user and tell the model to retry with the exact marker syntax.
      if [[ "$line" =~ (FILE_READ|FILE_WRITE|FILE_DELETE|FOLDER_CREATE|FOLDER_DELETE|DIR_LIST|ZIP_LIST|ZIP_READ|SHELL_RUN) ]] \
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
  for shell_file in "${shell_files[@]}"; do
    handle_shell_run_action "$shell_file"
    AGENT_HAD_TOOL_CALLS=1
  done

  echo
  rm -rf "$tmpdir"
}

ask_api_key() {
  if [[ -n "${API_KEY:-}" ]]; then
    return 0
  fi

  echo
  read -r -s -p "OpenRouter API key: " API_KEY
  echo

  if [[ -z "${API_KEY:-}" ]]; then
    err "No API key provided."
    exit 1
  fi
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
  local messages="$1" code_file="$2" header_file="${3:-}" payload tmp_body tmp_headers http_code body

  tmp_body="$(mktemp)"
  tmp_headers="$(mktemp)"
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

  http_code="$(
    curl -sS \
      -o "$tmp_body" \
      -D "$tmp_headers" \
      -w '%{http_code}' \
      -X POST "$OPENROUTER_URL" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -H "HTTP-Referer: http://localhost" \
      -H "X-Title: Termix Agent" \
      --data "$payload" 2>/dev/null || true
  )"
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

# Wraps call_openrouter with automatic retry-with-backoff specifically for
# HTTP 429 (rate limited) — common on OpenRouter's free-tier models under
# any real load. Same contract as call_openrouter: takes (messages, code_file),
# prints body to stdout, writes the final numeric code to code_file. Manages
# its own spinner for both the request wait and the backoff wait between
# attempts.
#
# Two 429 sub-cases are handled differently:
#   - Temporary (per-minute/per-second) throttling: worth retrying. We honor
#     the server's Retry-After header when present instead of guessing, and
#     otherwise fall back to exponential backoff with jitter, capped at
#     MAX_RATE_LIMIT_WAIT seconds.
#   - Exhausted daily/monthly free-tier quota: retrying within the same
#     session cannot help (the error body says so explicitly, e.g.
#     "free-models-per-day"), so we fail fast with a clear message instead
#     of burning through retries and making the user wait for nothing.
MAX_RATE_LIMIT_RETRIES=6
MAX_RATE_LIMIT_WAIT=60
call_openrouter_with_retry() {
  local messages="$1" code_file="$2" attempt=0 wait_secs=2 body http_code
  local header_file retry_after err_msg jitter

  header_file="$(mktemp)"

  while true; do
    start_spinner "thinking..."
    body="$(call_openrouter "$messages" "$code_file" "$header_file")"
    stop_spinner
    http_code="$(cat "$code_file" 2>/dev/null)"

    if [[ "$http_code" != "429" ]]; then
      rm -f "$header_file"
      printf '%s' "$body"
      return 0
    fi

    err_msg="$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null)"
    if [[ "$err_msg" =~ per-day|per-month|daily|quota|free-models-per ]]; then
      warn "OpenRouter free-tier quota exhausted: ${err_msg:-rate limit exceeded}"
      warn "Retrying won't help until the quota resets. Switch models (/model), add OpenRouter credits, or wait for the reset."
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

    warn "Rate limited by OpenRouter (HTTP 429). Retrying in ${wait_secs}s... ($attempt/$MAX_RATE_LIMIT_RETRIES)"
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

  body="$(call_openrouter_with_retry "$messages_json" "$code_tmp")"
  http_code="$(cat "$code_tmp" 2>/dev/null)"

  if [[ "$http_code" != "200" ]]; then
    err "OpenRouter request failed (HTTP $http_code)."
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
    body="$(call_openrouter_with_retry "$retry_messages" "$code_tmp")"
    http_code="$(cat "$code_tmp" 2>/dev/null)"

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
    current)
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
      clear
      banner
      status_panel
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
  banner
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
