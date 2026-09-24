# deploy.ps1
#
# Windows counterpart of deploy.sh - same steps, same prompts, same flags;
# keep the two in sync. Run it through deploy.bat (double-click, or
# `deploy.bat [--reload]` from a terminal), which takes care of
# PowerShell's execution policy.
#
# One-command entry point for the whole stack: makes sure .env exists,
# checks that the first-start seed (docker\seed\hydrorisk.sql) exists when
# the database volume doesn't exist yet, loads image tarballs from .\images\
# if they aren't already in the local Docker daemon, brings db+api up (and
# daemon, if asked for), then waits for db to be healthy and api to actually
# accept connections before returning.
#
# Usage: deploy.bat [--reload]
#   --reload   always (re)load every images\*.tar, even if images with the
#              same tags already exist locally.
#
# Deploying never creates the seed - that's a separate, earlier step:
# docker\seed\make-seed.bat --from-local | --from-stack.
#
# Written for Windows PowerShell 5.1 (preinstalled on Windows 10/11) and
# kept ASCII-only: 5.1 reads BOM-less scripts in the legacy ANSI code page,
# which would garble any emoji/box-drawing characters.

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# Same --flag spelling as deploy.sh (not PowerShell-style -Switch params), so
# the docs and muscle memory are identical on both platforms.
$Reload = $false
foreach ($arg in $args) {
    switch ($arg) {
        '--reload' { $Reload = $true }
        default {
            Write-Host 'Usage: deploy.bat [--reload]'
            exit 1
        }
    }
}

function Fail([string]$Message) {
    Write-Host "[X] $Message" -ForegroundColor Red
    exit 1
}

# Runs a native command with stderr discarded and returns its exit code.
# Wrapped because under $ErrorActionPreference='Stop', Windows PowerShell
# 5.1 turns any native stderr output into a terminating error.
function Test-Native([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>$null | Out-Null } finally { $ErrorActionPreference = $prev }
    return $LASTEXITCODE
}

# Same, but returns the command's stdout (trimmed), or $null if it failed.
function Get-NativeOutput([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Command 2>$null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Out-String).Trim()
}

function Test-Yes([string]$Answer) { return $Answer -match '^[Yy]$' }

# Loads every image tarball in .\images\ into the local Docker daemon, so
# docker-compose.yml's `image:` references resolve without a `build:` step.
function Import-Images {
    $tars = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'images') -Filter '*.tar' -File -ErrorAction SilentlyContinue)
    if ($tars.Count -eq 0) {
        Fail 'No .tar files found in images\ - build the images first (on a Unix machine: docker/container/{db,api,daemon}/docker-build.sh).'
    }
    foreach ($tar in $tars) {
        Write-Host "Loading $($tar.Name)..."
        docker load -i $tar.FullName
        if ($LASTEXITCODE -ne 0) { Fail "docker load failed for $($tar.Name)." }
    }
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

if (-not (Test-Path -LiteralPath '.env')) {
    Write-Host 'No .env found - copying .env.example to .env.'
    Copy-Item '.env.example' '.env'
    Fail 'Edit .env (set POSTGRES_PASSWORD at least), then re-run this script.'
}
# docker compose loads .env on its own; read here too so this script's own
# messages reflect the same values instead of their hardcoded defaults.
$cfg = @{}
foreach ($line in Get-Content -LiteralPath '.env') {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        $cfg[$Matches[1]] = $Matches[2].Trim('"', "'")
    }
}
$DbName  = if ($cfg['DB_NAME'])       { $cfg['DB_NAME'] }       else { 'hydrorisk' }
$ApiPort = if ($cfg['API_HOST_PORT']) { $cfg['API_HOST_PORT'] } else { '8001' }
$DbPort  = if ($cfg['DB_HOST_PORT'])  { $cfg['DB_HOST_PORT'] }  else { '5433' }

$DbVolume = 'hydrorisk_db-data'   # compose project "hydrorisk" + volume "db-data"
$SeedFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\seed\hydrorisk.sql'))

# First start (no db-data volume yet): the db container restores the seed as
# the initial database. Without one, the database would start empty (no
# users, every client gets 401) - so refuse to start at all, before the
# (slow) image loading below. See deploy.sh.
if ((Test-Native { docker volume inspect $DbVolume }) -ne 0) {
    if (-not (Test-Path -LiteralPath $SeedFile)) {
        Write-Host "[X] First start (no $DbVolume volume yet), but no seed at docker\seed\hydrorisk.sql." -ForegroundColor Red
        Write-Host '    Create it first: docker\seed\make-seed.bat --from-local  (or --from-stack on the source machine).'
        exit 1
    }
    $item = Get-Item -LiteralPath $SeedFile
    Write-Host "First start - the database will be seeded from docker\seed\hydrorisk.sql ($(Format-Size $item.Length), $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))."
}

# Unless --reload, only load from images\*.tar if at least one of the three
# images isn't already present locally.
if ($Reload) {
    Write-Host '-- Reloading images --'
    Import-Images
} else {
    $needLoad = $false
    foreach ($img in 'hydrorisk-db:latest', 'hydrorisk-api:latest', 'hydrorisk-daemon:runtime') {
        if ((Test-Native { docker image inspect $img }) -ne 0) { $needLoad = $true }
    }
    if ($needLoad) {
        Write-Host "One or more images aren't loaded locally yet."
        Import-Images
    }
}

Write-Host ''
$withDaemon = Read-Host 'Also start daemon? (needs a GPU, or falls back to CPU) [y/N]'
# --pull never: these images only ever come from images\*.tar, never a
# registry - a missing image should fail as such, not as "pull access denied".
$composeArgs = @('up', '-d', '--pull', 'never')
if (Test-Yes $withDaemon) {
    $composeArgs = @('--profile', 'daemon') + $composeArgs
}

Write-Host ''
Write-Host '-- Starting containers --'
docker compose @composeArgs
if ($LASTEXITCODE -ne 0) { Fail 'docker compose up failed.' }

# db's healthcheck already gates api's startup (depends_on:
# service_healthy) - this just waits for api's published port to accept
# connections too.
Write-Host ''
Write-Host -NoNewline 'Waiting for the API to accept connections...'
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', [int]$ApiPort)
        $ready = $true
    } catch {
        # not accepting connections yet
    } finally {
        $client.Close()
    }
    if ($ready) { break }
    Write-Host -NoNewline '.'
    Start-Sleep -Seconds 1
}
Write-Host ''
if (-not $ready) { Fail 'API did not become ready in time. Check: docker compose logs api' }

Write-Host "[OK] Stack is up. API: http://localhost:$ApiPort/  -  DB: localhost:$DbPort" -ForegroundColor Green
docker compose ps

# Started without a seed (or on an old volume that never got data), the
# database only has Datastore.jl's empty schemas - no users, so every client
# request is answered 401. Say so, with the way out.
$userCount = Get-NativeOutput { docker exec hydrorisk-db psql -U postgres -d $DbName -Atc 'select count(*) from core.users' }
if ($userCount -eq '0') {
    Write-Host ''
    Write-Host "[!] Database '$DbName' has no users - clients will get 401 Unauthorized." -ForegroundColor Yellow
    # A failed first-start seed leaves exactly this state (see deploy.sh).
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $dbLog = (docker logs hydrorisk-db 2>&1 | Out-String) } finally { $ErrorActionPreference = $prev }
    if ($dbLog -match 'seed-db: restoring .* failed') {
        Write-Host '    The seed restore failed on first start - see: docker compose logs db'
    }
    Write-Host "    To reseed: docker compose down; docker volume rm $DbVolume; then run deploy.bat again."
}
