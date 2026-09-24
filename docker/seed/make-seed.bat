@echo off
rem make-seed.bat - Windows launcher for make-seed.ps1 (the Windows
rem counterpart of make-seed.sh).
rem Usage: make-seed.bat --from-local   or   make-seed.bat --from-stack
rem
rem -ExecutionPolicy Bypass applies to this one invocation only, so the
rem script runs without changing the machine's PowerShell policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-seed.ps1" %*
set "RC=%ERRORLEVEL%"

rem When started by double-click (Explorer runs "cmd /c <this file>"),
rem keep the window open so the output can still be read.
echo %CMDCMDLINE% | find /i "/c" >nul && pause

exit /b %RC%
