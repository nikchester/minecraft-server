# Backup And Restore

## Backup Policy

- Scheduled backups run every 6 hours.
- A pre-deploy backup is mandatory before any deployment that can change runtime state.
- Backups are encrypted with restic and uploaded to Google Drive through rclone.
- A failed pre-deploy backup blocks deployment.

## Current Provider And History (2026-10-28)

Production has switched to Google Drive; a snapshot in the new restic repository
has been verified. Current runtime config has the sole remote `[gdrive]` with
`type = drive`, so backup and restore discover `gdrive` and use
`rclone:gdrive:minecraft-restic`. The existing GitHub production secret
`YANDEX_RCLONE_CONFIG` now holds that Google config. Its legacy name is retained
so the next deployment continues to install the Google config without a secret
rename. See `docs/SECRETS.md` for the offline deploy preflight contract.

Old Yandex Disk snapshots were **not migrated**; they remain preserved in the old
repository and are not listed by the new Google repository. Do not delete the old
repository or treat Google history as containing those snapshots. Restoring an
old Yandex snapshot requires a separately authorized operation with the old
repository configuration and credentials; normal deployment must not switch back.
Changing providers does not change the retention policy or initialize/migrate a
repository as part of this configuration guard.

## Backup Contents

Backups include mutable state required to reconstruct the Minecraft service:

- `world/`
- `world_nether/`
- `world_the_end/`
- plugin runtime data
- AuthMe data
- CoreProtect SQLite database
- whitelist, bans, ops
- runtime config not reproducible from Git

Paper and plugin JARs are normally reproduced from pinned metadata and are not the primary purpose of backups.

## Retention

Initial restic retention policy:

```text
4 snapshots/day for 7 days
1 snapshot/day for 30 days
1 snapshot/month for 6 months
```

## Manual Backup

```bash
sudo /opt/minecraft/bin/backup.sh scheduled
```

## Full Restore V1

Selective restore is out of scope for v1. The restore workflow restores full mutable state from a selected restic snapshot.

High-level restore flow:

1. Acquire global operation lock.
2. Stop Minecraft.
3. Restore selected snapshot into the mutable state location.
4. Start Minecraft.
5. Verify service health.
6. Notify owner.

Use `.github/workflows/restore-backup.yml` for owner-confirmed restore from GitHub Actions.
