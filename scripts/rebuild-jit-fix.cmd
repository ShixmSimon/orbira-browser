@echo off
rem ============================================================
rem  Incremental rebuild for the JIT probe fix, then stage + package.
rem
rem  Changed file (single .cc):
rem    arkweb/ohos_nweb/src/aura_shell/ohos_chrome_main_runner.cc
rem  Added a 1MiB fallback JIT probe, so a failed 256MiB CodeRange
rem  reservation no longer forces --jitless (which turned V8 into the
rem  interpreter and made heavy-JS pages load slowly and scroll janky).
rem
rem  Expect MINUTES, not hours: only that one translation unit is
rem  recompiled, then the three .so files are relinked.
rem  Watch ninja's [done/total]: a few dozen targets means the
rem  incremental cache is intact; tens of thousands means it is not.
rem
rem  Run from a normal Windows terminal where WSL works. This script
rem  cd's into the repo first and calls WSL with relative paths, so the
rem  non-ASCII folder name never crosses the cmd -> wsl boundary.
rem ============================================================
setlocal EnableExtensions
cd /d "%~dp0.."

echo [1/3] incremental engine build (ninja)...
wsl bash scripts/build-157-now.sh
if errorlevel 1 goto :fail

echo.
echo [2/3] staging .so into the Windows HAP project...
wsl bash scripts/package-157-stage.sh
if errorlevel 1 goto :fail

echo.
echo [3/3] packaging unsigned HAP...
call "%~dp0package-157-hap.cmd"
if errorlevel 1 goto :fail

echo.
echo === ALL DONE ===
echo HAP: artifacts\orbira-1.2.0-157-debug-unsigned.hap
exit /b 0

:fail
echo.
echo [FAILED] see the output above.
exit /b 1
