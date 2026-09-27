#!/usr/bin/env bash
set -euo pipefail

release_id="plugin-smoke-$(date -u +%Y%m%dT%H%M%SZ)"
release_dir="${MINECRAFT_ROOT}/releases/${release_id}"
log_file="${release_dir}/logs/paper-smoke.log"
timeout_seconds=${PAPER_SMOKE_TIMEOUT_SECONDS:-600}
paper_pid=""

cleanup() {
  if [[ -n "$paper_pid" ]] && kill -0 "$paper_pid" 2>/dev/null; then
    kill "$paper_pid" 2>/dev/null || true
    wait "$paper_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

show_redacted_log_tail() {
  python3 - "$log_file" <<'PY'
import os
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
for line in lines[-60:]:
    for name in ("RCON_PASSWORD", "MANAGEMENT_SERVER_SECRET", "AUTHME_MYSQL_PASSWORD", "DISCORD_BOT_TOKEN"):
        secret = os.environ.get(name, "")
        if secret:
            line = line.replace(secret, "[REDACTED]")
    print(line)
PY
}

echo "Preparing release ${release_id} from pinned repository versions..."
ARTIFACT_DOWNLOAD_MAX_TIME_SECONDS=${PAPER_ARTIFACT_DOWNLOAD_TIMEOUT_SECONDS:-600} \
  /opt/minecraft/bin/prepare-release.sh "$release_id"

python3 - "$release_dir" <<'PY'
import os
import pathlib
import sys
import yaml

release = pathlib.Path(sys.argv[1])
properties = {}
for line in (release / "server.properties").read_text(encoding="utf-8").splitlines():
    if line and not line.startswith("#") and "=" in line:
        key, value = line.split("=", 1)
        properties[key] = value

authme = yaml.safe_load(
    pathlib.Path("/srv/minecraft/shared/plugins/AuthMe/config.yml").read_text(encoding="utf-8")
)
checks = {
    "RCON_PASSWORD": properties.get("rcon.password"),
    "MANAGEMENT_SERVER_SECRET": properties.get("management-server-secret"),
    "AUTHME_MYSQL_PASSWORD": authme["DataSource"]["mySQLPassword"],
}
for name, rendered in checks.items():
    if not os.environ.get(name) or rendered != os.environ[name]:
        print(f"FAIL: {name} was not rendered from the smoke environment.", file=sys.stderr)
        raise SystemExit(1)
    print(f"PASS: {name} reached the rendered runtime configuration.")

discord = pathlib.Path("/srv/minecraft/shared/plugins/DiscordSRV")
expected = {"config.yml", "voice.yml", "alerts.yml", "linking.yml", "synchronization.yml", "messages.yml"}
for name in expected:
    path = discord / name
    if not path.is_file() or "{{" in path.read_text(encoding="utf-8"):
        print(f"FAIL: {name} missing or has unresolved markers.", file=sys.stderr)
        raise SystemExit(1)
    yaml.safe_load(path.read_text(encoding="utf-8"))
config = yaml.safe_load((discord / "config.yml").read_text(encoding="utf-8"))
if config.get("BotToken") != os.environ.get("DISCORD_BOT_TOKEN"):
    print("FAIL: DiscordSRV bot token was not rendered.", file=sys.stderr)
    raise SystemExit(1)
print("PASS: all six DiscordSRV configs rendered before Paper startup.")
PY

# Keep this isolated smoke offline from Discord; no real bot login is needed.
sed -i 's/^BotToken:.*/BotToken: ""/' \
  "$MINECRAFT_SHARED_DIR/plugins/DiscordSRV/config.yml"

echo "Starting the real Paper server and downloaded plugin JARs..."
cd "$release_dir"
java -Xms512M -Xmx1G -jar paper.jar nogui >"$log_file" 2>&1 &
paper_pid=$!

for ((second = 0; second < timeout_seconds; second += 2)); do
  if grep -Fq 'Done (' "$log_file"; then
    break
  fi
  if ! kill -0 "$paper_pid" 2>/dev/null; then
    echo "FAIL: Paper exited before completing startup. Last log lines (configured secrets redacted):" >&2
    show_redacted_log_tail >&2
    exit 1
  fi
  if (( second > 0 && second % 30 == 0 )); then
    echo "Paper is still starting (${second}s elapsed; timeout ${timeout_seconds}s)..."
  fi
  sleep 2
done

if ! grep -Fq 'Done (' "$log_file"; then
  echo "FAIL: Paper did not complete startup within ${timeout_seconds}s. Last log lines (configured secrets redacted):" >&2
  show_redacted_log_tail >&2
  exit 1
fi

python3 - "$release_dir" "$log_file" <<'PY'
import os
import pathlib
import sys
import zipfile

import yaml

release = pathlib.Path(sys.argv[1])
log = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
versions = yaml.safe_load(
    pathlib.Path("/opt/test/repo/minecraft/versions.yml").read_text(encoding="utf-8")
)
plugins = versions.get("plugins") or {}
enabled = []
failures = []

shared = pathlib.Path(os.environ.get("MINECRAFT_SHARED_DIR", "/srv/minecraft/shared"))
onlysleep_config = yaml.safe_load(
    (shared / "plugins/Onlysleep/config.yml").read_text(encoding="utf-8")
)
onlysleep_messages = yaml.safe_load(
    (shared / "plugins/Onlysleep/messages.yml").read_text(encoding="utf-8")
)
bstats_config = yaml.safe_load(
    (shared / "plugins/bStats/config.yml").read_text(encoding="utf-8")
)
if onlysleep_config.get("sleep-percentage") != 50:
    failures.append("Onlysleep: expected a 50% sleep threshold")
if onlysleep_config.get("per-world-sleep") is not True:
    failures.append("Onlysleep: expected sleep counts to be per-world")
if onlysleep_config.get("check-for-updates") is not False:
    failures.append("Onlysleep: automatic update checks must be disabled")
if onlysleep_messages.get("sleep", {}).get("start-sleep", "").find("лёг спать") < 0:
    failures.append("Onlysleep: Russian sleep notification was not rendered")
if onlysleep_messages.get("sleep", {}).get("progress-bar", "").find("Игроки спят") < 0:
    failures.append("Onlysleep: Russian progress notification was not rendered")
if bstats_config.get("enabled") is not False:
    failures.append("bStats: telemetry must be disabled")

for key, config in plugins.items():
    if not config.get("download_url"):
        continue
    jar_path = release / "plugins" / f"{key}-{config['version']}.jar"
    if not jar_path.is_file():
        failures.append(f"{key}: configured artifact is missing ({jar_path.name})")
        continue
    try:
        with zipfile.ZipFile(jar_path) as jar:
            metadata_name = next(
                (name for name in ("paper-plugin.yml", "plugin.yml") if name in jar.namelist()),
                None,
            )
            if metadata_name is None:
                failures.append(f"{key}: JAR has no Paper plugin metadata")
                continue
            metadata = yaml.safe_load(jar.read(metadata_name)) or {}
    except (OSError, zipfile.BadZipFile, KeyError, yaml.YAMLError) as error:
        failures.append(f"{key}: invalid plugin JAR metadata ({error})")
        continue

    name = metadata.get("name")
    if not name:
        failures.append(f"{key}: plugin metadata has no name")
        continue
    if f"Enabling {name} " not in log:
        failures.append(f"{key} ({name}): Paper did not enable the configured plugin")
        continue
    enabled.append(name)

if failures:
    print("FAIL: not every configured plugin started:", file=sys.stderr)
    for failure in failures:
        print(f" - {failure}", file=sys.stderr)
    raise SystemExit(1)
if not enabled:
    print("FAIL: no configured plugins were checked", file=sys.stderr)
    raise SystemExit(1)
print("PASS: Paper completed startup and enabled all configured plugins: " + ", ".join(enabled))
PY
