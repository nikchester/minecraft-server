#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

test_failed_release_rolls_back() {
  reset_environment
  prepare_release "rel1" || return 1
  /opt/minecraft/bin/deploy.sh || return 1
  assert_eq "rel1" "$(cat /srv/minecraft/state/current-release)" || return 1

  prepare_release "rel2" || return 1
  # See test/local/bin/systemctl: a release with this marker never gets
  # its stub launched, so verify_release fails for it specifically.
  touch "/srv/minecraft/releases/rel2/.force_fail"

  # A failed deploy still exits non-zero overall (rollback succeeded, but
  # the deploy itself did not) -- that's deploy.sh's actual contract, not
  # a fixture bug, so don't treat it as this test failing.
  DEPLOY_EMPTY_GRACE_SECONDS=1 VERIFY_PING_ATTEMPTS=2 /opt/minecraft/bin/deploy.sh || true

  assert_eq "ROLLED_BACK" "$(cat /srv/minecraft/state/deploy-state)" "(deploy-state)" || return 1
  assert_eq "rel1" "$(readlink -f /srv/minecraft/current | xargs basename)" "(current symlink after rollback)" || return 1
  systemctl is-active --quiet minecraft.service || {
    echo "  ASSERT FAILED: expected minecraft.service active again on rel1 after rollback" >&2
    return 1
  }
}

test_rollback_without_previous_release_fails_hard() {
  reset_environment
  prepare_release "rel1" || return 1
  touch "/srv/minecraft/releases/rel1/.force_fail"

  # First-ever deploy: there is no previous-release to roll back to.
  # rollback_release's own fail() call exits the whole script right at
  # that check, before it would ever reach the CRITICAL_FAILURE branch
  # (which is specifically for "rolling back also failed verification",
  # a different failure mode) -- so deploy-state stays at ROLLBACK, not
  # CRITICAL_FAILURE. The one thing that must hold regardless is that
  # this fails hard rather than silently succeeding or hanging.
  if DEPLOY_EMPTY_GRACE_SECONDS=1 VERIFY_PING_ATTEMPTS=2 /opt/minecraft/bin/deploy.sh; then
    echo "  ASSERT FAILED: expected deploy.sh to exit non-zero with no previous release to roll back to" >&2
    return 1
  fi
  assert_eq "ROLLBACK" "$(cat /srv/minecraft/state/deploy-state)" "(deploy-state)" || return 1
}

test_release_without_onlysleep_enable_evidence_rolls_back() {
  reset_environment
  prepare_release "rel1" || return 1
  /opt/minecraft/bin/deploy.sh || return 1

  prepare_release "rel2" || return 1
  touch "/srv/minecraft/releases/rel2/.omit_onlysleep_enable_log"
  DEPLOY_EMPTY_GRACE_SECONDS=1 /opt/minecraft/bin/deploy.sh \
    >/tmp/deploy-missing-onlysleep-enable.log 2>&1 || true

  assert_eq "ROLLED_BACK" "$(cat /srv/minecraft/state/deploy-state)" \
    "(deploy state when Onlysleep did not enable)" || return 1
  assert_eq "rel1" "$(readlink -f /srv/minecraft/current | xargs basename)" \
    "(current release after Onlysleep load failure)" || return 1
  assert_contains "$(cat /tmp/deploy-missing-onlysleep-enable.log)" \
    "Onlysleep load evidence was not found" "(failure is recorded in the deploy log)" || return 1
}

reset_environment
run_test "a release that fails verification rolls back to the previous one" test_failed_release_rolls_back
run_test "a first deploy with no previous release fails hard, not silently or by hanging" test_rollback_without_previous_release_fails_hard
run_test "a release without Onlysleep load evidence rolls back" test_release_without_onlysleep_enable_evidence_rolls_back
report_and_exit
