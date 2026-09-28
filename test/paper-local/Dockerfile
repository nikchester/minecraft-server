# Runs a real Paper server with pinned plugins for manual pre-production
# testing. See docs/LOCAL_PLUGIN_TESTING.md. Not part of the production
# release pipeline (scripts/prepare-release.sh) -- this is a throwaway
# container, rebuilt from minecraft/versions.yml each run.

ARG JAVA_MAJOR=25

FROM eclipse-temurin:${JAVA_MAJOR}-jre
ARG PAPER_URL
ARG AUTHME_URL
ARG DISCORDSRV_URL
WORKDIR /server
ADD ${PAPER_URL} /server/paper.jar
ADD ${AUTHME_URL} /server/plugins/AuthMe.jar
ADD ${DISCORDSRV_URL} /server/plugins/DiscordSRV.jar
COPY minecraft/plugins/AuthMe/config.yml minecraft/plugins/AuthMe/welcome.txt /server/plugins/AuthMe/
COPY minecraft/server.properties minecraft/server-icon.png ./
COPY test/paper-local/entrypoint.sh /server/entrypoint.sh
COPY test/paper-local/datapacks/tiny-test-world /server/datapack-template/tiny-test-world
# Local convenience only -- production keeps rcon on and enforces the
# whitelist (minecraft/server.properties); see docs/LOCAL_PLUGIN_TESTING.md.
RUN sed -i \
      -e 's/^enable-rcon=.*/enable-rcon=false/' \
      -e 's/^white-list=.*/white-list=false/' \
      -e 's/^enforce-whitelist=.*/enforce-whitelist=false/' \
      server.properties \
    && printf 'eula=true\n' > eula.txt \
    && chmod +x /server/entrypoint.sh
EXPOSE 25565
ENTRYPOINT ["/server/entrypoint.sh"]
