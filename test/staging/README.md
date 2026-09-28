# Local LAN staging (Paper)

This is a manually started **separate** Paper server. It uses the pinned Paper
and plugin versions and Git-tracked configuration from `minecraft/`, but never
shares the production world, accounts, secrets, backup destination or network
port. DiscordSRV is removed from each staging release before Paper starts, so
it cannot connect to the production Discord bot/channel. The existing fast
tests and disposable plugin smoke remain the CI gate (`test/local/run-all.sh`).

## Setup (Windows / Docker Desktop)

1. Start Docker Desktop and make sure your Windows network is **Private**.
2. Find your PC's LAN IPv4 with `ipconfig`. Copy `staging.env.example` to
   `staging.env` in this directory. Enter that exact LAN IPv4 and three unique
   local-only passwords. `staging.env` is ignored by Git; do not use production
   secrets or copy a production world into staging. The container's environment
   contains these local values and is visible to users with Docker access.
3. From the repository root, run the following in PowerShell:

```powershell
./test/staging/staging.ps1 start
./test/staging/staging.ps1 allow YourMinecraftName
./test/staging/staging.ps1 status
./test/staging/staging.ps1 logs
./test/staging/staging.ps1 stop
```

Players on the **same LAN** connect to `STAGING_BIND_IP:25566` (Java edition).
If another PC cannot connect, allow inbound TCP `25566` on Windows Firewall
for the Private profile only; do not set up router port forwarding or expose it
on a Public profile. The Compose port is bound to that LAN IPv4, not all host
interfaces. RCON port `25575` is reachable only inside the container; whitelist
and AuthMe are enabled. Because the repository deliberately uses
`online-mode=false`, users should choose a distinct password for staging AuthMe
and never use a production account password here. To remove a player, use the
in-game console command `whitelist remove <name>` through an admin or RCON.

The first start downloads the pinned JARs and creates a fresh world; it can
take several minutes and needs internet access. The starter waits for Paper
to answer RCON, sets the border to **256 blocks in diameter** centered at 0,0,
and enforces the whitelist. Up to four players may join; view and simulation
distance are four chunks. The persistent Docker volume holds the world,
player/plugin data and prepared releases. Stopping the server sends `stop`
via RCON and gives Paper up to 120 seconds to save. `restart: no` means it
will not start on reboot/Docker Desktop restart. Backups are a separate host
directory `test/staging/backups/`, ignored by Git.

## Update, rollback and backup

Always ask players to leave before stopping. These commands operate only on
the staging Compose project/volume:

```powershell
./test/staging/staging.ps1 backup    # stops Paper; archive stays in backups/
./test/staging/staging.ps1 start
./test/staging/staging.ps1 update    # stops, prepares Git-pinned release, restarts
./test/staging/staging.ps1 rollback  # restores previous release binaries/config
./test/staging/staging.ps1 restore staging-YYYYMMDDTHHMMSS.tar.gz DELETE-TEST-WORLD
./test/staging/staging.ps1 reset DELETE-TEST-WORLD # deletes the staging volume
```

`update` automatically rolls back to the previous release if the new Paper
does not answer RCON; check the logs if it does. A rollback does **not** undo
world/plugin database migrations; take a stopped-server backup before testing
a version upgrade. `restore` replaces the entire staging volume with the
specified local archive, keeps the server stopped, and requires explicit
confirmation; run `start` afterward. Backups include rendered local secrets
and player/plugin data, so keep them private. Never restore into production.
The reset command preserves the host backup directory.

## Acceptance checks

- `start` reports the LAN address and `worldborder get` over RCON reports 256.
- A whitelisted player connects from a second computer, places a block and
  disconnects; after `stop` and `start`, the block and location remain.
- An unlisted name is rejected. Only TCP 25566 is published by Compose.
- After `backup` / `update` / `rollback`, check `status` and the world contents.
- `stop` leaves no running staging container; reboot Docker Desktop and confirm
  it stays stopped until another explicit `start`.

No Ansible/systemd provisioning runs in this Docker profile. The fast suite
still exercises the production deployment controller with its `systemctl`
stub, while staging checks an actual Paper JVM and persistent world lifecycle.
