#!/usr/bin/env python3
"""
Thin client for the ipython-plugin's persistent kernel.

Reads Python code from stdin, makes sure the per-terminal-session kernel
daemon (ipy_server.py) is up (spawning it if this is the first call this
session), sends the code over a Unix socket, and prints back exactly what
the kernel produced. Exits 0 if the code ran without raising, 1 otherwise
— so a normal SHELL_RUN "exit=" code still means what the AI expects.

This is the script ipy_run.py's rewritten command actually invokes once the
user has confirmed it (or, for the "ipy>" shorthand, right away) — by the
time this runs, the code is a done deal; this file has no say over
whether it *should* run, only how it gets to the kernel and back.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time


def socket_path():
    # os.getsid(0) is stable across every subshell/subprocess Aulthium
    # forks for a single SHELL_RUN within one terminal session, but
    # differs between separate sessions/terminals — exactly the scope we
    # want a single kernel to live for.
    try:
        sid = os.getsid(0)
    except OSError:
        sid = os.getpid()
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    return os.path.join(base, f"aulthium-ipy-{sid}.sock")


def server_alive(path):
    if not os.path.exists(path):
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            s.connect(path)
            return True
    except OSError:
        return False


def spawn_server(path, workspace, idle_timeout):
    server_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ipy_server.py")
    subprocess.Popen(
        [
            "python3",
            server_py,
            "--socket",
            path,
            "--workspace",
            workspace,
            "--idle-timeout",
            str(idle_timeout),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def ensure_server(path, workspace, idle_timeout):
    if server_alive(path):
        return True
    if os.path.exists(path):
        try:
            os.remove(path)
        except OSError:
            pass
    spawn_server(path, workspace, idle_timeout)
    for _ in range(50):  # ~10s, generous for first-ever IPython import
        time.sleep(0.2)
        if server_alive(path):
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", default=os.getcwd())
    ap.add_argument("--idle-timeout", default="120")
    args = ap.parse_args()

    code = sys.stdin.read()
    path = socket_path()

    if not ensure_server(path, args.workspace, args.idle_timeout):
        sys.stderr.write(
            "ipython-repl: couldn't start the persistent IPython kernel "
            "(is the 'ipython' package installed? pip install ipython)\n"
        )
        return 1

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(300)
            s.connect(path)
            payload = json.dumps({"code": code, "cwd": args.workspace}).encode() + b"\n"
            s.sendall(payload)
            s.shutdown(socket.SHUT_WR)
            chunks = []
            while True:
                buf = s.recv(65536)
                if not buf:
                    break
                chunks.append(buf)
        resp = json.loads(b"".join(chunks).decode(errors="replace"))
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(
            f"ipython-repl: lost the kernel connection ({e}) — "
            "it will restart fresh on the next command.\n"
        )
        try:
            os.remove(path)
        except OSError:
            pass
        return 1

    if resp.get("stdout"):
        sys.stdout.write(resp["stdout"])
    if resp.get("stderr"):
        sys.stderr.write(resp["stderr"])
    return 0 if resp.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
