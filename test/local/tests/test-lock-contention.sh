#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

test_deploy_does_not_deadlock_on_its_own_backup_call() {
  # Regression test for the actual production bug: deploy.sh runs its
  # whole flow under with_global_lock, then shells out to backup.sh, which
  # independently wraps itself in the SAME lock file. Before the fix, that
  # second acquisition blocked for the full LOCK_TIMEOUT_SECONDS every
  # single deploy. A short timeout here makes a regression fail in
  # seconds instead of hanging for however long LOCK_TIMEOUT_SECONDS is.
  reset_environment
  prepare_release "rel1" || return 1
  if ! timeout 10 env LOCK_TIMEOUT_SECONDS=5 /opt/minecraft/bin/deploy.sh; then
    echo "  ASSERT FAILED: deploy.sh did not finish within 10s -- possible lock deadlock regression between deploy.sh and backup.sh" >&2
    return 1
  fi
}

test_concurrent_operation_blocks_then_proceeds() {
  reset_environment
  prepare_release "rel1" || return 1

  # Hold the global lock manually, as if some other operation were
  # already in flight, and confirm deploy.sh queues behind it instead of
  # running concurrently -- then confirm it actually proceeds once free.
  exec 8>"/srv/minecraft/state/operation.lock"
  flock 8

  timeout 12 /opt/minecraft/bin/deploy.sh &
  local deploy_pid=$!
  sleep 1

  if ! kill -0 "$deploy_pid" 2>/dev/null; then
    echo "  ASSERT FAILED: expected deploy.sh to still be blocked while the lock is held" >&2
    flock -u 8
    exec 8>&-
    return 1
  fi

  flock -u 8
  exec 8>&-

  if ! wait "$deploy_pid"; then
    echo "  ASSERT FAILED: deploy.sh should have proceeded and succeeded once the lock was released" >&2
    return 1
  fi
}

reset_environment
run_test "deploy.sh calling backup.sh under the same lock does not deadlock" test_deploy_does_not_deadlock_on_its_own_backup_call
run_test "a second operation blocks on the lock and proceeds once it's free" test_concurrent_operation_blocks_then_proceeds
report_and_exit
