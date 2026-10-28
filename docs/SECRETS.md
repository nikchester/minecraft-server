# Secrets

Secrets are not committed to Git. Values are added manually by the owner to GitHub repository secrets or, where production-only, to the GitHub `production` environment.

## Required Secrets

| Name | Scope | Purpose |
|------|-------|---------|
| `VPS_HOST` | production environment | VPS hostname or IP used by deploy workflows. |
| `VPS_USER` | production environment | SSH user used by deploy workflows. |
| `VPS_SSH_KEY` | production environment | Private SSH deploy key for GitHub Actions. |
| `RCON_PASSWORD` | production environment | Local-only RCON password rendered on the VPS. |
| `MANAGEMENT_SERVER_SECRET` | production environment | Minecraft management server secret. |
| `AUTHME_MYSQL_PASSWORD` | production environment | AuthMe's configured MySQL password. |
| `RESTIC_PASSWORD` | production environment | restic repository encryption password. |
| `YANDEX_RCLONE_CONFIG` | production environment | Legacy name: complete rclone config for the sole Google Drive remote (`[gdrive]`, `type = drive`), including OAuth token JSON with `refresh_token`. |
| `TELEGRAM_BOT_TOKEN` | production environment | Telegram bot token for alerts. |
| `TELEGRAM_CHAT_ID` | production environment | Telegram chat ID for owner alerts. |
| `DISCORD_BOT_TOKEN` | production environment | DiscordSRV bot token, rendered into `plugins/DiscordSRV/config.yml`'s `BotToken` on every deploy cycle (issue #20); the config is restricted to the Minecraft service account. |
| `HEALTHCHECKS_VPS_URL` | production environment | Healthchecks.io heartbeat URL for VPS liveness. |
| `HEALTHCHECKS_BACKUP_URL` | production environment | Healthchecks.io job URL for backup monitoring. |

Current project status: the owner reported that all required secrets have been added to the `production` environment.

### Backup provider (2026-10-28)

Production backups now use Google Drive. Keep the existing production secret name
`YANDEX_RCLONE_CONFIG` for backward compatibility; its value is Google Drive config,
not Yandex credentials. Deploy maps it to `BACKUP_RCLONE_CONFIG` and writes
`/etc/minecraft/secrets/rclone.conf`, preserving multiline content and JSON quotes
(CRLF is normalized to LF for runtime remote discovery). No GitHub secret rename
is required for the next deployment.

Before SSH or runtime secret transfer, deploy runs offline regression tests and
`scripts/validate-backup-config.py --env BACKUP_RCLONE_CONFIG`. It requires exactly
one runtime-compatible remote with `type = drive` and a JSON token containing a
nonempty `refresh_token`. The remote name is not hardcoded: backup and restore
discover the first section. Multiple remotes are rejected to avoid selecting the
wrong provider. `client_id`, `client_secret`, `root_folder_id` and a specific scope
are not required by this structural check; `drive.file` is accepted. See
[rclone Drive documentation](https://rclone.org/drive/) for optional OAuth settings.
The preflight never prints config/token values and does not contact Google: it
cannot verify token validity, permissions, quota, or repository identity.

## Runtime Secret Files

Automation renders runtime secret files under `/etc/minecraft/secrets/` with restrictive permissions. Files under that directory must never be copied into the repository.

For local release preparation, set the required secret as an environment
variable (for example, `RCON_PASSWORD`) or place it in the ignored project
`.env` file as `RCON_PASSWORD=value`. `scripts/render-config.py` uses the same
tracked template as production, gives rendered files mode `0600`, and fails
when a required value is missing. Do not use a real production secret in local
tests or commit `.env`.

Before deploying this branch, ensure `MANAGEMENT_SERVER_SECRET` and
`AUTHME_MYSQL_PASSWORD` exist in the GitHub `production` environment. Empty
AuthMe mail, GeoIP and LoginSecurity MySQL settings stay empty in the tracked
configuration and do not need GitHub secrets unless those features are enabled.

GitHub secret values cannot be downloaded with `gh` or read by a local process.
For local Paper smoke testing, use the disposable fallback values or provide
local-only values via exported environment variables or the ignored root `.env`
file. A safe pre-deploy check of the actual `production` secrets is tracked in
issue #31.

## Rotation

Rotate a secret by updating GitHub Secrets, re-running the relevant deployment/provisioning workflow, and verifying the affected function. If a secret may have been committed, revoke it immediately and rewrite it with a new value.
