#!/usr/bin/env python3
"""Offline production backup preflight. Never include input in diagnostics."""

import argparse
import json
import os
import re
import sys


def validate(config: str) -> None:
    # Match the first-section parser in scripts/lib.sh, after the workflow's
    # CRLF normalization. Do not accept indented/decorated section headers.
    sections = []
    options = {}
    for line in config.replace("\r\n", "\n").split("\n"):
        if not line.strip() or line.lstrip().startswith(("#", ";")):
            continue
        if line.lstrip().startswith("["):
            match = re.fullmatch(r"\[([\w.+@][\w .+@-]*)\]", line)
            if not match or match[1] != match[1].strip():
                raise ValueError("remote header is incompatible with runtime remote discovery")
            sections.append(match[1])
            if len(sections) != 1:
                raise ValueError("exactly one Google Drive remote is required")
            continue
        if not sections or "=" not in line:
            raise ValueError("invalid rclone configuration syntax")
        key, value = (part.strip() for part in line.split("=", 1))
        if not key or key in options:
            raise ValueError("empty or duplicate rclone option")
        options[key] = value
    if len(sections) != 1:
        raise ValueError("exactly one Google Drive remote is required")
    if options.get("type") != "drive":
        raise ValueError("backup remote type must be drive (Google Drive)")
    try:
        token = json.loads(options.get("token", ""))
    except (ValueError, RecursionError):
        raise ValueError("token must be valid JSON") from None
    if not isinstance(token, dict) or not isinstance(token.get("refresh_token"), str) or not token["refresh_token"].strip():
        raise ValueError("token must contain a nonempty refresh_token string")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", metavar="NAME", help="read this environment variable instead of stdin")
    args = parser.parse_args()
    try:
        config = os.environ.get(args.env, "") if args.env else sys.stdin.read()
        validate(config)
    except (ValueError, OSError):
        # Parser exceptions may include credentials; only our fixed diagnostics
        # are safe. Keep the CLI message independent of all supplied values.
        print("ERROR: backup config requires one runtime-compatible remote, type=drive, and a JSON token with refresh_token", file=sys.stderr)
        return 1
    print("Google Drive backup configuration preflight passed (offline)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
