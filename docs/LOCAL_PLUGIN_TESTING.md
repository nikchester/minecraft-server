# Local plugin testing (real Paper, in Docker)

How to build and run a real Paper server with a candidate plugin locally,
before that plugin is added to `minecraft/versions.yml` and wired into the
production release pipeline (`scripts/prepare-release.sh`). Tracking issue:
#20 (DiscordSRV's Voice Proximity module).

## Why this exists, and why it's separate from `test/local`

`test/local` (issue #9/#11) runs the deploy/backup/restore *scripts*
end-to-end but explicitly fakes Paper itself -- no real JVM, no real plugin
loading (see `test/local/README.md`, "What this replaces, and what it
doesn't"). It cannot tell you whether a plugin actually loads.

`test/paper-local` does the opposite: it runs the real Paper jar with the
real plugin jar, in a throwaway Docker container, so you can watch it start
up and, if you want, connect a client to it. It does not touch
`scripts/deploy.sh`, `systemd`, or the production VPS, and it is not part of
CI (CI's own Paper smoke test in `.github/workflows/ci.yml` starts a bare
Paper with no plugins, just to confirm the pinned build downloads and
boots).

## Requirements

- Docker Desktop, running.
- Nothing else -- Java lives inside the container, not on your host.

## Running it

```bash
./test/paper-local/run.sh
```

This reads `paper.download_url` and `java.major` out of
`minecraft/versions.yml` (so the local test always matches the pinned
production Paper build), downloads the pinned DiscordSRV release jar, and
starts the server in the foreground with port `25565` published to
`localhost`. Stop it with Ctrl-C; `docker compose -f
test/paper-local/docker-compose.yml down` cleans up afterward.

Compared to `minecraft/server.properties`, the container disables
`enable-rcon`, `white-list`, and `enforce-whitelist` for local convenience
only -- production keeps all three as committed. Nothing in this directory
is read by `scripts/prepare-release.sh` or `scripts/deploy.sh`.

`test/paper-local/cache/` (also `.gitignore`d) is bind-mounted to
`/server/cache`, where Paperclip (`paper.jar`'s own launcher, separate from
the `paper.jar` file itself baked into the image at build time) downloads
and patches the vanilla Mojang server jar on first boot. Persisting it means
recreating the container -- not just restarting it -- doesn't re-download
that every time.

DiscordSRV's own data directory (`plugins/DiscordSRV/`, containing
`config.yml` and `voice.yml`) is bind-mounted to `test/paper-local/data/`
on your machine (`.gitignore`d) so it survives restarts and you can edit it
directly -- see below.

`test/paper-local/entrypoint.sh` also forces three non-secret IDs on every
container start, since none of them grant access on their own without the
bot already invited with the right permissions: `config.yml`'s `Channels`
chat bridge (channel `1551597801933242418`) and `voice.yml`'s `Voice
category` (`1551598654245310494`) and `Lobby channel`
(`1551598909024112726`). These are the project's real, production Discord
server IDs, not disposable test ones -- local runs and production share the
same server/channels. All three are committed and baked into the image,
unlike the bot token below. `Voice enabled` is still `false` by default --
flip that yourself in `test/paper-local/data/DiscordSRV/voice.yml` once
you've set the bot token too (step 3 below); there's no point enabling the
module before the bot can actually connect.

## Verifying the plugin loaded

On first boot, with no configuration, watch the container log for Paper
reaching `Done (...)!` and a `[DiscordSRV]` enable line with no exception.
DiscordSRV starts with `BotToken: "BOTTOKEN"` (a placeholder) and `Voice
enabled: false` in its default config, so on a fresh run it enables in
Bukkit but logs that it isn't properly configured yet -- that's expected,
and confirms the plugin itself loads cleanly against the pinned Paper
build.

**Status (issue #20):** done and fully confirmed against a real bot -- `[JDA]
Login Successful!` / `Connected to WebSocket` / `Enabling voice module` with
no errors, account linking (`/discordsrv link`) works, joining the seeded
lobby channel works, and two linked participants moving apart/together
in-game changes what they hear over the lobby voice channel as expected.
Both players connected over LAN rather than `localhost` for this pass (the
container already publishes `25565` on `0.0.0.0`, so no compose changes were
needed); nothing about the proximity/falloff behavior itself is LAN-specific.

**The bot token is the one piece of this that's an actual secret: don't
commit it, and prefer editing `test/paper-local/data/DiscordSRV/config.yml`
directly over pasting it into chat** -- that path is gitignored specifically
so it never needs to leave your machine. (If a token does end up pasted
into a chat transcript for convenience, treat it as burned and regenerate
it in the Discord Developer Portal afterwards -- a chat transcript isn't a
secret store.)

1. Follow DiscordSRV's own [Initial
   Setup](https://docs.discordsrv.com/installation/initial-setup/) to
   create a Discord application/bot and invite it to the project's real
   Discord server. `Channels`, `Voice category`, and `Lobby channel` are
   already seeded to that server's channels by `entrypoint.sh` (see above);
   you only need the bot's token.
2. Start the container once (`./test/paper-local/run.sh`) so
   `test/paper-local/data/DiscordSRV/config.yml` and `voice.yml` get
   created, then stop it (or leave it running and restart after step 3).
3. Set `BotToken` in `test/paper-local/data/DiscordSRV/config.yml`, and
   `Voice enabled: true` in `voice.yml`.
4. Restart the container (`docker restart paper-local-paper-1`, or re-run
   `./test/paper-local/run.sh`) and confirm in the log that DiscordSRV logs
   in (`[JDA] Login Successful!` / `Connected to WebSocket`) and the voice
   module initializes with no errors.
5. With a Minecraft client connected to `localhost:25565` (or the host's LAN
   IP, for a second physical device) and linked to a Discord account
   (`/discordsrv link`), join the lobby voice channel in Discord and confirm
   two players moving apart/together in-game changes what they hear -- done,
   see "Status" above.

Note that recreating the container (not just restarting it) starts a fresh
world, so an account linked in a previous world needs `/discordsrv link`
again.

## Tiny test world

`test/paper-local/datapacks/tiny-test-world` is a small datapack that
`entrypoint.sh` copies into `world/datapacks/` on every container start (see
the comment there for why this works even though `world/` doesn't exist yet
on a fresh run). It runs once on world load and:

- Centers a 200-block worldborder on spawn (`worldborder center 0 0` /
  `worldborder set 200`) -- enough room to walk fully out of and back into
  DiscordSRV's default proximity range (~85 blocks: `Horizontal Strength 80`
  + `Falloff 5` in `voice.yml`) without leaving a tiny, easy-to-navigate
  area, instead of exploring a full-size world just to test distance
  falloff.
- Sets time to day and clears weather, so testing isn't interrupted by
  nightfall or rain. (A `gamerule doDaylightCycle false` line was here too,
  but that gamerule name doesn't parse in Minecraft 26.2 -- Mojang evidently
  renamed or removed it -- and an unparseable line fails the *entire*
  function, silently skipping the worldborder too, not just that one line.
  Dropped rather than guessed at a replacement name; time stays on a day/
  night cycle for now.)

It only takes effect on a *new* world -- restarting an existing container
keeps its already-generated world (and border) as-is; recreating the
container (`docker compose ... up --build`, or removing the container)
starts a fresh one and re-applies it. It's local-only, like everything else
in this directory: nothing here is copied into a production release.

## In production

Unlike SoundWave (previous candidate, see issue #20 history), DiscordSRV
ships ordinary GitHub Releases that `curl` fine, so adding it to
`minecraft/versions.yml` for real deployment was mechanically the same as
any other pinned plugin (`scripts/prepare-release.sh`'s existing
`download_plugins` step needed no changes).

DiscordSRV (`1.30.5`, pinned the same way as every other plugin) is now in
`minecraft/versions.yml`. `scripts/ensure-discordsrv-config.sh` (wired into
`scripts/deploy.sh`'s `run_deploy`) forces all of the following into
`plugins/DiscordSRV/config.yml`/`voice.yml` on every deploy cycle, so a
plugin update or a hand-edit reverting any of them to their generated
defaults gets corrected on the next tick. On first install, deploy extracts
the complete default files from the selected plugin JAR while Minecraft is
stopped, applies these settings, then starts the server; existing shared
configs are never replaced:

- `BotToken`, rendered from the `DISCORD_BOT_TOKEN` secret (`docs/SECRETS.md`)
  the same way `.github/workflows/deploy.yml` already renders
  `TELEGRAM_BOT_TOKEN`.
- `Channels`, `Voice category`, and `Lobby channel`, pointed at the project's
  real Discord server -- the same IDs `entrypoint.sh` seeds locally (see
  above), not separate test/production values.
- `Voice enabled: true`.
