#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

DISCORDSRV_CONFIG=${DISCORDSRV_CONFIG:-$MINECRAFT_SHARED_DIR/plugins/DiscordSRV/config.yml}
DISCORDSRV_VOICE_CONFIG=${DISCORDSRV_VOICE_CONFIG:-$MINECRAFT_SHARED_DIR/plugins/DiscordSRV/voice.yml}
DISCORD_BOT_TOKEN_FILE=${DISCORD_BOT_TOKEN_FILE:-/etc/minecraft/secrets/discord_bot_token}
DISCORDSRV_BOOTSTRAP_DEFAULTS=${DISCORDSRV_BOOTSTRAP_DEFAULTS:-false}

# The project's one real Discord server -- the same IDs
# test/paper-local/entrypoint.sh seeds locally (see
# docs/LOCAL_PLUGIN_TESTING.md); not secret (none grants access on its own
# without the bot already invited with the right permissions), so committed
# here rather than rendered from a secret file like the token above.
DISCORD_CHANNEL_ID="1551597801933242418"
DISCORD_VOICE_CATEGORY_ID="1551598654245310494"
DISCORD_LOBBY_CHANNEL_ID="1551598909024112726"

# On the first install DiscordSRV has not created its persistent config
# directory yet. Seed both complete defaults from the freshly selected plugin
# jar before the server starts, then the normal self-heal functions below can
# set the project-specific values. Only run this after minecraft.service has
# stopped; never replace existing files or edit them from a live deploy tick.
bootstrap_discordsrv_defaults() {
  [[ "$DISCORDSRV_BOOTSTRAP_DEFAULTS" == "true" ]] || return 0

  local plugin_jar
  plugin_jar=$(find "$MINECRAFT_CURRENT_DIR/plugins" -maxdepth 1 -type f -name 'discordsrv-*.jar' -print -quit 2>/dev/null || true)
  if [[ -z "$plugin_jar" ]]; then
    log "DiscordSRV jar not present in current release; skipping config bootstrap"
    return 0
  fi

  mkdir -p "$(dirname "$DISCORDSRV_CONFIG")" "$(dirname "$DISCORDSRV_VOICE_CONFIG")"
  python3 - "$plugin_jar" "$DISCORDSRV_CONFIG" "$DISCORDSRV_VOICE_CONFIG" <<'PY'
import os
import grp
import pwd
import sys
import tempfile
import zipfile

jar, config_path, voice_path = sys.argv[1:]
targets = {"config.yml": config_path, "voice.yml": voice_path}
with zipfile.ZipFile(jar) as archive:
    for name, target in targets.items():
        if os.path.exists(target):
            continue
        try:
            contents = archive.read(name)
        except KeyError:
            raise SystemExit(f"DiscordSRV jar is missing its embedded {name}")
        fd, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=os.path.dirname(target))
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(contents)
            os.chmod(temporary, 0o644)
            try:
                # Do not replace a config created concurrently or preserved
                # from an earlier run.
                os.link(temporary, target)
                os.chown(target, pwd.getpwnam("minecraft").pw_uid, grp.getgrnam("minecraft").gr_gid)
            except FileExistsError:
                pass
        finally:
            os.unlink(temporary)
PY
  log "seeded missing DiscordSRV config files from $(basename "$plugin_jar")"
}

# DiscordSRV writes its own config.yml on first run with a literal
# BotToken: "BOTTOKEN" placeholder (see minecraft/plugins/README.md); the
# real token is a secret (docs/SECRETS.md, DISCORD_BOT_TOKEN) and must never
# be committed, so it's rendered in here from
# /etc/minecraft/secrets/discord_bot_token instead -- same self-heal
# approach as ensure-authme-config.sh/ensure-dynamiclights-config.sh, so a
# plugin update or a hand-edit that reverts the key back to the placeholder
# gets corrected on the next deploy tick rather than leaving the bot offline
# until someone notices.
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

  if grep -qxF "BotToken: \"${token}\"" "$DISCORDSRV_CONFIG"; then
    return
  fi

  log "forcing BotToken in ${DISCORDSRV_CONFIG}"
  # Escape sed's replacement-side special characters (backslash, the "|"
  # delimiter used below, and "&" which sed expands to the whole match) so
  # the token is substituted as a literal string regardless of its content.
  escaped_token=$(printf '%s' "$token" | sed -e 's/[\&|]/\\&/g')
  sed -i "s|^BotToken:.*|BotToken: \"${escaped_token}\"|" "$DISCORDSRV_CONFIG"
}

# Same self-heal approach as the token above: config.yml/voice.yml live in
# the plugin's own persistent, uncommitted data directory, so a plugin
# update or hand-edit could drift these back to their generated defaults
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

bootstrap_discordsrv_defaults
ensure_discordsrv_token
ensure_discordsrv_channels
ensure_discordsrv_voice
secure_discordsrv_configs
