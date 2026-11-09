# Test-only image: runs the real production scripts (scripts/*.sh)
# unmodified, against real restic/rclone talking to a local minio
# container instead of Yandex Disk, with systemctl and curl shimmed out
# (see test/local/bin/) so there is no real Paper JVM and no network
# access. Never used in production -- see SPEC.md 12.5.
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      procps \
      python3 \
      python3-yaml \
      restic \
      rclone \
      util-linux \
      jq \
    && rm -rf /var/lib/apt/lists/*

# prepare-release.sh does `chown -R minecraft:minecraft` on every release;
# that user only needs to exist for chown to resolve the name, not for any
# privilege separation in a throwaway test container.
RUN groupadd --system minecraft \
    && useradd --system --gid minecraft --no-create-home --shell /usr/sbin/nologin minecraft \
    && mkdir -p /etc/sysctl.d

# Shims come first in PATH so they're picked up ahead of the real curl
# apt just installed (systemctl isn't installed at all -- there's no
# systemd in this image -- so the shim is the only one that exists).
COPY test/local/bin/ /opt/test/shim/
COPY test/local/stub/ /opt/test/stub/
COPY scripts/ /opt/minecraft/bin/
COPY scripts/ /opt/test/repo/scripts/
COPY systemd/ /opt/test/repo/systemd/
RUN chmod +x /opt/test/shim/* /opt/minecraft/bin/*.sh /opt/minecraft/bin/*.py \
    /opt/test/repo/scripts/*.sh /opt/test/repo/scripts/*.py

# prepare-release.sh reads minecraft/ config and assets relative to $PWD (not an
# env-overridable path), the same way the real deploy.yml workflow cds into the
# checked-out repo before calling it -- /opt/test/repo mirrors that.
COPY minecraft/ /opt/test/repo/minecraft/

ENV PATH="/opt/test/shim:${PATH}" \
    MINECRAFT_ROOT=/srv/minecraft \
    MINECRAFT_BIN_DIR=/opt/minecraft/bin \
    MINECRAFT_STATE_DIR=/srv/minecraft/state \
    MINECRAFT_CURRENT_DIR=/srv/minecraft/current \
    MINECRAFT_SHARED_DIR=/srv/minecraft/shared \
    MINECRAFT_LOCK_FILE=/srv/minecraft/state/operation.lock \
    ISSUE_77_DATAPACKS=false

COPY test/local/fixtures/ /opt/test/fixtures/
COPY test/local/tests/ /opt/test/tests/
COPY test/local/run-tests.sh /opt/test/run-tests.sh
RUN chmod +x /opt/test/run-tests.sh /opt/test/tests/*.sh

WORKDIR /opt/minecraft/bin
CMD ["/opt/test/run-tests.sh"]
