#!/usr/bin/env python3
"""
ipython-repl hook entry point.

Called two different ways by Aulthium:

1. As the "shell_exec" hook, on every SHELL_RUN command the AI proposes,
   BEFORE the user has confirmed it:
       hook.py shell_exec "<the proposed command text>"
   This must have NO side effects — Aulthium's confirm-before-run
   contract depends on that. All this does is decide whether the
   command looks like a Python invocation, and if so print a REWRITTEN
   command line that will (once the user confirms it and Aulthium
   actually runs it) hand that same code to the persistent IPython
   kernel via ipy_client.py. Printing nothing leaves the original
   command untouched, so anything that isn't recognizably Python
   passes straight through as normal.

2. As a "<prefix>> ..." shorthand forward (this plugin claims "ipy>"),
   when the USER (not the AI) types it directly:
       ipy_run.py "<code the user typed after ipy>>"
   This case IS the actual, already-approved action — there's no
   confirmation step for prefix shorthands — so it runs the code for
   real against the same persistent kernel and streams the result back
   immediately.
"""
import os
import re
import shlex
import subprocess
import sys
import importlib.util

INTERP_RE = r"(?:python3?|ipython3?)"
PLUGIN_DIR = os.path.dirname(os.path.abspath(__file__))
CLIENT_PATH = os.path.join(PLUGIN_DIR, "ipy_client.py")


def ipython_available():
    return importlib.util.find_spec("IPython") is not None


def extract_python_code(cmd_text, workspace):
    """Returns the Python source to run, or None if cmd_text doesn't look
    like one of the Python invocation shapes we know how to reroute."""
    text = cmd_text.strip("\n")
    if not text.strip():
        return None

    # Form 1 (single line): "<interp> -c '<code>'" or "<interp> some/file.py"
    if "\n" not in text:
        try:
            tokens = shlex.split(text, posix=True)
        except ValueError:
            tokens = []
        if tokens and re.fullmatch(INTERP_RE, tokens[0]):
            if len(tokens) == 3 and tokens[1] == "-c":
                return tokens[2]
            if len(tokens) == 2 and tokens[1].endswith(".py"):
                path = tokens[1]
                full = path if os.path.isabs(path) else os.path.join(workspace, path)
                if os.path.isfile(full):
                    try:
                        with open(full, "r", encoding="utf-8", errors="replace") as f:
                            return f.read()
                    except OSError:
                        return None
                return None

    # Form 2 (heredoc): "<interp> [-] <<[-]'DELIM'\n...body...\nDELIM"
    m = re.match(
        r"^" + INTERP_RE + r"\s*-?\s*<<-?\s*['\"]?(\w+)['\"]?\s*\n(.*)\n\1\s*$",
        text,
        re.DOTALL,
    )
    if m:
        return m.group(2)

    return None


def build_wrapped_command(workspace, idle_timeout, code):
    delim = "AULTHIUM_IPY_EOF"
    while delim in code:
        delim += "_"
    header = "python3 {client} --workspace {ws} --idle-timeout {t} <<'{d}'".format(
        client=shlex.quote(CLIENT_PATH),
        ws=shlex.quote(workspace),
        t=shlex.quote(str(idle_timeout)),
        d=delim,
    )
    return f"{header}\n{code.rstrip(chr(10))}\n{delim}"


def handle_shell_exec(cmd_text, workspace, idle_timeout):
    if not ipython_available():
        return  # plugin present but dependency missing -> pass everything through
    code = extract_python_code(cmd_text, workspace)
    if code is None:
        return
    print(build_wrapped_command(workspace, idle_timeout, code))


def handle_prefix(code, workspace, idle_timeout):
    if not ipython_available():
        sys.stderr.write(
            "ipython-repl: the 'ipython' package isn't installed — "
            "run: pip install ipython\n"
        )
        return 1
    proc = subprocess.run(
        [
            "python3",
            CLIENT_PATH,
            "--workspace",
            workspace,
            "--idle-timeout",
            str(idle_timeout),
        ],
        input=code,
        text=True,
    )
    return proc.returncode


def main():
    args = sys.argv[1:]
    workspace = os.environ.get("AULTHIUM_WORKSPACE_DIR", os.getcwd())
    idle_timeout = os.environ.get("AULTHIUM_PLUGIN_CFG_IDLE_TIMEOUT_MINUTES", "120")

    if not args:
        return 0

    if args[0] == "shell_exec":
        cmd_text = args[1] if len(args) > 1 else ""
        handle_shell_exec(cmd_text, workspace, idle_timeout)
        return 0

    # Otherwise: this is a "ipy> ..." toggle-prefix forward — args[0] is the
    # raw text the user typed after the prefix, run it for real.
    return handle_prefix(args[0], workspace, idle_timeout)


if __name__ == "__main__":
    sys.exit(main() or 0)
