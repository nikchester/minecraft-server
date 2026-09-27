#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FAILURES=0
WARNINGS=0
FAILURE_DETAILS=()
HOST=${MINECRAFT_HEALTH_HOST:-127.0.0.1}
PORT=${MINECRAFT_HEALTH_PORT:-25565}
DISK_WARNING=${MINECRAFT_DISK_WARNING_PERCENT:-80}
DISK_CRITICAL=${MINECRAFT_DISK_CRITICAL_PERCENT:-90}
BACKUP_MAX_AGE_SECONDS=${BACKUP_MAX_AGE_SECONDS:-86400}

check_service() {
  if ! systemctl is-active --quiet minecraft.service; then
    log "minecraft.service is not active"
    FAILURES=$((FAILURES + 1))
    FAILURE_DETAILS+=("minecraft.service inactive")
  fi
}

check_ping() {
  if ! "$SCRIPT_DIR/minecraft-status.py" "$HOST" "$PORT" >/tmp/minecraft-status.json; then
    log "Minecraft protocol ping failed"
    FAILURES=$((FAILURES + 1))
    FAILURE_DETAILS+=("Minecraft protocol ping failed")
  fi
}

check_disk() {
  local usage
  usage=$(df -P "$MINECRAFT_ROOT" | awk 'NR==2 { gsub("%", "", $5); print $5 }')
  if [[ "$usage" -ge "$DISK_CRITICAL" ]]; then
    telegram_alert critical "disk usage critical: ${usage}%"
    FAILURES=$((FAILURES + 1))
    FAILURE_DETAILS+=("disk usage ${usage}%")
  elif [[ "$usage" -ge "$DISK_WARNING" ]]; then
    telegram_alert warning "disk usage warning: ${usage}%"
    WARNINGS=$((WARNINGS + 1))
  fi
}

check_backup_age() {
  local stamp="$MINECRAFT_STATE_DIR/last-backup-success"
  if [[ ! -f "$stamp" ]]; then
    telegram_alert critical "no successful backup marker exists"
    FAILURES=$((FAILURES + 1))
    FAILURE_DETAILS+=("no successful backup marker")
    return
  fi
  local now last age
  now=$(date +%s)
  last=$(stat -c %Y "$stamp")
  age=$((now - last))
  if [[ "$age" -gt "$BACKUP_MAX_AGE_SECONDS" ]]; then
    telegram_alert critical "backup is stale: ${age}s old"
    FAILURES=$((FAILURES + 1))
    FAILURE_DETAILS+=("backup stale (${age}s)")
  fi
}

check_memory() {
  local available_kb
  available_kb=$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo)
  if [[ "$available_kb" -lt 262144 ]]; then
    telegram_alert warning "MemAvailable is below 256 MiB"
    WARNINGS=$((WARNINGS + 1))
  fi
}

# A controller in the middle of a release intentionally stops/restarts Paper.
# Skip only availability checks while it is actually running; disk, backup and
# memory checks remain active, and a failed/stopped controller is not masked.
controller_running() {
  local state
  state=$(systemctl show -p ActiveState --value "$1" 2>/dev/null || true)
  [[ "$state" == active || "$state" == activating || "$state" == reloading ]]
}
deploy_state=$(cat "$MINECRAFT_STATE_DIR/deploy-state" 2>/dev/null || true)
if [[ "$deploy_state" == BACKUP || "$deploy_state" == DEPLOYING \
    || "$deploy_state" == VERIFYING || "$deploy_state" == ROLLBACK \
    || "$deploy_state" == VERIFY_ROLLBACK ]] \
  && { controller_running minecraft-deploy.service \
    || controller_running minecraft-deploy-force.service; }; then
  log "deployment active; deferring Minecraft availability checks"
else
  check_service
  check_ping
fi
check_disk
check_backup_age
check_memory

if [[ "$FAILURES" -gt 0 ]]; then
  details=$(IFS='; '; printf '%s' "${FAILURE_DETAILS[*]}")
  telegram_alert critical "healthcheck failed with ${FAILURES} failures and ${WARNINGS} warnings: ${details}"
  exit 1
fi

log "healthcheck passed with ${WARNINGS} warnings"
