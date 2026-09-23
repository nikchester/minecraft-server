#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

# Exercises scripts/ensure-discordsrv-config.sh directly, the same reasoning
# as test-authme-config.sh: proves the self-heal logic itself, not deploy.sh's
# one-line call into it (covered by code review).
DISCORDSRV_CONFIG=/srv/minecraft/shared/plugins/DiscordSRV/config.yml
DISCORDSRV_VOICE_CONFIG=/srv/minecraft/shared/plugins/DiscordSRV/voice.yml
export DISCORDSRV_CONFIG DISCORDSRV_VOICE_CONFIG

FAKE_TOKEN_FILE=/tmp/discord_bot_token
FAKE_TOKEN="fake-test-token-not-a-real-secret"

write_stock_discordsrv_config() {
  mkdir -p "$(dirname "$DISCORDSRV_CONFIG")"
  cat >"$DISCORDSRV_CONFIG" <<'EOF'
BotToken: "BOTTOKEN"
Channels: {}
EOF
}

write_stock_discordsrv_voice_config() {
  mkdir -p "$(dirname "$DISCORDSRV_VOICE_CONFIG")"
  cat >"$DISCORDSRV_VOICE_CONFIG" <<'EOF'
Voice enabled: false
Tick speed: 5
Voice category:
Lobby channel:
Mute users who bypass speak permissions in the lobby: true
EOF
}

write_fake_token_file() {
  printf '%s' "$FAKE_TOKEN" >"$FAKE_TOKEN_FILE"
}

run_ensure() {
  DISCORD_BOT_TOKEN_FILE="$FAKE_TOKEN_FILE" /opt/minecraft/bin/ensure-discordsrv-config.sh
}

test_heals_stock_config() {
  reset_environment
  write_stock_discordsrv_config
  write_stock_discordsrv_voice_config
  write_fake_token_file
  run_ensure || return 1

  assert_contains "$(cat "$DISCORDSRV_CONFIG")" "BotToken: \"${FAKE_TOKEN}\"" \
    "(BotToken must be healed from the secret file)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(Channels must be healed to the project's real chat bridge channel)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice category: 1551598654245310494" \
    "(Voice category must be healed to the project's real category)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Lobby channel: 1551598909024112726" \
    "(Lobby channel must be healed to the project's real lobby channel)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(Voice enabled must be healed to true)" || return 1
}

test_re_heals_after_drift() {
  reset_environment
  write_stock_discordsrv_config
  write_stock_discordsrv_voice_config
  write_fake_token_file
  run_ensure || return 1

  # A plugin update/reinstall on the VPS can regenerate stock defaults at
  # any time, not just at deploy -- the next unconditional deploy-timer
  # tick (a no-op deploy, no new release pending) must still re-heal it.
  sed -i 's/^BotToken:.*/BotToken: "BOTTOKEN"/; s/^Channels:.*/Channels: {}/' "$DISCORDSRV_CONFIG"
  sed -i 's/^Voice category:.*/Voice category:/; s/^Lobby channel:.*/Lobby channel:/; s/^Voice enabled:.*/Voice enabled: false/' "$DISCORDSRV_VOICE_CONFIG"
  run_ensure || return 1

  assert_contains "$(cat "$DISCORDSRV_CONFIG")" "BotToken: \"${FAKE_TOKEN}\"" \
    "(drifted BotToken must be re-healed)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(drifted Channels must be re-healed)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice category: 1551598654245310494" \
    "(drifted Voice category must be re-healed)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Lobby channel: 1551598909024112726" \
    "(drifted Lobby channel must be re-healed)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(drifted Voice enabled must be re-healed)" || return 1
}

test_missing_config_is_a_noop() {
  reset_environment
  # A regular timer tick before DiscordSRV is installed must stay a no-op.
  write_fake_token_file
  run_ensure || return 1
  if [[ -f "$DISCORDSRV_CONFIG" || -f "$DISCORDSRV_VOICE_CONFIG" ]]; then
    echo "  ASSERT FAILED: config should not have been created" >&2
    return 1
  fi
}

test_bootstraps_full_configs_before_first_start() {
  reset_environment
  mkdir -p /srv/minecraft/current/plugins
  python3 - <<'PY'
import zipfile
with zipfile.ZipFile('/srv/minecraft/current/plugins/discordsrv-1.30.5.jar', 'w') as jar:
    jar.writestr('config.yml', 'BotToken: "BOTTOKEN"\nChannels: {}\nOther default: preserved\n')
    jar.writestr('voice.yml', 'Voice enabled: false\nVoice category:\nLobby channel:\nOther voice default: preserved\n')
PY
  write_fake_token_file
  DISCORDSRV_BOOTSTRAP_DEFAULTS=true run_ensure || return 1

  assert_contains "$(cat "$DISCORDSRV_CONFIG")" "BotToken: \"${FAKE_TOKEN}\"" \
    "(the token must be set before the first plugin start)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(the chat bridge must be set before the first plugin start)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Other default: preserved' \
    "(the full plugin defaults must be preserved)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(voice must be enabled before the first plugin start)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" 'Other voice default: preserved' \
    "(the full voice defaults must be preserved)" || return 1
}

test_missing_token_leaves_config_untouched() {
  reset_environment
  write_stock_discordsrv_config
  write_stock_discordsrv_voice_config
  rm -f "$FAKE_TOKEN_FILE"
  run_ensure || return 1

  # BotToken can't be healed without a readable secret file, but Channels
  # and voice settings aren't secret and must still be healed regardless.
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'BotToken: "BOTTOKEN"' \
    "(BotToken must be left alone when the secret file is unreadable)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(Channels must still be healed even without a bot token)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(Voice enabled must still be healed even without a bot token)" || return 1
}

reset_environment
run_test "heals a stock DiscordSRV config/voice config to the project's real server" test_heals_stock_config
run_test "DiscordSRV config heal re-applies if it drifts back to defaults" test_re_heals_after_drift
run_test "missing DiscordSRV config (plugin never started) is a no-op, not a failure" test_missing_config_is_a_noop
run_test "first DiscordSRV start is bootstrapped from the plugin's full defaults" test_bootstraps_full_configs_before_first_start
run_test "missing bot token secret still heals the non-secret channel/voice settings" test_missing_token_leaves_config_untouched
report_and_exit
