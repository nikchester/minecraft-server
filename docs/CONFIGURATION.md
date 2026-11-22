# Configuration sources and runtime files

## Source of truth

Configuration authored for the project is versioned in Git. Runtime files are
copied or rendered from these sources by release preparation; operators must
change the repository source and deploy rather than treating files under
`/srv/minecraft/current` or `/srv/minecraft/shared` as durable configuration.

| Git source | Runtime result | Notes |
|---|---|---|
| `minecraft/server.properties` | `/srv/minecraft/releases/<id>/server.properties` | `{{RCON_PASSWORD}}` is rendered by `scripts/render-config.py`. |
| `minecraft/spigot.yml`, `minecraft/bukkit.yml` | `/srv/minecraft/releases/<id>/spigot.yml`, `bukkit.yml` | Mob limits and ranges are versioned and rendered before Paper starts. |
| `minecraft/config/*.yml` | `/srv/minecraft/releases/<id>/config/*.yml` | Paper 26.3 production configs are rendered/copied before server startup. |
| `minecraft/plugins/<plugin>/**` | `/srv/minecraft/shared/plugins/<plugin>/**` | AuthMe, Chunky, CoreProtect, DiscordSRV, DynamicLights and Onlysleep configuration is rendered/copied during release preparation; databases remain persistent runtime state. DiscordSRV's `{{DISCORD_BOT_TOKEN}}` is resolved from runtime secrets. |
| `minecraft/versions.yml` | Release JARs under `/srv/minecraft/releases/<id>/` | Pins Minecraft, Paper, plugin versions, and artifact URLs. |
| `ansible/`, `systemd/`, `scripts/`, `.github/workflows/` | VPS packages, units, and deployment behavior | Installed by provisioning/deploy workflows. |
| `ansible/roles/minecraft/templates/server.properties.j2` | Ansible bootstrap server properties | Bootstrap-time template; normal releases use the source above. |

Worlds, plugin databases, player state, logs, and backups are persistent runtime
data, not configuration sources. Secret values are delivered separately as
files under `/etc/minecraft/secrets/` in production. Locally, the renderer
accepts environment variables or an ignored `.env` file. Never put real secret
values in tracked templates, generated release archives, or test fixtures.

The plugin source directories were imported from the production runtime. Secret
and private values are placeholders rendered from the same `/etc/minecraft/secrets/`
files as Paper's `server.properties`; production deployment provisions them from
the GitHub `production` environment. `scripts/ensure-authme-config.sh` and
`scripts/ensure-dynamiclights-config.sh` remain as idempotent safeguards for
project-specific settings after installation.

Geyser-Spigot and Floodgate are pinned in `minecraft/versions.yml`. Geyser's
committed configuration sets `auth-type: floodgate` and listens on port
`19132` with NetherNet transport; the Ansible firewall role opens both TCP and
UDP. Signaling advertises `minecraft.nikchester.ru:19132` to Bedrock clients,
because STUN on the VPS sees outbound UDP remapped to other ports. Deploy does not touch the firewall; apply firewall changes with the
`Provision VPS` workflow (`docs/OPERATIONS.md`). With AuthMe still enabled, Bedrock players use the same registration/login
flow as other offline-mode accounts.
