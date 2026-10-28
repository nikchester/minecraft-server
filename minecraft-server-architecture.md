# Minecraft Server Infrastructure Architecture

> **Status:** Architecture v1
> **Purpose:** Implementation specification for an AI coding agent / DevOps agent
> **Target:** Single small production-like Minecraft server for a private group of friends
> **Hosting model:** One VPS
> **Primary goals:** simplicity, reproducibility, safe updates, automatic recovery, backups, observability, and portfolio-quality engineering without unnecessary complexity

> **Companion documents:** `SPEC.md` is the implementation contract. `PLAN.md` is the phased build plan. This architecture document remains the detailed design rationale and constraint source.

> **Backup provider update (2026-10-28):** Google Drive is current. The legacy
> production secret `YANDEX_RCLONE_CONFIG` now holds the sole Google remote;
> old Yandex snapshots are preserved separately, not migrated. See
> `docs/BACKUP_RESTORE.md` and `docs/SECRETS.md`.

---

## 1. Project Overview

This project provisions and operates a small Minecraft server with a production-like DevOps workflow.

The server is intended for a private group of friends and should remain close to vanilla gameplay while allowing lightweight plugins required for authentication, auditing, backups, and administration.

The architecture deliberately avoids unnecessary complexity such as Kubernetes, Docker, Prometheus, Grafana, external databases, and large management panels.

The project must be reproducible from Git and backups.

Additional clarified implementation decisions:

- The VPS already exists and is provisioned over SSH; creating VPS infrastructure is out of scope for v1.
- GitHub Secrets and the GitHub `production` Environment are pre-provisioned and are part of the disaster-recovery source set.
- The implementation agent selects the latest stable Minecraft version, then pins Minecraft, Paper, Java, and plugin versions in repository metadata.
- Backup, deployment, force deployment, and restore share one global operation lock.
- AuthMe password recovery is an owner-only manual reset after out-of-game identity verification.
- Restore workflow v1 performs full mutable-state restore only.
- v1 update automation creates Paper update PRs only; plugin update automation is deferred.
- Recovery targets are best effort for a private server: RPO up to 24 hours is acceptable, and RTO is best effort.

### Main characteristics

- Vanilla-like survival server
- Maximum expected concurrent players: **5**
- Server available **24/7**
- Latest stable Minecraft version supported by the selected Paper release
- Paper server implementation
- Native Java process managed by systemd
- Debian 13 minimal
- One VPS
- Public GitHub repository
- Infrastructure managed with Ansible
- CI/CD using GitHub Actions
- GitHub-hosted runners for CI
- Player-aware deployments
- Telegram alerts
- External availability monitoring via Healthchecks.io
- Encrypted offsite backups to Google Drive using restic + rclone

---

# 2. Architecture Principles

The implementation should follow these principles:

1. **Keep the runtime simple**
   - Paper runs directly as a systemd service.
   - No Docker unless a future requirement justifies it.

2. **Infrastructure must be reproducible**
   - A new Debian VPS should be convertible into a working Minecraft server using Ansible and GitHub Actions.

3. **Git is the source of truth for configuration**
   - Infrastructure code, Paper configuration, plugin versions, scripts, systemd units, and workflows live in Git.
   - Mutable runtime data does not live in Git.

4. **Production changes must be validated**
   - No direct deployment from untested changes.
   - CI must pass before production deployment is possible.

5. **Deployments must not interrupt players**
   - Normal deployments wait until the server is empty.
   - Players are never automatically kicked.

6. **Backups are mandatory before destructive changes**
   - A failed pre-deploy backup blocks deployment.

7. **Automatic recovery should be conservative**
   - Ordinary failed deployments may roll back automatically.
   - World rollback after a Minecraft major/minor world-format upgrade requires explicit manual confirmation.

8. **Monitoring should be lightweight**
   - systemd, shell/Python scripts, Minecraft status ping, Telegram, and Healthchecks.io.
   - No large monitoring stack on the 4 GB VPS.

9. **Security should be reasonable for a small private server**
   - SSH keys only.
   - No root SSH login.
   - No password SSH authentication.
   - RCON is local only.
   - Secrets stored in GitHub Secrets.

---

# 3. High-Level Architecture

```text
                          ┌────────────────────────────┐
                          │        GitHub Repo         │
                          │                            │
                          │ Ansible                    │
                          │ Paper configs              │
                          │ Plugin manifest            │
                          │ Scripts                    │
                          │ systemd units/timers       │
                          │ GitHub Actions             │
                          └─────────────┬──────────────┘
                                        │
                              PR / CI / Approval
                                        │
                                        ▼
                          ┌────────────────────────────┐
                          │      GitHub Actions        │
                          │                            │
                          │ lint / validate            │
                          │ Paper smoke test           │
                          │ release preparation        │
                          │ deploy request             │
                          └─────────────┬──────────────┘
                                        │ SSH
                                        ▼
┌────────────────────────────────────────────────────────────────────┐
│                          Debian 13 VPS                             │
│                                                                    │
│  ┌────────────────────┐        ┌────────────────────────────────┐  │
│  │ minecraft.service  │        │ Deployment Controller          │  │
│  │                    │        │                                │  │
│  │ Paper              │◄──────►│ player-count check             │  │
│  │ AuthMeReloaded     │ RCON   │ 5-minute empty grace period    │  │
│  │ CoreProtect        │ local  │ pre-deploy backup              │  │
│  │                    │ only   │ deploy                         │  │
│  └──────────┬─────────┘        │ verify                         │  │
│             │                  │ rollback                       │  │
│             │                  └────────────┬───────────────────┘  │
│             │                               │                      │
│             ▼                               ▼                      │
│       World / plugin data             Telegram Alerts             │
│             │                                                      │
│             ▼                                                      │
│        restic backup                                                 │
│             │                                                      │
│             ▼                                                      │
│         rclone                                                     │
└─────────────┼──────────────────────────────────────────────────────┘
              │
              ▼
      ┌───────────────────┐
      │   Google Drive    │
      │ encrypted restic  │
      │ repository        │
      └───────────────────┘


VPS heartbeat ───────────────► Healthchecks.io ─────────► Telegram
Backup heartbeat ────────────► Healthchecks.io ─────────► Telegram
```

---

# 4. Server Runtime

## 4.1 Operating System

Use:

```text
Debian 13 minimal
```

The OS should be kept intentionally minimal.

Do not install desktop packages or unrelated services.

---

## 4.2 Minecraft Runtime

Use:

- Paper
- Latest stable Paper build compatible with the selected Minecraft version
- Java version required by that Paper release
- Java version must be explicitly pinned/documented in the repository

Do not blindly use `latest` during production deployment.

The selected Minecraft version, Paper build, plugin versions, and Java major version must be declared in version-controlled metadata.

Example:

```yaml
minecraft:
  version: "PINNED_VERSION"

paper:
  build: "PINNED_BUILD"

java:
  major: "REQUIRED_MAJOR_VERSION"
```

---

## 4.3 Native systemd Deployment

Paper runs directly on the host.

Do not use Docker.

Suggested directory layout:

```text
/srv/minecraft/
├── current/
│   ├── paper.jar
│   ├── server.properties
│   ├── config/
│   ├── plugins/
│   ├── world/
│   ├── world_nether/
│   ├── world_the_end/
│   └── ...
│
├── releases/
│   ├── <release-id-1>/
│   ├── <release-id-2>/
│   └── ...
│
├── shared/
│   ├── world/
│   ├── world_nether/
│   ├── world_the_end/
│   └── plugin-runtime-data/
│
└── state/
    ├── deploy-pending
    ├── current-release
    └── previous-release
```

The exact release layout may be adjusted during implementation, but deployments must support rollback of binaries/configuration.

---

## 4.4 Minecraft Service User

Create a dedicated Unix user:

```text
minecraft
```

Requirements:

- no interactive administrative privileges
- no unrestricted sudo
- owns Minecraft runtime directories
- runs `minecraft.service`

---

## 4.5 Java Memory

Target VPS size:

```text
2 vCPU
4 GB RAM
```

Initial Java heap target:

```text
-Xms2G
-Xmx3G
```

Do not allocate all 4 GB to the Java heap.

Memory must remain available for:

- Linux
- JVM native memory
- filesystem cache
- SSH
- restic/rclone during backup
- system services

Heap values should be configurable from Ansible variables.

---

# 5. Minecraft Gameplay Configuration

## 5.1 Server Type

The gameplay target is:

```text
vanilla-like survival
```

Avoid gameplay-changing plugins unless a real need appears.

Performance-related gameplay changes are acceptable only if the current VPS is unable to provide acceptable performance.

---

## 5.2 Player Limit

Configure:

```properties
max-players=15
```

---

## 5.3 Offline Authentication

Because the server must allow non-premium/offline clients:

```properties
online-mode=false
```

This creates an identity spoofing risk, therefore authentication is mandatory.

Use:

```text
AuthMeReloaded
```

Expected player flow:

```text
First login:
 /register <password> <password>

Later logins:
 /login <password>
```

---

## 5.4 Whitelist

Whitelist is enabled.

Whitelist is based on Minecraft identities, not IP addresses.

Players may connect from changing IP addresses.

Configure:

```properties
white-list=true
enforce-whitelist=true
```

Whitelist and AuthMe serve different purposes:

- whitelist limits who is allowed to join
- AuthMe verifies the person controlling an allowed nickname

---

## 5.5 Administration

Use normal Minecraft `op` for the server owner.

Do not install LuckPerms in v1.

OP should be granted only to trusted administrators.

---

# 6. Plugins

Keep the plugin set minimal.

## Required plugins

### AuthMeReloaded

Purpose:

- registration
- login
- offline-mode account protection

### CoreProtect

Purpose:

- audit block changes
- investigate player actions
- rollback accidental or malicious changes

Use SQLite for CoreProtect.

Retention target:

```text
30 days
```

Old CoreProtect records should be purged automatically.

---

## Optional administrative plugin

### Chunky

Use if world pre-generation is required.

Chunky is not required for normal runtime functionality.

It may be installed temporarily or permanently depending on operational convenience.

---

## Optional gameplay plugin

### Dynamic Lights

Purpose:

- held/worn light sources (torches, lanterns, etc.) illuminate nearby blocks without placing them, purely via phantom light packets

Configuration requirement:

```yaml
track_mobs: false
```

Mobs must not emit dynamic light from held/worn light sources (e.g. a zombie holding a torch); only players do. This config lives in the plugin's own, uncommitted data directory and is self-healed to `track_mobs: false` on every deploy cycle by `scripts/ensure-dynamiclights-config.sh`, since the plugin regenerates its config with `track_mobs: true` by default.

---

# 7. RCON

Enable RCON for automation.

Use cases:

- `save-all flush`
- `say`
- `stop`
- controlled administrative commands

RCON must not be exposed publicly.

Desired model:

```text
RCON listens only on localhost
127.0.0.1:<rcon-port>
```

External firewall must block the RCON port.

The RCON password is stored in GitHub Secrets and deployed to the server.

---

# 8. Network and Firewall

Publicly exposed services:

```text
SSH        TCP 22
Minecraft  TCP 25565
```

RCON is local only.

Suggested firewall policy:

```text
default deny incoming
default allow outgoing

allow 22/tcp
allow 25565/tcp
```

If the SSH port is changed later, the repository and documentation must be updated.

---

# 9. SSH Security

Requirements:

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

The owner connects using SSH keys.

Do not restrict SSH by source IP because the owner frequently changes networks.

Create separate keys per purpose.

Example:

```text
owner-laptop
github-deploy
```

Do not reuse the owner's private key for GitHub Actions.

---

# 10. DNS

The owner has an existing domain.

A dedicated subdomain will be created, for example:

```text
mc.example.com
```

DNS configuration itself may remain outside this repository unless automated later.

The Minecraft server should not depend on the raw VPS IP in user-facing documentation.

---

# 11. Git Repository

Repository visibility:

```text
PUBLIC
```

The repository must be safe to expose publicly.

Never commit secrets, world files, databases, logs, or backups.

Suggested repository structure:

```text
minecraft-infra/
├── README.md
├── docs/
│   ├── ARCHITECTURE.md
│   ├── OPERATIONS.md
│   ├── BACKUP_RESTORE.md
│   └── DISASTER_RECOVERY.md
│
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── production/
│   ├── group_vars/
│   ├── playbooks/
│   │   ├── bootstrap.yml
│   │   ├── minecraft.yml
│   │   └── restore.yml
│   └── roles/
│       ├── base/
│       ├── java/
│       ├── minecraft/
│       ├── firewall/
│       ├── backup/
│       ├── monitoring/
│       └── deployment/
│
├── minecraft/
│   ├── server.properties
│   ├── config/
│   │   ├── paper-global.yml
│   │   └── paper-world-defaults.yml
│   ├── plugins/
│   │   ├── AuthMe/
│   │   ├── Chunky/
│   │   ├── CoreProtect/
│   │   └── DynamicLights/
│   └── versions.yml
│
├── scripts/
│   ├── deploy.sh
│   ├── rollback.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── healthcheck.sh
│   ├── player-count.sh
│   ├── pending-deploy.sh
│   └── telegram.sh
│
├── systemd/
│   ├── minecraft.service
│   ├── minecraft-healthcheck.service
│   ├── minecraft-healthcheck.timer
│   ├── minecraft-backup.service
│   ├── minecraft-backup.timer
│   ├── minecraft-deploy.service
│   └── minecraft-deploy.timer
│
└── .github/
    └── workflows/
        ├── ci.yml
        ├── check-updates.yml
        ├── deploy.yml
        ├── force-deploy.yml
        └── restore-backup.yml
```

The agent may improve the exact layout, but must preserve separation of concerns.

---

# 12. Git Workflow

## 12.1 Main Branch

`main` represents the desired production state.

Direct production deployment from arbitrary branches is prohibited.

Preferred flow:

```text
feature branch
    ↓
Pull Request
    ↓
CI
    ↓
merge to main
    ↓
manual production approval
    ↓
deployment request
```

---

## 12.2 Approval Model

This is a single-maintainer project.

Do not require a second GitHub user to approve every PR.

Instead:

1. PR must pass all required CI checks.
2. Merge to `main`.
3. Production deployment uses a GitHub Environment.
4. The owner manually approves production deployment.

Production deployment must not happen before this approval.

---

# 13. CI Pipeline

CI must run on GitHub-hosted runners.

Do not install a permanent self-hosted GitHub Actions runner on the Minecraft VPS.

CI should run:

- on Pull Requests
- on pushes to development branches where appropriate
- optionally on `main` for verification

## Required CI checks

### Infrastructure

- YAML validation
- Ansible syntax check
- `ansible-lint`
- shell script linting with `shellcheck`
- formatting checks where applicable

### Security

- secret scanning
- fail CI if obvious credentials are committed

Possible tools:

- gitleaks
- GitHub secret scanning if available

### Repository consistency

Validate:

- required files exist
- plugin manifest is valid
- version metadata is valid
- no runtime/world files are tracked

### Paper smoke test

A GitHub-hosted Ubuntu runner must:

1. install the required Java version
2. download the pinned Paper build
3. install/configure required test plugins where feasible
4. accept the EULA in the temporary test environment
5. start Paper
6. wait for successful startup
7. perform a Minecraft status ping
8. fail if Paper crashes or does not become healthy
9. stop the test server cleanly

The smoke test must never use the production VPS.

---

# 14. Update Automation

## 14.1 Paper Build Updates

A scheduled GitHub Actions workflow should check for newer compatible Paper builds.

Target cadence:

```text
once per day
```

When a newer Paper build exists:

```text
create or update Pull Request
```

Do not automatically merge.

Flow:

```text
new Paper build
    ↓
automated PR
    ↓
CI
    ↓
owner reviews / merges
    ↓
manual production approval
    ↓
player-aware deployment
```

---

## 14.2 Plugin Updates

Where technically reliable, perform similar automated update checks for:

- AuthMeReloaded
- CoreProtect
- optional Chunky

Plugin versions must be pinned.

Do not silently download arbitrary latest plugin versions during production startup.

---

## 14.3 Minecraft Version Updates

A new Minecraft version must never be deployed automatically.

The automation may create a PR announcing/updating the version metadata.

The owner must explicitly approve and merge it.

Major/minor Minecraft upgrades must trigger stricter backup and rollback behavior.

---

# 15. Deployment Model

## 15.1 Normal Deployment

After merge to `main` and manual production approval:

1. Build/prepare release metadata.
2. Transfer or make the release available to the VPS.
3. Mark deployment as:

```text
PENDING
```

4. The VPS deployment controller checks player count.
5. If players are online:
   - do nothing destructive
   - keep deployment pending
   - never kick players
6. Once player count becomes zero:
   - start a 5-minute grace period
7. If a player reconnects during the grace period:
   - cancel the countdown
   - return to waiting state
8. If the server remains empty for the full 5 minutes:
   - run pre-deploy backup
9. If backup fails:
   - abort deployment
   - alert owner
10. If backup succeeds:
   - deploy release
11. Start Minecraft.
12. Run health checks.
13. If healthy:
   - mark deployment successful
14. If unhealthy:
   - trigger automatic release rollback
15. Start previous release.
16. Verify previous release health.
17. Notify owner.

---

# 16. Deployment State Machine

Suggested states:

```text
PENDING
  ↓
WAITING_FOR_EMPTY_SERVER
  ↓
EMPTY_GRACE_PERIOD
  ↓
BACKUP
  ↓
DEPLOYING
  ↓
VERIFYING
  ├── SUCCESS
  └── FAILED
        ↓
      ROLLBACK
        ↓
      VERIFY_ROLLBACK
        ├── ROLLED_BACK
        └── CRITICAL_FAILURE
```

State should be persisted on disk so a reboot does not lose deployment context.

---

# 17. Pending Deployment Notifications

Players must never be kicked automatically.

If a deployment remains pending for more than:

```text
24 hours
```

send:

- Telegram notification to the owner
- in-game notification to online players

After that:

- repeat in-game notification every **6 hours**
- repeat Telegram notification every **24 hours**

Example in-game message:

```text
An approved server update is waiting to be installed.
It will be installed automatically after all players leave.
```

The message must not imply that players are required to leave immediately.

---

# 18. Force Deploy

Provide a manually triggered GitHub Actions workflow:

```text
Force Deploy
```

This workflow is for emergency use.

It may bypass the "wait until zero players" policy only when explicitly triggered by the owner.

It must still:

- create a pre-deploy backup
- abort if backup fails
- send Telegram notification
- perform health verification
- roll back automatically if the ordinary release rollback is safe

A force deployment must be clearly marked in logs and Telegram.

---

# 19. Backups

## 19.1 Backup Stack

Use:

```text
restic
  ↓
rclone
  ↓
Google Drive
```

The restic repository must be encrypted.

---

## 19.2 Backup Schedule

Create backup:

```text
every 6 hours
```

Also create backup:

```text
before every deployment
```

---

## 19.3 Backup Contents

Backup all state required to reconstruct the Minecraft service.

Include:

- `world/`
- `world_nether/`
- `world_the_end/`
- plugin runtime data
- AuthMe data
- CoreProtect SQLite database
- whitelist
- bans
- ops
- Minecraft runtime configuration that is not reproducible from Git
- any mutable data required for recovery

Do not waste backup space on reproducible binaries/cache where unnecessary.

Paper JARs and plugin JARs should generally be recoverable from version metadata and Git.

---

## 19.4 Consistent Backup Procedure

Before backup:

```text
RCON: save-all flush
```

If needed for consistency:

```text
save-off
save-all flush
backup
save-on
```

If `save-off` is used, the implementation must guarantee `save-on` executes even when backup fails.

Use shell traps or equivalent error-safe cleanup.

---

## 19.5 Retention Policy

Required retention:

```text
4 snapshots/day for 7 days
1 snapshot/day for 30 days
1 snapshot/month for 6 months
```

Use restic forget/prune policies.

The exact restic command should be documented and tested.

---

# 20. Restore Strategy

## 20.1 Ordinary Deployment Rollback

If a normal Paper/config/plugin deployment fails:

Automatically restore:

- previous Paper release
- previous plugin set
- previous configuration

Do not automatically restore the world unless necessary and explicitly allowed.

---

## 20.2 Minecraft Version Upgrade Rollback

Minecraft version upgrades may alter world data.

Therefore:

```text
automatic world rollback is prohibited
```

If the upgrade fails or the owner wants to return to the previous version:

1. notify owner
2. identify the pre-upgrade backup
3. use a manually triggered GitHub Actions workflow
4. owner selects/confirms the restore
5. stop Minecraft
6. restore world/plugin state
7. restore compatible release
8. start Minecraft
9. verify
10. notify owner

---

# 21. Restore Backup Workflow

Create:

```text
.github/workflows/restore-backup.yml
```

Manual `workflow_dispatch`.

Expected inputs:

- backup snapshot / timestamp
- confirmation input
- optional restore scope

The workflow must require explicit manual confirmation before destructive restore.

It should not be possible to accidentally restore a backup merely by pushing code.

---

# 22. Monitoring

Monitoring should be intentionally lightweight.

Do not run Prometheus/Grafana/Loki on this VPS in v1.

---

## 22.1 Local Health Checks

Monitor:

- `minecraft.service` state
- Minecraft status ping on port 25565
- disk usage
- memory pressure
- backup age
- backup success
- crash/restart behavior
- deployment state

---

## 22.2 Minecraft Status Ping

Do not consider `systemctl is-active minecraft` sufficient.

A JVM can exist while the Minecraft server is unresponsive.

The health check must perform a real Minecraft status request.

Desired logic example:

```text
check fails once:
  no action

multiple consecutive failures:
  attempt service restart

server still unhealthy:
  Telegram critical alert
```

Avoid endless restart loops.

---

## 22.3 TPS/MSPT

Do not implement automatic TPS/MSPT alerting in v1.

If performance problems occur, use Paper/spark profiling manually.

This is intentionally deferred to avoid unnecessary complexity.

---

# 23. systemd Recovery

`minecraft.service` should restart after unexpected process failure.

Example policy:

```ini
Restart=on-failure
RestartSec=10
```

Also configure rate limiting so repeated crashes do not cause an infinite restart storm.

Example concept:

```text
maximum N restart attempts within a time window
```

If the restart limit is reached:

- stop retrying
- send critical Telegram alert

---

# 24. Scheduled Restarts

Do not perform daily preventive Minecraft restarts.

The server should restart only when:

- deployment requires it
- Paper crashes
- health recovery requires it
- the owner manually requests it
- operating system maintenance requires it

If memory leaks or degradation appear, diagnose the root cause rather than hiding it with a daily restart.

---

# 25. External Monitoring

Use:

```text
Healthchecks.io free plan
```

Purpose:

- detect complete VPS failure
- detect missing backup jobs

---

## 25.1 VPS Heartbeat

A systemd timer periodically sends a heartbeat to Healthchecks.io.

If the VPS disappears and heartbeats stop:

```text
Healthchecks.io
  ↓
Telegram
```

This solves the problem where the dead VPS cannot send its own alert.

---

## 25.2 Backup Watchdog

After a successful backup:

```text
send success heartbeat
```

On backup start/failure, use Healthchecks.io's supported job signaling where practical.

If backups stop executing, the external service must notify the owner.

---

# 26. Telegram Alerts

A dedicated Telegram bot should be used.

Required alert classes:

### Critical

- VPS heartbeat lost
- Minecraft unavailable after recovery attempt
- repeated crash loop
- deployment failed
- rollback failed
- backup failed
- backup overdue/stale
- disk critically full

### Warning

- disk usage warning
- memory pressure warning
- deployment pending over 24 hours
- rollback performed

### Informational

- successful deployment
- optional successful rollback
- optional version update status

Avoid noisy notifications such as:

- every player login
- every logout
- every normal systemd restart
- every successful scheduled backup unless specifically useful

---

# 27. Secrets

For this project, all secrets should be stored in:

```text
GitHub Secrets
```

This is an intentional simplification accepted for the small project size.

Potential secrets:

```text
SSH_DEPLOY_KEY
TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID
RCON_PASSWORD
RESTIC_PASSWORD
YANDEX_RCLONE_CONFIG
HEALTHCHECKS_* URLs/tokens
```

Production secrets should preferably be scoped to the GitHub:

```text
Environment: production
```

GitHub Actions may materialize required runtime secret files on the VPS.

Runtime secret files must:

- not be tracked in Git
- use restrictive permissions
- ideally be root-readable or service-user-readable only

Example:

```text
/etc/minecraft/secrets/
```

with permissions such as:

```text
0600
```

---

# 28. GitHub Production Environment

Create a GitHub Environment:

```text
production
```

Use it for:

- deployment secrets
- manual production approval
- deployment tracking

No production deployment should happen before the owner approves the production environment deployment.

---

# 29. Ansible

Ansible is responsible for provisioning the host.

A fresh Debian 13 VPS should be transformable into the required production server by running the documented Ansible playbook.

Ansible responsibilities:

- package installation
- system users
- SSH hardening
- firewall
- Java
- filesystem layout
- Paper runtime prerequisites
- systemd units
- systemd timers
- restic
- rclone
- health-check tooling
- deployment tooling
- log rotation if needed
- permissions

Ansible should be idempotent.

Repeated runs must not break the server.

---

# 30. Disaster Recovery

The project must support recovery after total VPS loss.

Expected recovery path:

```text
new Debian 13 VPS
    ↓
DNS updated if IP changed
    ↓
Ansible bootstrap
    ↓
Git configuration applied
    ↓
restic repository accessed through rclone/Google Drive
    ↓
latest chosen backup restored
    ↓
Paper/plugins restored from pinned versions
    ↓
Minecraft started
    ↓
health check
```

The goal is that the server can be reconstructed from:

```text
GitHub repository
+
GitHub Secrets
+
Google Drive backups
```

---

# 31. Logs

Use systemd journal for service logs where possible.

Minecraft native logs remain under the runtime directory.

Avoid adding a centralized logging stack.

Useful operational commands should be documented, for example:

```bash
systemctl status minecraft
journalctl -u minecraft
journalctl -u minecraft -f
```

Log retention must avoid filling the 60 GB disk.

Use logrotate or application-level retention if required.

---

# 32. Disk Usage

Target disk size:

```text
60 GB NVMe
```

Monitor disk usage.

Suggested initial alert thresholds:

```text
warning: 80%
critical: 90%
```

Thresholds should be configurable.

The implementation should consider growth from:

- worlds
- logs
- CoreProtect database
- temporary backups
- release directories

Do not retain unlimited old releases locally.

---

# 33. Memory Monitoring

Monitor host memory pressure.

Avoid triggering on short harmless spikes.

Suggested initial warning condition:

```text
sustained memory pressure / very low available memory
```

Exact implementation may use `MemAvailable` rather than naive "used RAM %" because Linux filesystem cache is reclaimable.

Do not alert merely because Linux uses free memory for cache.

---

# 34. Release Retention

Keep at least:

```text
current release
previous known-good release
```

Optionally retain a small number of older releases.

Do not keep unlimited releases on disk.

---

# 35. Health Verification After Deployment

A deployment is successful only after:

1. systemd reports the service running
2. Paper completes startup
3. Minecraft status ping succeeds
4. expected Minecraft version matches
5. required plugins are loaded where verifiable
6. no fatal startup error is detected

For offline authentication, deployment verification should ensure AuthMe is present and loaded.

A server without working authentication must not be considered a healthy production deployment.

---

# 36. Authentication Failure Safety

Because:

```properties
online-mode=false
```

AuthMe is security-critical.

If AuthMe fails to load after deployment:

```text
deployment must fail
```

Prefer:

```text
stop / rollback server
```

rather than leaving an unauthenticated offline-mode server online.

---

# 37. CoreProtect

CoreProtect is required from day one because it can only audit actions that happened while it was installed.

Configuration goals:

- SQLite backend
- low operational overhead
- retain approximately 30 days of activity
- automatic purge of old records
- include database in backups

CoreProtect is not a substitute for restic backups.

---

# 38. World Pre-generation

If exploration causes performance spikes, use Chunky to pre-generate a reasonable world radius.

This is optional.

Do not over-generate huge worlds without need because it increases:

- disk usage
- backup size
- backup duration

---

# 39. Performance Strategy

Start with mostly default Paper configuration.

Suggested initial values may be:

```properties
view-distance=8
simulation-distance=6
```

These should remain configurable and should not be treated as permanent if the VPS has more capacity.

Avoid applying random optimization guides that heavily alter gameplay.

If lag appears:

1. reproduce issue
2. use spark profiler
3. identify cause
4. optimize targeted component
5. only then reduce gameplay settings if needed

---

# 40. No Daily Maintenance Restart

The architecture deliberately avoids scheduled daily restarts.

This is an operational design choice.

The server should be capable of running continuously.

If reliability depends on daily restart, investigate:

- plugin leak
- JVM behavior
- excessive entities
- broken automation
- memory pressure
- world issue

---

# 41. Non-Goals

The following are explicitly out of scope for v1:

- Kubernetes
- Docker
- Pterodactyl
- Crafty Controller
- AMP panel
- Prometheus
- Grafana
- Loki
- Elasticsearch
- MariaDB/PostgreSQL
- Redis
- Kubernetes-style high availability
- multiple Minecraft nodes
- proxy network such as Velocity/BungeeCord
- automatic horizontal scaling
- automatic TPS/MSPT monitoring
- complex RBAC inside Minecraft
- mobile web administration
- daily scheduled restart

---

# 42. Implementation Priorities

Recommended implementation order:

## Phase 1 — Repository and CI

- create repository structure
- add version metadata
- add linting
- add secret scanning
- add Paper smoke test

## Phase 2 — Ansible Provisioning

- Debian bootstrap
- users
- Java
- SSH hardening
- firewall
- directories
- systemd

## Phase 3 — Minecraft

- Paper
- AuthMeReloaded
- whitelist
- CoreProtect
- OP administration
- base configs

## Phase 4 — Backup

- restic
- rclone
- Google Drive
- scheduled backup
- retention
- restore test

## Phase 5 — Monitoring

- local healthcheck
- Minecraft protocol ping
- Telegram
- Healthchecks.io heartbeat
- backup watchdog

## Phase 6 — Deployment

- release mechanism
- pending state
- player-aware deployment
- 5-minute grace period
- pre-deploy backup
- health verification
- automatic rollback

## Phase 7 — Update Automation

- Paper update checker
- automated PRs
- plugin update automation is deferred from v1

## Phase 8 — Disaster Recovery Test

- simulate new VPS
- provision with Ansible
- restore from Google Drive
- verify server health

---

# 43. Acceptance Criteria

The project is considered v1-complete when all of the following are true.

## Provisioning

- A fresh Debian 13 VPS can be prepared using Ansible.
- Re-running Ansible is safe.

## Minecraft

- Paper starts successfully.
- Maximum players is 5.
- Offline clients can use AuthMe registration/login.
- Whitelist works.
- CoreProtect records player changes.

## CI

- PRs trigger required tests.
- Broken shell/YAML/Ansible fails CI.
- Secret leaks are detected.
- Paper smoke test runs on GitHub-hosted runner.

## Deployment

- Production deployment requires manual GitHub approval.
- Deployment waits while players are online.
- No player is automatically kicked.
- Empty server must remain empty for 5 minutes before deployment.
- Pre-deploy backup is mandatory.
- Failed backup blocks deployment.
- Failed normal deployment rolls back automatically.

## Updates

- Paper updates can create automated PRs.
- New Minecraft versions are never automatically deployed.

## Backup

- Backups run every 6 hours.
- Backups are encrypted.
- Backups are stored outside the VPS.
- Retention policy is enforced.
- Restore procedure is tested.

## Monitoring

- Minecraft failure generates Telegram alert.
- Complete VPS failure generates Telegram alert through Healthchecks.io.
- Missing backup generates alert.
- Disk usage is monitored.

## Security

- SSH password login is disabled.
- Root SSH login is disabled.
- RCON is not public.
- Secrets are absent from the public repository.

## Disaster Recovery

- A new VPS can be reconstructed from Git + GitHub Secrets + Google Drive backup.

---

# 44. Important Implementation Constraints for the Agent

The implementation agent must follow these constraints:

1. Do not introduce Docker without explicit approval.
2. Do not introduce Kubernetes.
3. Do not install monitoring stacks that materially consume server RAM.
4. Do not expose RCON to the Internet.
5. Do not commit secrets.
6. Do not store worlds in Git.
7. Do not automatically kick players for deployment.
8. Do not automatically roll back world data after Minecraft version migration.
9. Do not deploy when the mandatory pre-deploy backup failed.
10. Do not automatically deploy a new Minecraft version.
11. Do not run a permanent GitHub Actions runner on the Minecraft VPS.
12. Prefer simple scripts/systemd/Ansible over additional long-running services.
13. Keep all automation understandable and maintainable by one administrator.
14. Document every operational command required for recovery and troubleshooting.
15. Any design deviation must be documented with a clear reason.

---

# 45. Final Desired Operational Experience

The target workflow should feel like this:

```text
Developer changes configuration
        ↓
Push branch
        ↓
GitHub CI tests everything
        ↓
PR merged to main
        ↓
Owner manually approves production
        ↓
Deployment becomes pending
        ↓
Players keep playing normally
        ↓
Server eventually becomes empty
        ↓
Wait 5 minutes
        ↓
Create encrypted pre-deploy backup
        ↓
Deploy
        ↓
Verify
        ↓
Success
```

If the deployment fails:

```text
failed deploy
    ↓
automatic rollback
    ↓
verify previous version
    ↓
Telegram notification
```

If the VPS completely dies:

```text
heartbeat disappears
    ↓
Healthchecks.io detects it
    ↓
Telegram notification
```

If the entire VPS is lost permanently:

```text
new VPS
    ↓
Ansible
    ↓
restore from Google Drive
    ↓
server online again
```

The system should be simple enough for one administrator, but structured enough to demonstrate practical DevOps skills in a public portfolio.
