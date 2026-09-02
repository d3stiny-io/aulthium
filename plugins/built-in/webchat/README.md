# webchat

Chat with Aulthium from a page in your browser instead of typing in the
terminal — same model, same tool use, same confirmation gate, just a
different window.

## What it does

`webchat` spins up a small local web server backed by whatever AI
provider/model Aulthium is currently configured with. It mirrors the
terminal session in a few ways that matter:

- **Markdown rendering** — headers, bold/italic, inline code, fenced code
  blocks, links, lists, and blockquotes render properly in the browser.
- **Rate-limit handling** — the same retry-with-backoff behavior as the
  terminal's `call_provider_with_retry`. A 429 or transient 5xx
  (500/502/503/504) is retried automatically (honoring `Retry-After` when
  present, otherwise exponential backoff with jitter, capped), an
  exhausted daily/monthly quota fails fast with a clear message instead
  of burning retries, and non-retryable errors (other 4xxs, connection
  failures) fail immediately. You'll see a live "rate limited, retrying
  in Xs" status in the browser instead of a silent spinner.
- **The same tool marker protocol as the terminal file agent:**
  - `FILE_READ`, `DIR_LIST`, `WEB_SEARCH` run immediately, no confirmation.
  - `FILE_WRITE`, `FILE_DELETE`, `SHELL_RUN` are gated behind an explicit
    yes/no click in the browser — the same gate `confirm_action` provides
    in the terminal.

`SHELL_RUN` runs with the same `$WORKSPACE_DIR` working directory and
timeout the terminal's `SHELL_RUN` uses, and is **not** sandboxed to that
folder — the command can reach anything the device's shell can reach. The
confirm gate starts synced to whatever `t> confirm on/off` was set to in
the terminal at the moment the plugin launched
(`AULTHIUM_SKIP_CONFIRMATIONS`), and can be flipped independently from the
page after that.

## Requirements

Stdlib-only at its core — `python3` is the only hard requirement. The
`WEB_SEARCH` marker prefers BeautifulSoup for parsing results when it's
installed, and falls back to a regex-based parser automatically if it's
not, so the plugin works either way:

```bash
pip install beautifulsoup4 --break-system-packages   # optional, improves WEB_SEARCH
```

## Usage

```
t> plugin run webchat
```

This launches the server, opens your browser to it, and starts serving
chat backed by your configured provider. Stop it the same way you'd stop
any other plugin process (Ctrl+C in the terminal that launched it, or
`t> plugin stop webchat` if supported by your Aulthium version).

## Configuration

Set with `t> plugin config webchat set <key> <value>`:

| Key | Default | Meaning |
| :--- | :--- | :--- |
| `port` | `8420` | Local port the chat page is served on |
| `max_rate_limit_retries` | `9` | Max retry attempts on 429/5xx before giving up |
| `max_rate_limit_wait` | `60` | Cap (seconds) on backoff wait between retries |
| `shell_timeout_secs` | `60` | Timeout for `SHELL_RUN` commands |

Legacy `AULTHIUM_WEBCHAT_PORT`-style environment variables are still
honored as a fallback if set, but `plugin config` is the supported path.

## Permissions

Declares `network`, `shell`, and `secrets` in `plugin.json` — it serves a
local HTTP server, can execute shell commands (after confirmation), and
reads the provider API key to talk to your configured AI provider.

## Security notes

- `SHELL_RUN` is real shell execution with your user's privileges. Only
  approve commands you understand and expect.
- The server binds to `127.0.0.1` — it isn't exposed to your network by
  default.
- Every file path proposed by the model must be relative and stay inside
  the workspace folder; absolute paths and `..` are rejected by the tool
  protocol, but this is a convention enforced by the prompt, not a
  sandbox — treat `SHELL_RUN` with the same caution you would in the
  terminal.
