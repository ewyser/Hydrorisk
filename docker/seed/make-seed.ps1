# make-seed.ps1
#
# Windows counterpart of make-seed.sh - same flags, same output; keep the two
# in sync. Run it through make-seed.bat, which takes care of PowerShell's
# execution policy.
#
# Writes hydrorisk.sql next to this script: the dump a fresh db container
# restores as its initial database on first start (no hydrorisk_db-data
# volume yet - see docker/container/db/seed-db.sh).
#
# Usage: make-seed.bat --from-local | --from-stack
#   --from-local   dump your local Postgres. Source is configurable via env
#                  vars: SRC_HOST (localhost), SRC_PORT (5432), SRC_USER
#                  (postgres), SRC_DB (hydrorisk), and PGPASSWORD (prompted
#                  for if unset).
#   --from-stack   dump the running stack's database (hydrorisk-db), e.g. to
#                  move the deployment to another machine.
#
# Dump format and options: see make-seed.sh.
#
# Written for Windows PowerShell 5.1 and kept ASCII-only (see deploy.ps1).
# Dumps are always written by the tool itself to a file (pg_dump -f, or
# pg_dump -f inside the container + docker cp), never redirected through
# PowerShell: 5.1 re-encodes redirected native output as UTF-16.

$ErrorActionPreference = 'Stop'

$SeedFile = Join-Path $PSScriptRoot 'hydrorisk.sql'
$TmpFile  = "$SeedFile.tmp"

function Fail([string]$Message) {
    Remove-Item -LiteralPath $TmpFile -Force -ErrorAction SilentlyContinue
    Write-Host "[X] $Message" -ForegroundColor Red
    exit 1
}

# Runs a native command, discarding stderr, and returns its stdout (trimmed)
# or $null if it failed. Wrapped because under $ErrorActionPreference='Stop',
# Windows PowerShell 5.1 turns any redirected native stderr into a
# terminating error.
function Get-NativeOutput([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Command 2>$null } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($out | Out-String).Trim()
}

# Finds pg_dump: on PATH, or else the newest version installed by the
# EnterpriseDB Postgres installer (which doesn't add itself to PATH).
function Find-PgDump {
    $cmd = Get-Command pg_dump -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(Get-ChildItem -Path "$env:ProgramFiles\PostgreSQL\*\bin\pg_dump.exe" -ErrorAction SilentlyContinue |
        Sort-Object { [int]($_.Directory.Parent.Name -replace '\D.*$', '') } -Descending)
    if ($candidates.Count -gt 0) { return $candidates[0].FullName }
    return $null
}

function Format-Size([long]$Bytes) {
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

if ($args.Count -ne 1 -or ($args[0] -ne '--from-local' -and $args[0] -ne '--from-stack')) {
    Write-Host 'Usage: make-seed.bat --from-local | --from-stack'
    exit 1
}

if ($args[0] -eq '--from-local') {
    $pgDump = Find-PgDump
    if (-not $pgDump) { Fail 'pg_dump not found - install the PostgreSQL client tools, or add their bin\ folder to PATH.' }
    $srcHost = if ($env:SRC_HOST) { $env:SRC_HOST } else { 'localhost' }
    $srcPort = if ($env:SRC_PORT) { $env:SRC_PORT } else { '5432' }
    $srcUser = if ($env:SRC_USER) { $env:SRC_USER } else { 'postgres' }
    $srcDb   = if ($env:SRC_DB)   { $env:SRC_DB }   else { 'hydrorisk' }

    if (-not $env:PGPASSWORD) {
        $secure = Read-Host "Local Postgres password ('$srcUser'@'${srcHost}:$srcPort')" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $env:PGPASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    Write-Host "-> Dumping '$srcDb' from ${srcHost}:$srcPort (user $srcUser)..."
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $pgDump -h $srcHost -p $srcPort -U $srcUser -d $srcDb -Fp --no-owner --no-privileges -f $TmpFile
    } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { Fail 'pg_dump failed - is your local Postgres running?' }
} else {
    # Same database name the stack uses (DB_NAME in deploy\.env).
    $dbName = 'hydrorisk'
    $envFile = Join-Path $PSScriptRoot '..\deploy\.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^\s*DB_NAME\s*=\s*(.*?)\s*$' -and $Matches[1]) { $dbName = $Matches[1].Trim('"', "'") }
        }
    }

    $running = Get-NativeOutput { docker ps --format '{{.Names}}' }
    if (-not (($running -split "`r?`n") -contains 'hydrorisk-db')) {
        Fail 'hydrorisk-db is not running - start the stack first (deploy\deploy.bat).'
    }

    # pg_dump runs inside the db container (version always matches the
    # server, nothing to install on the host) and writes a file there, which
    # docker cp then copies out byte-for-byte.
    Write-Host "-> Dumping '$dbName' from the running hydrorisk-db..."
    docker exec hydrorisk-db pg_dump -U postgres -d $dbName -Fp --no-owner --no-privileges -f /tmp/hydrorisk-seed.sql
    if ($LASTEXITCODE -ne 0) { Fail 'pg_dump inside hydrorisk-db failed.' }
    docker cp hydrorisk-db:/tmp/hydrorisk-seed.sql $TmpFile
    $cpCode = $LASTEXITCODE
    Get-NativeOutput { docker exec hydrorisk-db rm -f /tmp/hydrorisk-seed.sql } | Out-Null
    if ($cpCode -ne 0) { Fail 'Copying the dump out of hydrorisk-db failed.' }
}

Move-Item -LiteralPath $TmpFile -Destination $SeedFile -Force
Write-Host "[OK] Seed written: docker\seed\hydrorisk.sql ($(Format-Size (Get-Item -LiteralPath $SeedFile).Length))." -ForegroundColor Green
exit 0
