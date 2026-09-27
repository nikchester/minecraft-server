#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

test_normal_and_force_deploy_notices() {
  reset_environment
  prepare_release "rel1" || return 1
  /opt/minecraft/bin/deploy.sh || return 1

  # Keep a player online until the normal deploy has announced that it is
  # waiting, then log them out so the deploy can proceed through its grace.
  printf '1\n' >/tmp/minecraft-stub-online
  prepare_release "rel2" || return 1
  DEPLOY_PLAYER_POLL_SECONDS=1 DEPLOY_PENDING_NOTICE_INTERVAL_SECONDS=3 DEPLOY_RESTART_COUNTDOWN_SECONDS=2 \
    /opt/minecraft/bin/deploy.sh >/tmp/deploy-notice-test.log 2>&1 &
  local deploy_pid=$!
  local attempt=0
  while ((attempt < 50)); do
    attempt=$((attempt + 1))
    if grep -Fq 'say Скоро будет обновление.' /tmp/minecraft-stub-rcon.log 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if ! grep -Fq 'say Скоро будет обновление.' /tmp/minecraft-stub-rcon.log 2>/dev/null; then
    echo "  ASSERT FAILED: normal deploy did not announce that it is waiting for players" >&2
    cat /tmp/deploy-notice-test.log >&2
    kill "$deploy_pid" 2>/dev/null || true
    wait "$deploy_pid" 2>/dev/null || true
    return 1
  fi
  # Exercise the periodic notice using a short override so the test does
  # not spend five minutes waiting for a second announcement.
  local first_notices second_notices
  first_notices=$(grep -Fc 'say Скоро будет обновление.' /tmp/minecraft-stub-rcon.log)
  sleep 1
  second_notices=$(grep -Fc 'say Скоро будет обновление.' /tmp/minecraft-stub-rcon.log)
  assert_eq "$first_notices" "$second_notices" "(pending notice is rate-limited)" || return 1
  local attempt_repeated=0
  while ((attempt_repeated < 60)); do
    if [[ "$(grep -Fc 'say Скоро будет обновление.' /tmp/minecraft-stub-rcon.log)" -gt "$first_notices" ]]; then
      break
    fi
    attempt_repeated=$((attempt_repeated + 1))
    sleep 0.1
  done
  if [[ "$(grep -Fc 'say Скоро будет обновление.' /tmp/minecraft-stub-rcon.log)" -le "$first_notices" ]]; then
    echo "  ASSERT FAILED: pending notice was not repeated" >&2
    kill "$deploy_pid" 2>/dev/null || true
    wait "$deploy_pid" 2>/dev/null || true
    return 1
  fi
  printf '0\n' >/tmp/minecraft-stub-online
  if ! wait "$deploy_pid"; then
    echo "  ASSERT FAILED: normal deploy failed after player logout" >&2
    cat /tmp/deploy-notice-test.log >&2
    return 1
  fi
  assert_contains "$(cat /tmp/minecraft-stub-rcon.log)" \
    "say Сервер перезапустится через 2 секунды для обновления." "(normal deploy final warning)" || return 1
  assert_contains "$(cat /tmp/minecraft-stub-telegram.log)" \
    "Обновление ожидает выхода игроков." "(Telegram pending notice)" || return 1
  assert_contains "$(cat /tmp/minecraft-stub-telegram.log)" \
    "Начал деплой обновления Minecraft." "(Telegram deployment-start notice)" || return 1
  assert_contains "$(cat /tmp/minecraft-stub-telegram.log)" \
    "Деплой прошёл успешно. Сервер снова доступен — жду игроков!" "(Telegram success notice)" || return 1

  # A failed player announcement must not stop the deployment controller.
  : >/tmp/minecraft-stub-fail-say
  prepare_release "rel3" || return 1
  DEPLOY_RESTART_COUNTDOWN_SECONDS=0 /opt/minecraft/bin/deploy.sh >/tmp/deploy-notice-failure.log 2>&1 || return 1
  assert_eq "SUCCESS" "$(cat /srv/minecraft/state/deploy-state)" "(deploy continues when RCON notice fails)" || return 1
  assert_contains "$(cat /tmp/deploy-notice-failure.log)" \
    "could not send in-game deployment notice" "(RCON notice failure is logged)" || return 1

  rm -f /tmp/minecraft-stub-fail-say
  printf '1\n' >/tmp/minecraft-stub-online
  prepare_release "rel4" || return 1
  FORCE_DEPLOY=true DEPLOY_RESTART_COUNTDOWN_SECONDS=0 /opt/minecraft/bin/deploy.sh || return 1
  assert_contains "$(cat /tmp/minecraft-stub-rcon.log)" \
    "say Внимание: запущено принудительное обновление." "(force deploy warning)" || return 1
  assert_eq "SUCCESS" "$(cat /srv/minecraft/state/deploy-state)" "(force deploy state)" || return 1
}

reset_environment
run_test "normal and force deployments notify players through RCON" test_normal_and_force_deploy_notices
report_and_exit
