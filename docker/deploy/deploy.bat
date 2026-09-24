@echo off
rem deploy.bat - Windows launcher for deploy.ps1 (the Windows counterpart
rem of deploy.sh). Usage: deploy.bat [--reload]
rem
rem -ExecutionPolicy Bypass applies to this one invocation only, so the
rem script runs without changing the machine's PowerShell policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
set "RC=%ERRORLEVEL%"

rem When started by double-click (Explorer runs "cmd /c <this file>"),
rem keep the window open so the output can still be read.
echo %CMDCMDLINE% | find /i "/c" >nul && pause

exit /b %RC%
