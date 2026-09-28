#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

RELEASE_ID=${1:-$(date -u +%Y%m%dT%H%M%SZ)}
VERSION_FILE=${VERSION_FILE:-$PWD/minecraft/versions.yml}
RELEASE_DIR="$MINECRAFT_ROOT/releases/$RELEASE_ID"

read_yaml_value() {
  local expr=$1
  python3 - "$VERSION_FILE" "$expr" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
value = data
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

read_yaml_value_optional() {
  local expr=$1
  python3 - "$VERSION_FILE" "$expr" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
value = data
try:
    for part in sys.argv[2].split("."):
        value = value[part]
except (KeyError, TypeError):
    value = ""
print(value)
PY
}

download_artifact() {
  local url=$1 destination=$2 attempt=1 max_attempts=4
  local max_time=${ARTIFACT_DOWNLOAD_MAX_TIME_SECONDS:-180}
  local temporary_file="${destination}.part.$$" http_status curl_status retryable delay
  local -a retry_delays=(2 4 8)

  mkdir -p "$(dirname "$destination")"
  while ((attempt <= max_attempts)); do
    http_status=""
    curl_status=0
    if http_status=$(curl --silent --show-error --location \
      --connect-timeout 20 --max-time "$max_time" \
      --output "$temporary_file" --write-out '%{http_code}' "$url"); then
      curl_status=0
    else
      curl_status=$?
    fi
    http_status=${http_status:-000}

    if ((curl_status == 0)) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
      mv -f "$temporary_file" "$destination"
      return 0
    fi

    retryable=false
    if ((curl_status != 0)); then
      # Retry transport failures, not local setup/usage/certificate failures.
      case "$curl_status" in
        5|6|7|18|28|35|52|55|56) retryable=true ;;
      esac
    elif [[ "$http_status" =~ ^(408|429|5[0-9][0-9])$ ]]; then
      retryable=true
    fi

    rm -f "$temporary_file"
    if [[ "$retryable" != true || $attempt -ge $max_attempts ]]; then
      fail "artifact download failed after ${attempt}/${max_attempts} attempts (curl exit ${curl_status}, HTTP ${http_status}): ${url}"
    fi

    delay=${retry_delays[$((attempt - 1))]}
    log "artifact download attempt ${attempt}/${max_attempts} failed (curl exit ${curl_status}, HTTP ${http_status}); retrying in ${delay}s: ${url}"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

list_plugin_keys() {
  python3 - "$VERSION_FILE" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for key in (data.get("plugins") or {}):
    print(key)
PY
}

list_shared_plugin_data_dirs() {
  python3 - "$VERSION_FILE" <<'PY'
import sys
import yaml

data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for path in data.get("shared_plugin_data_dirs", []) or []:
    print(path)
PY
}

render_config_tree() {
  local source_dir=$1 output_dir=$2 source_file relative_path
  [[ -d "$source_dir" ]] || return 0
  while IFS= read -r -d '' source_file; do
    relative_path=${source_file#"$source_dir"/}
    "$SCRIPT_DIR/render-config.py" \
      --source "$source_file" \
      --output "$output_dir/$relative_path"
  done < <(find "$source_dir" -type f -print0)
}

download_plugins() {
  local key required download_url version jar_name
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    required=$(read_yaml_value_optional "plugins.${key}.required")
    download_url=$(read_yaml_value_optional "plugins.${key}.download_url")
    version=$(read_yaml_value_optional "plugins.${key}.version")
    if [[ -z "$download_url" ]]; then
      if [[ "$required" == "True" || "$required" == "true" ]]; then
        fail "no download_url configured for required plugin: $key"
      fi
      log "no download_url configured for optional plugin $key; skipping"
      continue
    fi
    jar_name="${key}-${version}.jar"
    log "downloading plugin $key ($version)"
    download_artifact "$download_url" "$RELEASE_DIR/plugins/$jar_name"
  done < <(list_plugin_keys)
}

# World data, whitelist/ban/op lists, and plugin data directories (AuthMe accounts,
# CoreProtect logs, etc.) must survive across releases even though each release gets
# a fresh directory. Persist them under MINECRAFT_SHARED_DIR and symlink them into
# the release so Paper and its plugins read/write the same files every deployment.
link_shared_state() {
  local world state_file key data_dir

  mkdir -p "$MINECRAFT_SHARED_DIR/plugins"

  for world in world world_nether world_the_end; do
    mkdir -p "$MINECRAFT_SHARED_DIR/$world"
    ln -sfnT "$MINECRAFT_SHARED_DIR/$world" "$RELEASE_DIR/$world"
  done

  for state_file in whitelist.json banned-players.json banned-ips.json ops.json; do
    [[ -f "$MINECRAFT_SHARED_DIR/$state_file" ]] || printf '[]' >"$MINECRAFT_SHARED_DIR/$state_file"
    ln -sfnT "$MINECRAFT_SHARED_DIR/$state_file" "$RELEASE_DIR/$state_file"
  done

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    data_dir=$(read_yaml_value_optional "plugins.${key}.data_dir")
    [[ -n "$data_dir" ]] || continue
    mkdir -p "$MINECRAFT_SHARED_DIR/plugins/$data_dir"
    render_config_tree "$PWD/minecraft/plugins/$data_dir" "$MINECRAFT_SHARED_DIR/plugins/$data_dir"
    ln -sfnT "$MINECRAFT_SHARED_DIR/plugins/$data_dir" "$RELEASE_DIR/plugins/$data_dir"
  done < <(list_plugin_keys)

  # Some plugins share server-wide state instead of owning a dedicated
  # directory (for example bStats' opt-out config). Keep these paths explicit
  # in versions.yml and link them with the same persistence/rendering rules.
  local shared_data_dir
  while IFS= read -r shared_data_dir; do
    [[ -n "$shared_data_dir" ]] || continue
    mkdir -p "$MINECRAFT_SHARED_DIR/plugins/$shared_data_dir"
    render_config_tree "$PWD/minecraft/plugins/$shared_data_dir" \
      "$MINECRAFT_SHARED_DIR/plugins/$shared_data_dir"
    ln -sfnT "$MINECRAFT_SHARED_DIR/plugins/$shared_data_dir" \
      "$RELEASE_DIR/plugins/$shared_data_dir"
  done < <(list_shared_plugin_data_dirs)

  chown -R minecraft:minecraft "$MINECRAFT_SHARED_DIR"
}

prepare() {
  local minecraft_version paper_build paper_url
  minecraft_version=$(read_yaml_value minecraft.version)
  paper_build=$(read_yaml_value paper.build)
  paper_url=$(read_yaml_value_optional paper.download_url)
  mkdir -p "$RELEASE_DIR/plugins" "$RELEASE_DIR/logs"
  if [[ -n "$paper_url" ]]; then
    download_artifact "$paper_url" "$RELEASE_DIR/paper.jar"
  else
    download_artifact \
      "https://api.papermc.io/v2/projects/paper/versions/${minecraft_version}/builds/${paper_build}/downloads/paper-${minecraft_version}-${paper_build}.jar" \
      "$RELEASE_DIR/paper.jar"
  fi
  download_plugins
  "$SCRIPT_DIR/render-config.py" \
    --source minecraft/server.properties \
    --output "$RELEASE_DIR/server.properties"
  local config_name
  for config_name in spigot.yml bukkit.yml; do
    "$SCRIPT_DIR/render-config.py" \
      --source "minecraft/$config_name" \
      --output "$RELEASE_DIR/$config_name"
  done
  render_config_tree "$PWD/minecraft/config" "$RELEASE_DIR/config"
  cp -a minecraft/server-icon.png "$RELEASE_DIR/server-icon.png"
  # Paper refuses to start at all without this; operating this server at
  # all is an implicit acceptance of the Minecraft EULA already.
  printf 'eula=true\n' >"$RELEASE_DIR/eula.txt"
  link_shared_state
  chown -R minecraft:minecraft "$RELEASE_DIR"
  printf '%s\n' "$RELEASE_ID" >"$MINECRAFT_STATE_DIR/target-release"
  log "prepared release $RELEASE_ID"
}

with_global_lock prepare
