#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
elif [[ $# -gt 0 ]]; then
  printf 'usage: %s [--force]\n' "$0" >&2
  exit 2
fi

REPO_DIR=${MINECRAFT_REPO_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}
SYSTEMD_UNIT_DIR=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
REQUEST_LOCK_FILE=${DEPLOY_REQUEST_LOCK_FILE:-$MINECRAFT_STATE_DIR/deploy-request.lock}
HANDOFF_TIMEOUT=${DEPLOY_HANDOFF_TIMEOUT_SECONDS:-3600}
HANDOFF_POLL=${DEPLOY_HANDOFF_POLL_SECONDS:-5}
REQUEST_TIMEOUT=${DEPLOY_REQUEST_TIMEOUT_SECONDS:-600}
REQUEST_POLL=${DEPLOY_REQUEST_POLL_SECONDS:-5}
NORMAL_UNIT=minecraft-deploy.service
FORCE_UNIT=minecraft-deploy-force.service
TIMER_UNIT=minecraft-deploy.timer
SUPERSEDE_FILE=$MINECRAFT_STATE_DIR/deploy-supersede-request

ensure_state_dir
exec 9>"$REQUEST_LOCK_FILE"
if ! flock -w "${DEPLOY_REQUEST_LOCK_TIMEOUT_SECONDS:-21600}" 9; then
  fail "another deployment request did not finish acquiring the request lock"
fi

timer_was_active=false
if systemctl is-active --quiet "$TIMER_UNIT"; then
  timer_was_active=true
  systemctl stop "$TIMER_UNIT"
fi

handoff_superseded=false
new_service_started=false
restore_timer() {
  local status=$?
  trap - EXIT
  if [[ "$handoff_superseded" == "true" && "$new_service_started" != "true" ]] \
    && [[ "$(cat "$MINECRAFT_STATE_DIR/deploy-state" 2>/dev/null || true)" == "SUPERSEDED" ]]; then
    local current_release
    current_release=$(cat "$MINECRAFT_STATE_DIR/current-release" 2>/dev/null || true)
    if [[ -n "$current_release" ]]; then
      printf '%s\n' "$current_release" >"$MINECRAFT_STATE_DIR/target-release"
    fi
  fi
  if [[ "$timer_was_active" == "true" ]]; then
    systemctl start "$TIMER_UNIT" || log "could not restore $TIMER_UNIT"
  fi
  if [[ "${DEPLOY_REQUEST_CLEANUP_REPO:-false}" == "true" ]]; then
    rm -rf -- "$REPO_DIR"
  fi
  exit "$status"
}
trap restore_timer EXIT

active_controller() {
  local unit state
  for unit in "$NORMAL_UNIT" "$FORCE_UNIT"; do
    state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)
    case "$state" in
      active|activating|reloading)
        printf '%s\n' "$unit"
        return 0
        ;;
    esac
  done
  return 1
}

wait_for_controller_handoff() {
  local started now unit state
  started=$(date +%s)
  while unit=$(active_controller); do
    state=$(cat "$MINECRAFT_STATE_DIR/deploy-state" 2>/dev/null || true)
    case "$state" in
      WAITING_FOR_EMPTY_SERVER|EMPTY_GRACE_PERIOD)
        if [[ "$handoff_superseded" != "true" ]]; then
          : >"$SUPERSEDE_FILE"
          handoff_superseded=true
          log "requested cooperative cancellation of pending deployment ($unit, state $state)"
        fi
        ;;
    esac

    now=$(date +%s)
    if [[ $((now - started)) -ge "$HANDOFF_TIMEOUT" ]]; then
      fail "timed out waiting for the active deployment to reach a safe handoff point (unit=$unit state=$state)"
    fi
    sleep "$HANDOFF_POLL"
  done

  if [[ "$(cat "$MINECRAFT_STATE_DIR/deploy-state" 2>/dev/null || true)" == "SUPERSEDED" ]]; then
    handoff_superseded=true
  fi
  rm -f "$SUPERSEDE_FILE"
}

wait_for_controller_handoff

install_staged_secrets() {
  local source_dir=${DEPLOY_SECRETS_DIR:-$REPO_DIR/.secrets}
  local secret_name
  [[ -d "$source_dir" ]] || return 0
  install -d -m 0700 /etc/minecraft/secrets
  for secret_name in \
    rcon_password \
    management_server_secret \
    authme_mysql_password \
    restic_password \
    telegram_bot_token \
    telegram_chat_id \
    discord_bot_token \
    healthchecks_backup_url \
    healthchecks_vps_url \
    rclone.conf; do
    [[ -f "$source_dir/$secret_name" ]] || fail "staged deployment secret is missing: $secret_name"
    install -m 0600 "$source_dir/$secret_name" "/etc/minecraft/secrets/$secret_name"
  done
}

install_staged_secrets

for script in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/scripts/*.py; do
  [[ -f "$script" ]] || continue
  install -m 0755 "$script" "$MINECRAFT_BIN_DIR/$(basename "$script")"
done
install -m 0644 "$REPO_DIR"/systemd/*.service "$SYSTEMD_UNIT_DIR/"
install -m 0644 "$REPO_DIR"/systemd/*.timer "$SYSTEMD_UNIT_DIR/"
systemctl daemon-reload

if [[ -n "${DEPLOY_RELEASE_ID:-}" ]]; then
  (cd "$REPO_DIR" && "$MINECRAFT_BIN_DIR/prepare-release.sh" "$DEPLOY_RELEASE_ID")
else
  (cd "$REPO_DIR" && "$MINECRAFT_BIN_DIR/prepare-release.sh")
fi

unit=$NORMAL_UNIT
if [[ "$FORCE" == "true" ]]; then
  unit=$FORCE_UNIT
fi
# A previous deployment may have left SUCCESS in deploy-state. Clear it before
# starting the new controller so the first status poll cannot mistake that
# stale result for completion of this request.
printf '%s\n' REQUESTED >"$MINECRAFT_STATE_DIR/deploy-state"
systemctl start --no-block "$unit"
new_service_started=true
if [[ "$timer_was_active" == "true" ]]; then
  systemctl start "$TIMER_UNIT"
  timer_was_active=false
fi

# Serialize preparation and service start, but don't hold the request lock for
# the whole player-wait/deploy lifecycle. A later request must be able to
# supersede this controller while it is still waiting for an empty server.
flock -u 9
exec 9>&-

request_started=$(date +%s)
observed_running=false
while true; do
  service_state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || true)
  deploy_state=$(cat "$MINECRAFT_STATE_DIR/deploy-state" 2>/dev/null || true)
  case "$service_state" in
    active|activating|reloading) observed_running=true ;;
  esac
  if [[ "$service_state" == "inactive" && "$deploy_state" == "SUCCESS" ]] \
    && [[ "$(cat "$MINECRAFT_STATE_DIR/current-release" 2>/dev/null || true)" == "$(cat "$MINECRAFT_STATE_DIR/target-release" 2>/dev/null || true)" ]]; then
    systemctl status "$unit" --no-pager || true
    exit 0
  fi
  if [[ "$service_state" == "inactive" && "$deploy_state" == "SUPERSEDED" ]]; then
    log "$unit was superseded by a newer deployment request"
    exit 0
  fi
  if [[ "$service_state" == "failed" ]]; then
    journalctl -u "$unit" -n 200 --no-pager || true
    fail "$unit failed (deploy state: ${deploy_state:-unknown})"
  fi
  if [[ "$service_state" == "inactive" && "$observed_running" == "true" ]]; then
    journalctl -u "$unit" -n 200 --no-pager || true
    fail "$unit stopped without a successful deployment (deploy state: ${deploy_state:-unknown})"
  fi
  now=$(date +%s)
  if [[ $((now - request_started)) -ge "$REQUEST_TIMEOUT" ]]; then
    if [[ "$service_state" == "active" || "$service_state" == "activating" || "$service_state" == "reloading" ]]; then
      log "deployment is still pending ($unit, state: ${deploy_state:-unknown}); check the service and deploy-state for its final result"
      # The request was accepted and the controller is still running. Its
      # completion cannot be reported as a failure merely because players
      # remain online (or backup / startup takes longer than the CI wait).
      exit 0
    fi
    fail "deployment did not complete (unit=$unit service=$service_state state=${deploy_state:-unknown})"
  fi
  sleep "$REQUEST_POLL"
done
