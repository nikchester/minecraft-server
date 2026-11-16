#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/harness.sh"

# Exercises the configuration self-heal scripts directly. Deploy/backup
# scenarios are covered by test-deploy-cycle.sh; direct calls here isolate
# configuration drift and first-start behavior from MinIO snapshot state.
AUTHME_CONFIG=/srv/minecraft/shared/plugins/AuthMe/config.yml
DISCORDSRV_CONFIG=/srv/minecraft/shared/plugins/DiscordSRV/config.yml
DISCORDSRV_VOICE_CONFIG=/srv/minecraft/shared/plugins/DiscordSRV/voice.yml
export DISCORDSRV_CONFIG DISCORDSRV_VOICE_CONFIG
FAKE_TOKEN_FILE=/tmp/discord_bot_token
FAKE_TOKEN="fake-test-token-not-a-real-secret"

# Stock AuthMe 6.x layout: settings.restrictions.timeout is split into
# loginTimeout/registerTimeout, and the unrelated settings.sessions.timeout
# keeps the old leaf name.
write_stock_authme_config() {
  mkdir -p "$(dirname "$AUTHME_CONFIG")"
  cat >"$AUTHME_CONFIG" <<'EOF'
settings:
    messagesLanguage: en
    perPlayerLocale: true
    serverName: Your Minecraft Server
    restrictions:
        allowedNicknameCharacters: '[a-zA-Z0-9_]*'
        loginTimeout: 30
        registerTimeout: 30
        maxRegPerIp: 1
        forceSurvivalMode: false
    sessions:
        enabled: false
        timeout: 10
DataSource:
    backend: SQLITE
EOF
}

# A config written by AuthMe 5.x, before AuthMe 6 has started once and
# migrated settings.restrictions.timeout into the two new keys.
write_pre_migration_authme_config() {
  mkdir -p "$(dirname "$AUTHME_CONFIG")"
  cat >"$AUTHME_CONFIG" <<'EOF'
settings:
    messagesLanguage: ru
    serverName: The Tatarland Rebirth
    restrictions:
        allowedNicknameCharacters: '[a-zA-Z0-9_]*'
        timeout: 60
        maxRegPerIp: 1
    sessions:
        enabled: false
        timeout: 10
DataSource:
    backend: SQLITE
EOF
}

# Prints the value at a dotted path of the AuthMe config, booleans as
# YAML spells them, so assertions check the exact key rather than a line
# that merely looks similar somewhere else in the file.
authme_value() {
  python3 - "$AUTHME_CONFIG" "$1" <<'PY'
import sys
import yaml

node = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    node = node[part]
print(str(node).lower() if isinstance(node, bool) else node)
PY
}

assert_authme_tuned() {
  local context=$1
  assert_eq 60 "$(authme_value settings.restrictions.loginTimeout)" \
    "(${context} settings.restrictions.loginTimeout must be healed to 60)" || return 1
  assert_eq 60 "$(authme_value settings.restrictions.registerTimeout)" \
    "(${context} settings.restrictions.registerTimeout must be healed to 60)" || return 1
  assert_eq 0 "$(authme_value settings.restrictions.maxRegPerIp)" \
    "(${context} settings.restrictions.maxRegPerIp must be healed to 0)" || return 1
  assert_eq ru "$(authme_value settings.messagesLanguage)" \
    "(${context} AuthMe player messages must use Russian)" || return 1
  assert_eq false "$(authme_value settings.perPlayerLocale)" \
    "(${context} AuthMe must not switch to each client's language)" || return 1
  assert_eq "The Tatarland Rebirth" "$(authme_value settings.serverName)" \
    "(${context} AuthMe welcome placeholder must use the server name)" || return 1
  # The unrelated settings.sessions.timeout must be left untouched.
  assert_eq 10 "$(authme_value settings.sessions.timeout)" \
    "(${context} settings.sessions.timeout must NOT be touched)" || return 1
}

test_heals_stock_config() {
  reset_environment
  # Simulates AuthMe having already generated its own config once (e.g. a
  # plugin reinstall/update regenerated stock defaults).
  write_stock_authme_config
  /opt/minecraft/bin/ensure-authme-config.sh || return 1
  assert_authme_tuned "stock config:" || return 1
}

test_re_heals_after_drift() {
  reset_environment
  write_stock_authme_config
  /opt/minecraft/bin/ensure-authme-config.sh || return 1

  # A plugin update/reinstall on the VPS can regenerate stock defaults at
  # any time, not just at deploy -- the next unconditional deploy-timer
  # tick (a no-op deploy, no new release pending) must still re-heal it.
  sed -i 's/loginTimeout: 60/loginTimeout: 30/; s/registerTimeout: 60/registerTimeout: 30/; s/maxRegPerIp: 0/maxRegPerIp: 1/; s/messagesLanguage: ru/messagesLanguage: en/; s/perPlayerLocale: false/perPlayerLocale: true/; s/serverName: The Tatarland Rebirth/serverName: Your Minecraft Server/' "$AUTHME_CONFIG"
  /opt/minecraft/bin/ensure-authme-config.sh || return 1
  assert_authme_tuned "drifted config:" || return 1
}

test_pre_migration_config_only_logs() {
  reset_environment
  # The deploy tick that installs AuthMe 6 runs this before the new plugin
  # has started: the 5.x key is still there and the new keys are not yet.
  write_pre_migration_authme_config
  local output
  output=$(/opt/minecraft/bin/ensure-authme-config.sh 2>&1) || return 1

  assert_contains "$output" "settings.restrictions.loginTimeout not found" || return 1
  assert_contains "$output" "settings.restrictions.registerTimeout not found" || return 1
  # The old key is AuthMe's own migration input and must be left alone.
  assert_eq 60 "$(authme_value settings.restrictions.timeout)" \
    "(pre-migration settings.restrictions.timeout must NOT be touched)" || return 1
  assert_eq 10 "$(authme_value settings.sessions.timeout)" \
    "(settings.sessions.timeout must NOT be touched)" || return 1
  assert_eq 0 "$(authme_value settings.restrictions.maxRegPerIp)" \
    "(keys that kept their place must still be healed)" || return 1
}

test_repository_authme_config_needs_no_healing() {
  reset_environment
  # Git is the source of the rendered config, so it must already hold the
  # values the periodic self-heal enforces; otherwise every release would
  # be followed by a forced rewrite.
  prepare_release authme-config || return 1
  local output
  output=$(/opt/minecraft/bin/ensure-authme-config.sh 2>&1) || return 1
  if [[ "$output" == *"forcing"* || "$output" == *"not found"* ]]; then
    echo "  ASSERT FAILED: repository AuthMe config needed healing: ${output}" >&2
    return 1
  fi
  assert_authme_tuned "repository config:" || return 1
  assert_eq false "$(authme_value settings.registration.dialog.preJoin.enable)" \
    "(pre-join login dialog must stay disabled)" || return 1
  assert_eq false "$(authme_value settings.registration.dialog.postJoin.enable)" \
    "(post-join login dialog must stay disabled)" || return 1
}

test_missing_config_is_a_noop() {
  reset_environment
  # AuthMe hasn't started yet (first-ever deploy): there's nothing to heal
  # and this must not fail the deploy tick that calls it.
  /opt/minecraft/bin/ensure-authme-config.sh || return 1
  if [[ -f "$AUTHME_CONFIG" ]]; then
    echo "  ASSERT FAILED: config should not have been created" >&2
    return 1
  fi
}

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

run_discordsrv_ensure() {
  DISCORD_BOT_TOKEN_FILE="$FAKE_TOKEN_FILE" /opt/minecraft/bin/ensure-discordsrv-config.sh
}

test_discordsrv_heals_stock_and_drifted_configuration() {
  reset_environment
  write_stock_discordsrv_config
  write_stock_discordsrv_voice_config
  write_fake_token_file
  run_discordsrv_ensure || return 1

  assert_contains "$(cat "$DISCORDSRV_CONFIG")" "BotToken: \"${FAKE_TOKEN}\"" \
    "(DiscordSRV BotToken must be read from the secret file)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(DiscordSRV chat channel must use the configured bridge)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice category: 1551598654245310494" \
    "(voice category must use the configured category)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Lobby channel: 1551598909024112726" \
    "(voice lobby must use the configured channel)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(voice must be enabled)" || return 1

  # Plugin updates may restore stock settings; a later deployment must heal
  # them again rather than preserving that drift.
  sed -i 's/^BotToken:.*/BotToken: "BOTTOKEN"/; s/^Channels:.*/Channels: {}/' "$DISCORDSRV_CONFIG"
  sed -i 's/^Voice category:.*/Voice category:/; s/^Lobby channel:.*/Lobby channel:/; s/^Voice enabled:.*/Voice enabled: false/' "$DISCORDSRV_VOICE_CONFIG"
  run_discordsrv_ensure || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" "BotToken: \"${FAKE_TOKEN}\"" \
    "(drifted DiscordSRV BotToken must be healed again)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(drifted DiscordSRV channel must be healed again)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(drifted voice setting must be healed again)" || return 1
}

test_discordsrv_missing_config_is_a_noop() {
  reset_environment
  write_fake_token_file
  run_discordsrv_ensure || return 1
  if [[ -f "$DISCORDSRV_CONFIG" || -f "$DISCORDSRV_VOICE_CONFIG" ]]; then
    echo "  ASSERT FAILED: absent DiscordSRV config must not be created during a regular check" >&2
    return 1
  fi
}

test_discordsrv_renders_repository_config_before_first_start() {
  reset_environment
  prepare_release first-start || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'BotToken: '\''test-discord-bot-token'\''' \
    "(token must be rendered from the runtime secret)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'ConfigVersion: 1.30.5' \
    "(complete versioned configuration must come from the repository)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(voice must be enabled before first plugin start)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" 'Vertical Strength: 40' \
    "(voice settings must come from the repository)" || return 1
  python3 - "$DISCORDSRV_CONFIG" "$DISCORDSRV_VOICE_CONFIG" <<'PY'
import sys
import yaml

config, voice = (yaml.safe_load(open(path, encoding="utf-8")) for path in sys.argv[1:])
assert config["BotToken"] == "test-discord-bot-token"
assert config["ConfigVersion"] == "1.30.5"
assert config["Channels"]["global"] == "1551597801933242418"
assert voice["Network"]["Vertical Strength"] == 40
PY
  local name
  for name in alerts linking synchronization messages; do
    if [[ ! -s "/srv/minecraft/shared/plugins/DiscordSRV/${name}.yml" ]]; then
      echo "  ASSERT FAILED: repository config ${name}.yml was not rendered" >&2
      return 1
    fi
  done
  printf '%s' 'test-discord-bot-token' >"$FAKE_TOKEN_FILE"
  DISCORD_BOT_TOKEN_FILE="$FAKE_TOKEN_FILE" \
    /opt/minecraft/bin/ensure-discordsrv-config.sh || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" "BotToken: 'test-discord-bot-token'" \
    '(periodic healing must not rewrite correctly rendered secrets)' || return 1
}

test_discordsrv_secret_is_required_for_preparation() {
  reset_environment
  local output
  if output=$(cd /opt/test/repo && env -u DISCORD_BOT_TOKEN \
    /opt/minecraft/bin/prepare-release.sh no-token 2>&1); then
    echo '  ASSERT FAILED: preparation must reject missing Discord bot token' >&2
    return 1
  fi
  assert_contains "$output" 'missing secret DISCORD_BOT_TOKEN' || return 1
  if [[ -e "$DISCORDSRV_CONFIG" ]]; then
    echo '  ASSERT FAILED: failed rendering must not create a placeholder config' >&2
    return 1
  fi
}

test_discordsrv_nonsecret_settings_heal_without_token() {
  reset_environment
  write_stock_discordsrv_config
  write_stock_discordsrv_voice_config
  rm -f "$FAKE_TOKEN_FILE"
  run_discordsrv_ensure || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'BotToken: "BOTTOKEN"' \
    "(BotToken must be preserved when the secret file is missing)" || return 1
  assert_contains "$(cat "$DISCORDSRV_CONFIG")" 'Channels: {"global": "1551597801933242418"}' \
    "(non-secret chat channel must still be healed)" || return 1
  assert_contains "$(cat "$DISCORDSRV_VOICE_CONFIG")" "Voice enabled: true" \
    "(non-secret voice settings must still be healed)" || return 1
}

reset_environment
run_test "heals a stock AuthMe config to the tuned timeout/IP-limit values" test_heals_stock_config
run_test "AuthMe config heal re-applies if it drifts back to defaults" test_re_heals_after_drift
run_test "pre-migration AuthMe 5.x config only logs the missing 6.x keys" test_pre_migration_config_only_logs
run_test "repository AuthMe config already holds the self-healed values" test_repository_authme_config_needs_no_healing
run_test "missing AuthMe config (plugin never started) is a no-op, not a failure" test_missing_config_is_a_noop
run_test "DiscordSRV runtime settings heal stock and drifted configs" test_discordsrv_heals_stock_and_drifted_configuration
run_test "missing plugin configuration remains a no-op before first start" test_discordsrv_missing_config_is_a_noop
run_test "first-start DiscordSRV configuration renders from Git" test_discordsrv_renders_repository_config_before_first_start
run_test "release preparation fails without DiscordSRV secret" test_discordsrv_secret_is_required_for_preparation
run_test "non-secret runtime settings heal without a bot-token secret" test_discordsrv_nonsecret_settings_heal_without_token
report_and_exit
