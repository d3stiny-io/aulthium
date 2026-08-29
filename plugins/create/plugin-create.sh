#!/usr/bin/env bash
set -u

# AULTHIUM-PLUGIN-CREATE
# Standalone plugin scaffolder for Aulthium. Run directly with bash — this
# is NOT a "t> ..." REPL command, it's a separate tool you invoke from an
# ordinary shell prompt:
#
#   ./aulthium-plugin-create.sh <name> [flags...]
#
# It writes the exact same plugin.json / entry-script / README shape the
# main aulthium.sh REPL expects under $PLUGINS_DIR, so anything scaffolded
# here can immediately be picked up with 't> plugin list' / 't> plugin run
# <name>' / 't> plugin verify <name>' in the main script. It deliberately
# does less than editing a plugin by hand would let you do — no
# uninstall/update/toggle/config-editing here, just: create it, and prove
# (via a real, unforgeable integrity hash) that what's on disk right now is
# exactly what was just written. There is no flag anywhere in this script
# that makes 'verify' report a match it didn't actually compute — that
# would defeat the entire point of having a fingerprint in the first place.
#
# Examples:
#   ./aulthium-plugin-create.sh mytool --security-print --verify
#   ./aulthium-plugin-create.sh webhook-relay \
#       --desc "Relays incoming webhooks to the active provider" \
#       --version 0.2.0 --runtime python3 \
#       --perm network --perm secrets \
#       --config timeout=30 --config retries=3 \
#       --security-print --verify

APP_NAME="AULTHIUM-PLUGIN-CREATE"
APP_VERSION="v1.0.0"

# Same override convention as the main script, so plugins land in the same
# place the REPL will look for them.
PLUGINS_DIR="${AULTHIUM_PLUGINS_DIR:-$HOME/.aulthium/plugins}"

KNOWN_PLUGIN_PERMISSIONS="network filesystem shell mcp secrets"

# ── Colors / icons (only used on a real terminal) ───────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_MUTED=$'\033[2;37m'
else
  C_RESET=""; C_BOLD=""; C_OK=""; C_WARN=""; C_ERR=""; C_MUTED=""
fi
ICON_OK="✓"; ICON_WARN="⚠"; ICON_ERR="✗"

warn() { printf "${C_WARN}${ICON_WARN} %s${C_RESET}\n" "$*" >&2; }
err()  { printf "${C_ERR}${ICON_ERR} %s${C_RESET}\n" "$*" >&2; }
ok()   { printf "${C_OK}${ICON_OK} %s${C_RESET}\n" "$*"; }
muted(){ printf "${C_MUTED}%s${C_RESET}\n" "$*"; }
box()  { printf '%s\n' "── $* ──"; }

check_deps() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v sha256sum >/dev/null 2>&1 || missing+=("sha256sum")
  if [[ "${#missing[@]}" -gt 0 ]]; then
    err "Missing required tool(s): ${missing[*]}"
    exit 1
  fi
}

plugin_permission_label() {
  case "$1" in
    network)    printf 'Network access — can make its own HTTP requests (beyond the AI API call itself).' ;;
    filesystem) printf 'Filesystem access — can read/write files outside the sandboxed workspace.' ;;
    shell)      printf 'Shell access — can run arbitrary commands on this machine.' ;;
    mcp)        printf 'MCP access — can call connected MCP servers/tools.' ;;
    secrets)    printf 'Secrets access — receives the live API key for the active provider.' ;;
    *)          printf 'Unrecognized permission scope.' ;;
  esac
}

# Same structural checks the main script applies to every install path.
plugin_manifest_validate() {
  local manifest="$1" name entry mode hook perms p unknown=""
  jq empty "$manifest" 2>/dev/null || { err "plugin.json isn't valid JSON."; return 1; }
  name="$(jq -r '.name // empty' "$manifest" 2>/dev/null)"
  [[ -n "$name" ]] || { err "plugin.json is missing a \"name\" field."; return 1; }
  mode="$(jq -r '.mode // "foreground"' "$manifest" 2>/dev/null)"
  if [[ "$mode" != "foreground" && "$mode" != "hook" ]]; then
    err "plugin.json \"mode\" must be \"foreground\" or \"hook\" (got '$mode')."
    return 1
  fi
  entry="$(jq -r '.entry // empty' "$manifest" 2>/dev/null)"
  [[ -n "$entry" ]] || warn "plugin.json has no \"entry\" command — it won't be runnable until one is added."
  if [[ "$mode" == "hook" ]]; then
    hook="$(jq -r '.hook // empty' "$manifest" 2>/dev/null)"
    [[ -n "$hook" ]] || { err "\"mode\": \"hook\" needs a \"hook\" field naming the hook point."; return 1; }
  fi
  perms="$(jq -r '.permissions[]? // empty' "$manifest" 2>/dev/null)"
  if [[ -n "$perms" ]]; then
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ " $KNOWN_PLUGIN_PERMISSIONS " == *" $p "* ]] || unknown="$unknown $p"
    done <<< "$perms"
    [[ -n "$unknown" ]] && warn "plugin.json declares unrecognized permission(s):$unknown"
  fi
  return 0
}

# Deterministic content hash of everything in the plugin dir except
# plugin.json (circular) and config.json (local overrides). Identical
# algorithm to the main script's plugin_tree_checksum, so a hash computed
# here and one computed later by 't> plugin verify' in aulthium.sh always
# agree on the same unmodified files.
plugin_tree_checksum() {
  local dir="$1"
  find "$dir" -type f ! -name 'plugin.json' ! -name 'config.json' -print0 2>/dev/null \
    | sort -z \
    | xargs -0 sha256sum 2>/dev/null \
    | sha256sum 2>/dev/null \
    | awk '{print $1}'
}

plugin_stamp_integrity() {
  local dest="$1" manifest hash stamped
  manifest="$dest/plugin.json"
  [[ -f "$manifest" ]] || return 1
  hash="$(plugin_tree_checksum "$dest")"
  stamped="$(jq --arg h "$hash" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
    '._integrity = {"sha256": $h, "at": $t}' "$manifest" 2>/dev/null)"
  [[ -n "$stamped" ]] && printf '%s\n' "$stamped" > "$manifest"
}

# Strictly read-only: recomputes the hash and compares it to what's
# recorded. Never repairs, never re-stamps, never takes a flag that makes
# a mismatch print as a match — a "verified" result here always means the
# files were independently re-hashed just now and the hash matched.
plugin_verify() {
  local name="$1" dir manifest stored current
  dir="$PLUGINS_DIR/$name"
  manifest="$dir/plugin.json"
  if [[ ! -f "$manifest" ]]; then
    err "No plugin named '$name' at $dir."
    return 1
  fi
  stored="$(jq -r '._integrity.sha256 // empty' "$manifest" 2>/dev/null)"
  if [[ -z "$stored" ]]; then
    warn "'$name' has no recorded integrity hash — nothing to verify against."
    return 1
  fi
  current="$(plugin_tree_checksum "$dir")"
  if [[ "$current" == "$stored" ]]; then
    ok "'$name' matches its recorded hash — files are unchanged since $(jq -r '._integrity.at // "creation"' "$manifest" 2>/dev/null)."
    return 0
  else
    err "'$name' does NOT match its recorded hash — files changed since $(jq -r '._integrity.at // "creation"' "$manifest" 2>/dev/null)."
    muted "recorded: $stored"
    muted "current:  $current"
    return 1
  fi
}

plugin_template_bash() {
  local path="$1" name="$2"
  cat > "$path" <<'TPL'
#!/usr/bin/env bash
# __PLUGIN_NAME__ — generated by aulthium-plugin-create.sh.
#
# Env vars Aulthium exports before launching this script (see
# plugin_export_env / plugin_export_config_env in aulthium.sh):
#   $AULTHIUM_API_KIND, $AULTHIUM_API_URL, $AULTHIUM_API_KEY, $AULTHIUM_MODEL
#   $AULTHIUM_PROVIDER, $AULTHIUM_PROVIDER_LABEL, $AULTHIUM_WORKSPACE_DIR
#   $AULTHIUM_PLUGIN_CONFIG_JSON   — this plugin's effective config, as JSON
#   $AULTHIUM_PLUGIN_CFG_<KEY>     — one var per top-level scalar config key
set -u

echo "__PLUGIN_NAME__ is running."
echo "Provider: $AULTHIUM_PROVIDER_LABEL   Model: $AULTHIUM_MODEL"
echo "Config:   $AULTHIUM_PLUGIN_CONFIG_JSON"

echo "Edit run.sh to build out __PLUGIN_NAME__. Press Enter to exit."
read -r _
TPL
  sed -i "s/__PLUGIN_NAME__/$name/g" "$path" 2>/dev/null
}

plugin_template_python() {
  local path="$1" name="$2"
  cat > "$path" <<'TPL'
#!/usr/bin/env python3
"""__PLUGIN_NAME__ — generated by aulthium-plugin-create.sh.

Env vars Aulthium exports before launching this script:
  AULTHIUM_API_KIND, AULTHIUM_API_URL, AULTHIUM_API_KEY, AULTHIUM_MODEL
  AULTHIUM_PROVIDER, AULTHIUM_PROVIDER_LABEL, AULTHIUM_WORKSPACE_DIR
  AULTHIUM_PLUGIN_CONFIG_JSON   -- this plugin's effective config, as JSON
  AULTHIUM_PLUGIN_CFG_<KEY>     -- one var per top-level scalar config key
"""
import json
import os

def main():
    print("__PLUGIN_NAME__ is running.")
    print(f"Provider: {os.environ.get('AULTHIUM_PROVIDER_LABEL')}   Model: {os.environ.get('AULTHIUM_MODEL')}")
    config = json.loads(os.environ.get("AULTHIUM_PLUGIN_CONFIG_JSON") or "{}")
    print(f"Config:   {config}")
    input("Edit run.py to build out __PLUGIN_NAME__. Press Enter to exit.")

if __name__ == "__main__":
    main()
TPL
  sed -i "s/__PLUGIN_NAME__/$name/g" "$path" 2>/dev/null
}

plugin_template_node() {
  local path="$1" name="$2"
  cat > "$path" <<'TPL'
#!/usr/bin/env node
// __PLUGIN_NAME__ — generated by aulthium-plugin-create.sh.
//
// Env vars Aulthium exports before launching this script:
//   AULTHIUM_API_KIND, AULTHIUM_API_URL, AULTHIUM_API_KEY, AULTHIUM_MODEL
//   AULTHIUM_PROVIDER, AULTHIUM_PROVIDER_LABEL, AULTHIUM_WORKSPACE_DIR
//   AULTHIUM_PLUGIN_CONFIG_JSON   -- this plugin's effective config, as JSON
//   AULTHIUM_PLUGIN_CFG_<KEY>     -- one var per top-level scalar config key

const config = JSON.parse(process.env.AULTHIUM_PLUGIN_CONFIG_JSON || "{}");

console.log("__PLUGIN_NAME__ is running.");
console.log(`Provider: ${process.env.AULTHIUM_PROVIDER_LABEL}   Model: ${process.env.AULTHIUM_MODEL}`);
console.log("Config:  ", config);

process.stdout.write("Edit run.js to build out __PLUGIN_NAME__. Press Enter to exit.");
process.stdin.once("data", () => process.exit(0));
TPL
  sed -i "s/__PLUGIN_NAME__/$name/g" "$path" 2>/dev/null
}

plugin_template_readme() {
  local path="$1" name="$2" desc="$3" mode="$4" runtime="$5" desc_safe
  cat > "$path" <<'TPL'
# __PLUGIN_NAME__

__PLUGIN_DESC__

Generated by `aulthium-plugin-create.sh`. Mode: __PLUGIN_MODE__. Runtime: __PLUGIN_RUNTIME__.

## Customizing this plugin

- The command Aulthium runs is `"entry"` in `plugin.json` — point it at
  whatever you build.
- Declared permissions live in `"permissions"` in `plugin.json`. Aulthium
  shows these as a y/N grant prompt at run time; changing this set gets
  the user re-prompted.
- Config defaults live in `"config"` in `plugin.json`; a user's own
  overrides live separately in `config.json` inside this folder.
- Run `t> plugin verify __PLUGIN_NAME__` in the main Aulthium REPL anytime
  to confirm these files still match what was recorded at creation.

Env vars Aulthium exports before launch: AULTHIUM_API_KIND, AULTHIUM_API_URL,
AULTHIUM_API_KEY, AULTHIUM_MODEL, AULTHIUM_PROVIDER, AULTHIUM_PROVIDER_LABEL,
AULTHIUM_WORKSPACE_DIR, AULTHIUM_PLUGIN_CONFIG_JSON, AULTHIUM_PLUGIN_CFG_<KEY>
TPL
  desc_safe="${desc:-No description yet.}"
  sed -i "s/__PLUGIN_NAME__/$name/g; s/__PLUGIN_MODE__/$mode/g; s/__PLUGIN_RUNTIME__/${runtime:-none}/g" "$path" 2>/dev/null
  desc_safe="${desc_safe//|/-}"
  desc_safe="${desc_safe//\\/\\\\}"
  desc_safe="${desc_safe//&/\\&}"
  sed -i "s|__PLUGIN_DESC__|${desc_safe}|" "$path" 2>/dev/null
}

usage() {
  cat <<EOF
$APP_NAME $APP_VERSION

Usage:
  $(basename "$0") <name> [flags...]

Flags:
  --desc "<text>"            short description (may contain spaces)
  --version <x.y.z>          default: 0.1.0
  --mode foreground|hook     default: foreground
  --hook <point>             required for --mode hook; default: web_search
  --toggle-prefix <p>        hook-mode shorthand, e.g. 'bws' for 'bws> on'
  --autostart                hook-mode: launch automatically every start
  --runtime bash|python3|node|none   default: bash
  --perm <scope>             repeatable — network/filesystem/shell/mcp/secrets
  --config <key>=<value>     repeatable — a config default
  --force                    overwrite an existing plugin of the same name
  --security-print           print the integrity hash right after creating
  --verify                   immediately verify the new plugin's files

Plugins are written under: \$AULTHIUM_PLUGINS_DIR or ~/.aulthium/plugins
(currently: $PLUGINS_DIR)

Example:
  $(basename "$0") mytool --security-print --verify
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -eq 0 ]]; then
    usage
    exit 0
  fi

  check_deps

  local name="" desc="" version="0.1.0" mode="foreground" hook="" toggle_prefix=""
  local runtime="bash" dir manifest entry perms=() cfg_json="{}" autostart="false"
  local force=0 do_secprint=0 do_verify=0
  local -a tokens=("$@")
  local n="${#tokens[@]}" i=0 t flag val k v
  local BOOL_FLAGS=" --autostart --security-print --verify --force "

  while (( i < n )); do
    t="${tokens[$i]}"
    case "$t" in
      --*)
        if [[ "$BOOL_FLAGS" == *" $t "* ]]; then
          case "$t" in
            --autostart)       autostart="true" ;;
            --security-print)  do_secprint=1 ;;
            --verify)          do_verify=1 ;;
            --force)           force=1 ;;
          esac
          ((i++))
        else
          flag="$t"; val=""
          ((i++))
          while (( i < n )) && [[ "${tokens[$i]}" != --* ]]; do
            val+="${val:+ }${tokens[$i]}"
            ((i++))
          done
          case "$flag" in
            --name)          name="$val" ;;
            --desc)          desc="$val" ;;
            --version)       [[ -n "$val" ]] && version="$val" ;;
            --mode)          [[ -n "$val" ]] && mode="$val" ;;
            --hook)          hook="$val" ;;
            --toggle-prefix) toggle_prefix="$val" ;;
            --runtime)       [[ -n "$val" ]] && runtime="$val" ;;
            --perm)          [[ -n "$val" ]] && perms+=("$val") ;;
            --config)
              if [[ "$val" == *=* ]]; then
                k="${val%%=*}"; v="${val#*=}"
                cfg_json="$(printf '%s' "$cfg_json" | jq --arg k "$k" --arg v "$v" '.[$k] = $v' 2>/dev/null)"
                [[ -z "$cfg_json" ]] && cfg_json="{}"
              else
                warn "Ignoring malformed --config '$val' (expected key=value)."
              fi
              ;;
            *)
              warn "Unknown flag '$flag' — ignoring."
              ;;
          esac
        fi
        ;;
      *)
        [[ -z "$name" ]] && name="$t"
        ((i++))
        ;;
    esac
  done

  if [[ -z "$name" ]]; then
    usage
    exit 1
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    err "Plugin name must contain only letters, numbers, - or _: got '$name'."
    exit 1
  fi

  mode="${mode,,}"
  if [[ "$mode" != "foreground" && "$mode" != "hook" ]]; then
    warn "Unrecognized mode '$mode' — defaulting to foreground."
    mode="foreground"
  fi
  [[ "$mode" == "hook" ]] && hook="${hook:-web_search}"

  runtime="${runtime,,}"
  case "$runtime" in
    bash|python3|python|node|none|"") : ;;
    *) warn "Unrecognized runtime '$runtime' — defaulting to bash."; runtime="bash" ;;
  esac

  if [[ "${#perms[@]}" -gt 0 ]]; then
    local p unknown=""
    for p in "${perms[@]}"; do
      [[ " $KNOWN_PLUGIN_PERMISSIONS " == *" $p "* ]] || unknown="$unknown $p"
    done
    [[ -n "$unknown" ]] && warn "Declaring unrecognized permission(s):$unknown — passed through as-is."
  fi

  mkdir -p "$PLUGINS_DIR" 2>/dev/null
  dir="$PLUGINS_DIR/$name"
  if [[ -d "$dir" ]]; then
    if [[ "$force" -eq 1 ]]; then
      rm -rf -- "$dir"
    else
      read -r -p "A plugin named '$name' already exists at $dir — overwrite it? [y/N] " ans
      case "${ans,,}" in
        y|yes) rm -rf -- "$dir" ;;
        *) warn "Cancelled."; exit 1 ;;
      esac
    fi
  fi

  if ! mkdir -p "$dir" 2>/dev/null; then
    err "Couldn't create $dir"
    exit 1
  fi

  case "$runtime" in
    bash)              entry="./run.sh" ;;
    python3|python)     runtime="python3"; entry="python3 ./run.py" ;;
    node)               entry="node ./run.js" ;;
    none|"")            runtime=""; entry="" ;;
  esac

  case "$entry" in
    "./run.sh")         plugin_template_bash "$dir/run.sh" "$name"; chmod +x "$dir/run.sh" 2>/dev/null ;;
    "python3 ./run.py") plugin_template_python "$dir/run.py" "$name"; chmod +x "$dir/run.py" 2>/dev/null ;;
    "node ./run.js")    plugin_template_node "$dir/run.js" "$name"; chmod +x "$dir/run.js" 2>/dev/null ;;
  esac
  plugin_template_readme "$dir/README.md" "$name" "$desc" "$mode" "$runtime"

  local perms_json="[]"
  if [[ "${#perms[@]}" -gt 0 ]]; then
    perms_json="$(printf '%s\n' "${perms[@]}" | jq -R . | jq -s . 2>/dev/null)"
    [[ -n "$perms_json" ]] || perms_json="[]"
  fi

  manifest="$dir/plugin.json"
  jq -n \
    --arg name "$name" \
    --arg desc "${desc:-}" \
    --arg version "$version" \
    --arg entry "$entry" \
    --arg runtime "${runtime:-}" \
    --arg mode "$mode" \
    --arg hook "$hook" \
    --arg toggle_prefix "$toggle_prefix" \
    --argjson autostart "$([[ "$autostart" == "true" ]] && printf true || printf false)" \
    --argjson permissions "$perms_json" \
    --argjson config "$cfg_json" \
    '{name: $name, description: $desc, version: $version}
     + (if $entry == "" then {} else {entry: $entry} end)
     + (if $runtime == "" then {} else {runtime: $runtime} end)
     + {mode: $mode}
     + (if $mode == "hook" then
         {hook: $hook}
         + (if $toggle_prefix == "" then {} else {toggle_prefix: $toggle_prefix} end)
         + {autostart: $autostart}
       else {} end)
     + {permissions: $permissions}
     + (if ($config | length) == 0 then {} else {config: $config} end)
    ' > "$manifest" 2>/dev/null

  if ! plugin_manifest_validate "$manifest"; then
    err "Generated plugin.json failed validation — check $manifest by hand."
    exit 1
  fi
  plugin_stamp_integrity "$dir"

  box "PLUGIN CREATED"
  printf "${C_BOLD}%s${C_RESET}${C_MUTED} v%s — %s${C_RESET}\n" "$name" "$version" "${desc:-(no description)}"
  muted "dir:   $dir"
  [[ -n "$entry" ]] && muted "entry: $entry"
  [[ "${#perms[@]}" -gt 0 ]] && muted "permissions: ${perms[*]}"
  ok "Created '$name'."
  [[ -n "$entry" ]] && muted "Edit the files in $dir to build it out, then load it from Aulthium: t> plugin install $dir"
  muted "Check file integrity anytime with this script's --verify, or in the main REPL: t> plugin verify $name"

  if [[ "$do_secprint" -eq 1 ]]; then
    local fp fp_at
    fp="$(jq -r '._integrity.sha256 // empty' "$manifest" 2>/dev/null)"
    fp_at="$(jq -r '._integrity.at // empty' "$manifest" 2>/dev/null)"
    box "SECURITY FINGERPRINT: $name"
    if [[ -n "$fp" ]]; then
      muted "sha256:  $fp"
      muted "stamped: ${fp_at:-unknown}"
      muted "covers every file under $dir except plugin.json/config.json."
    else
      warn "Could not compute a fingerprint — check that sha256sum/jq are available."
    fi
  fi

  if [[ "$do_verify" -eq 1 ]]; then
    plugin_verify "$name"
  fi
}

main "$@"
