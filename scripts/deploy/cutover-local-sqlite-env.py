#!/usr/bin/env python3
"""Point /etc/cleat_deploy/env at a local SQLite file. Comment Turso keys."""

from pathlib import Path
import sys

DATABASE_PATH = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/cleat_deploy/cleat.db"
ENV_PATH = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/etc/cleat_deploy/env")

text = ENV_PATH.read_text()
lines = []
seen_db = False

for line in text.splitlines():
    if line.startswith("TURSO_DATABASE_URL=") or line.startswith("TURSO_AUTH_TOKEN="):
        if line.startswith("#"):
            lines.append(line)
        else:
            lines.append(f"# {line}  # cutover-local-sqlite")
        continue

    if line.startswith("DATABASE_PATH="):
        lines.append(f"DATABASE_PATH={DATABASE_PATH}")
        seen_db = True
        continue

    lines.append(line)

if not seen_db:
    lines.append(f"DATABASE_PATH={DATABASE_PATH}")

ENV_PATH.write_text("\n".join(lines) + "\n")
