@echo off
rem ============================================================
rem  ONE-CLICK RELEASE build (UNSIGNED HAP) for the 157 engine.
rem
rem  Double-click this file, or run it from any terminal:
rem      package-157-release.cmd
rem
rem  It calls package-157-hap.cmd with the "release" argument:
rem      buildMode  = release
rem      bundleName = com.orbira.browser   (normal production name)
rem      artifact   = artifacts\orbira-VERSION-157-unsigned.hap
rem
rem  package-157-hap.cmd with NO argument stays the DEBUG build
rem  (com.orbira.browser11). Keep this file as the only release entry point
rem  so the two package names never get mixed up.
rem
rem  Prerequisite: run scripts\package-157-stage.sh once in WSL after any
rem  engine or resource change. This script does NOT stage assets - it only
rem  rebuilds the HAP from what is already in the shared project at
rem  D:\hmos-build-157\chromium-ui.
rem
rem  The HAP is UNSIGNED (this project has no signingConfigs). Sign it with
rem  the com.orbira.browser materials before installing on a device.
rem
rem  All text here is ASCII on purpose; the file uses CRLF line endings.
rem  Set PACKAGE_NO_PAUSE=1 to skip the final key press (batch use).
rem ============================================================
setlocal EnableExtensions

echo [release] one-click RELEASE build (unsigned HAP)
echo [release] project: D:\hmos-build-157\chromium-ui
echo [release] if engine assets changed, run package-157-stage.sh in WSL first
echo.

call "%~dp0package-157-hap.cmd" release
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
  echo [release] BUILD OK - unsigned HAP archived under artifacts\
  echo            name pattern: orbira-VERSION-157-unsigned.hap
) else (
  echo [release] BUILD FAILED with exit code %RC% - see output above
)
echo.
if not defined PACKAGE_NO_PAUSE (
  echo Press any key to close this window ...
  pause >nul
)
endlocal & exit /b %RC%
