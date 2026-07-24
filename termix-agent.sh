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

# In-memory conversation history only.
# We keep the system prompt in the history from the start.
SYSTEM_PROMPT='You are Termix Agent, a helpful terminal-based AI assistant. Answer clearly and concisely. Be practical, friendly, and accurate. If the user asks for a command, script, or code, provide a ready-to-run answer.'

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
}

init_history() {
  messages_json="$(jq -nc --arg content "$SYSTEM_PROMPT" '[{role:"system", content:$content}]')"
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
  t> clear                Clear the terminal
  t> reset                Start a new conversation
  t> history              Show chat history
  t> exit                 Exit Termix Agent

Chat:
  Type any normal message at the chat> prompt.

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
  count="$(wc -l <<< "$fuzzy_match" | tr -d ' ')"

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

send_chat() {
  local user_text="$1"
  local payload tmp_body http_code body reply
  tmp_body="$(mktemp)"

  append_message "user" "$user_text"

  payload="$(jq -nc \
    --arg model "$CURRENT_MODEL" \
    --argjson messages "$messages_json" \
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
      -H "Authorization: Bearer '"$API_KEY"'" \
      -H "Content-Type: application/json" \
      -H "HTTP-Referer: http://localhost" \
      -H "X-Title: Termix Agent" \
      --data "$payload" 2>/dev/null || true
  )"

  body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  if [[ "$http_code" != "200" ]]; then
    err "OpenRouter request failed (HTTP $http_code)."
    if [[ -n "$body" ]]; then
      echo "$body" | jq -r '.error.message // .message // .error // empty' 2>/dev/null || true
      echo "$body" | jq '.' 2>/dev/null || echo "$body"
    fi
    return 1
  fi

  reply="$(jq -r '.choices[0].message.content // empty' <<< "$body" 2>/dev/null)"
  if [[ -z "$reply" ]]; then
    err "No reply content returned."
    echo "$body" | jq '.' 2>/dev/null || echo "$body"
    return 1
  fi

  append_message "assistant" "$reply"
  printf '\n\033[1;36mTermix>\033[0m %s\n\n' "$reply"
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
    clear)
      clear
      banner
      echo "Connected to OpenRouter"
      echo "Current Model: $CURRENT_MODEL"
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
  init_history

  echo "Connected to OpenRouter"
  echo "Current Model: $CURRENT_MODEL"
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
