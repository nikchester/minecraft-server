#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

REQUIRED = [
    "SPEC.md",
    "PLAN.md",
    "README.md",
    "minecraft/versions.yml",
    "minecraft/server.properties",
    "ansible/playbooks/bootstrap.yml",
    "ansible/playbooks/firewall.yml",
    "scripts/backup.sh",
    "scripts/deploy.sh",
    "scripts/restore.sh",
    "systemd/minecraft.service",
    "systemd/minecraft-vps-heartbeat.timer",
    ".github/workflows/ci.yml",
]

FORBIDDEN_ROOTS = ["world", "world_nether", "world_the_end", "backups", "logs"]
FORBIDDEN_SUFFIXES = [".jar", ".sqlite", ".sqlite3", ".db", ".pem", ".key"]


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    return 1


def main():
    errors = 0
    for item in REQUIRED:
        if not (ROOT / item).exists():
            errors += fail(f"missing required path: {item}")
    for item in FORBIDDEN_ROOTS:
        if (ROOT / item).exists():
            errors += fail(f"runtime directory must not exist in repo root: {item}")
    for path in ROOT.rglob("*"):
        rel = path.relative_to(ROOT)
        if ".git" in rel.parts or ".opencode" in rel.parts:
            continue
        if path.is_file() and path.suffix in FORBIDDEN_SUFFIXES:
            errors += fail(f"forbidden tracked-style artifact present: {rel}")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
