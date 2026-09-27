#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

wait_for_state() {
  local expected=$1 attempts=${2:-200} attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if [[ "$(cat /srv/minecraft/state/deploy-state 2>/dev/null || true)" == "$expected" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "  ASSERT FAILED: deploy state did not become ${expected}" >&2
  return 1
}

wait_for_target_and_waiting_state() {
  local expected=$1 attempts=${2:-400} attempt
  for ((attempt = 0; attempt < attempts; attempt++)); do
    if [[ "$(cat /srv/minecraft/state/target-release 2>/dev/null || true)" == "$expected" ]] \
      && [[ "$(cat /srv/minecraft/state/deploy-state 2>/dev/null || true)" == "WAITING_FOR_EMPTY_SERVER" ]]; then
      return 0
    fi
    sleep 0.05
  done
  echo "  ASSERT FAILED: release ${expected} did not reach player wait" >&2
  return 1
}

wait_for_process() {
  local pid=$1 log_file=$2
  if ! wait "$pid"; then
    echo "  ASSERT FAILED: deployment request failed" >&2
    cat "$log_file" >&2
    return 1
  fi
}

test_safe_deploy_request_handoff() {
  reset_environment
  prepare_release "rel1" || return 1
  DEPLOY_RESTART_COUNTDOWN_SECONDS=0 /opt/minecraft/bin/deploy.sh || return 1

  # A newer request should supersede an older deployment that is waiting on
  # players, then prepare and deploy only the newest release.
  printf '1\n' >/tmp/minecraft-stub-online
  prepare_release "rel2" || return 1
  DEPLOY_PLAYER_POLL_SECONDS=1 systemctl start --no-block minecraft-deploy.service || return 1
  wait_for_state WAITING_FOR_EMPTY_SERVER || return 1
  systemctl start minecraft-deploy.timer || return 1

  DEPLOY_RELEASE_ID=rel3 \
    DEPLOY_HANDOFF_POLL_SECONDS=1 \
    DEPLOY_REQUEST_POLL_SECONDS=1 \
    DEPLOY_REQUEST_TIMEOUT_SECONDS=30 \
    DEPLOY_PLAYER_POLL_SECONDS=1 \
    DEPLOY_RESTART_COUNTDOWN_SECONDS=0 \
    /opt/test/repo/scripts/deploy-request.sh >/tmp/deploy-request-pending.log 2>&1 &
  local request_pid=$!
  if ! wait_for_target_and_waiting_state rel3; then
    kill "$request_pid" 2>/dev/null || true
    wait "$request_pid" 2>/dev/null || true
    cat /tmp/deploy-request-pending.log >&2
    return 1
  fi
  printf '0\n' >/tmp/minecraft-stub-online
  if ! wait_for_process "$request_pid" /tmp/deploy-request-pending.log; then
    return 1
  fi
  assert_eq "rel3" "$(cat /srv/minecraft/state/current-release)" "(newest waiting request deployed)" || return 1
  assert_eq "rel3" "$(cat /srv/minecraft/state/target-release)" "(superseded target replaced)" || return 1
  assert_eq "SUCCESS" "$(cat /srv/minecraft/state/deploy-state)" "(newest request succeeded)" || return 1
  assert_file_exists /tmp/minecraft-deploy-timer.state || return 1
  assert_eq "active" "$(cat /tmp/minecraft-deploy-timer.state)" "(previously active deploy timer restored)" || return 1
  if [[ -e /srv/minecraft/state/deploy-supersede-request ]]; then
    echo "  ASSERT FAILED: supersede marker was left behind" >&2
    return 1
  fi

  # Once the old controller is already taking its pre-deploy backup, a new
  # request must wait for it to finish rather than marking it for cancellation.
  prepare_release "rel4" || return 1
  : >/tmp/restic-hold
  rm -f /tmp/restic-release
  DEPLOY_RESTART_COUNTDOWN_SECONDS=0 systemctl start --no-block minecraft-deploy.service || return 1
  wait_for_state BACKUP || return 1

  DEPLOY_RELEASE_ID=rel5 \
    DEPLOY_HANDOFF_POLL_SECONDS=1 \
    DEPLOY_REQUEST_POLL_SECONDS=1 \
    DEPLOY_REQUEST_TIMEOUT_SECONDS=45 \
    DEPLOY_RESTART_COUNTDOWN_SECONDS=0 \
    /opt/test/repo/scripts/deploy-request.sh >/tmp/deploy-request-critical.log 2>&1 &
  request_pid=$!
  sleep 1
  assert_eq "rel4" "$(cat /srv/minecraft/state/target-release)" "(critical deployment target unchanged while waiting)" || return 1
  if [[ -e /srv/minecraft/state/deploy-supersede-request ]]; then
    echo "  ASSERT FAILED: critical deployment was marked for cancellation" >&2
    touch /tmp/restic-release
    return 1
  fi
  touch /tmp/restic-release
  if ! wait_for_process "$request_pid" /tmp/deploy-request-critical.log; then
    return 1
  fi
  rm -f /tmp/restic-hold /tmp/restic-release
  assert_eq "rel5" "$(cat /srv/minecraft/state/current-release)" "(queued request ran after critical deploy)" || return 1
  assert_eq "SUCCESS" "$(cat /srv/minecraft/state/deploy-state)" "(queued request succeeded)" || return 1

  # The same serialized request path also covers the force-deploy unit.
  printf '1\n' >/tmp/minecraft-stub-online
  DEPLOY_RELEASE_ID=rel6 \
    DEPLOY_REQUEST_POLL_SECONDS=1 \
    DEPLOY_REQUEST_TIMEOUT_SECONDS=30 \
    DEPLOY_RESTART_COUNTDOWN_SECONDS=0 \
    /opt/test/repo/scripts/deploy-request.sh --force >/tmp/deploy-request-force.log 2>&1 || {
      cat /tmp/deploy-request-force.log >&2
      return 1
    }
  assert_eq "rel6" "$(cat /srv/minecraft/state/current-release)" "(force request deployed)" || return 1
  assert_eq "SUCCESS" "$(cat /srv/minecraft/state/deploy-state)" "(force request succeeded)" || return 1
  assert_contains "$(cat /tmp/minecraft-stub-rcon.log)" \
    "say Внимание: запущено принудительное обновление." "(force request used force controller)" || return 1
}

test_long_pending_request_is_accepted_without_claiming_completion() {
  reset_environment
  prepare_release rel1 || return 1
  DEPLOY_RESTART_COUNTDOWN_SECONDS=0 /opt/minecraft/bin/deploy.sh || return 1
  printf '1\n' >/tmp/minecraft-stub-online
  DEPLOY_RELEASE_ID=rel2 DEPLOY_PLAYER_POLL_SECONDS=1 \
    DEPLOY_REQUEST_TIMEOUT_SECONDS=2 DEPLOY_REQUEST_POLL_SECONDS=1 \
    DEPLOY_RESTART_COUNTDOWN_SECONDS=0 \
    /opt/test/repo/scripts/deploy-request.sh >/tmp/deploy-request-timeout.log 2>&1 || {
      cat /tmp/deploy-request-timeout.log >&2
      return 1
    }
  assert_eq rel1 "$(cat /srv/minecraft/state/current-release)" '(request accepted; not yet deployed)' || return 1
  assert_contains "$(cat /tmp/deploy-request-timeout.log)" 'deployment is still pending' || return 1
  printf '0\n' >/tmp/minecraft-stub-online
  local attempt
  for ((attempt=0; attempt<150; attempt++)); do
    [[ "$(cat /srv/minecraft/state/current-release 2>/dev/null || true)" == rel2 ]] && break
    sleep 0.1
  done
  assert_eq rel2 "$(cat /srv/minecraft/state/current-release)" '(controller finishes after CI returns)' || return 1
}

reset_environment
run_test "deployment requests supersede only safe pending work" test_safe_deploy_request_handoff
run_test "long player wait returns accepted while controller keeps running" test_long_pending_request_is_accepted_without_claiming_completion
report_and_exit
