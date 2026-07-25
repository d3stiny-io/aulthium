#!/usr/bin/env bash
set -u

# TERMIX AGENT
# Single-file Bash terminal AI client for Termux / Linux
# Uses OpenRouter for free-model chat.
# Conversation stays in memory only while the process is running.

APP_NAME="TERMIX AGENT"
APP_VERSION="v1.0"
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

You can propose file and folder changes inside a single sandbox folder: $WORKSPACE_DIR
You may ONLY use relative paths inside that folder. Never use absolute paths, never use ".." to escape it, and never ask the user to run destructive shell commands.

To create or overwrite a file, output a block EXACTLY like this (nothing else on those marker lines):
<<<FILE_WRITE path="relative/path.txt">>>
the full file content goes here
<<<END_FILE_WRITE>>>

To delete a single file, output a line EXACTLY like this:
<<<FILE_DELETE path="relative/path.txt">>>

To create an empty folder on its own (not just as a side effect of writing a file into it), output a line EXACTLY like this:
<<<FOLDER_CREATE path="relative/folder">>>

Every action you propose will be shown to the user and requires their explicit yes/no confirmation before anything happens. Note that FILE_WRITE will also create any missing parent folders for that file as part of the same confirmation, so you don't need a separate FOLDER_CREATE before writing a file into a new folder — only use FOLDER_CREATE when you want an empty folder with no file in it yet.

You cannot delete folders, cannot run shell commands, and cannot touch anything outside the sandbox folder.
If the user asks for something outside those bounds, explain the limitation instead.
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    echo "Install it first and run this script again."
    exit 1
  }
}

say() {
  printf '\033[1;36m%s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33m%s\033[0m\n' "$*"
}

err() {
  printf '\033[1;31m%s\033[0m\n' "$*"
}

banner() {
  printf '\033[1;36m'
  cat <<'EOF'
████████╗███████╗██████╗ ███╗   ███╗██╗██╗  ██╗
╚══██╔══╝██╔════╝██╔══██╗████╗ ████║██║╚██╗██╔╝
   ██║   █████╗  ██████╔╝██╔████╔██║██║ ╚███╔╝
   ██║   ██╔══╝  ██╔══██╗██║╚██╔╝██║██║ ██╔██╗
   ██║   ███████╗██║  ██║██║ ╚═╝ ██║██║██╔╝ ██╗
   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚═╝╚═╝  ╚═╝

             T E R M I X   A G E N T
               AI Terminal Assistant
EOF
  printf '\033[0m\n'
}

cleanup_exit() {
  printf '\n'
  say "Goodbye."
  exit 0
}

trap cleanup_exit INT

check_deps() {
  need_cmd curl
  need_cmd jq
  need_cmd mktemp
  need_cmd sort
  need_cmd grep
  need_cmd realpath
}

confirm_yes_no() {
  local prompt="$1" ans
  read -r -p "$prompt [y/N]: " ans || ans="n"
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
  say "✓ Workspace set to: $WORKSPACE_DIR"
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
  cat <<'EOF'

Commands:
  t> help                 Show this menu
  t> model                Open the free-model picker
  t> model <name>         Switch to a model by name
  t> current              Show current model
  t> workdir              Show the current sandbox folder
  t> workdir <path>       Change the sandbox folder
  t> clear                Clear the terminal
  t> reset                Start a new conversation
  t> history              Show chat history
  t> exit                 Exit Termix Agent

Chat:
  Type any normal message at the chat> prompt.

File agent:
  The agent can propose creating/overwriting a file, deleting a single file,
  or creating an empty folder, all inside the sandbox folder (see
  't> workdir'). Every proposed change is shown to you and requires a
  yes/no confirmation before anything touches disk — a file write that
  needs a new parent folder will say so up front. It cannot delete folders,
  run shell commands, or reach outside the sandbox folder under any
  circumstance.

EOF
}

show_history() {
  local count
  count="$(jq 'length' <<< "$messages_json")"
  if [[ "$count" -le 1 ]]; then
    echo "No history yet."
    return
  fi

  jq -r '
    .[1:][] |
    "\(.role): \(.content)"
  ' <<< "$messages_json"
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
    echo "Falling back to a few known free models."
    cat <<'EOF'
[1] openrouter/free
[2] meta-llama/llama-3.3-8b-instruct:free
[3] deepseek/deepseek-chat-v3-0324:free
[4] mistralai/mistral-small-3.2-24b-instruct:free
[5] google/gemma-3-27b-it:free
EOF
    echo
    read -r -p "Model number or name (q to cancel): " query
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
    say "✓ Switched to: $CURRENT_MODEL"
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
  echo "Free model picker"
  echo "Current: $CURRENT_MODEL"
  echo
  echo "[0] openrouter/free (auto-router)"
  for i in "${!MODELS[@]}"; do
    printf "[%d] %s\n" "$((i + 1))" "${MODELS[$i]}"
  done
  echo
  echo "Type a number, part of a name, 'refresh', or 'q' to cancel."

  while true; do
    read -r -p "Model> " query || query="q"

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
        say "✓ Switched to: $CURRENT_MODEL"
        rm -f "$models_tmp" "$selection_tmp"
        return 0
        ;;
    esac

    if [[ "$query" =~ ^[0-9]+$ ]]; then
      selected_idx="$query"
      if (( selected_idx >= 1 && selected_idx <= models_count )); then
        CURRENT_MODEL="${MODELS[$((selected_idx - 1))]}"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        say "✓ Switched to: $CURRENT_MODEL"
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
      say "✓ Switched to: $CURRENT_MODEL"
      rm -f "$models_tmp" "$selection_tmp"
      return 0
    fi

    echo
    echo "Matches:"
    nl -ba "$selection_tmp" | sed 's/^\s*//'
    echo
    read -r -p "Choose number or q: " selected_idx || selected_idx="q"
    [[ "$selected_idx" == "q" ]] && continue

    if [[ "$selected_idx" =~ ^[0-9]+$ ]]; then
      match_line="$(sed -n "${selected_idx}p" "$selection_tmp")"
      if [[ -n "$match_line" ]]; then
        CURRENT_MODEL="$match_line"
        CURRENT_MODEL_LABEL="$CURRENT_MODEL"
        say "✓ Switched to: $CURRENT_MODEL"
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
      say "✓ Switched to: $CURRENT_MODEL"
      return 0
    fi
    err "Could not fetch free models right now."
    return 1
  fi

  exact_match="$(grep -Fx "$input" "$models_tmp" || true)"
  if [[ -n "$exact_match" ]]; then
    CURRENT_MODEL="$input"
    CURRENT_MODEL_LABEL="$CURRENT_MODEL"
    say "✓ Switched to: $CURRENT_MODEL"
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
    say "✓ Switched to: $CURRENT_MODEL"
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
    say "✓ Switched to: $CURRENT_MODEL"
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
  echo
  say "Agent wants to write a file:"
  echo "  $abs"
  echo "  ($lines lines)"
  if [[ -n "$missing_dirs" ]]; then
    echo "  This will also create folder(s): $missing_dirs"
  fi
  echo "--- preview (first 40 lines) ---"
  sed -n '1,40p' "$content_file"
  echo "--- end preview ---"

  if confirm_yes_no "Apply this write?"; then
    mkdir -p "$parent_dir" 2>/dev/null
    if cp "$content_file" "$abs"; then
      say "✓ Wrote $abs"
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

  echo
  say "Agent wants to create a folder:"
  echo "  $abs"

  if confirm_yes_no "Create this folder?"; then
    if mkdir -p "$abs"; then
      say "✓ Created $abs"
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

  echo
  say "Agent wants to delete a file:"
  echo "  $abs"

  if confirm_yes_no "Delete this file?"; then
    if rm -f "$abs"; then
      say "✓ Deleted $abs"
    else
      err "Failed to delete $abs"
    fi
  else
    warn "Skipped delete: $rel"
  fi
}

# Scans an assistant reply for FILE_WRITE / FILE_DELETE / FOLDER_CREATE
# markers, strips them out of what's shown as plain chat text, and runs each
# proposed action through the sandboxed, confirmation-gated handlers above.
process_agent_reply() {
  local reply="$1"
  local mode="text" path="" write_file="" idx=0
  local cleaned="" line
  local -a write_paths=() write_files=() delete_paths=() folder_paths=()
  local tmpdir
  tmpdir="$(mktemp -d)"

  while IFS= read -r line; do
    if [[ "$mode" == "text" ]]; then
      if [[ "$line" =~ ^\<\<\<FILE_WRITE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        idx=$((idx + 1))
        write_file="$tmpdir/block_$idx"
        : > "$write_file"
        mode="write"
        cleaned+="[proposed file write: $path]"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FILE_DELETE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        delete_paths+=("$path")
        cleaned+="[proposed file delete: $path]"$'\n'
        continue
      fi
      if [[ "$line" =~ ^\<\<\<FOLDER_CREATE\ path=\"(.*)\"\>\>\>$ ]]; then
        path="${BASH_REMATCH[1]}"
        folder_paths+=("$path")
        cleaned+="[proposed folder create: $path]"$'\n'
        continue
      fi
      cleaned+="$line"$'\n'
    else
      if [[ "$line" == '<<<END_FILE_WRITE>>>' ]]; then
        write_paths+=("$path")
        write_files+=("$write_file")
        mode="text"
        continue
      fi
      printf '%s\n' "$line" >> "$write_file"
    fi
  done <<< "$reply"

  printf '\n\033[1;36mTermix>\033[0m %s\n' "$cleaned"

  local i
  for i in "${!write_paths[@]}"; do
    handle_write_action "${write_paths[$i]}" "${write_files[$i]}"
  done
  for path in "${folder_paths[@]}"; do
    handle_folder_create_action "$path"
  done
  for path in "${delete_paths[@]}"; do
    handle_delete_action "$path"
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
  # $1 = messages JSON array. Writes response body to stdout, http code to
  # stderr on a line prefixed with "HTTP_CODE:" so both can be captured.
  local messages="$1" payload tmp_body http_code body

  tmp_body="$(mktemp)"
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
      -w '%{http_code}' \
      -X POST "$OPENROUTER_URL" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -H "HTTP-Referer: http://localhost" \
      -H "X-Title: Termix Agent" \
      --data "$payload" 2>/dev/null || true
  )"

  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  printf '%s' "$body"
  printf 'HTTP_CODE:%s' "$http_code" >&2
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

send_chat() {
  local user_text="$1"
  local body http_code reply retry_messages reasoning code_tmp
  code_tmp="$(mktemp)"

  append_message "user" "$user_text"

  body="$(call_openrouter "$messages_json" 2>"$code_tmp")"
  http_code="$(sed -n 's/^HTTP_CODE://p' "$code_tmp")"

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
      '. + [{role:"user", content:"Your previous response contained no final answer, only internal reasoning. Reply again with your actual final answer as plain text, including any <<<FILE_WRITE>>> or <<<FILE_DELETE>>> blocks if applicable."}]' \
      <<< "$messages_json")"
    body="$(call_openrouter "$retry_messages" 2>"$code_tmp")"
    http_code="$(sed -n 's/^HTTP_CODE://p' "$code_tmp")"

    if [[ "$http_code" == "200" ]]; then
      reply="$(jq -r '.choices[0].message.content // empty' <<< "$body" 2>/dev/null)"
    fi
  fi

  rm -f "$code_tmp"

  if [[ -n "$reply" ]]; then
    append_message "assistant" "$reply"
    process_agent_reply "$reply"
    return 0
  fi

  # Both attempts came back with empty content. Fall back to the model's
  # reasoning trace, if any, rather than showing nothing at all.
  reasoning="$(extract_reasoning_text "$body")"
  if [[ -n "$reasoning" ]]; then
    warn "This model didn't return a final answer, only its internal reasoning."
    echo "Showing that instead — treat it as a rough idea, not a finished answer:"
    printf '\n\033[1;36mTermix (reasoning trace)>\033[0m %s\n\n' "$reasoning"
    warn "Consider switching models with 't> model' — this one struggled with this request."
    append_message "assistant" "$reasoning"
    return 0
  fi

  err "No reply content returned."
  echo "$body" | jq '.' 2>/dev/null || echo "$body"
  return 1
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
      echo "Current model: $CURRENT_MODEL"
      ;;
    workdir)
      echo "Current sandbox folder: $WORKSPACE_DIR"
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
      echo "Connected to OpenRouter"
      echo "Current Model: $CURRENT_MODEL"
      echo "Sandbox folder: $WORKSPACE_DIR"
      echo
      echo "Type 't> help' for commands."
      echo "Press Ctrl+C to exit."
      echo
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

  echo "Connected to OpenRouter"
  echo "Current Model: $CURRENT_MODEL"
  echo "Sandbox folder: $WORKSPACE_DIR"
  echo
  echo "Type 't> help' for commands."
  echo "Type messages at the chat> prompt."
  echo "Press Ctrl+C to exit."
  echo

  while true; do
    local input=""
    if ! read -r -p "chat> " input; then
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
