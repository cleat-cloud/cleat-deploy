#!/usr/bin/env python3
"""Load a systemd EnvironmentFile and exec a command with literal values."""
import os
import re
import shlex
import sys

KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def unescape(value):
    out = []
    index = 0
    length = len(value)
    mapping = {"n": "\n", "\\": "\\", '"': '"', "'": "'"}
    while index < length:
        if value[index] == "\\" and index + 1 < length:
            out.append(mapping.get(value[index + 1], value[index + 1]))
            index += 2
        else:
            out.append(value[index])
            index += 1
    return "".join(out)


def parse(path):
    env = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line or line.lstrip().startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if not KEY.match(key):
                continue
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = unescape(value[1:-1])
            env[key] = value
    return env


def main(argv):
    extra = {}
    chdir = None
    print_exports = False
    while argv and argv[0].startswith("-"):
        flag = argv.pop(0)
        if flag == "--":
            break
        if flag == "--print-exports":
            print_exports = True
        elif flag == "--chdir":
            chdir = argv.pop(0)
        elif flag == "--set":
            item = argv.pop(0)
            key, _, value = item.partition("=")
            extra[key] = value
        else:
            sys.stderr.write("unknown flag: %s\n" % flag)
            sys.exit(2)

    if not argv:
        sys.stderr.write(
            "usage: cleat_env_exec.py [--print-exports] [--chdir DIR] [--set K=V] ENVFILE [CMD ...]\n"
        )
        sys.exit(2)

    path = argv.pop(0)
    parsed = parse(path)

    if print_exports:
        merged = dict(parsed)
        merged.update(extra)
        for key, value in merged.items():
            sys.stdout.write("export %s=%s\n" % (key, shlex.quote(value)))
        return

    if not argv:
        sys.stderr.write("missing command\n")
        sys.exit(2)

    env = os.environ.copy()
    env.update(parsed)
    env.update(extra)
    if chdir:
        os.chdir(chdir)
    os.execvpe(argv[0], argv, env)


if __name__ == "__main__":
    main(sys.argv[1:])
