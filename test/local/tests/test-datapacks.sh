#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

test_apply_preserves_unmanaged_files_and_rollback_restores_previous_packs() {
  reset_environment
  local staged=/srv/minecraft/releases/packs/datapacks
  local world=/srv/minecraft/shared/world/datapacks
  local backup=/srv/minecraft/releases/packs/datapack-rollback
  mkdir -p "$staged" "$world"
  printf 'unmanaged user pack\n' >"$world/user-pack.zip"
  printf 'old pack\n' >"$world/old.zip"
  printf '["old.zip"]\n' >"$world/.issue-77-managed.json"

  python3 - "$staged" <<'PY'
import json
import sys
import zipfile
from pathlib import Path

directory = Path(sys.argv[1])
for filename in ("new-a.zip", "new-b.zip"):
    with zipfile.ZipFile(directory / filename, "w") as archive:
        archive.writestr("pack.mcmeta", "{}")
        archive.writestr("data/test/functions/load.mcfunction", "say test\n")
(directory / ".issue-77-managed.json").write_text(
    json.dumps(["new-a.zip", "new-b.zip"]) + "\n", encoding="utf-8"
)
PY

  python3 /opt/minecraft/bin/apply-datapacks.py apply "$staged" "$world" "$backup" || return 1
  assert_file_exists "$world/new-a.zip" || return 1
  assert_file_exists "$world/new-b.zip" || return 1
  assert_file_exists "$world/user-pack.zip" || return 1
  if [[ -e "$world/old.zip" ]]; then
    echo "  ASSERT FAILED: old managed datapack was not removed" >&2
    return 1
  fi

  python3 /opt/minecraft/bin/apply-datapacks.py apply "$staged" "$world" "$backup" || return 1
  python3 /opt/minecraft/bin/apply-datapacks.py rollback "$world" "$backup" || return 1
  assert_file_exists "$world/old.zip" || return 1
  assert_file_exists "$world/user-pack.zip" || return 1
  if [[ -e "$world/new-a.zip" || -e "$world/new-b.zip" ]]; then
    echo "  ASSERT FAILED: failed release datapacks remained after rollback" >&2
    return 1
  fi
  assert_eq '["old.zip"]' "$(tr -d '\n ' <"$world/.issue-77-managed.json")" \
    "(managed manifest after rollback)" || return 1
  [[ ! -e "$backup" ]]
}

reset_environment
run_test "datapack apply preserves unmanaged packs and rollback restores old state" \
  test_apply_preserves_unmanaged_files_and_rollback_restores_previous_packs
report_and_exit
