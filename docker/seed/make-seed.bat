@echo off
rem make-seed.bat - Windows launcher for make-seed.sh, run through WSL (Docker
rem Desktop on Windows runs on WSL 2 anyway).
rem Usage: make-seed.bat --from-local   or   make-seed.bat --from-stack
rem
rem All logic lives in make-seed.sh - this file only checks that WSL can run
rem it, then hands over. "%~dp0." (not "%~dp0"): a trailing backslash
rem before the closing quote would escape it.
setlocal
set "SCRIPT=make-seed.sh"

wsl --exec bash -c "exit 0" >nul 2>&1
if errorlevel 1 (
    echo [X] No WSL Linux distribution with bash found. One-time setup:
    echo       1. In a terminal: wsl --install -d Ubuntu   ^(then create a user when asked^)
    echo       2. Docker Desktop ^> Settings ^> Resources ^> WSL integration: enable Ubuntu
    echo     Then run this again.
    set "RC=1"
    goto :end
)
wsl --exec bash -c "command -v docker" >nul 2>&1
if errorlevel 1 (
    echo [X] WSL works, but has no docker command. One-time setup:
    echo       Docker Desktop ^> Settings ^> Resources ^> WSL integration: enable your distribution
    echo       ^(and make sure Docker Desktop is running^). Then run this again.
    set "RC=1"
    goto :end
)

wsl --cd "%~dp0." --exec bash "./%SCRIPT%" %*
set "RC=%ERRORLEVEL%"

:end
rem When started by double-click (Explorer runs "cmd /c <this file>"),
rem keep the window open so the output can still be read.
echo %CMDCMDLINE% | find /i "/c" >nul && pause

exit /b %RC%
