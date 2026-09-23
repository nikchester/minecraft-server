#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FORCE=${FORCE_DEPLOY:-false}
GRACE_SECONDS=${DEPLOY_EMPTY_GRACE_SECONDS:-300}
PENDING_NOTICE_AFTER=${DEPLOY_PENDING_NOTICE_AFTER_SECONDS:-86400}

state_file() {
  printf '%s/deploy-state' "$MINECRAFT_STATE_DIR"
}

set_state() {
  ensure_state_dir
  printf '%s\n' "$1" >"$(state_file)"
  log "deployment state: $1"
}

wait_for_empty_server() {
  if [[ "$FORCE" == "true" ]]; then
    log "force deploy requested; skipping player wait"
    return
  fi
  if [[ ! -f "$MINECRAFT_STATE_DIR/current-release" ]] || ! systemctl is-active --quiet minecraft.service; then
    log "initial deployment or stopped server; no active players can be present"
    return
  fi
  set_state WAITING_FOR_EMPTY_SERVER
  local start now online
  start=$(date +%s)
  while true; do
    online=$("$SCRIPT_DIR/player-count.sh" 127.0.0.1 25565 || echo 999)
    if [[ "$online" -eq 0 ]]; then
      set_state EMPTY_GRACE_PERIOD
      sleep "$GRACE_SECONDS"
      online=$("$SCRIPT_DIR/player-count.sh" 127.0.0.1 25565 || echo 999)
      if [[ "$online" -eq 0 ]]; then
        return
      fi
      log "player joined during grace period; returning to wait"
    fi
    now=$(date +%s)
    if [[ $((now - start)) -gt "$PENDING_NOTICE_AFTER" ]]; then
      telegram_alert warning "deployment has been pending for more than 24 hours"
      if command -v mcrcon >/dev/null 2>&1; then
        true
      fi
      start=$now
    fi
    sleep 60
  done
}

verify_release() {
  # Called as `if verify_release; then ...`, which suspends set -e for
  # everything inside this function -- a command failing here does NOT
  # abort the function the way it would anywhere else in this script. Every
  # check below must therefore test its own result and `return 1` itself;
  # relying on set -e silently turns this into a no-op that always reports
  # success (which is exactly what happened: a status-ping timeout was
  # swallowed and the deploy was recorded as SUCCESS anyway).
  set_state VERIFYING
  systemctl start minecraft.service || return 1

  # First boot can take well over the old fixed 20s sleep (world
  # generation, plugin setup); poll instead of guessing a delay.
  local attempt
  for attempt in $(seq 1 "${VERIFY_PING_ATTEMPTS:-30}"); do
    if "$SCRIPT_DIR/minecraft-status.py" 127.0.0.1 25565 >/tmp/minecraft-deploy-status.json 2>/dev/null; then
      break
    fi
    if [[ "$attempt" -eq "${VERIFY_PING_ATTEMPTS:-30}" ]]; then
      log "minecraft protocol ping did not respond in time"
      return 1
    fi
    sleep 2
  done

  systemctl is-active --quiet minecraft.service || return 1

  if ! grep -Riq 'AuthMe' "$MINECRAFT_CURRENT_DIR/logs" 2>/dev/null; then
    log "AuthMe load evidence was not found in logs"
    return 1
  fi
}

rollback_release() {
  set_state ROLLBACK
  local previous
  previous=$(cat "$MINECRAFT_STATE_DIR/previous-release" 2>/dev/null || true)
  [[ -n "$previous" && -d "$MINECRAFT_ROOT/releases/$previous" ]] || fail "no previous release available"
  systemctl stop minecraft.service || true
  switch_current "$previous"
  set_state VERIFY_ROLLBACK
  if verify_release; then
    set_state ROLLED_BACK
    telegram_alert warning "deployment failed; rolled back to ${previous}"
  else
    set_state CRITICAL_FAILURE
    telegram_alert critical "deployment rollback failed"
    exit 1
  fi
}

prune_old_releases() {
  # Every deploy leaves a fresh ~150-250MB release directory behind and
  # nothing ever removes the old ones. current-release and previous-release
  # (needed for rollback) are always kept regardless of age; among the rest,
  # only the newest RELEASE_RETENTION_COUNT-minus-protected are kept.
  local keep_total=${RELEASE_RETENTION_COUNT:-5}
  local cur prev
  cur=$(cat "$MINECRAFT_STATE_DIR/target-release" 2>/dev/null || true)
  prev=$(cat "$MINECRAFT_STATE_DIR/previous-release" 2>/dev/null || true)
  local protected_count=0
  [[ -n "$cur" ]] && protected_count=$((protected_count + 1))
  [[ -n "$prev" && "$prev" != "$cur" ]] && protected_count=$((protected_count + 1))
  local extra_keep=$((keep_total - protected_count))
  [[ "$extra_keep" -lt 0 ]] && extra_keep=0
  local release kept=0
  while IFS= read -r release; do
    [[ -n "$release" ]] || continue
    if [[ "$release" == "$cur" || "$release" == "$prev" ]]; then
      continue
    fi
    if [[ "$kept" -lt "$extra_keep" ]]; then
      kept=$((kept + 1))
      continue
    fi
    rm -rf "$MINECRAFT_ROOT/releases/$release" || return 1
    log "pruned old release $release"
  done < <(find "$MINECRAFT_ROOT/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
}

switch_current() {
  local release_id=$1
  if [[ -d "$MINECRAFT_CURRENT_DIR" && ! -L "$MINECRAFT_CURRENT_DIR" ]]; then
    # Provisioning creates "current" as a real directory (with a rendered
    # server.properties) before the first release exists. Once a release is
    # ready, that placeholder is superseded entirely by the release's own
    # copy, so it is safe to remove outright rather than requiring it empty.
    rm -rf "$MINECRAFT_CURRENT_DIR" || fail "failed to remove existing current runtime directory"
  fi
  ln -sfnT "$MINECRAFT_ROOT/releases/$release_id" "$MINECRAFT_CURRENT_DIR"
}

run_deploy() {
  ensure_state_dir
  # Idempotent and cheap (a handful of stat/grep checks once already set
  # up); running it on every tick means swap self-heals if it's ever lost
  # (VPS migration, disk cleanup, a rebuilt host) without waiting for
  # someone to notice or re-run the full provisioning playbook.
  "$SCRIPT_DIR/ensure-swap.sh"
  # Same idempotent self-heal approach: DynamicLights regenerates its own
  # config with track_mobs back to its default (true) if the key ever goes
  # missing, so this forces it back to false on every tick instead of
  # waiting for someone to notice mobs are glowing.
  "$SCRIPT_DIR/ensure-dynamiclights-config.sh"
  # Same idempotent self-heal approach: AuthMe's own config.yml can drift
  # back to its short default registration/login timeout and per-IP
  # registration cap (e.g. a plugin update or reinstall regenerating
  # defaults) after being tuned by hand on the VPS, so this forces the
  # tuned values back on every tick instead of waiting for a player to
  # report they got kicked mid-registration.
  "$SCRIPT_DIR/ensure-authme-config.sh"
  # Same idempotent self-heal approach: DiscordSRV writes its own
  # config.yml/voice.yml with generated defaults (a "BOTTOKEN" placeholder,
  # an empty chat bridge, no voice category/lobby channel, voice disabled)
  # on first run, and a plugin update or hand-edit could revert any of them,
  # so this renders the real token, channels, and voice settings in on
  # every tick instead of leaving the bot silently offline or unconfigured.
  "$SCRIPT_DIR/ensure-discordsrv-config.sh"
  # minecraft-deploy.timer fires this unconditionally every minute. Without
  # this check, once a target release exists it would re-run a full backup
  # and bounce minecraft.service (kicking every connected player) forever,
  # even long after that release was already deployed successfully.
  if [[ -f "$MINECRAFT_STATE_DIR/target-release" && -f "$MINECRAFT_STATE_DIR/current-release" ]] \
    && [[ "$(cat "$MINECRAFT_STATE_DIR/target-release")" == "$(cat "$MINECRAFT_STATE_DIR/current-release")" ]]; then
    log "target release already deployed; nothing to do"
    return
  fi
  set_state PENDING
  wait_for_empty_server
  set_state BACKUP
  "$SCRIPT_DIR/backup.sh" pre-deploy
  set_state DEPLOYING
  systemctl stop minecraft.service || true
  # Release preparation is intentionally separate; this controller verifies and switches prepared releases.
  if [[ -f "$MINECRAFT_STATE_DIR/target-release" ]]; then
    target=$(cat "$MINECRAFT_STATE_DIR/target-release")
    [[ -d "$MINECRAFT_ROOT/releases/$target" ]] || fail "target release missing: $target"
    readlink -f "$MINECRAFT_CURRENT_DIR" | xargs -r basename >"$MINECRAFT_STATE_DIR/previous-release"
    switch_current "$target"
  fi
  # Seed DiscordSRV's complete embedded defaults and heal its project-specific
  # settings while the server is stopped, before its first plugin load. This
  # also avoids editing its persistent config files while players are online.
  DISCORDSRV_BOOTSTRAP_DEFAULTS=true "$SCRIPT_DIR/ensure-discordsrv-config.sh"
  if verify_release; then
    if [[ -f "$MINECRAFT_STATE_DIR/target-release" ]]; then
      # Pruning runs before current-release is written: if it fails (e.g.
      # disk full, permission issue), current-release stays at its old
      # value, so the timer's idempotency check sees target != current and
      # keeps retrying the whole deploy on the next tick instead of quietly
      # settling into a "done" state with the disk problem unresolved.
      prune_old_releases || fail "failed to prune old releases; deploy not finalized"
      cp "$MINECRAFT_STATE_DIR/target-release" "$MINECRAFT_STATE_DIR/current-release"
    fi
    set_state SUCCESS
    telegram_alert info "deployment succeeded"
  else
    rollback_release
  fi
}

with_global_lock run_deploy
