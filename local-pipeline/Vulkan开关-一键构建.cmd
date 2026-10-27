@echo off
rem ===========================================================================
rem  HarmonyOS Chrome - "Vulkan toggle" one-click builder (Windows entry point)
rem
rem  Double-click this file. All logic lives in vulkan-toggle-build.ps1 next to it.
rem
rem  This .cmd is intentionally 100%% ASCII-only:
rem    cmd.exe parses batch files with the OEM codepage, so any non-ASCII text in
rem    here would be garbled. Chinese output comes from the .ps1 (UTF-8 with BOM).
rem    chcp 65001 is set so the WSL-side script's Chinese stdout renders correctly.
rem
rem  Optional args are forwarded, e.g.:
rem     <this script> -Jobs 6
rem     <this script> -BackupOnly
rem     <this script> -SkipEngine
rem     <this script> -EngineOnly
rem ===========================================================================

chcp 65001 >nul 2>&1
title Vulkan Toggle - One-Click Build
setlocal

set "PS1=%~dp0vulkan-toggle-build.ps1"
if not exist "%PS1%" (
    echo.
    echo [ERROR] PowerShell script not found:
    echo         %PS1%
    echo.
    pause
    exit /b 1
)

set "PS_EXE=powershell.exe"
where pwsh.exe >nul 2>&1 && set "PS_EXE=pwsh.exe"

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo [DONE] All checks passed.
) else (
    echo [FAILED] exit code %RC%  -  copy the output above and send it to the assistant.
)
echo.
echo Press any key to close this window...
pause >nul
endlocal
exit /b %RC%
