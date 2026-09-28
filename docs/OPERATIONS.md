# Operations Runbook

## Service Commands

```bash
sudo systemctl status minecraft
sudo systemctl restart minecraft
sudo journalctl -u minecraft -n 200 --no-pager
sudo journalctl -u minecraft -f
```

## Health Checks

```bash
sudo /opt/minecraft/bin/healthcheck.sh
sudo /opt/minecraft/bin/player-count.sh
```

Health is not based on systemd alone. The health check must also perform a Minecraft status ping and verify required plugins where practical.

## Deployment Flow

Normal deployment happens through GitHub Actions after merge to `main` and manual approval of the `production` environment.

The VPS-side controller waits until the server is empty, waits an additional 5-minute grace period, creates a pre-deploy backup, deploys the release, verifies health, and rolls back binaries/configuration if verification fails.

## Project Releases And Versioning

Project releases use Semantic Versioning in the form `vMAJOR.MINOR.PATCH` (for example, `v1.4.2`). The first published project release establishes the baseline as `v1.0.0`. These numbers describe changes to the project/server experience; they are separate from the Minecraft, Paper, Java, and plugin versions pinned in `minecraft/versions.yml`.

Every change merged to `main` is included in a project release, including changes limited to CI, infrastructure, or documentation. Such changes normally increment PATCH. After a successful production deployment (CD), GitHub Actions creates or updates a release draft. The initial draft is `v1.0.0`; after the first stable release is published, later versions are resolved from the PR labels since the previous published release. The draft is reviewed and published manually. Telegram announcements are sent manually.

Each pull request should have exactly one SemVer label: `release:major`, `release:minor`, or `release:patch`. The label sets the version increment; when changes of different levels are combined into one release, Release Drafter chooses the highest level. Missing release labels fall back to PATCH, so every merged change still appears in the draft. Add `area:infrastructure` to a PR whose changes are operational or internal (for example CI, Ansible, backups, or documentation); it places that PR in the **Reliability and infrastructure** section. Other PRs are grouped into player-facing sections based on their SemVer label. Review the generated notes and adjust them for clarity before publishing.

Choose the increment based on the most significant change in the release:

- **MAJOR** (`v1.4.2` → `v2.0.0`): a breaking change to the established server experience that requires substantial player action or changes compatibility in a way players must account for. Examples include resetting or requiring a substantial migration of the world, changing access/authentication in a way that requires players to re-register or change how they connect, or a major rules/gameplay change that materially changes how the server is played. A Minecraft version upgrade is not automatically MAJOR; assess its actual impact on the world and players.
- **MINOR** (`v1.4.2` → `v1.5.0`): a new player-facing feature or meaningful gameplay expansion that remains compatible with the existing world and normal connection flow. Examples include adding a gameplay feature such as allowing a configured share of online players to skip the night.
- **PATCH** (`v1.4.2` → `v1.4.3`): bug fixes, small configuration adjustments, compatible plugin updates, and improvements limited to infrastructure, CI, operations, or documentation that do not introduce a new player-facing feature or a breaking change.

When a release contains changes from multiple categories, use the highest applicable increment: MAJOR takes precedence over MINOR, and MINOR over PATCH. Reset all lower components when incrementing a higher one (for example, `v1.4.2` → `v1.5.0` for MINOR, and `v1.4.2` → `v2.0.0` for MAJOR). Do not create multiple project versions for separate commits that are part of the same release draft.

Release notes should distinguish player-visible changes from operational work. Use sections such as **For players** and **Reliability and infrastructure**; include CI, Ansible, backup, deployment, and documentation changes in the latter when useful, even if there is nothing to report in the player section. Keep internal implementation detail concise and describe its practical effect where possible.

## Force Deploy

Use force deploy only for owner-approved emergencies. It may bypass player waiting, but still requires a successful pre-deploy backup and health verification.

## AuthMe Password Reset

AuthMe password recovery is manual in v1:

1. Verify the player identity outside Minecraft.
2. Use the AuthMe administrative command or documented plugin data procedure to reset the password.
3. Ask the player to log in and set a new password.
4. Do not automate self-service recovery in v1.

## Disk Pressure

Initial thresholds:

- warning: 80%
- critical: 90%

If disk is high, inspect world growth, logs, CoreProtect SQLite size, local releases, and temporary backup files. Do not delete current or previous known-good release while investigating deploy issues.

## Version Updates

Paper release preparation uses `paper.download_url` from `minecraft/versions.yml` when present. The current Paper artifact requires Java 25 or newer, so Java 25 is the pinned runtime target. The automated Paper update checker is disabled while a direct artifact URL is configured. Minecraft version upgrades are manual and require extra caution because world data may migrate. Plugin updates are manual in v1.

## OP And Whitelist

Initial OP and whitelist entries are managed manually through Minecraft console/RCON commands after bootstrap. Do not commit generated `ops.json` or `whitelist.json` runtime files to Git.
