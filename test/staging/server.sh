#!/usr/bin/env bash
set -euo pipefail

root=${MINECRAFT_ROOT:-/srv/minecraft}
current="$root/current"
state="$root/state"

prepare() {
  local release_id=$1
  mkdir -p "$state"
  /opt/minecraft/bin/prepare-release.sh "$release_id"
  # Staging must never log into production Discord or post to its channels.
  rm -f "$root/releases/$release_id"/plugins/discordsrv-*.jar
  python3 - "$root/releases/$release_id/server.properties" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
settings = {
    "motd": "Local staging - test world",
    "max-players": "4",
    "max-world-size": "128",
    "view-distance": "4",
    "simulation-distance": "4",
    "spawn-protection": "0",
    "enforce-whitelist": "true",
    "white-list": "true",
    "server-port": "25565",
    "rcon.port": "25575",
}
lines = path.read_text(encoding="utf-8").splitlines()
path.write_text("\n".join(
    f"{key}={settings[key]}" if key in settings else line
    for line in lines for key in [line.split("=", 1)[0]]
) + "\n", encoding="utf-8")
PY
}

switch_release() {
  local release_id=$1
  [[ -d "$root/releases/$release_id" ]] || { echo "Missing release $release_id" >&2; exit 1; }
  ln -sfnT "$root/releases/$release_id" "$current"
  printf '%s\n' "$release_id" >"$state/current-release"
}

case "${1:-serve}" in
  serve)
    if [[ ! -L "$current" ]]; then
      [[ ! -e "$current" ]] || { echo 'Current release is not a symlink' >&2; exit 1; }
      release_id="staging-$(date -u +%Y%m%dT%H%M%SZ)"
      prepare "$release_id"
      switch_release "$release_id"
    fi
    # No unattended restart: the server only runs while explicitly started.
    cd "$current"
    exec runuser -u minecraft -- java -Xms512M -Xmx2G -jar paper.jar nogui
    ;;
  update)
    [[ -L "$current" ]] || { echo 'Start staging once before updating' >&2; exit 1; }
    previous=$(basename "$(readlink "$current")")
    release_id="staging-$(date -u +%Y%m%dT%H%M%SZ)"
    [[ "$release_id" != "$previous" ]] || release_id="$release_id-$$"
    prepare "$release_id"
    printf '%s\n' "$previous" >"$state/previous-release"
    switch_release "$release_id"
    ;;
  rollback)
    [[ -f "$state/previous-release" ]] || { echo 'No previous release' >&2; exit 1; }
    previous=$(cat "$state/previous-release")
    current_release=$(basename "$(readlink "$current")")
    switch_release "$previous"
    printf '%s\n' "$current_release" >"$state/previous-release"
    ;;
  *) echo 'Usage: server.sh {serve|update|rollback}' >&2; exit 2 ;;
esac
