#!/usr/bin/env python3
"""Download the pinned Minecraft 26.2 datapacks into a release directory."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path


PACKS = (
    ("ketkets-player-shops", "Player Shops", "6EILA1ly"),
    ("simplest-chairs", "Simplest Chairs", "uPvd9ej7"),
    ("death-count", "Death Count", "LYKqYOA8"),
    ("drop-head", "Drop Head", "HxOqkLrX"),
    ("ketket-graves", "Graves", "KL6JT1nQ"),
    ("spawn-animations", "Spawn Animations", "kXr2QX8r"),
    ("easy-harvest-crops", "Easy Harvest Crops", "2STSwFtm"),
)
API = "https://api.modrinth.com/v2"
HEADERS = {"User-Agent": "nikchester/minecraft-server staging datapack installer"}


def get_json(url: str) -> object:
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=45) as response:
        return json.load(response)


def fetch(url: str, path: Path) -> None:
    request = urllib.request.Request(url, headers=HEADERS)
    temporary = path.with_suffix(path.suffix + ".part")
    with urllib.request.urlopen(request, timeout=90) as response, temporary.open("wb") as output:
        output.write(response.read())
    temporary.replace(path)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: install-datapacks.py <release/datapacks>", file=sys.stderr)
        return 2
    target = Path(sys.argv[1])
    target.mkdir(parents=True, exist_ok=True)
    marker = target / ".issue-77-managed.json"
    previous_files = json.loads(marker.read_text(encoding="utf-8")) if marker.exists() else []
    with tempfile.TemporaryDirectory(prefix="issue-77-packs-") as temp_dir:
        staged = Path(temp_dir)
        installed: list[tuple[str, str, str]] = []
        for slug, label, version_id in PACKS:
            version = get_json(f"{API}/version/{version_id}")
            if not isinstance(version, dict):
                raise RuntimeError(f"Unexpected Modrinth version response for {label}")
            if (
                "26.2" not in version.get("game_versions", [])
                or "datapack" not in version.get("loaders", [])
                or version.get("version_type") != "release"
            ):
                raise RuntimeError(f"Pinned Modrinth release is not a stable 26.2 datapack for {label}")
            files = version.get("files", [])
            if not files:
                raise RuntimeError(f"No downloadable file listed for {label} {version.get('version_number')}")
            file_info = next((entry for entry in files if entry.get("primary")), files[0])
            url = file_info.get("url")
            if not url:
                raise RuntimeError(f"Missing download URL for {label} {version.get('version_number')}")
            filename = Path(file_info.get("filename", f"{slug}.zip")).name
            archive = staged / filename
            fetch(url, archive)
            with zipfile.ZipFile(archive) as pack:
                names = pack.namelist()
                if not any(name.endswith("pack.mcmeta") for name in names) or not any(
                    "/data/" in f"/{name}" or name.startswith("data/") for name in names
                ):
                    raise RuntimeError(f"Downloaded file is not a valid datapack archive: {filename}")
            installed.append((label, version.get("version_number", "unknown"), filename))

        # Only remove files installed by this script; keep unrelated user packs.
        for filename in previous_files:
            old_file = target / Path(filename).name
            if old_file.is_file():
                old_file.unlink()
        for _, _, filename in installed:
            shutil.move(str(staged / filename), target / filename)
        marker.write_text(json.dumps([filename for _, _, filename in installed], indent=2) + "\n", encoding="utf-8")
        for label, version, filename in installed:
            print(f"Installed {label} {version} ({filename})")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, urllib.error.URLError, zipfile.BadZipFile, RuntimeError) as error:
        print(f"Datapack installation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
