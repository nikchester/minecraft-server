#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DISCORDSRV_CONFIG=${DISCORDSRV_CONFIG:-$MINECRAFT_SHARED_DIR/plugins/DiscordSRV/config.yml}
DISCORDSRV_VOICE_CONFIG=${DISCORDSRV_VOICE_CONFIG:-$MINECRAFT_SHARED_DIR/plugins/DiscordSRV/voice.yml}
DISCORD_BOT_TOKEN_FILE=${DISCORD_BOT_TOKEN_FILE:-/etc/minecraft/secrets/discord_bot_token}

# The project's one real Discord server -- the same IDs
# test/paper-local/entrypoint.sh seeds locally (see
# docs/LOCAL_PLUGIN_TESTING.md); not secret (none grants access on its own
# without the bot already invited with the right permissions), so committed
# here rather than rendered from a secret file like the token above.
DISCORD_CHANNEL_ID="1551597801933242418"
DISCORD_VOICE_CATEGORY_ID="1551598654245310494"
DISCORD_LOBBY_CHANNEL_ID="1551598909024112726"

# The release preparation renders the committed DiscordSRV config with the bot
# token from the secret store; this check heals drift in older installations.
ensure_discordsrv_token() {
  if [[ ! -f "$DISCORDSRV_CONFIG" ]]; then
    log "DiscordSRV config not present yet at ${DISCORDSRV_CONFIG} (plugin has not started); nothing to heal"
    return
  fi
  if [[ ! -r "$DISCORD_BOT_TOKEN_FILE" ]]; then
    log "no readable token at ${DISCORD_BOT_TOKEN_FILE}; leaving ${DISCORDSRV_CONFIG} as-is"
    return
  fi

  local token escaped_token
  token=$(<"$DISCORD_BOT_TOKEN_FILE")

  if grep -qxF "BotToken: \"${token}\"" "$DISCORDSRV_CONFIG" ||
    grep -qxF "BotToken: '${token}'" "$DISCORDSRV_CONFIG"; then
    return
  fi

  log "forcing BotToken in ${DISCORDSRV_CONFIG}"
  # Escape sed's replacement-side special characters (backslash, the "|"
  # delimiter used below, and "&" which sed expands to the whole match) so
  # the token is substituted as a literal string regardless of its content.
  escaped_token=$(printf '%s' "$token" | sed -e 's/[\&|]/\\&/g')
  sed -i "s|^BotToken:.*|BotToken: \"${escaped_token}\"|" "$DISCORDSRV_CONFIG"
}

# Same self-heal approach as the token above: config.yml/voice.yml are
# rendered into persistent plugin data, so a plugin update could drift them
# (an empty Channels map, a null Voice category/Lobby channel, Voice
# enabled: false). This forces them back to the real server on every tick
# instead of leaving the chat bridge or voice module silently unconfigured.
ensure_discordsrv_channels() {
  if [[ ! -f "$DISCORDSRV_CONFIG" ]]; then
    log "DiscordSRV config not present yet at ${DISCORDSRV_CONFIG} (plugin has not started); nothing to heal"
    return
  fi

  if ! grep -qxF "Channels: {\"global\": \"${DISCORD_CHANNEL_ID}\"}" "$DISCORDSRV_CONFIG"; then
    log "forcing Channels in ${DISCORDSRV_CONFIG}"
    sed -i "s|^Channels:.*|Channels: {\"global\": \"${DISCORD_CHANNEL_ID}\"}|" "$DISCORDSRV_CONFIG"
  fi
}

ensure_discordsrv_voice() {
  if [[ ! -f "$DISCORDSRV_VOICE_CONFIG" ]]; then
    log "DiscordSRV voice config not present yet at ${DISCORDSRV_VOICE_CONFIG} (plugin has not started); nothing to heal"
    return
  fi

  if ! grep -qxF "Voice category: ${DISCORD_VOICE_CATEGORY_ID}" "$DISCORDSRV_VOICE_CONFIG"; then
    log "forcing Voice category in ${DISCORDSRV_VOICE_CONFIG}"
    sed -i "s|^Voice category:.*|Voice category: ${DISCORD_VOICE_CATEGORY_ID}|" "$DISCORDSRV_VOICE_CONFIG"
  fi

  if ! grep -qxF "Lobby channel: ${DISCORD_LOBBY_CHANNEL_ID}" "$DISCORDSRV_VOICE_CONFIG"; then
    log "forcing Lobby channel in ${DISCORDSRV_VOICE_CONFIG}"
    sed -i "s|^Lobby channel:.*|Lobby channel: ${DISCORD_LOBBY_CHANNEL_ID}|" "$DISCORDSRV_VOICE_CONFIG"
  fi

  if ! grep -qxF "Voice enabled: true" "$DISCORDSRV_VOICE_CONFIG"; then
    log "enabling Voice in ${DISCORDSRV_VOICE_CONFIG}"
    sed -i "s|^Voice enabled:.*|Voice enabled: true|" "$DISCORDSRV_VOICE_CONFIG"
  fi
}

secure_discordsrv_configs() {
  local minecraft_uid minecraft_gid
  minecraft_uid=$(id -u minecraft)
  minecraft_gid=$(id -g minecraft)
  if [[ -f "$DISCORDSRV_CONFIG" ]]; then
    chown "$minecraft_uid:$minecraft_gid" "$DISCORDSRV_CONFIG"
    chmod 0600 "$DISCORDSRV_CONFIG"
  fi
  if [[ -f "$DISCORDSRV_VOICE_CONFIG" ]]; then
    chown "$minecraft_uid:$minecraft_gid" "$DISCORDSRV_VOICE_CONFIG"
    chmod 0644 "$DISCORDSRV_VOICE_CONFIG"
  fi
}

ensure_discordsrv_token
ensure_discordsrv_channels
ensure_discordsrv_voice
secure_discordsrv_configs
