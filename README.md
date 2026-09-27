# Minecraft Server Infrastructure

Production-like infrastructure for a small private Minecraft server at `minecraft.nikchester.ru`.

The project intentionally keeps runtime operations simple: one Debian 13 VPS, Paper as a native Java process under systemd, Ansible for provisioning, GitHub Actions for validation/deployment, restic+rclone backups to Yandex Disk, and lightweight Telegram/Healthchecks.io monitoring.

## Status

The server is live and deployed at `minecraft.nikchester.ru:25565`. The full pipeline (provision → deploy → backup → verify) has run end-to-end successfully on production:

- Paper (pinned build, see `minecraft/versions.yml`) running under `minecraft.service`, AuthMeReloaded and CoreProtect loaded.
- RCON bound locally but not exposed (only 22/tcp and 25565/tcp are open in the firewall).
- restic backups to Yandex Disk succeed, verified via `restic snapshots`.
- Telegram and Healthchecks.io alerts confirmed delivering (not just non-error exits), including a direct Telegram alert on a failed backup, not only a Healthchecks.io ping (#6, closed).
- Old release directories under `/srv/minecraft/releases` are pruned after every successful deploy, keeping the newest 5 and always protecting `current-release`/`previous-release` (#7, closed).
- A full `restore.sh` run against a real snapshot has been exercised end-to-end on production, including a pre-restore safety backup; verified whitelist and AuthMe data survive the restore (#8, closed).

## Documents

- `SPEC.md` - implementation contract and requirements.
- `PLAN.md` - phased implementation plan and exit criteria.
- `CONTRIBUTING.md` - branch/PR promotion rules and local verification commands.
- `minecraft-server-architecture.md` - detailed architecture rationale and constraints.
- `docs/OPERATIONS.md` - day-to-day commands and runbooks.
- `docs/LOCAL_PLUGIN_TESTING.md` - run a real Paper server with a candidate plugin locally, before it's added to production.
- `docs/WHITELIST.md` - add, check, and remove whitelist players.
- `docs/BACKUP_RESTORE.md` - backup and restore procedure.
- `docs/DISASTER_RECOVERY.md` - full VPS loss recovery.
- `docs/SECRETS.md` - expected GitHub secret names.
- `docs/CONFIGURATION.md` - configuration source/runtime inventory and migration status.

## Core Constraints

- No Docker or Kubernetes in v1.
- No public RCON.
- No secrets, worlds, databases, logs, or backups in Git.
- No normal deployment kicks players automatically.
- Failed pre-deploy backup blocks deployment.
- AuthMeReloaded is mandatory because `online-mode=false`.
- World rollback after Minecraft version migration requires explicit manual restore.

## Bootstrap Summary

Already done for the current VPS (see Status above); kept here as the procedure for re-provisioning from scratch, e.g. after a full VPS loss (`docs/DISASTER_RECOVERY.md`).

1. Create or confirm a Debian 13 minimal VPS.
2. Point `minecraft.nikchester.ru` to the VPS IP.
3. Add required GitHub Secrets and configure the `production` environment (`docs/SECRETS.md`).
4. Fill `ansible/inventory/production/hosts.yml` from `ansible/inventory/production/hosts.example.yml`.
5. Run Ansible bootstrap (`gh workflow run provision.yml`).
6. Run a deploy (`gh workflow run deploy.yml`) and verify Paper, AuthMe, CoreProtect, backups, and monitoring per the Status checklist above.

See `docs/OPERATIONS.md` and `docs/DISASTER_RECOVERY.md` for detailed commands.

## Local Validation

Install the same tools used in CI when available:

```bash
python3 scripts/validate-repository.py
shellcheck scripts/*.sh
ansible-playbook -i ansible/inventory/production/hosts.example.yml ansible/playbooks/bootstrap.yml --syntax-check
ansible-lint ansible/
```

Run the complete integration suite locally with Docker Desktop running:

```bash
bash test/local/run-all.sh
```

This runs the fast operational scenarios and starts pinned Paper with every
configured production plugin in a disposable container. CI runs the same
command on pull requests and pushes to `main`/`dev`. See `CONTRIBUTING.md` for
the fast-suite-only command and CI boundaries.
