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

## Google Drive OAuth Token Expired Or Revoked

Symptom: Telegram alerts `backup (scheduled) failed: Google Drive OAuth token
expired or revoked (invalid_grant)` and, after 24 hours, `backup is stale`. The
`minecraft-backup.service` journal contains rclone's
`oauth2: "invalid_grant" "Token has been expired or revoked."`. Retrying cannot
help: only a new OAuth token restores backups.

Root cause seen in production (issue #80): the Google Cloud OAuth consent screen
of the rclone client was in **Testing** publishing status. Google expires refresh
tokens issued to such clients after 7 days. The token issued on 2026-10-28 stopped
working on 2026-11-04.

Fix applied on 2026-11-06: a dedicated Google Cloud project
`minecraft-backup-rclone` with the Desktop OAuth client `rclone-minecraft-vps` and
Google Drive API enabled. Its consent screen is **In production**: Google allowed
publishing only after Branding had a home page (`https://nikchester.ru/`), a privacy
policy (`https://nikchester.ru/minecraft/privacy/`) and the authorized domain
`nikchester.ru`. With the non-sensitive `drive.file` scope no Google verification
is needed. A `drive.file` client sees only files it created, so this client writes
a new `minecraft-restic` repository. Snapshots from 2026-10-28 to 2026-11-04 stay in
the old client's folder of the same name.

Recovery:

1. In Google Cloud Console, open *Google Auth Platform → Audience* for the project
   that owns the rclone `client_id`. Make sure its status is **In production**.
   Without it the new token also expires in 7 days.
2. On a workstation with a browser, run
   `rclone authorize "drive" "<client_id>" "<client_secret>"` with the same client
   as in production, and approve access with the Google account that owns the
   backup folder. Use the same scope as production (`drive.file`), otherwise the
   existing `minecraft-restic` folder created by this client is not visible.
3. Replace only the `token = {...}` line of the `[gdrive]` remote with the JSON
   that `rclone authorize` printed. Keep all other lines unchanged.
4. Store the full updated config in the GitHub `production` environment secret
   `YANDEX_RCLONE_CONFIG`. Do this before step 5: every deployment overwrites
   `/etc/minecraft/secrets/rclone.conf` from this secret.
5. Run the `Deploy` workflow on `main` (`workflow_dispatch`).
   `deploy-request.sh` installs the new `rclone.conf` before the pre-deploy backup.
6. On the VPS, run `sudo systemctl start minecraft-backup.service` and check
   `journalctl -u minecraft-backup.service -n 30` for `backup completed`.
7. Wait for the next `minecraft-healthcheck.timer` run and confirm that the
   `backup stale` alerts stop.

`backup.sh` runs `restic init` only when restic exits with code 10 (repository
does not exist). An authentication or network failure never initializes a new
repository.

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
