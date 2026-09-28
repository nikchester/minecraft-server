#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

AUTHME_CONFIG=${AUTHME_CONFIG:-$MINECRAFT_SHARED_DIR/plugins/AuthMe/config.yml}

# AuthMeReloaded 5.6.0 (pinned in minecraft/versions.yml) nests two
# unrelated settings under the exact same leaf key name "timeout":
# settings.restrictions.timeout (login/registration kick timer, seconds)
# and settings.sessions.timeout (an unrelated remembered-session setting).
# A plain grep/sed on the key name alone would risk also rewriting the
# wrong one, so this locates the line number of restrictions.timeout by
# tracking which settings.* section is currently open, then edits that
# exact line by number -- sed -i preserves the target file's existing
# ownership/permissions, which matters here since this runs as root on
# every deploy tick but the file must stay owned by the minecraft user.
#
# settings.restrictions.timeout defaults to 30s -- too short for players to
# type a password twice -- and settings.restrictions.maxRegPerIp defaults
# to 1, blocking a second registration behind the same IP (e.g. the same
# household) from registering; 0 means unlimited. Both live in AuthMe's
# own, uncommitted plugin data directory and regenerate at their defaults
# if the key is ever missing, so this self-heals on every deploy cycle the
# same way DynamicLights' config does (see ensure-dynamiclights-config.sh)
# instead of relying on a manual VPS edit surviving a plugin update or
# reinstall.
find_restrictions_line() {
  local key=$1
  awk -v key="$key" '
    {
      line = $0
      stripped = line
      sub(/^[[:space:]]*/, "", stripped)
      if (stripped ~ /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        indent = length(line) - length(stripped)
        name = stripped
        sub(/:.*/, "", name)
        if (name == "restrictions") {
          in_restrictions = 1
          r_indent = indent
        } else if (in_restrictions && indent <= r_indent) {
          in_restrictions = 0
        }
        next
      }
      if (in_restrictions && stripped ~ ("^" key ":[[:space:]]*[0-9]+[[:space:]]*$")) {
        print NR
      }
    }
  ' "$AUTHME_CONFIG"
}

heal_restrictions_key() {
  local key=$1 value=$2 lineno current
  lineno=$(find_restrictions_line "$key")
  if [[ -z "$lineno" ]]; then
    log "settings.restrictions.${key} not found in ${AUTHME_CONFIG}; leaving as-is (unexpected config layout)"
    return
  fi
  current=$(sed -n "${lineno}p" "$AUTHME_CONFIG")
  if [[ "$current" =~ ^([[:space:]]*)${key}:[[:space:]]*${value}[[:space:]]*$ ]]; then
    return
  fi
  log "forcing settings.restrictions.${key}: ${value} in ${AUTHME_CONFIG}"
  sed -i "${lineno}s/^\([[:space:]]*\)${key}:.*/\1${key}: ${value}/" "$AUTHME_CONFIG"
}

find_settings_line() {
  local key=$1
  awk -v key="$key" '
    {
      line = $0
      stripped = line
      sub(/^[[:space:]]*/, "", stripped)
      if (stripped ~ /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/) {
        indent = length(line) - length(stripped)
        name = stripped
        sub(/:.*/, "", name)
        if (name == "settings") {
          in_settings = 1
          settings_indent = indent
        } else if (in_settings && indent <= settings_indent) {
          in_settings = 0
        }
        next
      }
      if (in_settings && stripped ~ ("^" key ":[[:space:]]*[^[:space:]#].*$")) {
        indent = length(line) - length(stripped)
        if (indent == settings_indent + 4) print NR
      }
    }
  ' "$AUTHME_CONFIG"
}

heal_settings_key() {
  local key=$1 value=$2 lineno current
  lineno=$(find_settings_line "$key")
  if [[ -z "$lineno" ]]; then
    log "settings.${key} not found in ${AUTHME_CONFIG}; leaving as-is (unexpected config layout)"
    return
  fi
  current=$(sed -n "${lineno}p" "$AUTHME_CONFIG")
  if [[ "$current" =~ ^([[:space:]]*)${key}:[[:space:]]*${value}[[:space:]]*$ ]]; then
    return
  fi
  log "forcing settings.${key}: ${value} in ${AUTHME_CONFIG}"
  sed -i "${lineno}s/^\\([[:space:]]*\\)${key}:.*/\\1${key}: ${value}/" "$AUTHME_CONFIG"
}

ensure_authme_config() {
  if [[ ! -f "$AUTHME_CONFIG" ]]; then
    log "AuthMe config not present yet at ${AUTHME_CONFIG} (plugin has not started); nothing to heal"
    return
  fi

  heal_restrictions_key timeout 60
  heal_restrictions_key maxRegPerIp 0
  heal_settings_key messagesLanguage ru
  heal_settings_key serverName "The Tatarland Rebirth"
}

ensure_authme_config
