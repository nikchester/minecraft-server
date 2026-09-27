#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

test_availability_during_deploy() {
  reset_environment
  touch /srv/minecraft/state/last-backup-success
  printf 'activating\n' >/tmp/minecraft-deploy.state
  printf 'DEPLOYING\n' >/srv/minecraft/state/deploy-state
  /opt/minecraft/bin/healthcheck.sh || return 1
  printf 'WAITING_FOR_EMPTY_SERVER\n' >/srv/minecraft/state/deploy-state
  if /opt/minecraft/bin/healthcheck.sh >/tmp/healthcheck-waiting.log 2>&1; then
    echo '  ASSERT FAILED: player wait masked an unexpected server outage' >&2
    return 1
  fi
  printf 'DEPLOYING\n' >/srv/minecraft/state/deploy-state
  printf 'failed\n' >/tmp/minecraft-deploy.state
  if /opt/minecraft/bin/healthcheck.sh >/tmp/healthcheck-failed.log 2>&1; then
    echo '  ASSERT FAILED: a failed deploy controller masked a stopped server' >&2
    return 1
  fi
  assert_contains "$(cat /tmp/healthcheck-failed.log)" 'minecraft.service is not active' || return 1
  assert_contains "$(cat /tmp/healthcheck-failed.log)" 'Minecraft protocol ping failed' || return 1
}

test_backup_failure_remains_visible_during_deploy() {
  reset_environment
  printf 'activating\n' >/tmp/minecraft-deploy-force.state
  printf 'BACKUP\n' >/srv/minecraft/state/deploy-state
  rm -f /srv/minecraft/state/last-backup-success
  if /opt/minecraft/bin/healthcheck.sh >/tmp/healthcheck-backup.log 2>&1; then
    echo '  ASSERT FAILED: deployment masked a missing backup' >&2
    return 1
  fi
  assert_contains "$(cat /tmp/minecraft-stub-telegram.log)" 'no successful backup marker' || return 1
}

run_test 'deployment suppresses only temporary downtime, not stopped-controller failures' test_availability_during_deploy
run_test 'backup failures remain visible during forced deployment' test_backup_failure_remains_visible_during_deploy
report_and_exit
