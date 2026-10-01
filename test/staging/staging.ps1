param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('start', 'stop', 'status', 'logs', 'allow', 'update', 'rollback', 'backup', 'restore', 'reset')]
    [string]$Action,
    [Parameter(Position = 1)]
    [string]$Player,
    [Parameter(Position = 2)]
    [string]$Confirmation
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$envFile = Join-Path $PSScriptRoot 'staging.env'
$composeFile = Join-Path $PSScriptRoot 'compose.yml'
if (-not (Test-Path -LiteralPath $envFile)) {
    throw "Create $envFile from staging.env.example with your LAN IPv4 and unique local passwords."
}
$config = @{}
foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
    if ($line -match '^\s*([A-Z_]+)=(.*)$') { $config[$matches[1]] = $matches[2] }
}
foreach ($key in @('STAGING_BIND_IP', 'STAGING_RCON_PASSWORD', 'STAGING_MANAGEMENT_SECRET', 'STAGING_AUTHME_PASSWORD')) {
    if (-not $config[$key] -or $config[$key] -match '^replace-') { throw "Set $key in staging.env." }
}
$address = $null
if (-not [System.Net.IPAddress]::TryParse($config['STAGING_BIND_IP'], [ref]$address) -or
    $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
    $address.ToString() -eq '0.0.0.0' -or $address.ToString().StartsWith('127.')) {
    throw 'STAGING_BIND_IP must be the Windows computer LAN IPv4, not localhost or 0.0.0.0.'
}
$compose = @('compose', '--env-file', $envFile, '-f', $composeFile)

function Invoke-Compose {
    & docker @compose @args
    if ($LASTEXITCODE -ne 0) { throw "Docker Compose failed (exit $LASTEXITCODE)." }
}

function Stop-Server {
    $ErrorActionPreference = 'Continue'
    & docker @compose exec -T paper /opt/minecraft/bin/rcon-command.py stop 2>$null
    $ErrorActionPreference = 'Stop'
    # Paper saves its players and dimensions during graceful shutdown.
    Invoke-Compose stop -t 120 paper
}

function Start-Server {
    Invoke-Compose up -d --build paper
    $ready = $false
    for ($attempt = 0; $attempt -lt 150; $attempt++) {
        $ErrorActionPreference = 'Continue'
        & docker @compose exec -T paper /opt/minecraft/bin/rcon-command.py list 2>$null | Out-Null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        $running = & docker @compose ps --status running -q paper
        if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect staging container state.' }
        if (-not $running) { throw 'Paper exited before RCON became ready. Inspect staging logs.' }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'Paper did not answer RCON within 5 minutes. Inspect staging logs.' }
    Invoke-Compose exec -T paper /opt/minecraft/bin/rcon-command.py 'worldborder center 0 0'
    Invoke-Compose exec -T paper /opt/minecraft/bin/rcon-command.py 'worldborder set 256'
    Invoke-Compose exec -T paper /opt/minecraft/bin/rcon-command.py 'whitelist on'
    # Seed the staging whitelist on every start without replacing manually added players.
    Invoke-Compose exec -T paper /opt/minecraft/bin/rcon-command.py 'whitelist add Chest3rf1eld'
    "Staging is available at $($config['STAGING_BIND_IP']):25566 (LAN only)."
}

function Maintain-Release([string]$Operation) {
    Stop-Server
    $switched = $false
    try {
        if ($Operation -eq 'update') { Invoke-Compose build paper }
        Invoke-Compose run --rm --no-deps paper $Operation
        $switched = $true
        Start-Server
    } catch {
        $failure = $_
        if ($Operation -eq 'update') {
            # A failed build/prepare leaves the old release selected; a failed
            # startup after switching needs the previous release restored.
            if ($switched) {
                Stop-Server
                Invoke-Compose run --rm --no-deps paper rollback
            }
            Start-Server
        }
        throw $failure
    }
}

switch ($Action) {
    'start' { Start-Server }
    'stop' { Stop-Server }
    'status' { Invoke-Compose ps }
    'logs' { Invoke-Compose logs --tail 100 -f paper }
    'allow' {
        if ($Player -cnotmatch '^[A-Za-z0-9_]{3,16}$') { throw 'Usage: staging.ps1 allow MinecraftPlayerName' }
        Invoke-Compose exec -T paper /opt/minecraft/bin/rcon-command.py "whitelist add $Player"
    }
    'update' { Maintain-Release 'update' }
    'rollback' { Maintain-Release 'rollback' }
    'backup' {
        Stop-Server
        $name = 'staging-' + (Get-Date -Format 'yyyyMMddTHHmmss') + '.tar.gz'
        Invoke-Compose run --rm --no-deps --entrypoint tar paper -czf "/backups/$name" -C /srv/minecraft .
        "Backup: $(Join-Path $PSScriptRoot "backups/$name")"
    }
    'restore' {
        if ($Player -cnotmatch '^staging-\d{8}T\d{6}\.tar\.gz$' -or $Confirmation -cne 'DELETE-TEST-WORLD') {
            throw 'Usage: staging.ps1 restore staging-YYYYMMDDTHHMMSS.tar.gz DELETE-TEST-WORLD'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot "backups/$Player"))) {
            throw "Backup $Player not found."
        }
        Stop-Server
        Invoke-Compose down --volumes
        Invoke-Compose run --rm --no-deps --entrypoint tar paper -xzf "/backups/$Player" -C /srv/minecraft
        # The archive was unpacked by root, but Paper itself runs as minecraft.
        Invoke-Compose run --rm --no-deps --entrypoint chown paper -R minecraft:minecraft /srv/minecraft
        'Staging backup restored; run start to launch Paper.'
    }
    'reset' {
        if ($Player -cne 'DELETE-TEST-WORLD') { throw 'Usage: staging.ps1 reset DELETE-TEST-WORLD (deletes all staging world data)' }
        Stop-Server
        Invoke-Compose down --volumes
        'Staging world deleted. Backups in test/staging/backups remain.'
    }
}
