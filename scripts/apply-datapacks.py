#!/usr/bin/env python3
"""Apply or roll back the managed issue #77 datapacks in a world directory."""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


MARKER = ".issue-77-managed.json"


def managed_files(directory: Path) -> list[str]:
    marker = directory / MARKER
    if not marker.exists():
        return []
    names = json.loads(marker.read_text(encoding="utf-8"))
    if not isinstance(names, list) or any(
        not isinstance(name, str) or Path(name).name != name for name in names
    ):
        raise RuntimeError(f"Invalid managed datapack manifest: {marker}")
    return names


def restore(world: Path, backup: Path) -> None:
    state_path = backup / "state.json"
    if not state_path.exists():
        return
    state = json.loads(state_path.read_text(encoding="utf-8"))
    for filename in managed_files(world):
        (world / filename).unlink(missing_ok=True)
    for filename in state["files"]:
        shutil.copy2(backup / filename, world / filename)
    marker = world / MARKER
    if state["marker_present"]:
        shutil.copy2(backup / MARKER, marker)
    else:
        marker.unlink(missing_ok=True)
    shutil.rmtree(backup)


def apply(staged: Path, world: Path, backup: Path) -> None:
    names = managed_files(staged)
    if not names:
        raise RuntimeError(f"No managed datapacks listed in {staged / MARKER}")
    for filename in names:
        archive = staged / filename
        if not archive.is_file():
            raise RuntimeError(f"Staged datapack is missing: {archive}")
        with zipfile.ZipFile(archive) as pack:
            contents = pack.namelist()
            if not any(name.endswith("pack.mcmeta") for name in contents) or not any(
                "/data/" in f"/{name}" or name.startswith("data/") for name in contents
            ):
                raise RuntimeError(f"Invalid datapack archive: {archive}")

    if backup.exists():
        if (backup / ".complete").exists():
            print("Managed datapacks already applied for this release")
            return
        restore(world, backup)

    world.mkdir(parents=True, exist_ok=True)
    backup.mkdir(parents=True)
    old_names = managed_files(world)
    old_marker = world / MARKER
    for filename in old_names:
        old_file = world / filename
        if old_file.is_file():
            shutil.copy2(old_file, backup / filename)
    if old_marker.exists():
        shutil.copy2(old_marker, backup / MARKER)
    (backup / "state.json").write_text(
        json.dumps({"files": [name for name in old_names if (backup / name).exists()],
                    "marker_present": old_marker.exists()}, indent=2)
        + "\n",
        encoding="utf-8",
    )

    try:
        for filename in old_names:
            if filename not in names:
                (world / filename).unlink(missing_ok=True)
        for filename in names:
            with tempfile.NamedTemporaryFile(dir=world, delete=False) as temp_file:
                temporary = Path(temp_file.name)
            shutil.copyfile(staged / filename, temporary)
            temporary.replace(world / filename)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=world, delete=False) as temp_file:
            json.dump(names, temp_file, indent=2)
            temp_file.write("\n")
            marker_temp = Path(temp_file.name)
        marker_temp.replace(world / MARKER)
        (backup / ".complete").touch()
    except Exception:
        restore(world, backup)
        raise
    print(f"Applied {len(names)} managed datapacks")


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in {"apply", "rollback"}:
        print("Usage: apply-datapacks.py apply <release/datapacks> <world/datapacks> <backup-dir>", file=sys.stderr)
        print("   or: apply-datapacks.py rollback <world/datapacks> <backup-dir>", file=sys.stderr)
        return 2

    if sys.argv[1] == "apply":
        if len(sys.argv) != 5:
            return 2
        apply(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]))
    else:
        if len(sys.argv) != 4:
            return 2
        restore(Path(sys.argv[2]), Path(sys.argv[3]))
        print("Restored datapacks from deployment snapshot")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, zipfile.BadZipFile, RuntimeError) as error:
        print(f"Datapack operation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
