@echo off
REM docker-load-runtime.bat  (rev 2026-09-09c)
REM
REM Windows counterpart to docker-load-runtime.sh: loads a saved
REM cORIUm.jl runtime image tarball and runs it. Run this on the machine
REM that will actually execute the container (the GPU host) - see
REM docs/src/mpi.md, "Docker deployment", for the full build-vs-run story.

REM enabledelayedexpansion is REQUIRED: several variables below are both set
REM and read inside the same parenthesized if() block. Without delayed
REM expansion cmd.exe substitutes their (empty) parse-time values, which
REM previously fed empty paths to robocopy ("Parametre non valide #1" /
REM "Il manque un operande") and left the staged-copy path blank.
setlocal enabledelayedexpansion

echo [docker-load-runtime.bat rev 2026-09-09c]
echo(

set "IMAGE_NAME=ubuntu-corium"
set "STAGE=runtime"
set "IMAGE_TAG=%IMAGE_NAME%:%STAGE%"

set "SH_DIR=%~dp0"
set "DEFAULT_TAR=%SH_DIR%image\%IMAGE_NAME%-%STAGE%.tar"

set "IMAGE_TAR="
set /p "IMAGE_TAR=Path to the image tarball [%DEFAULT_TAR%]: "
if "%IMAGE_TAR%"=="" set "IMAGE_TAR=%DEFAULT_TAR%"
REM strip surrounding quotes the user may have pasted / drag-and-dropped
set "IMAGE_TAR=%IMAGE_TAR:"=%"

if not exist "%IMAGE_TAR%" (
    echo No tarball found at: %IMAGE_TAR%
    goto :fail
)

REM `docker load` on Docker Desktop reads the tarball through the WSL2 VM's
REM 9p/virtiofs bridge to the Windows filesystem, which is slow - and much
REM slower still when the tarball sits on a removable/network drive (e.g. a
REM mapped drive like G:\). For a multi-GB image that turns into minutes of
REM apparent hang, and the bridge can even fail outright with
REM "docker-import ... input/output error". Stage a local copy on the
REM system drive first (skipped if the tarball is already there) so
REM `docker load` reads from fast local disk instead.
for %%F in ("%IMAGE_TAR%") do (
    set "TAR_DRIVE=%%~dF"
    set "TAR_NAME=%%~nxF"
    set "TAR_DIR=%%~dpF"
    set "TAR_SIZE_B=%%~zF"
)
REM %%~dpF always ends with a backslash; a trailing "\" immediately before
REM the closing quote is parsed as an escaped quote by the command line
REM (robocopy then saw one mangled argument - "aucun repertoire de
REM destination specifie"). Drop it.
if defined TAR_DIR if "!TAR_DIR:~-1!"=="\" set "TAR_DIR=!TAR_DIR:~0,-1!"
if not defined TAR_SIZE_B set "TAR_SIZE_B=0"
REM set /a is 32-bit signed and overflows on multi-GB byte counts, so
REM report GB by trimming 9 decimal digits rather than dividing.
set "TAR_SIZE_GB=!TAR_SIZE_B:~0,-9!"
if not defined TAR_SIZE_GB set "TAR_SIZE_GB=<1"

if /i not "!TAR_DRIVE!"=="%SystemDrive%" (
    REM %TEMP% can itself be redirected to a network/roaming profile path on
    REM managed machines, which would defeat the whole point - stage under a
    REM known-local folder on %SystemDrive% instead.
    set "STAGE_DIR=%SystemDrive%\corium-stage"
    if not exist "!STAGE_DIR!" mkdir "!STAGE_DIR!"
    set "LOCAL_TAR=!STAGE_DIR!\%IMAGE_NAME%-%STAGE%.tar"
    echo !IMAGE_TAR! ^(~!TAR_SIZE_GB! GB^) is not on %SystemDrive% - staging a local copy at !LOCAL_TAR! first.
    echo Started at %TIME% - this can take a while and may show no output for long
    echo stretches even while it is working ^(check Task Manager's Disk tab if unsure^).
    echo Running: robocopy "!TAR_DIR!" "!STAGE_DIR!" "!TAR_NAME!" /J
    robocopy "!TAR_DIR!" "!STAGE_DIR!" "!TAR_NAME!" /J
    if errorlevel 8 (
        echo Local copy failed - loading directly from !IMAGE_TAR! instead ^(will be slower^).
    ) else (
        echo Local copy finished at %TIME%.
        set "IMAGE_TAR=!LOCAL_TAR!"
    )
)

echo(
echo Loading image from !IMAGE_TAR! ^(started %TIME%^)...
echo If this window shows no progress bars, cmd.exe is likely just not redrawing
echo docker's carriage-return progress lines - it is not necessarily stuck; run
echo this script from PowerShell instead for live progress, or check Task
echo Manager's Disk tab to confirm it is still reading.
docker load -i "!IMAGE_TAR!"
if errorlevel 1 goto :fail
echo Finished loading at %TIME%.

REM --- optional host mount for simulation output ---
REM The entrypoint/solver honor a VOLUME_MOUNT env var (see cORE!/cORES!
REM in src/home/program/workflow/cORE.jl) to redirect output under a
REM mounted host path, so it survives past the container's lifetime.
set "HOST_DIR="
set /p "HOST_DIR=Host directory to mount as simulation output (leave empty to skip): "
set "HOST_DIR=%HOST_DIR:"=%"
if not "%HOST_DIR%"=="" (
    if not exist "%HOST_DIR%" mkdir "%HOST_DIR%"
    echo Mounting %HOST_DIR% -^> /mnt/output ^(VOLUME_MOUNT^)
)

REM --- GPU access ---
set "GPU_INPUT="
set /p "GPU_INPUT=Enable GPU passthrough with --gpus all? [Y/n]: "

REM entrypoint.sh (baked into the image) regenerates LocalPreferences.toml
REM here, against whatever GPU/MPI is actually present in this container,
REM before dropping into bash. Branching into explicit docker run calls
REM below, rather than composing a quoted argument string in a variable,
REM which is unreliable in cmd.exe.
echo Starting container from %IMAGE_TAG%...

if /i "%GPU_INPUT%"=="n" (
    if "%HOST_DIR%"=="" (
        docker run -it %IMAGE_TAG%
    ) else (
        docker run -it -v "%HOST_DIR%:/mnt/output" -e VOLUME_MOUNT=/mnt/output %IMAGE_TAG%
    )
) else (
    if "%HOST_DIR%"=="" (
        docker run --gpus all -it %IMAGE_TAG%
    ) else (
        docker run --gpus all -it -v "%HOST_DIR%:/mnt/output" -e VOLUME_MOUNT=/mnt/output %IMAGE_TAG%
    )
)

goto :end

:fail
echo(
echo *** Script stopped on an error (see messages above). ***

:end
echo(
pause
endlocal
