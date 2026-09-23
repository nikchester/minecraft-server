# Secrets

Secrets are not committed to Git. Values are added manually by the owner to GitHub repository secrets or, where production-only, to the GitHub `production` environment.

## Required Secrets

| Name | Scope | Purpose |
|------|-------|---------|
| `VPS_HOST` | production environment | VPS hostname or IP used by deploy workflows. |
| `VPS_USER` | production environment | SSH user used by deploy workflows. |
| `VPS_SSH_KEY` | production environment | Private SSH deploy key for GitHub Actions. |
| `RCON_PASSWORD` | production environment | Local-only RCON password rendered on the VPS. |
| `RESTIC_PASSWORD` | production environment | restic repository encryption password. |
| `YANDEX_RCLONE_CONFIG` | production environment | rclone config content for Yandex Disk remote. |
| `TELEGRAM_BOT_TOKEN` | production environment | Telegram bot token for alerts. |
| `TELEGRAM_CHAT_ID` | production environment | Telegram chat ID for owner alerts. |
| `DISCORD_BOT_TOKEN` | production environment | DiscordSRV bot token, rendered into `plugins/DiscordSRV/config.yml`'s `BotToken` on every deploy cycle (issue #20); the config is restricted to the Minecraft service account. |
| `HEALTHCHECKS_VPS_URL` | production environment | Healthchecks.io heartbeat URL for VPS liveness. |
| `HEALTHCHECKS_BACKUP_URL` | production environment | Healthchecks.io job URL for backup monitoring. |

Current project status: the owner reported that all required secrets have been added to the `production` environment.

## Runtime Secret Files

Automation renders runtime secret files under `/etc/minecraft/secrets/` with restrictive permissions. Files under that directory must never be copied into the repository.

## Rotation

Rotate a secret by updating GitHub Secrets, re-running the relevant deployment/provisioning workflow, and verifying the affected function. If a secret may have been committed, revoke it immediately and rewrite it with a new value.
