FROM eclipse-temurin:25-jre

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl python3 python3-yaml util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system minecraft \
    && useradd --system --gid minecraft --no-create-home --shell /usr/sbin/nologin minecraft

COPY scripts/ /opt/minecraft/bin/
COPY minecraft/ /opt/test/repo/minecraft/
COPY test/staging/server.sh /opt/test/staging/server.sh

RUN chmod +x /opt/minecraft/bin/*.sh /opt/minecraft/bin/*.py /opt/test/staging/server.sh

ENV MINECRAFT_ROOT=/srv/minecraft \
    MINECRAFT_BIN_DIR=/opt/minecraft/bin \
    MINECRAFT_STATE_DIR=/srv/minecraft/state \
    MINECRAFT_CURRENT_DIR=/srv/minecraft/current \
    MINECRAFT_SHARED_DIR=/srv/minecraft/shared \
    MINECRAFT_LOCK_FILE=/srv/minecraft/state/operation.lock

WORKDIR /opt/test/repo
ENTRYPOINT ["/opt/test/staging/server.sh"]
CMD ["serve"]
