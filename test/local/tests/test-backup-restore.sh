#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

# Matches test/local/fixtures/rclone.conf's [minio] section plus backup.sh's
# own default of rclone:<remote>:minecraft-restic -- hardcoded here rather
# than re-deriving it, since the fixture is what pins this value, not the
# script logic under test.
export RESTIC_REPOSITORY="rclone:minio:minecraft-restic"
export RESTIC_PASSWORD_FILE=/opt/test/fixtures/restic_password
export HOME=/root

latest_scheduled_snapshot() {
  restic snapshots --json --tag scheduled 2>/dev/null | python3 -c 'import json, sys; snapshots = json.load(sys.stdin); print(max(snapshots, key=lambda snapshot: snapshot["time"])["id"] if snapshots else "")'
}

deploy_one_release() {
  prepare_release "rel1" || return 1
  /opt/minecraft/bin/deploy.sh || return 1
}

test_backup_creates_snapshot() {
  reset_environment
  deploy_one_release || return 1
  local before after
  before=$(latest_scheduled_snapshot) || return 1
  /opt/minecraft/bin/backup.sh scheduled || return 1
  after=$(latest_scheduled_snapshot) || return 1
  assert_file_exists /srv/minecraft/state/last-backup-success || return 1
  if [[ -z "$after" || "$after" == "$before" ]]; then
    echo "  ASSERT FAILED: expected a new scheduled snapshot (before=${before} after=${after})" >&2
    return 1
  fi
}

test_restore_recovers_modified_file() {
  reset_environment
  deploy_one_release || return 1
  /opt/minecraft/bin/backup.sh scheduled || return 1
  local snapshot
  snapshot=$(restic snapshots --json --tag scheduled --latest 1 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | head -1 | cut -d'"' -f4)
  [[ -n "$snapshot" ]] || {
    echo "  ASSERT FAILED: could not find the snapshot just created" >&2
    return 1
  }

  printf '{"tampered": true}\n' >/srv/minecraft/shared/whitelist.json

  /opt/minecraft/bin/restore.sh "$snapshot" CONFIRM_FULL_RESTORE || return 1

  local restored
  restored=$(cat /srv/minecraft/shared/whitelist.json)
  if [[ "$restored" == *tampered* ]]; then
    echo "  ASSERT FAILED: whitelist.json still shows the tampered content after restore" >&2
    return 1
  fi
}

test_pre_restore_backup_does_not_evict_target() {
  # Regression test for the exact bug found running this for real against
  # production: restore.sh's own pre-restore safety backup landed in the
  # same restic daily bucket as the snapshot being restored, and its
  # forget/prune deleted that snapshot before restic restore ever ran.
  reset_environment
  deploy_one_release || return 1
  /opt/minecraft/bin/backup.sh pre-deploy || return 1
  local target
  target=$(restic snapshots --json --tag pre-deploy --latest 1 2>/dev/null | grep -o '"short_id":"[a-f0-9]*"' | head -1 | cut -d'"' -f4)
  [[ -n "$target" ]] || {
    echo "  ASSERT FAILED: could not find the pre-deploy snapshot just created" >&2
    return 1
  }

  # restore.sh's pre-restore backup happens inside this call; if the old
  # bug were still present, restic restore would fail here with
  # "no matching ID found for prefix" and this returns non-zero.
  /opt/minecraft/bin/restore.sh "$target" CONFIRM_FULL_RESTORE || return 1
}

reset_environment
run_test "backup.sh creates a real restic snapshot in minio" test_backup_creates_snapshot
run_test "restore.sh recovers a modified file from a snapshot" test_restore_recovers_modified_file
run_test "pre-restore backup does not evict the snapshot being restored" test_pre_restore_backup_does_not_evict_target
report_and_exit
