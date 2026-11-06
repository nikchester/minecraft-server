#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

REASON=${1:-scheduled}
# systemd units run without $HOME set, which makes restic warn on every
# invocation ("unable to locate cache directory") and skip its local
# metadata cache entirely.
export HOME=${HOME:-/root}
export RCLONE_CONFIG=${RCLONE_CONFIG:-/etc/minecraft/secrets/rclone.conf}
RCLONE_REMOTE=${RCLONE_REMOTE:-$(rclone_remote_name)}
RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-rclone:${RCLONE_REMOTE:-yandex}:minecraft-restic}
export RESTIC_REPOSITORY
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-/etc/minecraft/secrets/restic_password}
HEALTHCHECKS_BACKUP_URL_FILE=${HEALTHCHECKS_BACKUP_URL_FILE:-/etc/minecraft/secrets/healthchecks_backup_url}

send_hc() {
  local suffix=${1:-}
  if [[ -r "$HEALTHCHECKS_BACKUP_URL_FILE" ]]; then
    # Strip stray whitespace (e.g. a leading space from a copy-paste into
    # the GitHub secret) -- curl rejects a URL containing any outright.
    curl -fsS "$(tr -d '[:space:]' <"$HEALTHCHECKS_BACKUP_URL_FILE")${suffix}" >/dev/null || true
  fi
}

run_backup() {
  ensure_state_dir
  send_hc "/start"
  # Healthchecks.io only gets a silent ping here; without a direct alert, a
  # single failed run is invisible in Telegram unless backups keep failing
  # for a full day (healthcheck.sh's own 24h staleness check is the only
  # other thing watching this).
  FAILURE_HINT=""
  trap 'send_hc "/fail"; telegram_alert critical "backup (${REASON}) failed${FAILURE_HINT}"' ERR
  log "starting ${REASON} backup"
  # restic (>= 0.17) exits 10 only when the repository genuinely does not
  # exist yet. Any other failure -- an expired Google Drive OAuth token, a
  # network outage, a wrong password -- must fail the backup as-is: treating
  # it as "not initialized" (as this used to) logged a misleading message and
  # buried the real cause under a doomed restic init (issue #80).
  local probe_output probe_status=0
  probe_output=$(restic cat config 2>&1 >/dev/null) || probe_status=$?
  if [[ "$probe_status" -eq 10 ]]; then
    log "restic repository not initialized yet; initializing"
    restic init
  elif [[ "$probe_status" -ne 0 ]]; then
    printf '%s\n' "$probe_output" >&2
    if [[ "$probe_output" == *invalid_grant* ]]; then
      # Google revoked or expired the rclone refresh token. Retrying cannot
      # help; only re-authorizing the remote does (docs/BACKUP_RESTORE.md).
      FAILURE_HINT=": Google Drive OAuth token expired or revoked (invalid_grant); re-authorize rclone, see docs/BACKUP_RESTORE.md"
    else
      FAILURE_HINT=": restic repository is unreachable (exit ${probe_status})"
    fi
    log "restic repository check failed${FAILURE_HINT}"
    # Not "return 1": a plain failing command is what fires the ERR trap.
    false
  fi
  # A prior backup killed mid-run (VPS reboot, OOM, manual intervention)
  # leaves its repository lock behind; restic unlock only clears locks
  # whose owning process is confirmed gone, so this is safe to run every time.
  restic unlock || true
  if systemctl is-active --quiet minecraft.service; then
    # Not "|| fail ...": fail() exits directly, which bypasses the ERR
    # trap above entirely (an explicit exit is not a failing command as
    # far as the trap is concerned) -- letting this fail naturally under
    # set -e is what actually fires the trap's Healthchecks/Telegram alert.
    "$SCRIPT_DIR/rcon-command.py" "save-all flush"
  fi
  # World data, whitelist/ban/op lists, and plugin data (AuthMe accounts,
  # CoreProtect logs) all live under MINECRAFT_SHARED_DIR and are symlinked
  # into the active release by prepare-release.sh, so backing up this one
  # tree covers everything that must survive a restore.
  timeout "${RESTIC_TIMEOUT_SECONDS:-900}" restic backup \
    "$MINECRAFT_ROOT/shared" \
    --tag "minecraft" \
    --tag "$REASON"
  # Only the regular cadence prunes old snapshots. A pre-deploy/pre-restore
  # backup is a one-off protective snapshot taken seconds before some other
  # operation -- running forget/prune here risks evicting whatever snapshot
  # that operation actually needed. This is exactly what happened testing
  # the restore path: a pre-restore backup landed in the same daily bucket
  # as the snapshot being restored, "keep-daily 30" only keeps the newest
  # per day, and forget/prune deleted the very snapshot restore.sh was
  # about to use, failing the restore after the server was already stopped.
  if [[ "$REASON" == "scheduled" ]]; then
    timeout "${RESTIC_TIMEOUT_SECONDS:-900}" restic forget --keep-within-daily 7d --keep-daily 30 --keep-monthly 6 --prune
  fi
  touch "$MINECRAFT_STATE_DIR/last-backup-success"
  send_hc
  trap - ERR
  log "backup completed"
}

with_global_lock run_backup
