# deploy.ps1
#
# Windows counterpart of deploy.sh - same steps, same prompts, same flags;
# keep the two in sync. Run it through deploy.bat (double-click, or
# `deploy.bat [--reload]` from a terminal), which takes care of
# PowerShell's execution policy.
#
# One-command entry point for the whole stack: makes sure .env exists,
# checks that the first-start seed (docker\seed\hydrorisk.sql) exists when
# the database volume doesn't exist yet, loads each image tarball from
# .\images\ whose image isn't already in the local Docker daemon, brings
# db+api up (and daemon, if asked for), then waits for db to be healthy and
# api to actually accept connections before returning.
#
# Usage: deploy.bat [--reload]
#   --reload   always (re)load every images\*.tar, even if the loaded images
#              already match them. Without it, only tarballs whose image
#              differs from (or is missing in) the local Docker daemon are
#              loaded - freshly built tarballs are picked up on their own.
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

# Windows' own bsdtar (Windows 10 1803+), by full path: a GNU tar from Git
# for Windows earlier on PATH would read "E:\..." as a remote host "E:".
$TarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

# Reads a tarball's small index.json/manifest.json and returns its tag
# (e.g. hydrorisk-db:latest) and the image IDs it can have once loaded
# (without the sha256: prefix): the index digest (containerd image store,
# e.g. Docker Desktop's default) and the config digest (classic image
# store). tar seeks past the layers, so this is instant even for multi-GB
# tarballs. $null if it can't be read (no tar.exe, unexpected format).
function Get-TarImageInfo([string]$Tar) {
    if (-not (Test-Path -LiteralPath $TarExe)) { return $null }
    $manifest = Get-NativeOutput { & $TarExe -xOf $Tar manifest.json }
    if (-not $manifest) { return $null }
    $index = Get-NativeOutput { & $TarExe -xOf $Tar index.json }
    $ids = @([regex]::Matches("$index $manifest", '(?:"digest":"sha256:|"Config":"[^"]*?)([0-9a-f]{64})') |
        ForEach-Object { $_.Groups[1].Value })
    $tag = $null
    if ($manifest -match '"RepoTags":\["([^"]+)"') { $tag = $Matches[1] }
    if (-not $tag) { return $null }
    return @{ Tag = $tag; Ids = $ids }
}

# Loads each image tarball in .\images\ into the local Docker daemon, so
# docker-compose.yml's `image:` references resolve without a `build:` step -
# but only the ones whose image isn't already loaded (unless --reload). An
# image a load replaces is remembered in $ReplacedImages and removed once
# the stack runs on the new one.
#
# Skips macOS "._*" AppleDouble files, which a Mac leaves next to every file
# it copies onto an exFAT/FAT external drive: "._hydrorisk-api.tar" matches
# *.tar but isn't an image, and docker load fails on it.
$ReplacedImages = @()
function Sync-Images {
    $tars = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'images') -Filter '*.tar' -File -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith('._') })
    if ($tars.Count -eq 0) {
        Fail 'No .tar files found in images\ - build the images first (on a Unix machine: docker/container/{db,api,daemon}/docker-build.sh).'
    }
    foreach ($tar in $tars) {
        $info = Get-TarImageInfo $tar.FullName
        $current = $null
        if ($info) {
            $current = Get-NativeOutput { docker image inspect --format '{{.Id}}' $info.Tag }
        }
        if (-not $Reload -and $current) {
            if ($info.Ids -contains ($current -replace '^sha256:', '')) {
                Write-Host "$($info.Tag) is up to date."
                continue
            }
            Write-Host "$($info.Tag) differs from $($tar.Name) - replacing it."
        }
        Write-Host "Loading $($tar.Name)..."
        docker load -i $tar.FullName
        if ($LASTEXITCODE -ne 0) { Fail "docker load failed for $($tar.Name)." }
        if ($current) { $script:ReplacedImages += $current }
    }

    foreach ($img in 'hydrorisk-db:latest', 'hydrorisk-api:latest', 'hydrorisk-daemon:runtime') {
        if ((Test-Native { docker image inspect $img }) -ne 0) {
            Fail "$img is neither loaded nor in any images\*.tar - build it first (docker/container/*/docker-build.sh)."
        }
    }
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

# Runs $Check (a sh command line) in a throwaway container with $HostDir
# bind-mounted at /probe, exactly like docker-compose.yml's own bind mounts,
# and returns its exit code. A host folder Docker can't actually see (e.g.
# an external drive plugged in after Docker Desktop started) doesn't make
# the mount fail - it shows up empty - so this is the only reliable check.
# hydrorisk-db's image is used just for its sh; its entrypoint is bypassed.
function Test-DockerMount([string]$HostDir, [string]$Check) {
    return Test-Native { docker run --rm --mount "type=bind,source=$HostDir,target=/probe" --entrypoint sh hydrorisk-db:latest -c $Check }
}

function Write-DockerMountHint {
    Write-Host '    Docker cannot see this folder. If it is on an external drive: plug the drive in,'
    Write-Host '    restart Docker Desktop (or run "wsl --shutdown"), then run deploy.bat again -'
    Write-Host '    or copy the Hydrorisk folder to a local disk (e.g. C:\) and deploy from there.'
}

# Prints db's seed-db lines, i.e. whether the first-start seed was restored
# and if not, why.
function Show-SeedLog {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $log = @(docker logs hydrorisk-db 2>&1 | ForEach-Object { "$_" }) } finally { $ErrorActionPreference = $prev }
    $lines = @($log | Where-Object { $_ -match 'seed-db' })
    if ($lines.Count -gt 0) {
        Write-Host 'Seed (docker compose logs db):'
        $lines | ForEach-Object { Write-Host "    $_" }
    }
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

$DbVolume  = 'hydrorisk_db-data'   # compose project "hydrorisk" + volume "db-data"
$SeedDir   = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\seed'))
$SeedFile  = Join-Path $SeedDir 'hydrorisk.sql'
$DaemonDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\volume\daemon-data'))

# First start (no db-data volume yet): the db container restores the seed as
# the initial database. Without one, the database would start empty (no
# users, every client gets 401) - so refuse to start at all, before the
# (slow) image loading below. See deploy.sh.
$FirstStart = (Test-Native { docker volume inspect $DbVolume }) -ne 0
if ($FirstStart) {
    if (-not (Test-Path -LiteralPath $SeedFile)) {
        Write-Host "[X] First start (no $DbVolume volume yet), but no seed at docker\seed\hydrorisk.sql." -ForegroundColor Red
        Write-Host '    Create it first: docker\seed\make-seed.bat --from-local  (or --from-stack on the source machine).'
        exit 1
    }
    $item = Get-Item -LiteralPath $SeedFile
    # Dropbox/OneDrive "online-only" placeholder: exists for Test-Path, but
    # its content is only downloaded when Windows itself opens the file -
    # not when Docker reads it through a bind mount.
    # Compared as plain ints: RECALL_ON_DATA_ACCESS isn't a member of
    # .NET Framework's [IO.FileAttributes], so it can't be cast to one.
    $cloudOnly = 0x1000 -bor 0x400000   # OFFLINE | RECALL_ON_DATA_ACCESS
    if (([int]$item.Attributes) -band $cloudOnly) {
        Fail 'docker\seed\hydrorisk.sql is an online-only cloud placeholder - make it "available offline" (Dropbox/OneDrive), then re-run.'
    }
    if ($item.Length -eq 0) {
        Fail 'docker\seed\hydrorisk.sql is empty - copy it again (or recreate it with docker\seed\make-seed.bat).'
    }
    Write-Host "First start - the database will be seeded from docker\seed\hydrorisk.sql ($(Format-Size $item.Length), $($item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))."
}

Write-Host '-- Images --'
Sync-Images

# The seed existing on this machine isn't enough - the db container must
# see it through the ../seed bind mount too, or it starts without it.
if ($FirstStart) {
    if ((Test-DockerMount $SeedDir 'test -s /probe/hydrorisk.sql') -ne 0) {
        Write-Host "[X] docker\seed\hydrorisk.sql exists, but a container mounting $SeedDir doesn't see it." -ForegroundColor Red
        Write-DockerMountHint
        exit 1
    }
}

Write-Host ''
$withDaemon = Read-Host 'Also start daemon? (needs a GPU, or falls back to CPU) [y/N]'

# daemon's output goes to ..\volume\daemon-data (bind mount) - check that
# what the container writes there actually lands in this folder.
New-Item -ItemType Directory -Force -Path $DaemonDir | Out-Null
if (Test-Yes $withDaemon) {
    $probe = Join-Path $DaemonDir '.docker-probe'
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    $null = Test-DockerMount $DaemonDir 'touch /probe/.docker-probe'
    if (-not (Test-Path -LiteralPath $probe)) {
        Write-Host "[X] A container mounting $DaemonDir can't write into it - daemon output wouldn't reach volume\." -ForegroundColor Red
        Write-DockerMountHint
        exit 1
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}
# --pull never: these images only ever come from images\*.tar, never a
# registry - a missing image should fail as such, not as "pull access denied".
# --wait: return only once db and api are healthy (daemon: running) - api's
# healthcheck (docker-compose.yml) passes once it really answers HTTP, so
# compose shows it as "Waiting" until then instead of an early "Started".
$composeArgs = @('up', '-d', '--pull', 'never', '--wait', '--wait-timeout', '900')
if (Test-Yes $withDaemon) {
    $composeArgs = @('--profile', 'daemon') + $composeArgs
    # Give daemon the GPU (docker-compose.gpu.yml) only when the host has a
    # working NVIDIA one - requesting it on a host without makes Docker
    # refuse to create the container. Docker Desktop needs this explicit
    # request; NVIDIA_VISIBLE_DEVICES alone gives the container no GPU.
    if ((Get-Command nvidia-smi -ErrorAction SilentlyContinue) -and ((Test-Native { nvidia-smi -L }) -eq 0)) {
        Write-Host 'NVIDIA GPU found - daemon gets GPU access (docker-compose.gpu.yml).'
        $composeArgs = @('-f', 'docker-compose.yml', '-f', 'docker-compose.gpu.yml') + $composeArgs
    } else {
        Write-Host 'No NVIDIA GPU found on this host - daemon runs on CPU.'
    }
}

Write-Host ''
Write-Host '-- Starting containers --'
docker compose @composeArgs
if ($LASTEXITCODE -ne 0) {
    Show-SeedLog
    $apiState = Get-NativeOutput { docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' hydrorisk-api }
    if (-not $apiState) { $apiState = 'not created' }
    Write-Host "[X] The stack did not become healthy (api: $apiState). Last api log lines:" -ForegroundColor Red
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { docker logs --tail 20 hydrorisk-api 2>&1 | ForEach-Object { Write-Host "    $_" } } finally { $ErrorActionPreference = $prev }
    Write-Host '    More: docker compose logs api  (and: docker compose logs db)'
    exit 1
}

Write-Host "[OK] Stack is up. API: http://localhost:$ApiPort/  -  DB: localhost:$DbPort" -ForegroundColor Green
docker compose ps

# Images replaced by Sync-Images above: the recreated containers now run on
# the new ones, so the old ones are just disk space. One still used by a
# container (e.g. a daemon not started this time) stays - rm refuses it.
foreach ($id in $ReplacedImages) {
    if ((Test-Native { docker image rm $id }) -eq 0) { Write-Host "Removed replaced image $($id.Substring(7, 12))." }
}

if ($FirstStart) {
    Write-Host ''
    Show-SeedLog
}

# Started without a seed (or on an old volume that never got data), the
# database only has Datastore.jl's empty schemas - no users, so every client
# request is answered 401. A failed query (e.g. core.users missing) is just
# as bad. Say so, and offer the way out: once the db-data volume exists the
# seed is never read again, so reseeding means removing it.
$userCount = Get-NativeOutput { docker exec hydrorisk-db psql -U postgres -d $DbName -Atc 'select count(*) from core.users' }
if ($userCount -eq '0' -or $null -eq $userCount) {
    Write-Host ''
    if ($null -eq $userCount) {
        Write-Host "[!] Could not read users from database '$DbName' - clients will likely get 401 Unauthorized." -ForegroundColor Yellow
    } else {
        Write-Host "[!] Database '$DbName' has no users - clients will get 401 Unauthorized." -ForegroundColor Yellow
    }
    if (-not $FirstStart) {
        Write-Host "    The $DbVolume volume already existed, so docker\seed\hydrorisk.sql was not read."
    }
    Show-SeedLog
    if ((Test-Path -LiteralPath $SeedFile) -and (Get-Item -LiteralPath $SeedFile).Length -gt 0) {
        $reset = Read-Host "Delete the database volume ($DbVolume) now, to reseed from docker\seed\hydrorisk.sql on the next run? [y/N]"
        if (Test-Yes $reset) {
            docker compose --profile daemon down
            if ($LASTEXITCODE -ne 0) { Fail 'docker compose down failed.' }
            docker volume rm $DbVolume
            if ($LASTEXITCODE -ne 0) { Fail "docker volume rm $DbVolume failed." }
            Write-Host "[OK] $DbVolume removed - run deploy.bat again to start with the seed." -ForegroundColor Green
            exit 0
        }
    }
    Write-Host "    To reseed: docker compose down; docker volume rm $DbVolume; then run deploy.bat again."
}

# daemon's entrypoint warns (and keeps output inside the container) when the
# volume\ mount isn't writable for its user - surface that here.
if (Test-Yes $withDaemon) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $daemonLog = (docker logs hydrorisk-daemon 2>&1 | Out-String) } finally { $ErrorActionPreference = $prev }
    if ($daemonLog -match 'not writable by mpiuser') {
        Write-Host ''
        Write-Host "[!] daemon can't write to $DaemonDir - its output stays inside the container. See: docker compose logs daemon" -ForegroundColor Yellow
    }
}
