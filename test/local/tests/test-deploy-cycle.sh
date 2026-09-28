#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

test_first_deploy_succeeds() {
  reset_environment
  prepare_release "rel1" || return 1
  assert_contains "$(cat /srv/minecraft/releases/rel1/server.properties)" \
    "rcon.password=test-rcon-password" "(rendered from repository template)" || return 1
  assert_file_exists /srv/minecraft/releases/rel1/config/paper-global.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/AuthMe/config.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/Chunky/config.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/CoreProtect/config.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/DynamicLights/config.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/Onlysleep/config.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/Onlysleep/messages.yml || return 1
  assert_file_exists /srv/minecraft/shared/plugins/bStats/config.yml || return 1
  assert_contains "$(cat /srv/minecraft/shared/plugins/Onlysleep/config.yml)" \
    "sleep-percentage: 50" "(Onlysleep sleep threshold)" || return 1
  assert_contains "$(cat /srv/minecraft/shared/plugins/bStats/config.yml)" \
    "enabled: false" "(bStats opt-out)" || return 1
  assert_contains "$(cat /srv/minecraft/shared/plugins/AuthMe/config.yml)" \
    "mySQLPassword: 'test-authme-mysql-password'" "(rendered plugin secret)" || return 1
  if grep -R -q '{{[A-Z][A-Z0-9_]*}}' /srv/minecraft/releases/rel1/config /srv/minecraft/shared/plugins; then
    echo "  ASSERT FAILED: unreplaced template marker in runtime configs" >&2
    return 1
  fi
  if grep -q '{{[A-Z][A-Z0-9_]*}}' /srv/minecraft/releases/rel1/server.properties; then
    echo "  ASSERT FAILED: unreplaced template marker in runtime server.properties" >&2
    return 1
  fi
  /opt/minecraft/bin/deploy.sh || return 1
  assert_eq "SUCCESS" "$(cat /srv/minecraft/state/deploy-state)" "(deploy-state)" || return 1
  assert_eq "rel1" "$(cat /srv/minecraft/state/current-release)" "(current-release)" || return 1
  assert_eq "rel1" "$(readlink -f /srv/minecraft/current | xargs basename)" "(current symlink target)" || return 1
  assert_file_exists /srv/minecraft/shared/whitelist.json || return 1
  systemctl is-active --quiet minecraft.service || {
    echo "  ASSERT FAILED: expected minecraft.service to be active after a successful deploy" >&2
    return 1
  }
}

test_repeat_deploy_is_noop() {
  # Assumes test_first_deploy_succeeds already ran and left rel1 deployed;
  # run_test calls each function independently, so re-derive that state.
  reset_environment
  prepare_release "rel1" || return 1
  /opt/minecraft/bin/deploy.sh || return 1
  local before after
  before=$(cat /srv/minecraft/state/last-backup-success 2>/dev/null || echo missing)
  # A second run with the same target must not re-run backup/restart the
  # service -- that's the exact bug fixed for the retention work (the
  # timer fires this every minute forever otherwise).
  /opt/minecraft/bin/deploy.sh || return 1
  after=$(cat /srv/minecraft/state/last-backup-success 2>/dev/null || echo missing)
  assert_eq "$before" "$after" "(backup marker must be untouched on a no-op deploy)" || return 1
}

test_second_release_prunes_and_updates_previous() {
  reset_environment
  prepare_release "rel1" || return 1
  /opt/minecraft/bin/deploy.sh || return 1
  prepare_release "rel2" || return 1
  DEPLOY_EMPTY_GRACE_SECONDS=1 /opt/minecraft/bin/deploy.sh || return 1
  assert_eq "rel2" "$(cat /srv/minecraft/state/current-release)" "(current-release after 2nd deploy)" || return 1
  assert_eq "rel1" "$(cat /srv/minecraft/state/previous-release)" "(previous-release after 2nd deploy)" || return 1
}

test_transient_artifact_failures_are_retried() {
  reset_environment
  local attempts_file=/tmp/curl-paper-attempts
  rm -f "$attempts_file"
  CURL_SHIM_FAIL_FIRST_N=2 \
    CURL_SHIM_FAIL_URL_MATCH=fill-data.papermc.io \
    CURL_SHIM_FAILURE_MODE=network \
    CURL_SHIM_STATE_FILE="$attempts_file" \
    prepare_release "retry-success" || return 1

  assert_eq "3" "$(cat "$attempts_file")" \
    "(two transient failures should be retried, then the Paper artifact succeeds)" || return 1
  assert_file_exists /srv/minecraft/releases/retry-success/paper.jar || return 1
  if compgen -G '/srv/minecraft/releases/retry-success/paper.jar.part.*' >/dev/null; then
    echo "  ASSERT FAILED: temporary partial artifact was left behind" >&2
    return 1
  fi
}

test_permanent_http_failure_stops_release_preparation() {
  reset_environment
  local attempts_file=/tmp/curl-paper-attempts
  rm -f "$attempts_file"
  if CURL_SHIM_HTTP_STATUS=404 \
    CURL_SHIM_FAIL_URL_MATCH=fill-data.papermc.io \
    CURL_SHIM_STATE_FILE="$attempts_file" \
    prepare_release "retry-404" >/tmp/prepare-release-404.log 2>&1; then
    echo "  ASSERT FAILED: a permanent HTTP 404 must fail release preparation" >&2
    return 1
  fi

  assert_eq "1" "$(cat "$attempts_file")" "(HTTP 404 must not be retried)" || return 1
  if [[ -e /srv/minecraft/releases/retry-404/paper.jar \
    || -e /srv/minecraft/state/target-release ]]; then
    echo "  ASSERT FAILED: failed download must not produce a usable release" >&2
    return 1
  fi
  assert_contains "$(cat /tmp/prepare-release-404.log)" \
    "after 1/4 attempts (curl exit 0, HTTP 404)" "(permanent error diagnostic)" || return 1
}

test_transient_failure_exhaustion_stops_release_preparation() {
  reset_environment
  local attempts_file=/tmp/curl-paper-attempts
  rm -f "$attempts_file"
  if CURL_SHIM_FAIL_FIRST_N=4 \
    CURL_SHIM_FAIL_URL_MATCH=fill-data.papermc.io \
    CURL_SHIM_FAILURE_MODE=network \
    CURL_SHIM_STATE_FILE="$attempts_file" \
    prepare_release "retry-exhausted" >/tmp/prepare-release-exhausted.log 2>&1; then
    echo "  ASSERT FAILED: exhausted transient failures must stop release preparation" >&2
    return 1
  fi

  assert_eq "4" "$(cat "$attempts_file")" "(initial attempt plus three retries)" || return 1
  assert_contains "$(cat /tmp/prepare-release-exhausted.log)" \
    "after 4/4 attempts (curl exit 7, HTTP 000)" "(retry exhaustion diagnostic)" || return 1
  if [[ -e /srv/minecraft/releases/retry-exhausted/paper.jar \
    || -e /srv/minecraft/state/target-release ]]; then
    echo "  ASSERT FAILED: exhausted download must not produce a usable release" >&2
    return 1
  fi
}

reset_environment
run_test "first deploy reaches SUCCESS with the stub server" test_first_deploy_succeeds
run_test "repeat deploy of the same release is a no-op" test_repeat_deploy_is_noop
run_test "second release becomes current, first becomes previous" test_second_release_prunes_and_updates_previous
run_test "transient artifact failures are retried" test_transient_artifact_failures_are_retried
run_test "permanent HTTP failure stops release preparation without retry" test_permanent_http_failure_stops_release_preparation
run_test "exhausted artifact retries stop release preparation" test_transient_failure_exhaustion_stops_release_preparation
report_and_exit
