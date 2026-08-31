#!/usr/bin/env python3
"""
Persistent per-terminal-session IPython kernel for the ipython-plugin
plugin. Spawned lazily by ipy_client.py on the first Python SHELL_RUN of
a session and reused for every one after that, so the AI's variables,
imports, and %history survive across separate SHELL_RUN calls the way a
real interactive IPython session would — instead of a fresh, empty
interpreter every time.

Wire format: one JSON object per connection, no length prefix (the
client half-closes its write side after sending, so a plain read-until-
EOF is enough) — {"code": "...", "cwd": "..."} in, then this process
replies with {"stdout": "...", "stderr": "...", "success": bool} and
closes. Single-threaded and one request at a time on purpose: the AI's
actions are already sequential, so there's nothing to gain from
concurrency here and it would only complicate kernel state.
"""
import argparse
import contextlib
import io
import json
import os
import socket
import sys
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--idle-timeout", type=float, default=120)
    args = ap.parse_args()

    try:
        from IPython.core.interactiveshell import InteractiveShell
    except ImportError:
        sys.stderr.write("ipy_server: IPython isn't installed (pip install ipython)\n")
        sys.exit(1)

    shell = InteractiveShell.instance()
    # Verbose mode gives a per-frame traceback with each frame's local
    # variables printed alongside it — the actual "better debugging" this
    # plugin exists for, and it's built into IPython itself.
    try:
        shell.InteractiveTB.set_mode("Verbose")
    except Exception:
        pass

    try:
        os.chdir(args.workspace)
    except OSError:
        pass

    if os.path.exists(args.socket):
        try:
            os.remove(args.socket)
        except OSError:
            pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.socket)
    os.chmod(args.socket, 0o600)
    srv.listen(5)
    srv.settimeout(1.0)

    last_activity = time.time()
    idle_seconds = max(args.idle_timeout, 0) * 60

    def handle(conn):
        nonlocal last_activity
        last_activity = time.time()
        with conn:
            conn.settimeout(30)
            data = b""
            try:
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
            except socket.timeout:
                pass

            try:
                req = json.loads(data.decode(errors="replace"))
            except json.JSONDecodeError:
                try:
                    conn.sendall(json.dumps(
                        {"stdout": "", "stderr": "ipy_server: bad request\n", "success": False}
                    ).encode())
                except OSError:
                    pass
                return

            code = req.get("code", "")
            cwd = req.get("cwd")
            if cwd:
                try:
                    os.chdir(cwd)
                except OSError:
                    pass

            out_buf, err_buf = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out_buf), contextlib.redirect_stderr(err_buf):
                result = shell.run_cell(code, store_history=True)

            resp = {
                "stdout": out_buf.getvalue(),
                "stderr": err_buf.getvalue(),
                "success": bool(result.success),
            }
            try:
                conn.sendall(json.dumps(resp).encode())
            except OSError:
                pass

    try:
        while True:
            if idle_seconds and (time.time() - last_activity) > idle_seconds:
                break
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            handle(conn)
    finally:
        try:
            os.remove(args.socket)
        except OSError:
            pass


if __name__ == "__main__":
    main()
