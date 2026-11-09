FROM eclipse-temurin:25-jre

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      python3 \
      python3-yaml \
      util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system minecraft \
    && useradd --system --gid minecraft --no-create-home --shell /usr/sbin/nologin minecraft

COPY scripts/ /opt/minecraft/bin/
COPY minecraft/ /opt/test/repo/minecraft/
COPY test/local/run-paper-plugin-smoke.sh /opt/test/run-paper-plugin-smoke.sh

RUN chmod +x /opt/minecraft/bin/*.sh /opt/minecraft/bin/*.py /opt/test/run-paper-plugin-smoke.sh

ENV MINECRAFT_ROOT=/srv/minecraft \
    MINECRAFT_BIN_DIR=/opt/minecraft/bin \
    MINECRAFT_STATE_DIR=/srv/minecraft/state \
    MINECRAFT_CURRENT_DIR=/srv/minecraft/current \
    MINECRAFT_SHARED_DIR=/srv/minecraft/shared \
    MINECRAFT_LOCK_FILE=/srv/minecraft/state/operation.lock \
    ISSUE_77_DATAPACKS=false

WORKDIR /opt/test/repo
CMD ["/opt/test/run-paper-plugin-smoke.sh"]
