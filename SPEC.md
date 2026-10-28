# Minecraft Server Infrastructure Specification

> Generated via spec-interview on 2026-09-19
> Status: APPROVED FOR IMPLEMENTATION

---

## 1. Overview

### 1.1 Problem Statement

The project must provision and operate a small private Minecraft server for a group of friends while demonstrating production-like DevOps practices. The server should stay simple enough for one administrator, but it must still support reproducible setup, safe updates, automatic recovery from ordinary failures, backups, monitoring, and disaster recovery.

The main pain points are manual server maintenance, unsafe updates, weak backup discipline, and lack of visibility when the server or backups fail.

### 1.2 Solution Summary

Build a one-VPS Minecraft infrastructure managed from a public GitHub repository. Paper runs directly as a native Java process under systemd on Debian 13. Ansible provisions the host. GitHub Actions validates changes, runs smoke tests, and triggers approved deployments. Deployments wait for the server to become empty, create a mandatory pre-deploy backup, verify health, and roll back binaries/configuration on failure. Backups use encrypted restic repositories uploaded to Google Drive through rclone. Monitoring uses systemd timers, Minecraft status ping checks, Telegram alerts, and Healthchecks.io.

Backup provider updated 2026-10-28: Google Drive is current. The legacy production
secret `YANDEX_RCLONE_CONFIG` holds the sole Google remote. Old Yandex snapshots
remain separate and were not migrated; see `docs/BACKUP_RESTORE.md`.

### 1.3 Success Metrics

- Fresh-server reproducibility: a new Debian 13 VPS can be configured with Ansible and restored from backups.
- Safe deployment: no normal deployment kicks players automatically.
- Backup reliability: scheduled backups run every 6 hours and missing backups alert the owner.
- Security baseline: SSH password login and root SSH login are disabled; RCON is not publicly reachable.
- Portfolio quality: the public repository contains no secrets or runtime data and includes clear operational documentation.

### 1.4 Non-Goals

- Docker, Kubernetes, Pterodactyl, Crafty Controller, AMP, or any large management panel.
- Prometheus, Grafana, Loki, Elasticsearch, MariaDB, PostgreSQL, Redis, or other heavy supporting services in v1.
- Multi-node Minecraft networks, Velocity/BungeeCord, high availability, or horizontal scaling.
- Automatic player kicking during normal deployments.
- Automatic world rollback after Minecraft version migrations.
- Automatic deployment of new Minecraft versions.
- Automatic TPS/MSPT alerting in v1.
- Complex Minecraft RBAC or LuckPerms in v1.
- Web or mobile administration UI.
- Daily scheduled preventive restarts.

---

## 2. Users And Use Cases

### 2.1 Target Users

| User Type | Description | Technical Level | Usage Frequency |
|-----------|-------------|-----------------|-----------------|
| Owner / administrator | Maintains infrastructure, approves deploys, handles incidents, restores backups. | High | Weekly or as needed |
| Player | Private friend-group player using Minecraft client, possibly offline/non-premium client. | Low to medium | Daily or weekly |
| Implementation agent | AI coding/DevOps agent implementing the repository and automation. | High | During project build-out |

### 2.2 Primary Use Cases

1. **Play vanilla-like survival**: players join a private whitelisted server and authenticate with AuthMe.
2. **Deploy configuration or version changes safely**: owner merges tested changes, approves production, and deployment waits until no players are online.
3. **Recover from failed deployment**: deployment health checks fail, previous release is restored, and owner receives a Telegram alert.
4. **Recover from VPS loss**: owner provisions a new Debian 13 VPS, applies Ansible, restores mutable state from Google Drive backups, and updates DNS if needed.
5. **Audit or repair griefing/accidents**: owner uses CoreProtect records and restic backups depending on severity.

### 2.3 Primary User Journey

```text
Owner changes config
  -> opens PR
  -> CI validates repository, infrastructure scenarios, and Paper/plugin startup
  -> merge to main
  -> owner approves GitHub production environment
  -> deployment becomes pending on VPS
  -> deployment waits for zero players
  -> 5-minute empty grace period
  -> pre-deploy backup
  -> release deploy
  -> health verification
  -> success alert or rollback alert
```

---

## 3. Functional Requirements

### 3.1 Core Features (MVP)

| Feature | Description | Priority | Acceptance Criteria |
|---------|-------------|----------|---------------------|
| Repository structure | Create maintainable Git layout for Ansible, Minecraft config, scripts, systemd units, docs, and workflows. | P0 | Required directories and docs exist; runtime data is ignored. |
| Version metadata | Pin Minecraft, Paper build, Java major version, and plugin versions. | P0 | Production deploys use metadata, not arbitrary latest downloads. |
| CI validation | Validate YAML, Ansible, shell scripts, secrets, repository consistency, and Paper startup. | P0 | Broken config fails CI before production deployment. |
| Ansible provisioning | Configure an existing Debian 13 VPS over SSH. | P0 | Re-running Ansible is safe and idempotent. |
| Paper runtime | Run Paper directly as a systemd-managed Java process. | P0 | Minecraft status ping succeeds on port 25565. |
| Offline authentication | Support `online-mode=false` with AuthMeReloaded. | P0 | AuthMe loads successfully; server is unhealthy if AuthMe fails. |
| Whitelist | Restrict access to approved Minecraft identities. | P0 | `white-list=true` and `enforce-whitelist=true` are configured. |
| CoreProtect | Record player actions for audit and rollback. | P0 | CoreProtect SQLite data is retained about 30 days and backed up. |
| RCON automation | Enable local-only RCON for scripts. | P0 | RCON listens on localhost only and firewall does not expose it. |
| Backups | Create encrypted restic backups through rclone to Google Drive. | P0 | Scheduled backup succeeds; pre-deploy backup blocks deploy on failure. |
| Player-aware deployment | Deploy only after the server is empty for 5 minutes. | P0 | Online players are never automatically kicked during normal deploy. |
| Release rollback | Roll back binaries/configuration after failed normal deploy. | P0 | Previous release starts and passes health verification. |
| Telegram alerts | Notify owner about critical and warning states. | P0 | Failed deploy, failed backup, missing backup, and service failure alert. |
| Healthchecks.io | Detect VPS disappearance and missing backup runs externally. | P0 | Lost heartbeat triggers Telegram via Healthchecks.io. |
| Full restore workflow | Restore complete mutable state from selected backup manually. | P0 | `restore-backup.yml` requires explicit confirmation and performs full restore only. |

### 3.2 Phase 2 Features

- Paper update checker that creates or updates a PR for newer compatible Paper builds.
- Optional Chunky setup if exploration causes performance spikes.
- More detailed operational runbooks after first live deployment.

### 3.3 Future Considerations

- Plugin update automation for AuthMeReloaded, CoreProtect, and Chunky.
- Selective restore scopes such as world-only or plugin-data-only.
- TPS/MSPT monitoring if real lag problems appear.
- More advanced in-game permissions if a second administrator becomes necessary.

---

## 4. Technical Architecture

### 4.1 System Overview

```text
GitHub repository
  -> GitHub Actions CI and deployment approval
  -> SSH to Debian 13 VPS
  -> systemd-managed Paper server
  -> restic encrypted backups
  -> rclone to Google Drive
  -> Healthchecks.io and Telegram alerts
```

### 4.2 Data Model

This project has file-based operational state rather than an application database.

```text
VersionMetadata
- minecraft.version: string
- paper.build: string
- java.major: integer
- plugins[]: name, version, source, checksum if available

Release
- release_id: string
- paper_jar: file
- plugins: files
- configuration: files
- created_at: timestamp
- status: current | previous | retained

DeploymentState
- state: pending | waiting | grace_period | backup | deploying | verifying | success | failed | rollback | critical_failure
- target_release_id: string
- previous_release_id: string
- force: boolean
- updated_at: timestamp

BackupSnapshot
- restic_snapshot_id: string
- created_at: timestamp
- scope: full mutable state
- reason: scheduled | pre_deploy | manual_restore_test

PlayerIdentity
- minecraft_name: string
- whitelisted: boolean
- authme_registered: boolean
```

### 4.3 Key Interfaces

| Interface | Description | Auth |
|-----------|-------------|------|
| SSH | GitHub Actions and owner access to VPS. | SSH keys only |
| RCON localhost | `save-all flush`, `say`, `stop`, player count, admin commands. | Local secret |
| Minecraft TCP 25565 | Player access and status ping checks. | Whitelist + AuthMe |
| GitHub Actions | CI, deployment approval, force deploy, restore workflow. | GitHub auth + Environment approval |
| Google Drive via rclone | Offsite backup storage. | rclone credentials in GitHub Secrets |
| Healthchecks.io | External heartbeat and backup watchdog. | Secret URLs/tokens |
| Telegram Bot API | Owner notifications. | Bot token and chat ID |

### 4.4 State Management

- Git is the source of truth for infrastructure code, scripts, workflows, systemd units, Minecraft configuration, plugin manifests, and version metadata.
- The VPS filesystem is the source of truth for live mutable state until it is backed up.
- Google Drive restic repository is the offsite source for current disaster recovery snapshots.
- GitHub Secrets / GitHub Environment hold pre-provisioned deployment and backup secrets.
- Deployment state is persisted on disk so reboot does not lose deploy context.

### 4.5 Technology Stack

| Layer | Technology | Rationale |
|-------|------------|-----------|
| OS | Debian 13 minimal | Small, stable, common server baseline. |
| Minecraft | Paper | Production-grade Minecraft server with plugin support. |
| Runtime | Native Java + systemd | Simple and resource-efficient for one VPS. |
| Provisioning | Ansible | Idempotent server configuration from Git. |
| CI/CD | GitHub Actions | Fits public repo and Environment approvals. |
| Backups | restic + rclone | Encrypted backups to Google Drive. |
| Monitoring | systemd timers, scripts, Healthchecks.io, Telegram | Lightweight enough for 4 GB RAM VPS. |
| Data store | Files and SQLite plugin data | Avoids unnecessary external databases. |

---

## 5. UI/UX Design

### 5.1 User-Facing Surfaces

1. **Minecraft client**: server list, join flow, AuthMe registration/login, in-game deployment notices.
2. **GitHub repository**: PRs, CI checks, Environment deployment approvals, manual workflows.
3. **Telegram chat**: critical, warning, and informational operational alerts.
4. **Documentation**: README and runbooks for setup, operation, backup, restore, and disaster recovery.

### 5.2 Player Flow

```text
Player connects
  -> whitelist check
  -> if first login: /register <password> <password>
  -> later logins: /login <password>
  -> plays normally
```

If a player forgets an AuthMe password, the owner performs a manual reset after verifying the player outside the game.

### 5.3 Deployment Notices

- Normal deployments must not pressure players to leave.
- If a deployment is pending for more than 24 hours, notify owner via Telegram and notify online players in-game.
- Repeat in-game notice every 6 hours and Telegram notice every 24 hours while still pending.

### 5.4 Error States

- Players see simple in-game notices only for pending deploys and planned administrative actions.
- Owner receives actionable Telegram messages with failure class, host, operation, and suggested next command or runbook.
- GitHub workflows fail loudly when CI, deploy, backup, or restore checks fail.

### 5.5 Accessibility And Responsiveness

No custom web UI exists in v1. GitHub, Telegram, and Minecraft clients provide their own accessibility behavior.

---

## 6. Integration And Dependencies

### 6.1 External Systems

| System | Purpose | Protocol | Owner |
|--------|---------|----------|-------|
| GitHub | Repository, CI/CD, secrets, deployment approval. | Git/HTTPS/SSH | Owner |
| VPS provider | Provides already-created Debian 13 server. | SSH | Owner/provider |
| Google Drive | Offsite backup storage. | rclone remote | Owner/provider |
| Healthchecks.io | External heartbeat and backup monitoring. | HTTPS | Vendor |
| Telegram | Alerts. | Bot API HTTPS | Telegram/vendor |
| PaperMC API | Download pinned Paper build and check Paper updates. | HTTPS | PaperMC |
| Plugin sources | Download pinned plugin artifacts manually or by scripted source. | HTTPS | Plugin maintainers |

### 6.2 Data Flows

```text
GitHub repo -> GitHub Actions -> SSH -> VPS
VPS mutable state -> restic -> rclone -> Google Drive
VPS timers -> Healthchecks.io -> Telegram
VPS scripts -> Telegram Bot API -> owner
Minecraft clients -> TCP 25565 -> Paper server
```

### 6.3 Failure Handling

| Dependency | Failure Mode | Handling Strategy |
|------------|--------------|-------------------|
| GitHub Actions | CI/deploy runner unavailable | No deployment; owner retries later. |
| GitHub Secrets | Missing or wrong secret | Workflow fails before unsafe operation where possible. |
| Google Drive/rclone | Backup upload fails | Backup fails, deploy blocked if pre-deploy, owner alerted. |
| Healthchecks.io | Monitoring service unavailable | Local health checks still run; owner may not receive external outage alert. |
| Telegram | Alert delivery fails | Log alert failure locally and in workflow output. |
| Paper/plugin download source | Artifact unavailable | CI/update workflow fails; production remains unchanged. |
| VPS network | Server unreachable | Healthchecks.io detects missing heartbeat and alerts owner. |

---

## 7. Error Handling And Edge Cases

### 7.1 Error Taxonomy

| Error Type | User Message | Technical Detail | Recovery |
|------------|--------------|------------------|----------|
| Backup failed | None to players; Telegram to owner. | restic/rclone stderr and exit code. | Fix backup issue; rerun backup; deploy remains blocked. |
| Deployment pending too long | In-game gentle notice. | Deployment state remains pending. | Wait, force deploy manually if necessary. |
| Deploy health failed | Telegram failure and rollback notice. | systemd, ping, version, plugin checks. | Automatic release rollback; manual investigation. |
| Rollback failed | Critical Telegram alert. | Previous release failed verification. | Manual intervention via runbook. |
| AuthMe missing/unloaded | No public server should remain online. | Plugin verification fails. | Stop or roll back server. |
| RCON failure | Owner alert if operation depends on it. | RCON command stderr/timeout. | Abort backup/deploy step if consistency depends on RCON. |
| Disk critical | Telegram critical alert. | Disk usage above critical threshold. | Prune releases/logs/backups; investigate world growth. |

### 7.2 Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| Player joins during 5-minute grace period | Cancel countdown and return to waiting state. |
| Backup already running when deploy wants pre-deploy backup | Global operation lock prevents conflict; deploy waits or fails safely with alert according to implementation timeout. |
| Restore requested during deploy | Global lock prevents concurrent destructive operations. |
| VPS reboots during pending deploy | Persisted deployment state allows controller to resume safely. |
| Minecraft starts but status ping fails | Health check fails; restart or rollback depending on context. |
| AuthMe password lost | Owner manually resets after out-of-game identity verification. |
| Minecraft version upgrade changes world format | Automatic world rollback is prohibited; manual full restore only. |
| Force deploy requested with players online | Allowed only by explicit owner workflow; backup still required. |

### 7.3 Partial Failure Handling

- Deployment failures after release switch trigger binary/config rollback only.
- World data is not automatically restored except through explicit manual restore workflow.
- Restore workflow v1 restores full mutable state only; selective restore is out of scope.
- If `save-off` is used for backup consistency, cleanup must guarantee `save-on` runs via shell trap or equivalent.

---

## 8. Security And Privacy

### 8.1 Authentication

- SSH uses keys only.
- GitHub Actions uses a dedicated deploy key, not the owner's private key.
- Minecraft runs in `online-mode=false`, so AuthMeReloaded is mandatory.
- RCON is authenticated and reachable only from localhost.

### 8.2 Authorization

| Role | Create | Read | Update | Delete |
|------|--------|------|--------|--------|
| Owner | All infrastructure and Minecraft administration. | All operational data. | All. | All, including restore. |
| Player | In-game actions only. | Own gameplay view. | Own gameplay state through normal play. | No infrastructure deletes. |
| GitHub Actions deploy key | Deploy configured artifacts and run approved automation. | Required repository artifacts/secrets. | Production files through scripts. | No unrestricted manual deletes beyond scripted operations. |

### 8.3 Data Classification

| Data Type | Classification | Encryption | Retention |
|-----------|---------------|------------|-----------|
| RCON password | Secret | GitHub Secrets; restrictive file permissions on VPS. | Rotate manually as needed. |
| restic password | Secret | GitHub Secrets only. | Rotate manually with documented procedure. |
| rclone/Google Drive credentials | Secret | GitHub Secrets only (legacy name `YANDEX_RCLONE_CONFIG`). | Rotate manually as needed. |
| Telegram token/chat ID | Secret | GitHub Secrets only. | Rotate if exposed. |
| AuthMe data | Sensitive player data | In encrypted restic backups; filesystem permissions on VPS. | As part of backup retention. |
| World data | Private group data | Encrypted restic backups. | As part of backup retention. |
| CoreProtect SQLite | Sensitive audit data | Encrypted restic backups. | About 30 days in live DB; backup retention separately. |
| Logs | Operational data | Local filesystem permissions. | Must not fill disk; rotate/prune. |

### 8.4 Compliance Requirements

No formal GDPR, SOC2, HIPAA, or similar compliance target exists for v1. The repository must still avoid committing secrets or private runtime data.

### 8.5 Audit Trail

- Git history records infrastructure changes.
- GitHub Actions records CI, deploy, force deploy, and restore runs.
- CoreProtect records in-game block/activity audit events for about 30 days.
- Deployment and backup scripts log operation IDs, timestamps, release IDs, and outcomes.

---

## 9. Performance And Reliability

### 9.1 Performance Targets

| Metric | Target | Measurement |
|--------|--------|-------------|
| Concurrent players | Up to 5 | Minecraft player count/status query |
| Minecraft status ping | Should respond during healthy runtime | Healthcheck script |
| Initial heap | `-Xms2G -Xmx3G` on 4 GB VPS | systemd/JVM config |
| View distance | Start with 8 | `server.properties` |
| Simulation distance | Start with 6 | `server.properties` |

### 9.2 Availability Target

The server should run 24/7 on a best-effort private-server basis. No strict commercial SLA is required.

### 9.3 Recovery Targets

- RPO: best effort, up to 24 hours acceptable for this private server.
- RTO: best effort; restore speed is secondary to simplicity and correctness.
- Scheduled backups still run every 6 hours to reduce normal data-loss risk.

### 9.4 Scalability Plan

Scale target is fixed at one small private server with 5 expected concurrent players. If load exceeds this, first diagnose with profiling, then tune Paper settings or VPS size. Do not introduce clustering or proxy networks in v1.

### 9.5 Graceful Degradation

- Under player activity, normal deployment waits rather than interrupting gameplay.
- Under backup failure, deploy is blocked rather than risking data loss.
- Under repeated server health failure, restart attempts are rate-limited and critical alert is sent.

---

## 10. Operations

### 10.1 Deployment

Deployment is initiated through GitHub Actions after merge to `main` and manual approval of the `production` environment. The VPS deployment controller executes the player-aware deployment flow.

### 10.2 Global Operation Lock

Backup, deployment, force deployment, and restore must share one global lock. Concurrent destructive or consistency-sensitive operations are prohibited.

### 10.3 Monitoring And Alerting

| Metric | Threshold | Alert | Response |
|--------|-----------|-------|----------|
| VPS heartbeat | Missed Healthchecks.io heartbeat | Critical Telegram | Investigate VPS/provider/network. |
| Backup age | Backup overdue | Critical Telegram | Check systemd timer, restic, rclone, Google Drive. |
| Disk usage | Warning 80%, critical 90% | Warning/critical Telegram | Prune releases/logs, inspect world/CoreProtect growth. |
| Minecraft ping | Multiple consecutive failures | Restart then critical Telegram if still failing | Investigate service logs and Paper logs. |
| Deployment state | Pending more than 24h | Warning Telegram and in-game notice | Wait or manually force deploy. |

### 10.4 Debugging

Runbooks must document commands for:

- `systemctl status minecraft`
- `journalctl -u minecraft`
- live log follow
- Minecraft status ping
- restic snapshot listing
- rclone connectivity test
- deployment state inspection
- manual backup
- manual restore dry-run or preparation

### 10.5 Rollback Plan

- Normal deploy rollback restores previous release binaries/configuration.
- It does not automatically restore world data.
- Minecraft major/minor rollback after world migration requires explicit manual full restore from backup.

### 10.6 Configuration Management

- Non-secret config lives in Git.
- Secrets are pre-provisioned in GitHub Secrets / GitHub Environment.
- Runtime secret files on VPS are generated by automation with restrictive permissions and never committed.

---

## 11. Testing Strategy

### 11.1 Test Levels

| Level | Scope | Tooling | Coverage Target |
|-------|-------|---------|-----------------|
| Static | YAML, shell, Ansible, repository consistency, secrets. | yamllint or equivalent, shellcheck, ansible-lint, gitleaks. | Required in CI. |
| Mocked integration | Deploy, backup/restore, rollback, lock, notifications, config healing, and artifact-download failure/retry behavior. | `test/local/run-fast.sh` with isolated Docker services and command shims. | Required in CI. |
| Paper/plugin startup | Pinned Paper starts and enables every plugin artifact configured in `minecraft/versions.yml`. | `test/local/run-paper-plugin-smoke.sh` in Docker. | Required in CI; no production secrets or external service login. |
| Integration | Ansible applies to VPS, systemd starts services, backups execute. | Ansible, shell scripts. | Required before v1 complete. |
| Operational | Deploy, rollback, backup, full restore, alerts. | Manual or workflow-driven tests. | Required before v1 complete. |

### 11.2 Test Data Strategy

- CI integration tests use disposable containers and temporary directories only.
- Production world data is never used in CI.
- Plugin startup validation does not authenticate DiscordSRV to Discord or call production APIs.
- Restore tests should use a controlled backup snapshot or fresh test state where possible.

### 11.3 Acceptance Criteria

The project is v1 complete only when all acceptance criteria from `minecraft-server-architecture.md` are satisfied and the implementation plan in `PLAN.md` reaches the final verification phase.

---

## 12. Verification Environment

### 12.1 Dev Server

- Start command: not applicable for an app server; local verification uses scripts and CI workflows.
- Production service command: `systemctl start minecraft` through systemd.
- Minecraft URL: `mc.<owner-domain>` or direct host during setup, TCP port `25565`.
- Health endpoint: Minecraft protocol status ping, not HTTP.

### 12.2 Database

- Type: no central database.
- Plugin storage: CoreProtect SQLite; AuthMe file/SQLite storage depending on plugin configuration.
- ORM/migration tool: none.
- Direct query command: SQLite CLI for plugin databases where needed.

### 12.3 Test Runners

| Type | Tool | Command |
|------|------|---------|
| YAML validation | Repository-selected YAML linter | Defined in CI |
| Shell lint | shellcheck | Defined in CI |
| Ansible syntax | ansible | `ansible-playbook --syntax-check ...` |
| Ansible lint | ansible-lint | Defined in CI |
| Secret scan | gitleaks or GitHub secret scanning | Defined in CI |
| Complete integration suite | Docker Compose harness | `bash test/local/run-all.sh` |
| Fast mocked scenarios | Docker Compose harness | `bash test/local/run-fast.sh` |

### 12.4 Verification Patterns

- API verification: not applicable except external HTTPS calls to GitHub, Healthchecks.io, Telegram, PaperMC, and plugin sources.
- UI verification: GitHub workflow state, Telegram messages, and in-game messages.
- DB verification: SQLite inspection for CoreProtect/AuthMe only when operationally necessary.
- CI checks: lint, secret scan, repository consistency, mocked infrastructure scenarios, and Paper/plugin startup.

### 12.5 Local Testing Infrastructure

Local testing infrastructure allows validating infrastructure scripts (`deploy.sh`, `backup.sh`, `restore.sh`, `prepare-release.sh`, `lib.sh`) without deploying to the production VPS. This addresses the gap where script bugs were previously discovered only in production.

#### 12.5.1 Scope

| Test Category | In Scope | Out of Scope |
|---------------|----------|--------------|
| Full deploy cycle | Player-aware wait, pre-deploy backup, release switch, health check, rollback (against a stub) | Actual Minecraft gameplay |
| Backup/restore | restic + rclone to local S3-compatible storage (RustFS) | Real Google Drive |
| Mocked operational integration | Deploy lifecycle, backup/restore, locking, notifications, config healing, and artifact download behavior | Production VPS and production credentials |
| Paper/plugin startup | Start pinned Paper with every configured production plugin and verify each enables | Gameplay, production databases, external plugin authentication/services |
| Ansible provisioning | Not covered locally | Use real VPS for provisioning validation |

#### 12.5.2 Environment

- **Platform:** Docker Desktop on Windows (WSL2 backend).
- **Fast test container:** Debian-based image WITHOUT systemd.
- **Systemctl shim:** A wrapper script that emulates systemctl behavior against the lightweight Minecraft protocol stub.
- **Paper/plugin smoke container:** Java runtime that downloads artifacts from pinned metadata and starts real Paper directly; it does not emulate systemd or deploy/rollback.
- **Storage:** Ephemeral RustFS S3-compatible container (clean slate per test run, no persistence between runs).
- **Scripts:** Run unmodified; no code changes to production scripts for testability.

#### 12.5.3 Systemctl Shim

The shim must handle these commands used by production scripts:

| Command | Shim Behavior |
|---------|---------------|
| `systemctl is-active --quiet minecraft.service` | Return 0 if Java/stub process running, 1 otherwise |
| `systemctl start minecraft.service` | Start the stub process in background |
| `systemctl stop minecraft.service` | Graceful stop (SIGTERM, then SIGKILL after timeout) |
| `systemctl restart minecraft.service` | Stop then start |
| `systemctl daemon-reload` | No-op (no systemd in test env) |

#### 12.5.4 Test Data

- **World data:** Minimal fake world structure (~10 files, few KB) created at test setup.
- **Plugin data:** Stub directories matching production layout without actual plugin JARs.
- **Configuration:** Production-like `server.properties`, plugin configs with test-appropriate values.
- **Releases:** Pre-built test release artifacts for deploy/rollback testing.

#### 12.5.5 Minecraft Stub and Plugin Smoke

The fast deploy/backup tests do not use the real Paper JVM. Instead:

- **TCP stub:** A lightweight process that binds to port 25565 and responds to Minecraft protocol status pings.
- **Purpose:** Allows health check scripts to verify "server is up" without JVM overhead.
- **RCON stub:** Optional; responds to basic RCON commands (`list`, `save-all`, `stop`) if needed for script testing.

The `plugins` Compose profile runs the real pinned Paper JAR and downloads each
configured plugin JAR from `minecraft/versions.yml`. It discovers each plugin
name from the JAR's `paper-plugin.yml` or `plugin.yml`, waits for Paper startup,
and checks that every configured artifact was enabled, including optional
plugins such as DiscordSRV. The smoke seeds DiscordSRV defaults but leaves its
bot token blank: it proves local plugin startup without authenticating to
Discord or calling any external plugin service. This catches artifact,
compatibility, and startup regressions, but is not a gameplay test.

#### 12.5.6 CI Integration

- **Required CI job:** GitHub Actions runs `bash test/local/run-all.sh` on every pull request and every push to `main` or `dev`, after static validation and secret scanning.
- **Merge gate:** The integration job must be configured as a required status check in GitHub branch protection/rulesets so a failure blocks pull-request merges.
- **Failure policy:** Artifact download exhaustion, Paper startup failure, any configured plugin failing to enable, or a mocked scenario failure fails the job; artifacts are not silently skipped.
- **Isolation:** CI uses only dummy local values and ephemeral containers. It does not use production secrets, live worlds, Discord authentication, or external integration credentials.
- **Cleanup:** `run-all.sh` tears down its Compose stack on exit, including failed/interrupted test runs.

#### 12.5.7 Test Execution

```text
Developer changes script/config/plugin metadata
  -> runs `bash test/local/run-all.sh`
  -> RustFS starts (ephemeral S3-compatible storage)
  -> mocked integration scenarios run with systemctl shim
  -> test scenarios execute (deploy, backup, restore, rollback)
  -> assertions verify state transitions, file placement, lock behavior
  -> pinned Paper and every configured plugin start in an isolated container
  -> logs confirm each plugin was enabled
  -> containers torn down on success or failure
```

Use `bash test/local/run-fast.sh` for faster feedback on mocked scenarios only;
the complete run including real artifact downloads and Paper startup takes
several minutes on a cold cache.

#### 12.5.8 Success Criteria

- [ ] deploy.sh completes full cycle with stub server and shim
- [ ] backup.sh creates restic snapshot in local RustFS storage
- [ ] restore.sh restores from a RustFS snapshot correctly
- [ ] Rollback scenario restores previous release after simulated health failure
- [ ] Lock contention between deploy and backup is handled correctly
- [ ] Scripts exit with correct codes on success and failure paths
- [ ] Transient Paper/plugin artifact download failures retry with bounded backoff; permanent errors and exhausted retries fail release preparation
- [ ] Complete integration suite starts Paper and verifies every configured plugin JAR enables without production credentials or external logins
- [ ] CI runs the complete integration suite for pull requests and pushes to `main`/`dev`; its status is required for merge

---

## 13. Implementation Plan

The authoritative implementation plan is `PLAN.md`.

### 13.1 Phases

| Phase | Scope | Milestone |
|-------|-------|-----------|
| 1 | Repository foundation and CI | Validated public repo baseline. |
| 2 | Ansible provisioning | Existing Debian 13 VPS configured idempotently. |
| 3 | Minecraft runtime | Paper, AuthMe, whitelist, CoreProtect working. |
| 4 | Backups | Encrypted scheduled and pre-deploy backups. |
| 5 | Monitoring | Local checks, Telegram, Healthchecks.io. |
| 6 | Deployment | Player-aware deployment and rollback. |
| 7 | Update automation | Paper update PR workflow. |
| 8 | Disaster recovery | Full restore path tested and documented. |

### 13.2 Risks And Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| AuthMe fails on offline-mode server | Medium | High | Treat missing AuthMe as failed health check; stop or roll back. |
| Backup credentials fail | Medium | High | Fail deploy if pre-deploy backup fails; alert owner. |
| World migration is irreversible without restore | Medium | High | Require manual restore confirmation for Minecraft version rollback. |
| Public repo leaks secrets | Low | High | `.gitignore`, secret scanning, GitHub Secrets only. |
| Disk fills from world/logs/releases | Medium | Medium | Disk alerts, release retention, log rotation, CoreProtect purge. |
| Over-complex automation becomes unmaintainable | Medium | Medium | Avoid heavy services; keep scripts documented and simple. |

### 13.3 Open Questions

No critical open questions remain. Implementation choices may be adjusted only if they preserve the constraints in `minecraft-server-architecture.md` and are documented with rationale.

---

## 14. Appendix

### 14.1 Glossary

| Term | Definition |
|------|------------|
| Paper | Minecraft server implementation with plugin support. |
| AuthMeReloaded | Authentication plugin required because `online-mode=false`. |
| CoreProtect | Audit and rollback plugin for player actions. |
| RCON | Local remote console protocol used by automation scripts. |
| restic | Encrypted backup tool. |
| rclone | Tool used to access Google Drive remote storage. |
| RPO | Recovery point objective; acceptable data loss window. |
| RTO | Recovery time objective; acceptable recovery duration. |

### 14.2 References

- `minecraft-server-architecture.md`
- `PLAN.md`

### 14.3 Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-09-19 | OpenCode | Created implementation-ready specification from architecture and interview decisions. |
| 2026-09-20 | OpenCode | Added section 12.5 Local Testing Infrastructure per issue #9. |
