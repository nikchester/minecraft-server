# Plugins

Plugin JAR files are not committed. Versions are declared in `../versions.yml` and are installed during release preparation.

Required plugins for v1:

- AuthMeReloaded — its committed `config.yml` keeps `settings.restrictions.timeout: 60` and `settings.restrictions.maxRegPerIp: 0`; release preparation renders it into persistent plugin data, and `scripts/ensure-authme-config.sh` also checks these settings on deploy ticks.
- CoreProtect
- SkinsRestorer — players can use `/skin set <licensed-account-name>` to copy a Minecraft account's skin; `/skin clear` restores their account skin. Its first start generates the plugin's default configuration in persistent plugin data. See the [SkinsRestorer player guide](https://skinsrestorer.net/docs/features/change-skin).
- Onlysleep — the pinned 1.4.2 build skips the night once 50% of eligible players in that world are sleeping (rounded up). Its settings and Russian player-facing messages are committed under `Onlysleep/`; the shared bStats config opts out of metrics.

Optional administrative plugin:

- Chunky

Optional gameplay plugin:

- Dynamic Lights — held/worn light sources illuminate the world around a player without placing blocks. Its committed `config.yml` keeps `track_mobs: false`; `scripts/ensure-dynamiclights-config.sh` also checks this setting on deploy ticks.

Optional communication plugin (issue #20):

- DiscordSRV — its committed `config.yml` and `voice.yml` pin the chat channel and proximity voice settings; release preparation renders `DISCORD_BOT_TOKEN` from the environment or `/etc/minecraft/secrets/discord_bot_token` (`../../docs/SECRETS.md`). The config is based on the pinned 1.30.5 upstream defaults. Local live testing confirmed bot login, chat relay, and two-player proximity voice. See `../../docs/LOCAL_PLUGIN_TESTING.md` for the test setup and production configuration details.
