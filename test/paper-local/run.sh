#!/usr/bin/env bash
# Builds and runs a real Paper server, with a candidate plugin (issue #20:
# DiscordSRV's Voice Proximity module), in Docker for local manual testing.
# See docs/LOCAL_PLUGIN_TESTING.md for what this covers and what it doesn't.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
VERSIONS_FILE="$REPO_ROOT/minecraft/versions.yml"

# Pulls a scalar out of a simple two-level "top:\n  key: value" YAML block
# without a YAML parser (none of java/python/yq is guaranteed on the host --
# only bash/awk/docker are required to run this). Only fit for the flat
# minecraft/versions.yml shape; not a general YAML reader.
yaml_scalar() {
  local top=$1 key=$2
  awk -v top="$top" -v key="$key" '
    $0 ~ "^" top ":" { in_block=1; next }
    in_block && /^[^ ]/ { in_block=0 }
    in_block && $0 ~ "^  " key ":" {
      sub("^  " key ": *", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$VERSIONS_FILE"
}

yaml_plugin_url() {
  local plugin=$1
  awk -v plugin="$plugin" '
    $0 == "  " plugin ":" { in_block=1; next }
    in_block && /^  [^ ]/ { in_block=0 }
    in_block && /^    download_url:/ {
      sub(/^    download_url: */, "")
      gsub(/"/, "")
      print
      exit
    }
  ' "$VERSIONS_FILE"
}

export JAVA_MAJOR
JAVA_MAJOR=$(yaml_scalar java major)
export PAPER_URL
PAPER_URL=$(yaml_scalar paper download_url)
export AUTHME_URL
AUTHME_URL=$(yaml_plugin_url authme_reloaded)

if [[ -z "$PAPER_URL" ]]; then
  echo "no paper.download_url in $VERSIONS_FILE" >&2
  exit 1
fi
if [[ -z "$AUTHME_URL" ]]; then
  echo "no plugins.authme_reloaded.download_url in $VERSIONS_FILE" >&2
  exit 1
fi

mkdir -p "$SCRIPT_DIR/data/DiscordSRV" "$SCRIPT_DIR/cache"

docker compose -f "$SCRIPT_DIR/docker-compose.yml" up --build "$@"
